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
