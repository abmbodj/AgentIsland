//! E2E: the real island-hook binary → local socket → headless core.
use island_core::server::{Config, Core};
use serde_json::Value;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

fn fixture(name: &str) -> Value {
    let p = format!("{}/../../fixtures/claude/{name}.json", env!("CARGO_MANIFEST_DIR"));
    serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
}

struct Harness {
    core: Core,
    sock: PathBuf,
    snapshots: Arc<Mutex<Vec<Value>>>,
}

fn start(name: &str) -> Harness {
    let dir = std::env::temp_dir().join(format!("isl-e2e-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let sock = dir.join("s.sock");
    let snapshots = Arc::new(Mutex::new(vec![]));
    let sink = snapshots.clone();
    let core = Core::start(
        Config { support_dir: dir.join("support"), home: dir.join("home"), socket: Some(sock.clone()), hook_source: None },
        Box::new(move |json: String| sink.lock().unwrap().push(serde_json::from_str(&json).unwrap())),
    )
    .unwrap();
    Harness { core, sock, snapshots }
}

impl Harness {
    /// Run the hook binary like Claude Code would; returns (stdout, elapsed).
    fn hook(&self, fixture_name: &str, payload_patch: Value) -> (String, Duration) {
        let f = fixture(fixture_name);
        let mut payload = f["payload"].clone();
        for (k, v) in payload_patch.as_object().unwrap() {
            payload[k] = v.clone();
        }
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_island-hook"));
        cmd.arg("claude").env_clear().env("ISLAND_SOCKET", &self.sock);
        for (k, v) in f["env"].as_object().unwrap() {
            cmd.env(k, v.as_str().unwrap());
        }
        // The captured agent is long gone; stand in with a live process (this test runner).
        cmd.env("CLAUDE_PID", std::process::id().to_string());
        let t = Instant::now();
        let mut child = cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
        child.stdin.take().unwrap().write_all(payload.to_string().as_bytes()).unwrap();
        let out = child.wait_with_output().unwrap();
        assert!(out.status.success(), "hook must always exit 0");
        (String::from_utf8(out.stdout).unwrap(), t.elapsed())
    }

    fn last(&self) -> Value {
        self.snapshots.lock().unwrap().last().cloned().unwrap_or(Value::Null)
    }
}

#[test]
fn new_session_reaches_the_island_well_under_a_second() {
    let h = start("latency");
    let (out, elapsed) = h.hook("SessionStart", serde_json::json!({}));
    assert_eq!(out, "", "non-blocking events print nothing");
    assert!(elapsed < Duration::from_millis(1000), "took {elapsed:?}");
    let snap = h.last();
    assert_eq!(snap["sessions"][0]["project"], "proj");
    assert_eq!(snap["sessions"][0]["state"], "idle");
    assert_eq!(snap["sessions"][0]["pid"], std::process::id());
}

#[test]
fn hook_captures_terminal_identity_from_its_environment() {
    let h = start("identity");
    h.hook("UserPromptSubmit", serde_json::json!({}));
    let t = &h.last()["sessions"][0]["terminal"];
    assert_eq!(t["tmuxPane"], "%0");
    assert!(t["pids"].as_array().unwrap().len() >= 2, "process chain captured: {t}");
}

#[test]
fn hook_fails_open_when_the_island_is_not_running() {
    let h = start("failopen");
    let sock = h.sock.clone();
    drop(h);
    let mut child = Command::new(env!("CARGO_BIN_EXE_island-hook"))
        .arg("claude")
        .env("ISLAND_SOCKET", sock)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(fixture("PermissionRequest-Bash")["payload"].to_string().as_bytes()).unwrap();
    let t = Instant::now();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success());
    assert!(out.stdout.is_empty());
    // Must not wait for the island's 2 s reply timeout. (Spawning from the cargo test process adds
    // ~150 ms of exec overhead before main(); the hook itself takes <1 ms, measured in production at 3.4 ms median.)
    assert!(t.elapsed() < Duration::from_millis(1000), "took {:?}", t.elapsed());
}

#[test]
fn status_subcommand_returns_the_live_snapshot() {
    let h = start("status");
    h.hook("SessionStart", serde_json::json!({}));
    let out = Command::new(env!("CARGO_BIN_EXE_island-hook")).arg("status").env("ISLAND_SOCKET", &h.sock).output().unwrap();
    let v: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["sessions"][0]["project"], "proj");
}

