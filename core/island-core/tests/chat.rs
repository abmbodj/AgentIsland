//! Composer chats against fake `claude` / `codex` scripts: transcript folding, follow-ups, Stop, failures.
use island_core::chat::Chats;
use island_core::chat::{Image, Settings};
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
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "say hello", vec![], Settings::default()).unwrap();
    let t = wait_for(&chats, id, "idle");
    assert_eq!(kinds(&t), ["user", "assistant", "tool"]);
    let e = t["entries"].as_array().unwrap();
    assert_eq!(e[1]["text"], "Hello");
    assert_eq!((e[2]["name"].as_str(), e[2]["input"].as_str(), e[2]["output"].as_str(), e[2]["status"].as_str()), (Some("Bash"), Some("echo hi"), Some("hi"), Some("done")));
    assert_eq!(t["sessionId"], "sess-1");

    chats.send(&tools, id, "again", vec![], Settings::default()).unwrap();
    wait_for(&chats, id, "idle");
    let args = std::fs::read_to_string(root.join("bin/claude.args")).unwrap();
    assert!(args.lines().nth(1).unwrap().contains("--resume sess-1"), "{args}");
    assert_eq!(chats.list()[0]["title"], "say hello");
}

#[test]
fn transcript_pull_returns_only_entries_changed_since_the_revision() {
    let (tools, root) = fixture("rev", &[("claude", CLAUDE)]);
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "one", vec![], Settings::default()).unwrap();
    let rev = wait_for(&chats, id, "idle")["rev"].as_u64().unwrap();
    assert!(chats.transcript(id, rev).unwrap()["entries"].as_array().unwrap().is_empty());
    chats.send(&tools, id, "two", vec![], Settings::default()).unwrap();
    wait_for(&chats, id, "idle");
    let t = chats.transcript(id, rev).unwrap();
    let idx: Vec<u64> = t["entries"].as_array().unwrap().iter().map(|e| e["index"].as_u64().unwrap()).collect();
    assert_eq!(idx, [3, 4, 5]);
}

#[test]
fn stop_kills_the_turn_and_leaves_the_chat_usable() {
    let (tools, root) = fixture("stop", &[("claude", "echo '{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"s\"}'\nsleep 30")]);
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "go", vec![], Settings::default()).unwrap();
    assert!(chats.send(&tools, id, "too soon", vec![], Settings::default()).is_err());
    chats.stop(id);
    let t = wait_for(&chats, id, "idle");
    assert_eq!(kinds(&t), ["user", "notice"]);
}

#[test]
fn crash_with_stderr_marks_the_chat_failed_and_keeps_the_reason() {
    let (tools, root) = fixture("crash", &[("claude", "echo 'not logged in' >&2; exit 3")]);
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "go", vec![], Settings::default()).unwrap();
    let t = wait_for(&chats, id, "failed");
    assert_eq!(t["error"], "not logged in");
    assert_eq!(kinds(&t), ["user", "error"]);
}

#[test]
fn missing_binary_and_bad_folder_are_reported() {
    let (tools, root) = fixture("missing", &[]);
    let chats = Chats::default();
    let id = chats.start(&tools, "codex", root.to_str().unwrap(), "go", vec![], Settings::default()).unwrap();
    assert!(wait_for(&chats, id, "failed")["error"].as_str().unwrap().contains("codex"));
    assert!(chats.start(&tools, "claude", "/nonexistent-dir", "go", vec![], Settings::default()).is_err());
    assert!(chats.start(&tools, "claude", root.to_str().unwrap(), "  ", vec![], Settings::default()).is_err());
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
    let id = chats.start(&tools, "codex", root.to_str().unwrap(), "list", vec![], Settings::default()).unwrap();
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
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "go", vec![], Settings::default()).unwrap();
    assert_eq!(kinds(&wait_for(&chats, id, "idle")), ["user", "assistant"]);
}

