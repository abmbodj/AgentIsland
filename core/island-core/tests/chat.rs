//! Composer chats against fake `claude` / `codex` scripts: transcript folding, follow-ups, Stop, failures.
use island_core::chat::Chats;
use island_core::pr::Tools;
use serde_json::Value;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::time::{Duration, Instant};

fn fixture(name: &str, scripts: &[(&str, &str)]) -> (Tools, PathBuf) {
    let root = std::env::temp_dir().join(format!("island-chat-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("bin")).unwrap();
    for (n, body) in scripts {
        let p = root.join("bin").join(n);
        std::fs::write(&p, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    (Tools { dirs: vec![root.join("bin")] }, root)
}

fn wait_for(chats: &Chats, id: u64, status: &str) -> Value {
    let end = Instant::now() + Duration::from_secs(10);
    loop {
        let t = chats.transcript(id, 0).unwrap();
        if t["status"] == status {
            return t;
        }
        assert!(Instant::now() < end, "never reached {status}: {t}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn kinds(t: &Value) -> Vec<String> {
    t["entries"].as_array().unwrap().iter().map(|e| e["kind"].as_str().unwrap().to_string()).collect()
}

const CLAUDE: &str = r#"echo "$@" >> "$0.args"
echo '{"type":"system","subtype":"init","session_id":"sess-1"}'
echo '{"type":"stream_event","event":{"type":"message_start","message":{"id":"m'$$'"}}}'
echo '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}'
echo '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}}'
echo '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}}'
echo '{"type":"assistant","message":{"id":"m'$$'","content":[{"type":"text","text":"Hello"},{"type":"tool_use","id":"t'$$'","name":"Bash","input":{"command":"echo hi"}}]}}'
echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t'$$'","content":"hi","is_error":false}]}}'
echo '{"type":"result","subtype":"success","is_error":false,"session_id":"sess-1"}'"#;

#[test]
fn claude_turn_streams_text_and_tool_rows_then_follow_up_resumes() {
    let (tools, root) = fixture("claude", &[("claude", CLAUDE)]);
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "say hello").unwrap();
    let t = wait_for(&chats, id, "idle");
    assert_eq!(kinds(&t), ["user", "assistant", "tool"]);
    let e = t["entries"].as_array().unwrap();
    assert_eq!(e[1]["text"], "Hello");
    assert_eq!((e[2]["name"].as_str(), e[2]["input"].as_str(), e[2]["output"].as_str(), e[2]["status"].as_str()), (Some("Bash"), Some("echo hi"), Some("hi"), Some("done")));
    assert_eq!(t["sessionId"], "sess-1");

    chats.send(&tools, id, "again").unwrap();
    wait_for(&chats, id, "idle");
    let args = std::fs::read_to_string(root.join("bin/claude.args")).unwrap();
    assert!(args.lines().nth(1).unwrap().contains("--resume sess-1"), "{args}");
    assert_eq!(chats.list()[0]["title"], "say hello");
}

#[test]
fn transcript_pull_returns_only_entries_changed_since_the_revision() {
    let (tools, root) = fixture("rev", &[("claude", CLAUDE)]);
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "one").unwrap();
    let rev = wait_for(&chats, id, "idle")["rev"].as_u64().unwrap();
    assert!(chats.transcript(id, rev).unwrap()["entries"].as_array().unwrap().is_empty());
    chats.send(&tools, id, "two").unwrap();
    wait_for(&chats, id, "idle");
    let t = chats.transcript(id, rev).unwrap();
    let idx: Vec<u64> = t["entries"].as_array().unwrap().iter().map(|e| e["index"].as_u64().unwrap()).collect();
    assert_eq!(idx, [3, 4, 5]);
}

#[test]
fn stop_kills_the_turn_and_leaves_the_chat_usable() {
    let (tools, root) = fixture("stop", &[("claude", "echo '{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"s\"}'\nsleep 30")]);
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "go").unwrap();
    assert!(chats.send(&tools, id, "too soon").is_err());
    chats.stop(id);
    let t = wait_for(&chats, id, "idle");
    assert_eq!(kinds(&t), ["user", "notice"]);
}

#[test]
fn crash_with_stderr_marks_the_chat_failed_and_keeps_the_reason() {
    let (tools, root) = fixture("crash", &[("claude", "echo 'not logged in' >&2; exit 3")]);
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "go").unwrap();
    let t = wait_for(&chats, id, "failed");
    assert_eq!(t["error"], "not logged in");
    assert_eq!(kinds(&t), ["user", "error"]);
}

#[test]
fn missing_binary_and_bad_folder_are_reported() {
    let (tools, root) = fixture("missing", &[]);
    let chats = Chats::default();
    let id = chats.start(&tools, "codex", root.to_str().unwrap(), "go").unwrap();
    assert!(wait_for(&chats, id, "failed")["error"].as_str().unwrap().contains("codex"));
    assert!(chats.start(&tools, "claude", "/nonexistent-dir", "go").is_err());
    assert!(chats.start(&tools, "claude", root.to_str().unwrap(), "  ").is_err());
}

#[test]
fn codex_items_become_messages_and_tool_rows() {
    let script = r#"echo '{"type":"thread.started","thread_id":"th-1"}'
echo '{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"On it"}}'
echo '{"type":"item.started","item":{"id":"i1","type":"command_execution","command":"ls","aggregated_output":"","exit_code":null}}'
echo '{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"ls","aggregated_output":"a","exit_code":2}}'
echo '{"type":"turn.completed"}'"#;
    let (tools, root) = fixture("codex", &[("codex", script)]);
    let chats = Chats::default();
    let id = chats.start(&tools, "codex", root.to_str().unwrap(), "list").unwrap();
    let t = wait_for(&chats, id, "idle");
    assert_eq!(kinds(&t), ["user", "assistant", "tool"]);
    assert_eq!(t["entries"][2]["status"], "error");
    assert_eq!(t["sessionId"], "th-1");
}

#[test]
fn text_after_a_thinking_block_is_not_duplicated() {
    let script = r#"echo '{"type":"stream_event","event":{"type":"message_start","message":{"id":"mm"}}}'
echo '{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}}'
echo '{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hi"}}}'
echo '{"type":"assistant","message":{"id":"mm","content":[{"type":"text","text":"Hi"}]}}'
echo '{"type":"result","subtype":"success","is_error":false}'"#;
    let (tools, root) = fixture("think", &[("claude", script)]);
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "go").unwrap();
    assert_eq!(kinds(&wait_for(&chats, id, "idle")), ["user", "assistant"]);
}

#[test]
fn delete_kills_a_running_turn_and_forgets_the_chat() {
    let (tools, root) = fixture("delete", &[("claude", "echo $$ > \"$0.pid\"\nsleep 30")]);
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "go").unwrap();
    let pidfile = root.join("bin/claude.pid");
    let end = Instant::now() + Duration::from_secs(10);
    while !pidfile.exists() {
        assert!(Instant::now() < end, "agent never started");
        std::thread::sleep(Duration::from_millis(20));
    }
    let pid = std::fs::read_to_string(&pidfile).unwrap().trim().to_string();
    chats.delete(id);
    assert!(chats.list().as_array().unwrap().is_empty());
    assert!(chats.transcript(id, 0).is_err());
    let alive = || std::process::Command::new("kill").args(["-0", &pid]).output().unwrap().status.success();
    while alive() {
        assert!(Instant::now() < end, "agent still running after delete");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn handoff_waits_for_exit_and_is_claimed_once() {
    let script = "echo '{\"type\":\"result\",\"session_id\":\"native-session\",\"is_error\":false}'\nexec 1>&-\nwhile [ ! -f \"$0.release\" ]; do sleep 0.02; done";
    let (tools, root) = fixture("handoff-queue", &[("claude", script)]);
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "remember this").unwrap();
    let end = Instant::now() + Duration::from_secs(10);
    while chats.transcript(id, 0).unwrap()["sessionId"].is_null() {
        assert!(Instant::now() < end, "native session never arrived");
        std::thread::sleep(Duration::from_millis(10));
    }
    chats.request_handoff(id, "terminal").unwrap();
    chats.cancel_handoff(id).unwrap();
    assert!(chats.transcript(id, 0).unwrap()["handoff"].is_null());
    chats.request_handoff(id, "terminal").unwrap();
    assert_eq!(chats.transcript(id, 0).unwrap()["handoff"]["status"], "queued");
    assert!(chats.send(&tools, id, "blocked").is_err());
    assert_eq!(chats.claim_handoffs(&tools), serde_json::json!([]));
    std::fs::write(root.join("bin/claude.release"), "").unwrap();
    let before = wait_for(&chats, id, "idle");
    let claims = chats.claim_handoffs(&tools);
    assert_eq!(claims[0]["sessionId"], "native-session");
    assert_eq!(claims[0]["cwd"], root.to_str().unwrap());
    assert_eq!(claims[0]["bin"], std::fs::canonicalize(root.join("bin/claude")).unwrap().to_str().unwrap());
    assert!(claims[0]["path"].as_str().unwrap().contains(root.join("bin").to_str().unwrap()));
    assert_eq!(chats.claim_handoffs(&tools), serde_json::json!([]));
    assert!(chats.cancel_handoff(id).is_err());
    chats.finish_handoff(id, None).unwrap();
    let after = chats.transcript(id, 0).unwrap();
    assert_eq!(after["entries"], before["entries"]);
    assert_eq!(after["handoff"]["status"], "opened");
    assert!(chats.send(&tools, id, "blocked").is_err());
    assert!(chats.request_handoff(id, "iterm").is_err());
    chats.request_handoff(id, "terminal").unwrap();
    assert_eq!(chats.claim_handoffs(&tools).as_array().unwrap().len(), 1);
    chats.finish_handoff(id, Some("could not reopen")).unwrap();
    assert_eq!(chats.list()[0]["handoff"]["status"], "opened");
    assert!(chats.send(&tools, id, "still blocked").is_err());
}

#[test]
fn handoff_cancellation_and_failure_restore_replies() {
    let (tools, root) = fixture("handoff-recover", &[("claude", CLAUDE)]);
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "hello").unwrap();
    wait_for(&chats, id, "idle");
    assert!(chats.request_handoff(id, "codexDesktop").is_err());
    assert!(chats.request_handoff(id, "unknown").is_err());
    assert!(chats.finish_handoff(id, None).is_err());
    chats.request_handoff(id, "claudeDesktop").unwrap();
    chats.cancel_handoff(id).unwrap();
    assert!(chats.transcript(id, 0).unwrap()["handoff"].is_null());
    chats.send(&tools, id, "again").unwrap();
    wait_for(&chats, id, "idle");
    chats.request_handoff(id, "ghostty").unwrap();
    chats.claim_handoffs(&tools);
    assert!(chats.send(&tools, id, "launching").is_err());
    chats.finish_handoff(id, Some("Ghostty could not open")).unwrap();
    let t = chats.transcript(id, 0).unwrap();
    assert!(t["handoff"].is_null());
    assert_eq!(t["handoffError"], "Ghostty could not open");
    chats.send(&tools, id, "recovered").unwrap();
    wait_for(&chats, id, "idle");
    chats.request_handoff(id, "terminal").unwrap();
    chats.delete(id);
    assert_eq!(chats.claim_handoffs(&tools), serde_json::json!([]));
    assert!(chats.request_handoff(id, "terminal").is_err());
    assert!(chats.finish_handoff(id, None).is_err());
}

