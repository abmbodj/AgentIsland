mod common;
use common::claude;
use island_core::store::{State, Store};
use serde_json::json;

const T0: u64 = 1_000_000;

#[test]
fn session_start_creates_idle_session_with_project_name() {
    let mut s = Store::default();
    s.handle(&claude("SessionStart", json!({})), T0);
    let snap = s.snapshot();
    assert_eq!(snap.sessions.len(), 1);
    assert_eq!(snap.sessions[0].project, "proj");
    assert_eq!(snap.sessions[0].agent, "claude");
    assert_eq!(snap.sessions[0].state, State::Idle);
}

fn store_with_session() -> Store {
    let mut s = Store::default();
    s.handle(&claude("SessionStart", json!({})), T0);
    s
}

fn only(s: &Store) -> island_core::store::Session {
    let snap = s.snapshot();
    assert_eq!(snap.sessions.len(), 1, "expected exactly one session");
    snap.sessions[0].clone()
}

#[test]
fn any_event_creates_the_session_lazily_and_later_events_reuse_it() {
    let mut s = Store::default();
    s.handle(&claude("UserPromptSubmit", json!({})), T0);
    s.handle(&claude("PreToolUse-Bash", json!({})), T0 + 10);
    assert_eq!(only(&s).state, State::Working);
}

#[test]
fn prompt_submit_starts_a_working_turn() {
    let mut s = store_with_session();
    s.handle(&claude("UserPromptSubmit", json!({})), T0 + 5);
    let sess = only(&s);
    assert_eq!(sess.state, State::Working);
    assert_eq!(sess.since, T0 + 5);
    assert_eq!(sess.activity, "Thinking");
}

#[test]
fn tool_use_sets_a_human_activity_label() {
    let mut s = store_with_session();
    s.handle(&claude("PreToolUse-Bash", json!({})), T0 + 5);
    assert_eq!(only(&s).activity, "Running `touch hello.txt`");
    s.handle(&claude("PreToolUse-Bash", json!({"tool_name":"Edit","tool_input":{"file_path":"/x/src/auth.ts"}})), T0 + 6);
    assert_eq!(only(&s).activity, "Editing auth.ts");
    s.handle(&claude("PreToolUse-Bash", json!({"tool_name":"Read","tool_input":{"file_path":"/x/README.md"}})), T0 + 7);
    assert_eq!(only(&s).activity, "Reading README.md");
    s.handle(&claude("PreToolUse-Bash", json!({"tool_name":"Grep","tool_input":{"pattern":"x"}})), T0 + 8);
    assert_eq!(only(&s).activity, "Searching");
    s.handle(&claude("PreToolUse-Agent", json!({})), T0 + 9);
    assert_eq!(only(&s).activity, "Delegating to Explore");
}

#[test]
fn long_commands_are_truncated_in_the_label() {
    let mut s = store_with_session();
    let long = "cargo test --workspace --all-features -- --nocapture --test-threads=1";
    s.handle(&claude("PreToolUse-Bash", json!({"tool_input":{"command":long}})), T0 + 5);
    let a = only(&s).activity;
    assert!(a.starts_with("Running `cargo test --workspace"), "{a}");
    assert!(a.ends_with("…`"), "{a}");
    assert!(a.chars().count() <= 44, "{a}");
}

#[test]
fn permission_request_needs_input_until_the_tool_completes() {
    let mut s = store_with_session();
    s.handle(&claude("PreToolUse-Bash", json!({})), T0 + 1);
    s.handle(&claude("PermissionRequest-Bash", json!({})), T0 + 2);
    assert_eq!(only(&s).state, State::NeedsInput);
    assert_eq!(s.snapshot().attention, 1);
    s.handle(&claude("PostToolUse-Bash", json!({})), T0 + 3);
    assert_eq!(only(&s).state, State::Working);
    assert_eq!(s.snapshot().attention, 0);
}

