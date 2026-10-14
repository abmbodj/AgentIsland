mod common;
use common::claude;
use island_core::store::{Answer, State, Store};
use serde_json::{json, Value};

const T0: u64 = 1_000_000;

fn pending(s: &Store) -> Vec<island_core::store::Attention> {
    s.snapshot().sessions.iter().flat_map(|x| x.pending.clone()).collect()
}

fn state(s: &Store) -> State {
    s.snapshot().sessions[0].state
}

fn reply(s: &mut Store) -> Vec<(u64, Value)> {
    s.take_replies().into_iter().map(|(id, out)| (id, if out.is_empty() { Value::Null } else { serde_json::from_str(&out).unwrap() })).collect()
}

#[test]
fn permission_request_is_held_with_a_readable_card() {
    let mut s = Store::default();
    let held = s.handle(&claude("PermissionRequest-Bash", json!({})), T0);
    let a = &pending(&s)[0];
    assert_eq!(held, Some(a.id));
    assert!(a.held);
    assert_eq!(a.kind, "approval");
    assert_eq!(a.title, "Run command");
    assert_eq!(a.detail, "touch hello.txt");
    assert!(a.can_allow_session);
}

#[test]
fn allow_replies_with_claudes_exact_decision_and_resumes_work() {
    let mut s = Store::default();
    let id = s.handle(&claude("PermissionRequest-Bash", json!({})), T0).unwrap();
    s.answer(id, Answer::Allow, T0 + 1);
    assert_eq!(
        reply(&mut s),
        vec![(id, json!({"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}))]
    );
    assert!(pending(&s).is_empty());
    assert_eq!(state(&s), State::Working);
}

#[test]
fn deny_tells_claude_who_denied_it() {
    let mut s = Store::default();
    let id = s.handle(&claude("PermissionRequest-Bash", json!({})), T0).unwrap();
    s.answer(id, Answer::Deny, T0 + 1);
    let (_, r) = &reply(&mut s)[0];
    assert_eq!(r["hookSpecificOutput"]["decision"]["behavior"], "deny");
    assert_eq!(r["hookSpecificOutput"]["decision"]["message"], "Denied from Agent Island");
}

#[test]
fn allow_for_session_adds_a_session_rule_for_this_exact_command() {
    let mut s = Store::default();
    let id = s.handle(&claude("PermissionRequest-Bash", json!({})), T0).unwrap();
    s.answer(id, Answer::AllowSession, T0 + 1);
    let (_, r) = &reply(&mut s)[0];
    assert_eq!(
        r["hookSpecificOutput"]["decision"],
        json!({"behavior":"allow","updatedPermissions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"touch hello.txt"}],"behavior":"allow","destination":"session"}]})
    );
}

#[test]
fn questions_are_answered_through_updated_input() {
    let mut s = Store::default();
    let id = s.handle(&claude("PermissionRequest-AskUserQuestion", json!({})), T0).unwrap();
    let a = &pending(&s)[0];
    assert_eq!(a.kind, "question");
    assert!(!a.can_allow_session);
    assert_eq!(a.questions[0].question, "Which color do you prefer?");
    assert_eq!(a.questions[0].options.iter().map(|o| o.label.as_str()).collect::<Vec<_>>(), ["Red", "Green", "Blue"]);

    s.answer(id, Answer::Answers([("Which color do you prefer?".to_string(), "Green".to_string())].into()), T0 + 1);
    let (_, r) = &reply(&mut s)[0];
    let d = &r["hookSpecificOutput"]["decision"];
    assert_eq!(d["behavior"], "allow");
    assert_eq!(d["updatedInput"]["answers"], json!({"Which color do you prefer?": "Green"}));
    assert_eq!(d["updatedInput"]["questions"][0]["header"], "Color", "original questions echoed back");
}

#[test]
fn answering_in_the_terminal_releases_the_waiting_hook_silently() {
    let mut s = Store::default();
    s.handle(&claude("PreToolUse-Bash", json!({})), T0);
    let id = s.handle(&claude("PermissionRequest-Bash", json!({})), T0 + 1).unwrap();
    s.handle(&claude("PostToolUse-Bash", json!({})), T0 + 2);
    assert_eq!(reply(&mut s), vec![(id, Value::Null)], "empty reply frees the orphaned hook");
    assert!(pending(&s).is_empty());
    assert_eq!(state(&s), State::Working);
}

#[test]
fn answering_a_question_in_the_terminal_withdraws_its_card() {
    // PostToolUse echoes the questions plus the "answers" the user picked in the terminal.
    let mut s = Store::default();
    let id = s.handle(&claude("PermissionRequest-AskUserQuestion", json!({})), T0).unwrap();
    s.handle(&claude("PostToolUse-AskUserQuestion", json!({})), T0 + 1);
    assert_eq!(reply(&mut s), vec![(id, Value::Null)]);
    assert!(pending(&s).is_empty());
}

#[test]
fn a_killed_hook_withdraws_its_card() {
    let mut s = Store::default();
    let id = s.handle(&claude("PermissionRequest-Bash", json!({})), T0).unwrap();
    s.hook_gone(id, T0 + 1);
    assert!(pending(&s).is_empty());
    assert!(reply(&mut s).is_empty(), "nobody left to reply to");
    assert_ne!(state(&s), State::NeedsInput);
}

#[test]
fn turn_end_releases_every_waiting_hook() {
    let mut s = Store::default();
    let id = s.handle(&claude("PermissionRequest-Bash", json!({})), T0).unwrap();
    s.handle(&claude("Stop", json!({})), T0 + 1);
    assert_eq!(reply(&mut s), vec![(id, Value::Null)]);
}

#[test]
fn answering_twice_or_late_is_harmless() {
    let mut s = Store::default();
    let id = s.handle(&claude("PermissionRequest-Bash", json!({})), T0).unwrap();
    s.answer(id, Answer::Allow, T0 + 1);
    reply(&mut s);
    s.answer(id, Answer::Deny, T0 + 2);
    assert!(reply(&mut s).is_empty());
}

#[test]
fn edits_show_a_counted_diff() {
    let mut s = Store::default();
    let input = json!({"file_path":"/x/src/auth.ts","old_string":"a\nb\nc","new_string":"a\nB\nc\nd\ne"});
    s.handle(&claude("PermissionRequest-Bash", json!({"tool_name":"Edit","tool_input":input})), T0);
    let a = &pending(&s)[0];
    assert_eq!(a.title, "Edit auth.ts");
    assert_eq!(a.detail, "/x/src/auth.ts");
    let d = a.diff.as_ref().unwrap();
    assert_eq!((d.added, d.removed), (3, 1));
    assert!(d.text.contains("-b\n") && d.text.contains("+B\n"), "{}", d.text);
}

#[test]
fn writes_diff_against_the_file_on_disk() {
    let dir = std::env::temp_dir().join(format!("isl-write-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let f = dir.join("config.json");
    std::fs::write(&f, "one\ntwo\n").unwrap();
    let mut s = Store::default();
    let input = json!({"file_path": f.to_str().unwrap(), "content":"one\nthree\n"});
    s.handle(&claude("PermissionRequest-Bash", json!({"tool_name":"Write","tool_input":input})), T0);
    let a = &pending(&s)[0];
    assert_eq!(a.title, "Write config.json");
    let d = a.diff.as_ref().unwrap();
    assert_eq!((d.added, d.removed), (1, 1));
}

#[test]
fn new_files_count_every_line_as_added() {
    let mut s = Store::default();
    let input = json!({"file_path":"/nonexistent/dir/new.md","content":"a\nb\n"});
    s.handle(&claude("PermissionRequest-Bash", json!({"tool_name":"Write","tool_input":input})), T0);
    let d = pending(&s)[0].diff.clone().unwrap();
    assert_eq!((d.added, d.removed), (2, 0));
}

#[test]
fn subagent_requests_say_which_subagent_asks() {
    let mut s = Store::default();
    s.handle(&claude("SubagentStart", json!({})), T0);
    s.handle(&claude("PermissionRequest-Bash", json!({"agent_id":"ab77a0d0ea52d01b9","agent_type":"Explore"})), T0 + 1);
    assert_eq!(pending(&s)[0].subagent.as_deref(), Some("Explore"));
}

fn wrap_up(input: Value) -> island_core::protocol::HookMessage {
    claude("PostToolUse-Bash", json!({"tool_name": "mcp__ccd_turn__wrap_up", "tool_input": input, "tool_response": []}))
}

#[test]
fn a_desktop_next_step_question_waits_on_the_island_until_the_user_replies() {
    let mut s = Store::default();
    s.handle(&claude("UserPromptSubmit", json!({})), T0);
    s.handle(&wrap_up(json!({"recap": "Fixed the bug. Nothing committed.", "ask": "Commit this fix?",
        "actions": [{"action": "commit"}, {"label": "Not yet"}]})), T0 + 1);
    assert!(pending(&s).is_empty(), "the box shows only once the turn ends");
    s.handle(&claude("Stop", json!({})), T0 + 2);

    let a = &pending(&s)[0];
    assert!(!a.held, "nothing to reply to: it is answered in the app");
    assert_eq!(a.kind, "question");
    assert_eq!(a.questions[0].question, "Commit this fix?");
    assert_eq!(a.note.as_deref(), Some("Fixed the bug. Nothing committed."));
    assert_eq!(state(&s), State::NeedsInput);
    assert!(reply(&mut s).is_empty());

    s.handle(&claude("UserPromptSubmit", json!({})), T0 + 3);
    assert!(pending(&s).is_empty());
    assert_eq!(state(&s), State::Working);
}

#[test]
fn a_recap_without_a_question_just_finishes() {
    let mut s = Store::default();
    s.handle(&claude("UserPromptSubmit", json!({})), T0);
    s.handle(&wrap_up(json!({"recap": "Done."})), T0 + 1);
    s.handle(&claude("Stop", json!({})), T0 + 2);
    assert!(pending(&s).is_empty());
    assert_eq!(state(&s), State::Finished);
}

#[test]
fn opening_the_session_hands_the_next_step_over_to_the_app() {
    let mut s = Store::default();
    s.handle(&claude("UserPromptSubmit", json!({})), T0);
    s.handle(&wrap_up(json!({"recap": "r", "ask": "Commit?"})), T0 + 1);
    s.handle(&claude("Stop", json!({})), T0 + 2);
    let sess = s.snapshot().sessions[0].clone();
    s.viewed(&sess.agent, &sess.id, T0 + 3);
    assert!(pending(&s).is_empty(), "a box dismissed in the app must not stick on the island");
    assert_eq!(state(&s), State::Idle);
}

#[test]
fn a_next_step_keeps_the_background_agents_activity() {
    let mut s = Store::default();
    s.handle(&claude("UserPromptSubmit", json!({})), T0);
    s.handle(&wrap_up(json!({"recap": "r", "ask": "Commit?"})), T0 + 1);
    s.handle(&claude("Stop-bgtasks", json!({})), T0 + 2);
    assert_eq!(pending(&s).len(), 1);
    assert!(s.snapshot().sessions[0].activity.starts_with("Waiting for"));
}

#[test]
fn a_subagent_wrap_up_does_not_replace_the_next_step() {
    let mut s = Store::default();
    s.handle(&claude("UserPromptSubmit", json!({})), T0);
    s.handle(&wrap_up(json!({"recap": "r", "ask": "Commit?"})), T0 + 1);
    let mut sub = wrap_up(json!({"recap": "sub"}));
    let mut p: Value = serde_json::from_str(&sub.payload).unwrap();
    p["agent_id"] = json!("a1");
    sub.payload = p.to_string();
    s.handle(&sub, T0 + 2);
    s.handle(&claude("Stop", json!({})), T0 + 3);
    assert_eq!(pending(&s)[0].questions[0].question, "Commit?");
}

#[test]
fn the_apps_create_pr_offer_is_kept_with_its_recap_until_the_next_prompt() {
    let mut s = Store::default();
    s.handle(&claude("UserPromptSubmit", json!({})), T0);
    s.handle(&wrap_up(json!({"recap": "Added the widget.", "actions": [{"action": "commit"}]})), T0 + 1);
    assert_eq!(s.snapshot().sessions[0].pr_offer, None);
    s.handle(&wrap_up(json!({"recap": "Added the widget.", "ask": "Open a PR?", "actions": [{"action": "create_pr"}]})), T0 + 2);
    s.handle(&claude("Stop", json!({})), T0 + 3);
    assert_eq!(s.snapshot().sessions[0].pr_offer.as_deref(), Some("Added the widget."));
    s.handle(&claude("UserPromptSubmit", json!({})), T0 + 4);
    assert_eq!(s.snapshot().sessions[0].pr_offer, None);
}