#[test]
fn handoff_claim_validates_session_executable_and_folder_at_claim_time() {
    let chats = Chats::default();
    let (tools, root) = fixture("handoff-session", &[("codex", "echo '{\"type\":\"turn.completed\"}'")]);
    let id = chats.start(&tools, "codex", root.to_str().unwrap(), "hello").unwrap();
    wait_for(&chats, id, "idle");
    chats.request_handoff(id, "codexDesktop").unwrap();
    assert_eq!(chats.claim_handoffs(&tools), serde_json::json!([]));
    let t = chats.transcript(id, 0).unwrap();
    assert!(t["handoff"].is_null());
    assert!(t["handoffError"].as_str().unwrap().contains("session"));
    for missing in ["binary", "folder", "permissions"] {
        let (tools, root) = fixture(&format!("handoff-{missing}"), &[("claude", CLAUDE)]);
        let id = chats.start(&tools, "claude", root.to_str().unwrap(), "hello").unwrap();
        wait_for(&chats, id, "idle");
        chats.request_handoff(id, "iterm").unwrap();
        match missing {
            "binary" => std::fs::remove_file(root.join("bin/claude")).unwrap(),
            "folder" => std::fs::remove_dir_all(&root).unwrap(),
            _ => std::fs::set_permissions(root.join("bin/claude"), std::fs::Permissions::from_mode(0o644)).unwrap(),
        }
        assert_eq!(chats.claim_handoffs(&tools), serde_json::json!([]));
        let t = chats.transcript(id, 0).unwrap();
        assert!(t["handoff"].is_null());
        assert!(!t["handoffError"].as_str().unwrap().is_empty());
    }
}