#[test]
fn plan_approval_clears_when_the_tool_completes_with_a_different_input() {
    // The desktop app's ExitPlanMode request carries the plan; the completed tool's input does not.
    let mut s = store_with_session();
    let plan = json!({"tool_name": "ExitPlanMode", "tool_input": {"plan": "# Plan", "planFilePath": "/tmp/p.md"}});
    s.handle(&claude("PermissionRequest-Bash", plan), T0 + 1);
    assert_eq!(s.snapshot().attention, 1);
    s.handle(&claude("PostToolUse-Bash", json!({"tool_name": "ExitPlanMode", "tool_input": {}})), T0 + 2);
    assert_eq!(s.snapshot().attention, 0);
    assert_eq!(only(&s).state, State::Working);
}

#[test]
fn tool_activity_while_waiting_for_input_keeps_needs_input() {
    let mut s = store_with_session();
    s.handle(&claude("PermissionRequest-Bash", json!({})), T0 + 2);
    // a subagent keeps working in the background
    s.handle(&claude("PreToolUse-Bash-subagent", json!({})), T0 + 3);
    assert_eq!(only(&s).state, State::NeedsInput);
}

#[test]
fn stop_finishes_the_turn_and_clears_pending_input() {
    let mut s = store_with_session();
    s.handle(&claude("PermissionRequest-Bash", json!({})), T0 + 2);
    s.handle(&claude("Stop", json!({})), T0 + 3);
    assert_eq!(only(&s).state, State::Finished);
    assert_eq!(s.snapshot().attention, 0);
}

#[test]
fn stop_with_running_background_agents_stays_working() {
    let mut s = store_with_session();
    s.handle(&claude("UserPromptSubmit", json!({})), T0 + 1);
    s.handle(&claude("Stop-bgtasks", json!({})), T0 + 3);
    let sess = only(&s);
    assert_eq!(sess.state, State::Working);
    assert_eq!(sess.activity, "Waiting for 1 agent");
}

#[test]
fn stop_failure_is_an_error() {
    let mut s = store_with_session();
    s.handle(&claude("UserPromptSubmit", json!({})), T0 + 1);
    s.handle(&claude("Stop", json!({"hook_event_name":"StopFailure"})), T0 + 3);
    assert_eq!(only(&s).state, State::Error);
}

#[test]
fn notifications_do_not_change_state() {
    let mut s = store_with_session();
    s.handle(&claude("UserPromptSubmit", json!({})), T0 + 1);
    s.handle(&claude("Notification", json!({})), T0 + 2);
    assert_eq!(only(&s).state, State::Working);
}

const SEC: u64 = 1000;
const MIN: u64 = 60 * SEC;

fn sid(s: &Store) -> (String, String) {
    let x = only(s);
    (x.agent, x.id)
}

#[test]
fn finished_fades_to_idle_once_viewed() {
    let mut s = store_with_session();
    s.handle(&claude("Stop", json!({})), T0 + 1);
    let (agent, id) = sid(&s);
    s.viewed(&agent, &id, T0 + 2);
    assert_eq!(only(&s).state, State::Idle);
}

#[test]
fn viewing_a_working_session_changes_nothing() {
    let mut s = store_with_session();
    s.handle(&claude("UserPromptSubmit", json!({})), T0 + 1);
    let (agent, id) = sid(&s);
    s.viewed(&agent, &id, T0 + 2);
    assert_eq!(only(&s).state, State::Working);
}

#[test]
fn finished_turn_resumes_working_on_next_prompt() {
    let mut s = store_with_session();
    s.handle(&claude("Stop", json!({})), T0 + 1);
    s.handle(&claude("UserPromptSubmit", json!({})), T0 + 2);
    assert_eq!(only(&s).state, State::Working);
}

#[test]
fn session_end_marks_ended_then_removes_after_grace() {
    let mut s = store_with_session();
    s.handle(&claude("SessionEnd", json!({})), T0 + 1);
    assert_eq!(only(&s).state, State::Ended);
    assert_eq!(s.next_deadline(), Some(T0 + 1 + 10 * SEC));
    s.tick(T0 + 1 + 9 * SEC);
    assert_eq!(s.snapshot().sessions.len(), 1);
    s.tick(T0 + 1 + 10 * SEC);
    assert_eq!(s.snapshot().sessions.len(), 0);
}

#[test]
fn agent_pid_comes_from_claude_pid_env() {
    let s = store_with_session();
    assert_eq!(only(&s).pid, Some(68105));
}