#[test]
fn delete_kills_a_running_turn_and_forgets_the_chat() {
    let (tools, root) = fixture("delete", &[("claude", "echo $$ > \"$0.pid\"\nsleep 30")]);
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "go", vec![], Settings::default()).unwrap();
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
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "remember this", vec![], Settings::default()).unwrap();
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
    assert!(chats.send(&tools, id, "blocked", vec![], Settings::default()).is_err());
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
    chats.finish_handoff(id, token(&chats, id), None).unwrap();
    let after = chats.transcript(id, 0).unwrap();
    assert_eq!(after["entries"], before["entries"]);
    assert_eq!(after["handoff"]["status"], "opened");
    assert!(chats.send(&tools, id, "blocked", vec![], Settings::default()).is_err());
    assert!(chats.request_handoff(id, "iterm").is_err());
    chats.request_handoff(id, "terminal").unwrap();
    assert_eq!(chats.claim_handoffs(&tools).as_array().unwrap().len(), 1);
    chats.finish_handoff(id, token(&chats, id), Some("could not reopen")).unwrap();
    assert_eq!(chats.list()[0]["handoff"]["status"], "opened");
    assert!(chats.send(&tools, id, "still blocked", vec![], Settings::default()).is_err());
}

#[test]
fn handoff_cancellation_and_failure_restore_replies() {
    let (tools, root) = fixture("handoff-recover", &[("claude", CLAUDE)]);
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "hello", vec![], Settings::default()).unwrap();
    wait_for(&chats, id, "idle");
    assert!(chats.request_handoff(id, "codexDesktop").is_err());
    assert!(chats.request_handoff(id, "unknown").is_err());
    assert!(chats.finish_handoff(id, token(&chats, id), None).is_err());
    chats.request_handoff(id, "claudeDesktop").unwrap();
    chats.cancel_handoff(id).unwrap();
    assert!(chats.transcript(id, 0).unwrap()["handoff"].is_null());
    chats.send(&tools, id, "again", vec![], Settings::default()).unwrap();
    wait_for(&chats, id, "idle");
    chats.request_handoff(id, "ghostty").unwrap();
    chats.claim_handoffs(&tools);
    assert!(chats.send(&tools, id, "launching", vec![], Settings::default()).is_err());
    chats.finish_handoff(id, token(&chats, id), Some("Ghostty could not open")).unwrap();
    let t = chats.transcript(id, 0).unwrap();
    assert!(t["handoff"].is_null());
    assert_eq!(t["handoffError"], "Ghostty could not open");
    chats.send(&tools, id, "recovered", vec![], Settings::default()).unwrap();
    wait_for(&chats, id, "idle");
    chats.request_handoff(id, "terminal").unwrap();
    chats.delete(id);
    assert_eq!(chats.claim_handoffs(&tools), serde_json::json!([]));
    assert!(chats.request_handoff(id, "terminal").is_err());
    assert!(chats.finish_handoff(id, token(&chats, id), None).is_err());
}

#[test]
fn handoff_claim_validates_session_executable_and_folder_at_claim_time() {
    let chats = Chats::default();
    let (tools, root) = fixture("handoff-session", &[("codex", "echo '{\"type\":\"turn.completed\"}'")]);
    let id = chats.start(&tools, "codex", root.to_str().unwrap(), "hello", vec![], Settings::default()).unwrap();
    wait_for(&chats, id, "idle");
    chats.request_handoff(id, "codexDesktop").unwrap();
    assert_eq!(chats.claim_handoffs(&tools), serde_json::json!([]));
    let t = chats.transcript(id, 0).unwrap();
    assert!(t["handoff"].is_null());
    assert!(t["handoffError"].as_str().unwrap().contains("session"));
    for missing in ["binary", "folder", "permissions"] {
        let (tools, root) = fixture(&format!("handoff-{missing}"), &[("claude", CLAUDE)]);
        let id = chats.start(&tools, "claude", root.to_str().unwrap(), "hello", vec![], Settings::default()).unwrap();
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
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "hello", vec![], Settings::default()).unwrap();
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
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "hello", vec![], Settings::default()).unwrap();
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

#[test]
fn delayed_launcher_failure_after_opened_preserves_read_only_history() {
    let (tools, root) = fixture("handoff-delayed", &[("claude", CLAUDE)]);
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "hello", vec![], Settings::default()).unwrap();
    wait_for(&chats, id, "idle");
    chats.request_handoff(id, "terminal").unwrap();
    chats.claim_handoffs(&tools);
    chats.finish_handoff(id, token(&chats, id), None).unwrap();
    chats.finish_handoff(id, token(&chats, id), Some("CLI exited with code 1")).unwrap();
    let t = chats.transcript(id, 0).unwrap();
    assert_eq!(t["handoff"]["status"], "opened");
    assert_eq!(t["handoffError"], "CLI exited with code 1");
    assert!(chats.send(&tools, id, "retry here", vec![], Settings::default()).is_err());
    chats.request_handoff(id, "terminal").unwrap();
    assert_eq!(chats.claim_handoffs(&tools).as_array().unwrap().len(), 1);
    chats.finish_handoff(id, token(&chats, id), Some("retry failed")).unwrap();
    assert!(chats.send(&tools, id, "still read only", vec![], Settings::default()).is_err());
}