#[test]
fn statusline_passthrough_prints_the_original_output_and_feeds_usage() {
    let h = start("statusline");
    let mut child = Command::new(env!("CARGO_BIN_EXE_island-hook"))
        .args(["statusline", "--", "cat; echo ' <- original'"])
        .env("ISLAND_SOCKET", &h.sock)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let resets = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() + 3600;
    let input = format!(r#"{{"rate_limits":{{"five_hour":{{"used_percentage":12,"resets_at":{resets}}}}}}}"#);
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(String::from_utf8(out.stdout).unwrap(), format!("{input} <- original\n"));
    std::thread::sleep(Duration::from_millis(100));
    assert_eq!(h.last()["usage"]["claude"]["windows"][0]["usedPercent"], 12.0);
}

#[test]
fn a_dead_agent_process_ends_its_session() {
    let h = start("pidexit");
    let mut sleeper = Command::new("sleep").arg("30").spawn().unwrap();
    let pid = sleeper.id().to_string();
    // Same fixture, but pretend the agent is our sleeper process.
    let f = fixture("UserPromptSubmit");
    let mut child = Command::new(env!("CARGO_BIN_EXE_island-hook"))
        .arg("claude")
        .env("ISLAND_SOCKET", &h.sock)
        .env("CLAUDE_PID", &pid)
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(f["payload"].to_string().as_bytes()).unwrap();
    child.wait().unwrap();
    assert_eq!(h.last()["sessions"][0]["state"], "working");
    sleeper.kill().unwrap();
    sleeper.wait().unwrap();
    let t = Instant::now();
    while h.last()["sessions"][0]["state"] != "error" && t.elapsed() < Duration::from_secs(2) {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(h.last()["sessions"][0]["state"], "error", "killed mid-turn");
    let _ = &h.core;
}

#[test]
fn an_unwatchable_but_live_pid_is_not_treated_as_exited() {
    let h = start("eperm");
    let f = fixture("UserPromptSubmit");
    let mut child = Command::new(env!("CARGO_BIN_EXE_island-hook"))
        .arg("claude")
        .env("ISLAND_SOCKET", &h.sock)
        .env("CLAUDE_PID", "1") // launchd: kevent refuses (EPERM) but it is alive
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(f["payload"].to_string().as_bytes()).unwrap();
    child.wait().unwrap();
    assert_eq!(h.last()["sessions"][0]["state"], "working");
}


/// Start the hook like Claude would, without waiting for it.
fn spawn_hook(h: &Harness, fixture_name: &str) -> std::process::Child {
    let f = fixture(fixture_name);
    let mut child = Command::new(env!("CARGO_BIN_EXE_island-hook"))
        .arg("claude")
        .env("ISLAND_SOCKET", &h.sock)
        .env("CLAUDE_PID", std::process::id().to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(f["payload"].to_string().as_bytes()).unwrap();
    child
}

fn wait_for(h: &Harness, pred: impl Fn(&Value) -> bool) -> Value {
    let t = Instant::now();
    loop {
        let s = h.last();
        if pred(&s) || t.elapsed() > Duration::from_secs(3) {
            return s;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn approval_waits_for_the_island_and_prints_claudes_decision() {
    let h = start("approve");
    let child = spawn_hook(&h, "PermissionRequest-Bash");
    let snap = wait_for(&h, |s| s["attention"] == 1);
    let card = &snap["sessions"][0]["pending"][0];
    assert_eq!(card["held"], true);
    std::thread::sleep(Duration::from_millis(100));
    h.core.send(&serde_json::json!({"type":"answer","id":card["id"],"decision":"allow"}));
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success());
    let v: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["hookSpecificOutput"]["decision"]["behavior"], "allow");
    assert_eq!(wait_for(&h, |s| s["attention"] == 0)["attention"], 0);
}

#[test]
fn answering_in_the_terminal_releases_the_hook_with_no_decision() {
    let h = start("terminal-answer");
    let child = spawn_hook(&h, "PermissionRequest-Bash");
    wait_for(&h, |s| s["attention"] == 1);
    h.hook("PostToolUse-Bash", serde_json::json!({}));
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success());
    assert!(out.stdout.is_empty(), "no decision: the terminal already answered");
    assert_eq!(h.last()["attention"], 0);
}

#[test]
fn a_killed_hook_withdraws_the_card() {
    let h = start("killed");
    let mut child = spawn_hook(&h, "PermissionRequest-Bash");
    wait_for(&h, |s| s["attention"] == 1);
    child.kill().unwrap();
    child.wait().unwrap();
    assert_eq!(wait_for(&h, |s| s["attention"] == 0)["attention"], 0);
}

#[test]
fn while_paused_approvals_fall_through_to_the_agent_immediately() {
    let h = start("paused");
    h.core.send(&serde_json::json!({"type":"pause","paused":true}));
    let t = Instant::now();
    let out = spawn_hook(&h, "PermissionRequest-Bash").wait_with_output().unwrap();
    assert!(out.stdout.is_empty());
    assert!(t.elapsed() < Duration::from_millis(1000));
}

// ---- Codex: a fake app-server daemon (WebSocket over UDS) to exercise attach → request → answer.

struct FakeDaemon {
    to_client: std::sync::mpsc::Sender<Value>,
    from_client: std::sync::mpsc::Receiver<Value>,
}

fn ws_read(s: &mut std::os::unix::net::UnixStream) -> Option<Value> {
    use std::io::Read;
    let mut h = [0u8; 2];
    s.read_exact(&mut h).ok()?;
    let mut len = (h[1] & 0x7f) as usize;
    if len == 126 {
        let mut b = [0u8; 2];
        s.read_exact(&mut b).ok()?;
        len = u16::from_be_bytes(b) as usize;
    } else if len == 127 {
        let mut b = [0u8; 8];
        s.read_exact(&mut b).ok()?;
        len = u64::from_be_bytes(b) as usize;
    }
    let mut mask = [0u8; 4];
    s.read_exact(&mut mask).ok()?;
    let mut p = vec![0u8; len];
    s.read_exact(&mut p).ok()?;
    p.iter_mut().enumerate().for_each(|(i, b)| *b ^= mask[i % 4]);
    serde_json::from_slice(&p).ok()
}

fn ws_write(s: &mut std::os::unix::net::UnixStream, v: &Value) {
    let p = v.to_string().into_bytes();
    let mut f = vec![0x81];
    if p.len() < 126 {
        f.push(p.len() as u8);
    } else {
        f.push(126);
        f.extend_from_slice(&(p.len() as u16).to_be_bytes());
    }
    f.extend_from_slice(&p);
    s.write_all(&f).unwrap();
}

fn fake_daemon(codex_home: &std::path::Path) -> FakeDaemon {
    use std::io::{BufRead, BufReader};
    let dir = codex_home.join("app-server-control");
    std::fs::create_dir_all(&dir).unwrap();
    let listener = std::os::unix::net::UnixListener::bind(dir.join("app-server-control.sock")).unwrap();
    let (to_client, rx) = std::sync::mpsc::channel::<Value>();
    let (tx, from_client) = std::sync::mpsc::channel::<Value>();
    std::thread::spawn(move || {
        let (mut s, _) = listener.accept().unwrap();
        let mut r = BufReader::new(s.try_clone().unwrap());
        loop {
            let mut l = String::new();
            r.read_line(&mut l).unwrap();
            if l == "\r\n" { break; }
        }
        s.write_all(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n").unwrap();
        let mut w = s.try_clone().unwrap();
        std::thread::spawn(move || {
            for v in rx { ws_write(&mut w, &v); }
        });
        let mut rs = r.into_inner();
        while let Some(v) = ws_read(&mut rs) {
            if tx.send(v).is_err() { break; }
        }
    });
    FakeDaemon { to_client, from_client }
}

impl FakeDaemon {
    fn expect(&self, method: &str) -> Value {
        loop {
            let v = self.from_client.recv_timeout(Duration::from_secs(3)).expect(method);
            if v["method"] == method { return v; }
        }
    }
}

fn codex_fixture(name: &str) -> Value {
    serde_json::from_str(&std::fs::read_to_string(format!("{}/../../fixtures/codex/{name}.json", env!("CARGO_MANIFEST_DIR"))).unwrap()).unwrap()
}

fn codex_hook(h: &Harness, home: &std::path::Path, name: &str) -> String {
    let f = codex_fixture(name);
    let mut c = Command::new(env!("CARGO_BIN_EXE_island-hook"))
        .arg("codex")
        .env("ISLAND_SOCKET", &h.sock)
        .env("CODEX_HOME", home)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    c.stdin.take().unwrap().write_all(f["payload"].to_string().as_bytes()).unwrap();
    String::from_utf8(c.wait_with_output().unwrap().stdout).unwrap()
}

#[test]
fn codex_session_attaches_to_its_daemon_and_answers_inline() {
    let h = start("codex-inline");
    let home = std::path::PathBuf::from(format!("/tmp/isl-cx-{}", std::process::id())); // short: UDS paths are limited to 104 bytes
    let _ = std::fs::remove_dir_all(&home);
    let d = fake_daemon(&home);

    codex_hook(&h, &home, "SessionStart");
    let init = d.expect("initialize");
    assert_eq!(init["params"]["capabilities"]["experimentalApi"], true);
    d.to_client.send(serde_json::json!({"id": init["id"], "result": {"userAgent": "fake"}})).unwrap();
    d.expect("initialized");
    let resume = d.expect("thread/resume");
    assert_eq!(resume["params"]["threadId"], "01a12fc4-413a-7d30-8744-8d3dc1664395");
    d.to_client.send(serde_json::json!({"id": resume["id"], "result": {"thread": {}}})).unwrap();
    assert_eq!(wait_for(&h, |s| s["sessions"][0]["inline"] == true)["sessions"][0]["inline"], true);

    // The hook never blocks Codex, and adds no card for an attached session.
    assert_eq!(codex_hook(&h, &home, "PermissionRequest-Bash"), "");
    d.to_client.send(codex_fixture("appserver-commandApproval")).unwrap();
    let snap = wait_for(&h, |s| s["attention"] == 1);
    let card = &snap["sessions"][0]["pending"][0];
    assert_eq!(card["detail"], "touch codex-approve.txt");
    h.core.send(&serde_json::json!({"type":"answer","id":card["id"],"decision":"allowSession"}));
    let reply = loop {
        let v = d.from_client.recv_timeout(Duration::from_secs(3)).unwrap();
        if v.get("result").is_some() { break v; }
    };
    assert_eq!(reply, serde_json::json!({"id": 0, "result": {"decision": "acceptForSession"}}));

    // Rate limits arrive as notifications.
    d.to_client.send(codex_fixture("appserver-rateLimits")).unwrap();
    let snap = wait_for(&h, |s| !s["usage"]["codex"].is_null());
    assert_eq!(snap["usage"]["codex"]["windows"][1]["label"], "wk");
}

#[test]
fn codex_without_a_daemon_falls_back_to_a_handoff_card() {
    let h = start("codex-handoff");
    let home = std::env::temp_dir().join(format!("isl-cx-none-{}", std::process::id()));
    codex_hook(&h, &home, "SessionStart");
    assert_eq!(codex_hook(&h, &home, "PermissionRequest-Bash"), "", "never blocks");
    let card = &wait_for(&h, |s| s["attention"] == 1)["sessions"][0]["pending"][0];
    assert_eq!(card["held"], false);
}
