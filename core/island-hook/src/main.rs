//! island-hook: the tiny process agents run on every hook event.
//! Reads the agent's JSON, adds terminal identity, forwards it to Agent Island over a local
//! socket and prints whatever the island answers. Always fails open: if the island is not
//! running (or anything goes wrong) it prints nothing and exits 0.
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

const ENV_KEYS: &[&str] = &[
    "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "ITERM_SESSION_ID", "TMUX", "TMUX_PANE",
    "__CFBundleIdentifier", "CLAUDE_PID", "WT_SESSION", "VSCODE_PID", "GHOSTTY_RESOURCES_DIR", "CODEX_HOME",
    "CLAUDE_CODE_HOST_SESSION_ID",
];

fn socket_path() -> PathBuf {
    std::env::var_os("ISLAND_SOCKET").map(PathBuf::from).unwrap_or_else(|| {
        PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join("Library/Application Support/AgentIsland/island.sock")
    })
}

fn codex_rollout_home(payload: Option<&Value>) -> Option<&Path> {
    let path = Path::new(payload?["transcript_path"].as_str()?);
    let folder = path.parent()?;
    // Active rollouts are under sessions/YYYY/MM/DD. Archived rollouts live one level deep.
    let root = if folder.ends_with("archived_sessions") {
        folder
    } else {
        let sessions = folder.parent()?.parent()?.parent()?;
        if !sessions.ends_with("sessions") { return None }
        sessions
    };
    root.parent().filter(|home| home.is_absolute())
}

#[cfg(target_os = "macos")]
mod procinfo {
    unsafe extern "C" {
        fn devname(dev: libc::dev_t, kind: libc::mode_t) -> *const libc::c_char;
    }

    pub struct Proc {
        pub ppid: i32,
        pub comm: String,
        pub tty: Option<String>,
    }

    pub fn info(pid: i32) -> Option<Proc> {
        let mut bi: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
        let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
        let n = unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, &mut bi as *mut _ as *mut libc::c_void, size) };
        if n != size {
            return None;
        }
        let comm = unsafe { std::ffi::CStr::from_ptr(bi.pbi_comm.as_ptr()) }.to_string_lossy().into_owned();
        // NODEV (-1) means no controlling terminal.
        let tty = (bi.e_tdev != u32::MAX && bi.e_tdev != 0)
            .then(|| unsafe { devname(bi.e_tdev as libc::dev_t, libc::S_IFCHR) })
            .filter(|p| !p.is_null())
            .map(|p| unsafe { std::ffi::CStr::from_ptr(p) }.to_string_lossy().into_owned());
        Some(Proc { ppid: bi.pbi_ppid as i32, comm, tty })
    }
}

/// Our ancestors (nearest first) and the first controlling tty found on the way up.
fn process_chain() -> (Vec<Value>, Option<String>) {
    let mut pids = vec![];
    let mut tty = None;
    #[cfg(target_os = "macos")]
    {
        let mut pid = std::process::id() as i32;
        for _ in 0..32 {
            let Some(p) = procinfo::info(pid) else { break };
            pids.push(json!({"pid": pid, "comm": p.comm}));
            if tty.is_none() {
                tty = p.tty;
            }
            if p.ppid <= 1 {
                break;
            }
            pid = p.ppid;
        }
    }
    (pids, tty)
}

fn send(msg: &Value, wait_for_reply: Option<Option<Duration>>) -> Option<String> {
    let mut s = UnixStream::connect(socket_path()).ok()?;
    s.set_write_timeout(Some(Duration::from_millis(200))).ok()?;
    s.write_all(format!("{msg}\n").as_bytes()).ok()?;
    let read_timeout = wait_for_reply?;
    s.set_read_timeout(read_timeout).ok()?;
    let mut line = String::new();
    BufReader::new(s).read_line(&mut line).ok()?;
    let reply: Value = serde_json::from_str(&line).ok()?;
    reply["stdout"].as_str().map(str::to_string)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).map(String::as_str).unwrap_or("");
    let mut input = Vec::new();
    if mode != "status" {
        let _ = std::io::stdin().read_to_end(&mut input);
    }
    let payload = String::from_utf8_lossy(&input).into_owned();

    match mode {
        "status" => {
            // Debug/test helper: print the island's current snapshot.
            if let Some(out) = send(&json!({"v": 1, "agent": "query"}), Some(Some(Duration::from_secs(2)))) {
                println!("{out}");
            }
        }
        "statusline" => {
            // Fire-and-forget copy for the usage strip, then run the user's own status line unchanged.
            let _ = send(&json!({"v": 1, "agent": "statusline", "payload": payload}), None);
            if let Some(original) = args.iter().position(|a| a == "--").and_then(|i| args.get(i + 1)) {
                if let Ok(mut child) = Command::new("sh").arg("-c").arg(original).stdin(Stdio::piped()).spawn() {
                    if let Some(mut stdin) = child.stdin.take() {
                        let _ = stdin.write_all(&input);
                    }
                    let _ = child.wait();
                }
            }
        }
        // The island's own headless runs (writing a PR) are not sessions.
        "claude" | "codex" if std::env::var_os("AGENT_ISLAND_INTERNAL").is_some() => {}
        agent @ ("claude" | "codex") => {
            let parsed = serde_json::from_str::<Value>(&payload).ok();
            // Cursor's agent runs the Claude hooks in ~/.claude too, in its own payload shape.
            // `codex exec --ephemeral` (T3 Code's title and commit-message helper) has no transcript at all.
            let ephemeral = |v: &Value| agent == "codex" && v.get("transcript_path").is_some_and(Value::is_null);
            if parsed.as_ref().is_some_and(|v| v.get("cursor_version").is_some() || ephemeral(v)) {
                return;
            }
            let event = parsed.as_ref().and_then(|v| v["hook_event_name"].as_str());
            // Approvals wait for the user (the agent's own timeout bounds us); everything else is quick.
            let wait = if event == Some("PermissionRequest") { None } else { Some(Duration::from_secs(2)) };
            let mut env: serde_json::Map<String, Value> = ENV_KEYS
                .iter()
                .filter_map(|k| std::env::var(k).ok().map(|v| (k.to_string(), Value::String(v))))
                .collect();
            // The rollout records the actual home even if the hook runs in a different directory.
            if agent == "codex" {
                if let Some(home) = env.get_mut("CODEX_HOME") {
                    let path = Path::new(home.as_str().unwrap_or_default());
                    if !path.as_os_str().is_empty() && path.is_relative() {
                        let resolved = codex_rollout_home(parsed.as_ref()).map(Path::to_path_buf)
                            .or_else(|| std::env::current_dir().ok().map(|cwd| cwd.join(path)));
                        if let Some(resolved) = resolved {
                            *home = json!(resolved);
                        }
                    }
                }
            }
            let (pids, tty) = process_chain();
            let msg = json!({"v": 1, "agent": agent, "payload": payload, "env": env, "tty": tty, "pids": pids});
            if let Some(out) = send(&msg, Some(wait)) {
                print!("{out}");
            }
        }
        _ => {}
    }
}