fn token(chats: &Chats, id: u64) -> u64 {
    chats.transcript(id, 0).ok().and_then(|t| t["handoff"]["token"].as_u64()).unwrap_or(0)
}

#[test]
fn stale_launcher_callbacks_cannot_change_a_later_attempt() {
    let (tools, root) = fixture("handoff-stale", &[("claude", CLAUDE)]);
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "hello", vec![], Settings::default()).unwrap();
    wait_for(&chats, id, "idle");
    chats.request_handoff(id, "terminal").unwrap();
    let cancelled = token(&chats, id);
    chats.cancel_handoff(id).unwrap();
    chats.request_handoff(id, "terminal").unwrap();
    let first = chats.claim_handoffs(&tools)[0]["token"].as_u64().unwrap();
    assert!(first > cancelled);
    chats.finish_handoff(id, first, None).unwrap();
    chats.finish_handoff(id, first, None).unwrap(); // duplicate success is harmless
    chats.request_handoff(id, "terminal").unwrap();
    let reopened = chats.claim_handoffs(&tools)[0]["token"].as_u64().unwrap();
    assert!(reopened > first);
    assert!(chats.finish_handoff(id, first, Some("old failure")).is_err());
    assert_eq!(chats.transcript(id, 0).unwrap()["handoff"]["status"], "launching");
    assert!(chats.transcript(id, 0).unwrap()["handoffError"].is_null());
    chats.finish_handoff(id, reopened, None).unwrap();
    chats.finish_handoff(id, reopened, Some("reopened CLI exited nonzero")).unwrap();
    assert_eq!(chats.transcript(id, 0).unwrap()["handoff"]["status"], "opened");
    assert!(chats.send(&tools, id, "still read only", vec![], Settings::default()).is_err());
}

#[test]
fn codex_resumed_turns_keep_messages_and_tools_when_item_ids_repeat() {
    let script = r#"if [ -f "$0.seen" ]; then text=MARKER; else text=Saved; touch "$0.seen"; fi
echo '{"type":"thread.started","thread_id":"native-history"}'
echo '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"'$text'"}}'
echo '{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"echo '$text'"}}'
echo '{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"echo '$text'","aggregated_output":"'$text'","exit_code":0}}'
echo '{"type":"turn.completed"}'"#;
    let (tools, root) = fixture("codex-repeat-ids", &[("codex", script)]);
    let chats = Chats::default();
    let id = chats.start(&tools, "codex", root.to_str().unwrap(), "remember marker", vec![], Settings::default()).unwrap();
    let first = wait_for(&chats, id, "idle");
    chats.send(&tools, id, "recall marker", vec![], Settings::default()).unwrap();
    let t = wait_for(&chats, id, "idle");
    assert_eq!(kinds(&t), ["user", "assistant", "tool", "user", "assistant", "tool"]);
    assert_eq!(t["entries"][1]["text"], "Saved");
    assert_eq!(t["entries"][4]["text"], "MARKER");
    assert_eq!(t["entries"][2]["output"], "Saved");
    assert_eq!(t["entries"][5]["output"], "MARKER");
    assert_eq!(t["entries"][2], first["entries"][2]);
    assert_eq!(t["sessionId"], "native-history");
    chats.request_handoff(id, "terminal").unwrap();
    assert_eq!(chats.claim_handoffs(&tools)[0]["sessionId"], "native-history");
    assert_eq!(chats.transcript(id, 0).unwrap()["entries"], t["entries"]);
}

fn s(model: Option<&str>, effort: Option<&str>, mode: Option<&str>, fast: bool) -> Settings {
    Settings { model: model.map(Into::into), effort: effort.map(Into::into), mode: mode.map(Into::into), fast, name: None, ultracode: false }
}

