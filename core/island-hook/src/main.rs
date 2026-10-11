//! island-hook: the tiny process agents run on every hook event.
//! Reads the agent's JSON, adds terminal identity, forwards it to Agent Island over a local
//! socket and prints whatever the island answers. Always fails open: if the island is not
//! running (or anything goes wrong) it prints nothing and exits 0.
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

const ENV_KEYS: &[&str] = &[
    "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "ITERM_SESSION_ID", "TMUX", "TMUX_PANE",
    "__CFBundleIdentifier", "CLAUDE_PID", "WT_SESSION", "VSCODE_PID", "GHOSTTY_RESOURCES_DIR",
];

fn socket_path() -> PathBuf {
    std::env::var_os("ISLAND_SOCKET").map(PathBuf::from).unwrap_or_else(|| {
        PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join("Library/Application Support/AgentIsland/island.sock")
    })
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
        agent @ ("claude" | "codex") => {
            let event = serde_json::from_str::<Value>(&payload).ok().and_then(|v| v["hook_event_name"].as_str().map(str::to_string));
            // Approvals wait for the user (the agent's own timeout bounds us); everything else is quick.
            let wait = if event.as_deref() == Some("PermissionRequest") { None } else { Some(Duration::from_secs(2)) };
            let env: serde_json::Map<String, Value> = ENV_KEYS
                .iter()
                .filter_map(|k| std::env::var(k).ok().map(|v| (k.to_string(), Value::String(v))))
                .collect();
            let (pids, tty) = process_chain();
            let msg = json!({"v": 1, "agent": agent, "payload": payload, "env": env, "tty": tty, "pids": pids});
            if let Some(out) = send(&msg, Some(wait)) {
                print!("{out}");
            }
        }
        _ => {}
    }
}
