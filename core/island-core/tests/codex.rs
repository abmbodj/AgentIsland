mod common;
use common::{codex, fixture_in};
use island_core::store::{Answer, State, Store};
use serde_json::{json, Value};

const T0: u64 = 1_791_800_000_000;
const THREAD: &str = "01a12fc4-413a-7d30-8744-8d3dc1664395";
const CONN: u64 = 7;

fn only(s: &Store) -> island_core::store::Session {
    let snap = s.snapshot();
    assert_eq!(snap.sessions.len(), 1);
    snap.sessions[0].clone()
}

fn attached() -> Store {
    let mut s = Store::default();
    s.handle(&codex("SessionStart", json!({})), T0);
    s.set_attached("codex", THREAD, Some(CONN));
    s
}

#[test]
fn codex_sessions_track_like_claude_ones() {
    let mut s = Store::default();
    s.handle(&codex("SessionStart", json!({})), T0);
    assert_eq!((only(&s).agent.as_str(), only(&s).project.as_str(), only(&s).state), ("codex", "proj", State::Idle));
    s.handle(&codex("UserPromptSubmit", json!({})), T0 + 1);
    s.handle(&codex("PreToolUse-Bash", json!({})), T0 + 2);
    assert_eq!(only(&s).activity, "Running `touch codex-approve.txt`");
    s.handle(&codex("PreToolUse-request_user_input", json!({})), T0 + 3);
    assert_eq!(only(&s).activity, "Asking a question");
    s.handle(&codex("Stop", json!({})), T0 + 4);
    assert_eq!(only(&s).state, State::Finished);
}

#[test]
fn attached_codex_hooks_never_wait_on_the_island() {
    let mut s = attached();
    assert_eq!(s.handle(&codex("PermissionRequest-Bash", json!({})), T0 + 1), None);
}

#[test]
fn unattached_codex_approvals_wait_for_an_inline_allow_or_deny() {
    let mut s = Store::default();
    let id = s.handle(&codex("PermissionRequest-Bash", json!({})), T0).expect("held");
    let a = only(&s).pending[0].clone();
    assert!(a.held && a.releasable);
    assert!(!a.can_allow_session, "hooks can't grant session rules in Codex");
    assert_eq!(a.note.as_deref(), Some("May I create codex-approve.txt in the workspace with escalated write access?"));
    s.answer(id, Answer::Allow, T0 + 1);
    let (rid, out) = s.take_replies().remove(0);
    assert_eq!(rid, id);
    assert_eq!(serde_json::from_str::<Value>(&out).unwrap()["hookSpecificOutput"]["decision"]["behavior"], "allow");
}

#[test]
fn releasing_hands_the_prompt_back_to_codex() {
    let mut s = Store::default();
    let id = s.handle(&codex("PermissionRequest-Bash", json!({})), T0).unwrap();
    s.release(id);
    assert_eq!(s.take_replies(), vec![(id, String::new())], "empty reply: Codex shows its own prompt");
    let a = only(&s).pending[0].clone();
    assert!(!a.held, "card becomes a handoff");
    // PostToolUse input lacks the request's "description": match on the command.
    s.handle(&codex("PostToolUse-Bash", json!({})), T0 + 1);
    assert!(only(&s).pending.is_empty());
}

#[test]
fn attached_sessions_get_inline_cards_from_the_app_server() {
    let mut s = attached();
    s.handle(&codex("PermissionRequest-Bash", json!({})), T0 + 1);
    assert!(only(&s).pending.is_empty(), "the hook adds nothing; the app-server request does");
    s.appserver_message(CONN, &fixture_in("codex", "appserver-commandApproval"), T0 + 2);
    let a = only(&s).pending[0].clone();
    assert!(a.held);
    assert_eq!(a.title, "Run command");
    assert_eq!(a.detail, "touch codex-approve.txt");
    assert_eq!(a.note.as_deref(), Some("May I create codex-approve.txt in the workspace with escalated write access?"));
    assert!(a.can_allow_session);
    assert_eq!(only(&s).state, State::NeedsInput);
}

fn replies(s: &mut Store) -> Vec<(u64, Value)> {
    s.take_appserver_replies()
}