#[test]
fn claude_settings_become_flags_on_start_and_on_resume() {
    let (tools, root) = fixture("claude-flags", &[("claude", CLAUDE)]);
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "plan it", vec![], s(Some("opus"), Some("high"), Some("plan"), true)).unwrap();
    wait_for(&chats, id, "idle");
    chats.send(&tools, id, "go", vec![], s(None, None, Some("acceptEdits"), false)).unwrap();
    wait_for(&chats, id, "idle");
    let args = std::fs::read_to_string(root.join("bin/claude.args")).unwrap();
    let lines: Vec<&str> = args.lines().collect();
    assert!(lines[0].contains("--model opus --effort high --permission-mode plan --settings {\"fastMode\":true}"), "{args}");
    assert!(lines[1].contains("--permission-mode acceptEdits --resume sess-1"), "{args}");
    assert!(!lines[1].contains("--model"), "Default passes no flag: {args}");
}

#[test]
fn codex_defaults_to_workspace_write_and_maps_model_and_reasoning() {
    let script = r#"echo "$@" >> "$0.args"
echo '{"type":"thread.started","thread_id":"th-1"}'
echo '{"type":"turn.completed"}'"#;
    let (tools, root) = fixture("codex-flags", &[("codex", script)]);
    let chats = Chats::default();
    let id = chats.start(&tools, "codex", root.to_str().unwrap(), "hi", vec![], Settings::default()).unwrap();
    wait_for(&chats, id, "idle");
    chats.send(&tools, id, "more", vec![], s(Some("gpt-6-sol"), Some("xhigh"), Some("danger-full-access"), false)).unwrap();
    wait_for(&chats, id, "idle");
    let args = std::fs::read_to_string(root.join("bin/codex.args")).unwrap();
    let lines: Vec<&str> = args.lines().collect();
    assert_eq!(lines[0], "exec --json --skip-git-repo-check -s workspace-write -- hi");
    assert_eq!(lines[1], "exec --json --skip-git-repo-check -m gpt-6-sol -c model_reasoning_effort=\"xhigh\" -s danger-full-access resume th-1 -- more");
}

#[test]
fn settings_that_could_smuggle_flags_or_unknown_modes_are_refused() {
    let (tools, root) = fixture("bad-settings", &[("claude", CLAUDE), ("codex", "exit 0")]);
    let dir = root.to_str().unwrap();
    let chats = Chats::default();
    for bad in [
        s(Some("--dangerously-skip-permissions"), None, None, false),
        s(None, Some("high max"), None, false),
        s(None, Some("high\"x"), None, false),
        s(Some(""), None, None, false),
        s(None, None, Some("manual"), false),
        s(None, None, Some("dontAsk"), false),
    ] {
        assert!(chats.start(&tools, "claude", dir, "x", vec![], bad.clone()).is_err(), "{bad:?}");
    }
    assert!(chats.start(&tools, "codex", dir, "x", vec![], s(None, None, Some("plan"), false)).is_err());
    assert!(chats.start(&tools, "codex", dir, "x", vec![], s(None, None, None, true)).is_err(), "fast is Claude only");
    assert!(chats.list().as_array().unwrap().is_empty(), "a refused start leaves no chat behind");

    let id = chats.start(&tools, "claude", dir, "ok", vec![], Settings::default()).unwrap();
    wait_for(&chats, id, "idle");
    assert!(chats.send(&tools, id, "x", vec![], s(None, None, Some("manual"), false)).is_err());
    assert_eq!(kinds(&chats.transcript(id, 0).unwrap()).iter().filter(|k| *k == "user").count(), 1, "a refused send adds no message");
}

#[test]
fn a_caption_marks_the_first_turn_and_every_change_of_settings() {
    let (tools, root) = fixture("caption", &[("claude", CLAUDE)]);
    let chats = Chats::default();
    let plan = Settings { name: Some("Opus 5.5".into()), ..s(Some("opus"), Some("xhigh"), Some("plan"), true) };
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "one", vec![], plan.clone()).unwrap();
    wait_for(&chats, id, "idle");
    chats.send(&tools, id, "two", vec![], plan).unwrap();
    wait_for(&chats, id, "idle");
    chats.send(&tools, id, "three", vec![], Settings::default()).unwrap();
    let t = wait_for(&chats, id, "idle");
    let captions: Vec<&str> = t["entries"].as_array().unwrap().iter()
        .filter(|e| e["kind"] == "user").map(|e| e["caption"].as_str().unwrap()).collect();
    assert_eq!(captions, ["Plan · Opus 5.5 · Extra high · Fast", "", "Default"], "same settings: no caption; a change back to all-Default says so");
    assert_eq!(t["settings"]["mode"], Value::Null);
    assert_eq!(chats.list()[0]["settings"]["fast"], false);
}

