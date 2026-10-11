use island_core::installer::{install_claude, uninstall_claude, ClaudeParts};
use serde_json::Value;

const HOOK: &str = "/Users/me/Library/Application Support/AgentIsland/bin/island-hook";
const ALL: ClaudeParts = ClaudeParts { hooks: true, statusline: true };

fn fixture(name: &str) -> String {
    std::fs::read_to_string(format!("{}/../../fixtures/settings/{name}", env!("CARGO_MANIFEST_DIR"))).unwrap()
}

fn json(s: &str) -> Value {
    serde_json::from_str(s).expect("valid JSON")
}

fn our_commands(v: &Value, event: &str) -> Vec<String> {
    v["hooks"][event]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|g| g["hooks"].as_array().unwrap().iter())
        .map(|h| h["command"].as_str().unwrap().to_string())
        .filter(|c| c.contains("AgentIsland/bin/island-hook"))
        .collect()
}

const EVENTS: [&str; 12] = [
    "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
    "PermissionRequest", "Notification", "Stop", "StopFailure", "SubagentStart", "SubagentStop",
];

#[test]
fn install_adds_one_fail_open_hook_per_event_and_keeps_foreign_hooks() {
    let after = install_claude(Some(&fixture("claude-spaced-colon.json")), HOOK, ALL).unwrap();
    let v = json(&after);
    for e in EVENTS {
        assert_eq!(
            our_commands(&v, e),
            vec![format!("'{HOOK}' claude 2>/dev/null || true")],
            "event {e}"
        );
    }
    assert_eq!(v["hooks"]["PostToolUse"].as_array().unwrap().len(), 2, "foreign PostToolUse hook kept");
    assert_eq!(v["hooks"]["PreToolUse"][0]["matcher"], "*");
    assert_eq!(v["hooks"]["PermissionRequest"][0]["hooks"][0]["timeout"], 86400);
    assert_eq!(v["model"], "opus[1m]");
}

#[test]
fn install_only_adds_lines_and_rewrites_the_statusline_command() {
    let before = fixture("claude-spaced-colon.json");
    let after = install_claude(Some(&before), HOOK, ALL).unwrap();
    // Every original line survives, in order, except the statusLine command line.
    let mut rest = after.lines();
    for line in before.lines().filter(|l| !l.contains("gsd-statusline")) {
        assert!(rest.any(|l| l == line), "original line lost or reformatted: {line:?}");
    }
    // New text follows the file's own `"key" : value` style.
    assert!(after.contains("\"PreToolUse\" : ["), "{after}");
}

#[test]
fn statusline_wrapper_tees_to_the_island_and_falls_back_to_the_original() {
    let after = install_claude(Some(&fixture("claude-spaced-colon.json")), HOOK, ALL).unwrap();
    let cmd = json(&after)["statusLine"]["command"].as_str().unwrap().to_string();
    let original = r#"node "/Users/me/.claude/hooks/gsd-statusline.js""#;
    assert_eq!(
        cmd,
        format!("'{HOOK}' statusline -- 'node \"/Users/me/.claude/hooks/gsd-statusline.js\"' 2>/dev/null || sh -c 'node \"/Users/me/.claude/hooks/gsd-statusline.js\"'")
    );
    assert!(cmd.contains(original));
}

#[test]
fn statusline_is_created_when_absent() {
    let after = install_claude(Some(&fixture("claude-standard.json")), HOOK, ALL).unwrap();
    let v = json(&after);
    assert_eq!(v["statusLine"]["type"], "command");
    assert_eq!(v["statusLine"]["command"], format!("'{HOOK}' statusline 2>/dev/null || true"));
    assert!(after.contains("\"statusLine\": {"), "uses the file's `\"key\": value` style:\n{after}");
}

#[test]
fn install_is_idempotent() {
    let once = install_claude(Some(&fixture("claude-standard.json")), HOOK, ALL).unwrap();
    let twice = install_claude(Some(&once), HOOK, ALL).unwrap();
    assert_eq!(once, twice);
}

#[test]
fn parts_can_be_declined() {
    let after = install_claude(Some(&fixture("claude-spaced-colon.json")), HOOK, ClaudeParts { hooks: true, statusline: false }).unwrap();
    assert!(!json(&after)["statusLine"]["command"].as_str().unwrap().contains("island-hook"));
}

#[test]
fn missing_file_and_empty_object_get_a_complete_config() {
    for before in [None, Some(fixture("claude-empty-object.json"))] {
        let after = install_claude(before.as_deref(), HOOK, ALL).unwrap();
        let v = json(&after);
        assert_eq!(our_commands(&v, "Stop").len(), 1);
        assert!(v["statusLine"]["command"].as_str().unwrap().contains("statusline"));
    }
}

#[test]
fn malformed_json_is_refused() {
    assert!(install_claude(Some("{ \"model\": "), HOOK, ALL).is_err());
}

#[test]
fn surgical_uninstall_restores_the_original_exactly() {
    for name in ["claude-spaced-colon.json", "claude-standard.json", "claude-empty-object.json"] {
        let before = fixture(name);
        let installed = install_claude(Some(&before), HOOK, ALL).unwrap();
        let removed = uninstall_claude(&installed, Some(&before)).unwrap();
        assert_eq!(removed.as_deref(), Some(before.as_str()), "{name}");
    }
}

#[test]
fn uninstall_keeps_changes_made_after_install() {
    let before = fixture("claude-spaced-colon.json");
    let installed = install_claude(Some(&before), HOOK, ALL).unwrap();
    let drifted = installed.replace("\"model\" : \"opus[1m]\"", "\"model\" : \"sonnet\"");
    let removed = uninstall_claude(&drifted, Some(&before)).unwrap().unwrap();
    assert_eq!(removed, before.replace("\"model\" : \"opus[1m]\"", "\"model\" : \"sonnet\""));
}

#[test]
fn uninstall_of_a_file_we_created_deletes_it() {
    let installed = install_claude(None, HOOK, ALL).unwrap();
    assert_eq!(uninstall_claude(&installed, None).unwrap(), None);
}
