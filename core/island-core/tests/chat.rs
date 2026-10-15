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