#[test]
fn a_terminal_handoff_carries_the_chats_last_flags() {
    let (tools, root) = fixture("handoff-flags", &[("claude", CLAUDE)]);
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "one", vec![], s(Some("opus"), None, Some("plan"), false)).unwrap();
    wait_for(&chats, id, "idle");
    chats.request_handoff(id, "terminal").unwrap();
    let claim = chats.claim_handoffs(&tools);
    assert_eq!(claim[0]["args"], serde_json::json!(["--model", "opus", "--permission-mode", "plan"]));
}

#[test]
fn ultracode_rides_in_the_same_settings_json_as_fast_mode_and_is_claude_only() {
    let (tools, root) = fixture("ultracode", &[("claude", CLAUDE), ("codex", "exit 0")]);
    let dir = root.to_str().unwrap();
    let chats = Chats::default();
    let ultra = Settings { ultracode: true, name: Some("Opus 5.5".into()), ..s(Some("opus"), None, None, true) };
    let id = chats.start(&tools, "claude", dir, "go", vec![], ultra).unwrap();
    let t = wait_for(&chats, id, "idle");
    let args = std::fs::read_to_string(root.join("bin/claude.args")).unwrap();
    assert!(args.contains("--model opus --settings {\"fastMode\":true,\"ultracode\":true}"), "{args}");
    assert_eq!(t["entries"][0]["caption"], "Opus 5.5 · Fast · Ultracode");
    assert!(chats.start(&tools, "codex", dir, "x", vec![], Settings { ultracode: true, ..Settings::default() }).is_err());
}

#[test]
fn ask_user_question_waits_for_an_answer_and_images_ride_in_the_user_message() {
    let script = r#"read first
echo "$first" >> "$0.in"
echo '{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Which?","options":[{"label":"A"}]}]}}}'
read resp
echo "$resp" >> "$0.in"
echo '{"type":"result","subtype":"success","is_error":false,"session_id":"s"}'"#;
    let (tools, root) = fixture("question", &[("claude", script)]);
    let chats = Chats::default();
    let img = Image { media_type: "image/png".into(), data: "QUJD".into() };
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "look", vec![img.clone()], Settings::default()).unwrap();
    let end = Instant::now() + Duration::from_secs(10);
    while chats.transcript(id, 0).unwrap()["question"].is_null() {
        assert!(Instant::now() < end, "no question arrived");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(chats.transcript(id, 0).unwrap()["entries"][0]["images"], 1);
    chats.answer(id, Some(serde_json::json!({"Which?": "A"}))).unwrap();
    let t = wait_for(&chats, id, "idle");
    assert!(t["question"].is_null());
    let log = std::fs::read_to_string(root.join("bin/claude.in")).unwrap();
    assert!(log.contains("\"data\":\"QUJD\"") && log.contains("\"text\":\"look\""), "{log}");
    assert!(log.contains("\"behavior\":\"allow\"") && log.contains("\"answers\":{\"Which?\":\"A\"}"), "{log}");
    assert!(chats.start(&tools, "codex", root.to_str().unwrap(), "x", vec![img], Settings::default()).is_err(), "images are Claude only");
}

#[test]
fn other_tool_permissions_are_denied_and_skip_declines_the_question() {
    let script = r#"read first
echo '{"type":"control_request","request_id":"b1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{}}}'
read denied
echo "$denied" >> "$0.in"
echo '{"type":"control_request","request_id":"q1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[]}}}'
read skipped
echo "$skipped" >> "$0.in"
echo '{"type":"result","subtype":"success","is_error":false,"session_id":"s"}'"#;
    let (tools, root) = fixture("deny", &[("claude", script)]);
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "go", vec![], Settings::default()).unwrap();
    let end = Instant::now() + Duration::from_secs(10);
    while chats.transcript(id, 0).unwrap()["question"].is_null() {
        assert!(Instant::now() < end, "no question arrived");
        std::thread::sleep(Duration::from_millis(20));
    }
    chats.answer(id, None).unwrap();
    wait_for(&chats, id, "idle");
    let log = std::fs::read_to_string(root.join("bin/claude.in")).unwrap();
    let lines: Vec<&str> = log.lines().collect();
    assert!(lines[0].contains("\"request_id\":\"b1\"") && lines[0].contains("\"behavior\":\"deny\""), "{log}");
    assert!(lines[1].contains("\"request_id\":\"q1\"") && lines[1].contains("\"behavior\":\"deny\""), "{log}");
}