#[test]
fn process_exit_mid_turn_is_an_error() {
    let mut s = store_with_session();
    s.handle(&claude("UserPromptSubmit", json!({})), T0 + 1);
    s.process_exited(68105, T0 + 2);
    assert_eq!(only(&s).state, State::Error);
    s.tick(T0 + 2 + 10 * SEC);
    assert!(s.snapshot().sessions.is_empty());
}

#[test]
fn process_exit_while_idle_is_a_normal_end() {
    let mut s = store_with_session();
    s.process_exited(68105, T0 + 2);
    assert_eq!(only(&s).state, State::Ended);
}

fn without_pid(mut m: island_core::protocol::HookMessage) -> island_core::protocol::HookMessage {
    m.env.remove("CLAUDE_PID");
    m
}

#[test]
fn quiet_working_session_without_pid_goes_stale_then_is_dropped() {
    let mut s = Store::default();
    s.handle(&without_pid(claude("UserPromptSubmit", json!({}))), T0);
    s.tick(T0 + 29 * MIN);
    assert_eq!(only(&s).state, State::Working);
    s.tick(T0 + 30 * MIN);
    assert_eq!(only(&s).state, State::Stale);
    s.tick(T0 + 30 * MIN + 2 * 60 * MIN);
    assert!(s.snapshot().sessions.is_empty());
}

#[test]
fn stale_session_comes_back_on_any_event() {
    let mut s = Store::default();
    s.handle(&without_pid(claude("UserPromptSubmit", json!({}))), T0);
    s.tick(T0 + 30 * MIN);
    s.handle(&without_pid(claude("PreToolUse-Bash", json!({}))), T0 + 31 * MIN);
    assert_eq!(only(&s).state, State::Working);
}

#[test]
fn sessions_with_a_live_pid_never_go_stale() {
    let mut s = store_with_session();
    s.handle(&claude("UserPromptSubmit", json!({})), T0);
    s.tick(T0 + 5 * 60 * MIN);
    assert_eq!(only(&s).state, State::Working);
}

#[test]
fn terminal_identity_is_captured() {
    let s = store_with_session();
    let t = only(&s).terminal;
    assert_eq!(t.tty.as_deref(), Some("ttys001"));
    assert_eq!(t.tmux_pane.as_deref(), Some("%0"));
    assert_eq!(t.program.as_deref(), Some("tmux"));
}

#[test]
fn desktop_host_session_id_is_captured() {
    let mut s = Store::default();
    let mut m = claude("SessionStart", json!({}));
    m.env.insert("CLAUDE_CODE_HOST_SESSION_ID".into(), "local_17a9f453-e7a4".into());
    s.handle(&m, T0);
    assert_eq!(only(&s).terminal.host_session.as_deref(), Some("local_17a9f453-e7a4"));
}

#[test]
fn subagents_nest_under_their_parent_and_fade_after_stopping() {
    let mut s = store_with_session();
    s.handle(&claude("PreToolUse-Agent", json!({})), T0 + 1);
    s.handle(&claude("SubagentStart", json!({})), T0 + 2);
    s.handle(&claude("PreToolUse-Bash-subagent", json!({})), T0 + 3);
    let sess = only(&s);
    assert_eq!(sess.subagents.len(), 1);
    assert_eq!(sess.subagents[0].kind, "Explore");
    assert!(sess.subagents[0].activity.starts_with("Running `find"));
    assert_eq!(sess.activity, "Delegating to Explore", "subagent tools must not relabel the parent");

    s.handle(&claude("SubagentStop", json!({})), T0 + 4);
    assert!(only(&s).subagents[0].done);
    s.tick(T0 + 4 + 1500);
    assert!(only(&s).subagents.is_empty());
}

#[test]
fn stop_events_from_unknown_internal_agents_are_ignored() {
    let mut s = store_with_session();
    s.handle(&claude("UserPromptSubmit", json!({})), T0 + 1);
    s.handle(&claude("SubagentStop-internal", json!({})), T0 + 2);
    let sess = only(&s);
    assert!(sess.subagents.is_empty());
    assert_eq!(sess.state, State::Working);
}