#[test]
fn app_server_decisions_map_to_codex_vocabulary() {
    for (answer, decision) in [(Answer::Allow, "accept"), (Answer::AllowSession, "acceptForSession"), (Answer::Deny, "decline")] {
        let mut s = attached();
        s.appserver_message(CONN, &fixture_in("codex", "appserver-commandApproval"), T0 + 2);
        let id = only(&s).pending[0].id;
        s.answer(id, answer, T0 + 3);
        assert_eq!(replies(&mut s), vec![(CONN, json!({"id": 0, "result": {"decision": decision}}))]);
        assert_eq!(only(&s).state, State::Working);
    }
}

#[test]
fn codex_questions_answer_by_question_id() {
    let mut s = attached();
    s.appserver_message(CONN, &fixture_in("codex", "appserver-requestUserInput"), T0 + 2);
    let a = only(&s).pending[0].clone();
    assert_eq!(a.kind, "question");
    assert_eq!(a.questions[0].id, "preferred_color");
    assert!(a.questions[0].allows_other);
    assert_eq!(a.questions[0].options[1].label, "Green");
    s.answer(a.id, Answer::Answers([("Which color do you prefer?".to_string(), "Green".to_string())].into()), T0 + 3);
    assert_eq!(
        replies(&mut s),
        vec![(CONN, json!({"id": 1, "result": {"answers": {"preferred_color": {"answers": ["Green"]}}}}))]
    );
}

#[test]
fn answered_elsewhere_removes_the_card_without_replying() {
    let mut s = attached();
    s.appserver_message(CONN, &fixture_in("codex", "appserver-commandApproval"), T0 + 2);
    s.appserver_message(CONN, &fixture_in("codex", "appserver-resolved"), T0 + 3);
    assert!(only(&s).pending.is_empty());
    assert!(replies(&mut s).is_empty());
    assert_eq!(only(&s).state, State::Working);
}

#[test]
fn losing_the_app_server_turns_inline_cards_into_handoffs() {
    let mut s = attached();
    s.appserver_message(CONN, &fixture_in("codex", "appserver-commandApproval"), T0 + 2);
    s.appserver_closed(CONN);
    assert!(!only(&s).pending[0].held);
    assert!(!only(&s).inline);
}

#[test]
fn codex_rate_limits_come_from_the_app_server() {
    let mut s = attached();
    s.appserver_message(CONN, &fixture_in("codex", "appserver-rateLimits"), 1_791_810_000_000);
    let u = s.snapshot().usage.codex.expect("codex usage");
    let w: Vec<(String, f64, u64)> = u.windows.iter().map(|w| (w.label.clone(), w.used_percent, w.resets_at)).collect();
    assert_eq!(w, vec![("5h".into(), 0.0, 1_791_820_767_000), ("wk".into(), 15.0, 1_792_333_696_000)]);
}

#[test]
fn codex_rate_limits_also_come_from_rollout_token_counts() {
    let mut s = Store::default();
    let line = json!({"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":98.0,"window_minutes":300,"resets_at":1_791_820_767u64},"secondary":{"used_percent":15.0,"window_minutes":10080,"resets_at":1_792_333_696u64}}}});
    s.codex_rollout_rate_limits(&line, 1_791_810_000_000);
    let u = s.snapshot().usage.codex.unwrap();
    assert_eq!(u.windows[0].used_percent, 98.0);
    assert_eq!(u.windows[1].label, "wk");
}

#[test]
fn interrupt_ends_the_turn_quietly() {
    let mut s = Store::default();
    s.handle(&codex("UserPromptSubmit", json!({})), T0);
    s.handle(&codex("PermissionRequest-Bash", json!({})), T0 + 1);
    s.handle(&codex("Stop", json!({"hook_event_name":"Interrupt"})), T0 + 2);
    assert!(only(&s).pending.is_empty());
    assert_eq!(only(&s).state, State::Idle);
}

#[test]
fn identity_resolved_from_the_tui_process_replaces_the_daemon_env() {
    let mut s = Store::default();
    s.handle(&codex("SessionStart", json!({})), T0);
    let t = island_core::store::Terminal { program: Some("iTerm.app".into()), tty: Some("ttys004".into()), ..Default::default() };
    s.set_identity("codex", THREAD, t, Some(4242));
    s.handle(&codex("PreToolUse-Bash", json!({})), T0 + 1); // later hooks (daemon env) must not clobber it
    let x = only(&s);
    assert_eq!((x.terminal.program.as_deref(), x.terminal.tty.as_deref(), x.pid), (Some("iTerm.app"), Some("ttys004"), Some(4242)));
}