#[test]
fn concurrent_claims_launch_a_chat_only_once() {
    let (tools, root) = fixture("handoff-concurrent", &[("claude", CLAUDE)]);
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "hello").unwrap();
    wait_for(&chats, id, "idle");
    chats.request_handoff(id, "terminal").unwrap();
    std::thread::scope(|scope| {
        let a = scope.spawn(|| chats.claim_handoffs(&tools).as_array().unwrap().len());
        let b = scope.spawn(|| chats.claim_handoffs(&tools).as_array().unwrap().len());
        assert_eq!(a.join().unwrap() + b.join().unwrap(), 1);
    });
}

#[test]
fn handoff_preserves_the_discovered_symlink_directory_for_env_runtimes() {
    let (tools, root) = fixture("handoff-symlink", &[("island-test-runtime", "exec /bin/sh \"$@\"")]);
    let real = root.join("package/claude");
    std::fs::create_dir_all(real.parent().unwrap()).unwrap();
    std::fs::write(&real, "#!/usr/bin/env island-test-runtime\necho '{\"type\":\"result\",\"session_id\":\"symlink-session\",\"is_error\":false}'\n").unwrap();
    std::fs::set_permissions(&real, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::os::unix::fs::symlink(&real, root.join("bin/claude")).unwrap();
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "hello").unwrap();
    assert_eq!(wait_for(&chats, id, "idle")["sessionId"], "symlink-session");
    chats.request_handoff(id, "terminal").unwrap();
    let claims = chats.claim_handoffs(&tools);
    let claim = &claims[0];
    let resumed = std::process::Command::new(claim["bin"].as_str().unwrap())
        .args(["--resume", claim["sessionId"].as_str().unwrap()])
        .env("PATH", claim["path"].as_str().unwrap())
        .current_dir(claim["cwd"].as_str().unwrap()).output().unwrap();
    assert!(resumed.status.success(), "{}", String::from_utf8_lossy(&resumed.stderr));
    assert!(String::from_utf8_lossy(&resumed.stdout).contains("symlink-session"));
}
