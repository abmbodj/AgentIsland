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
