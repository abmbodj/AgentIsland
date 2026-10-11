//! Consent-based config edits: pure text in, text out. File I/O, backups and hashes live in `install`.
use crate::jsonedit::{self, Node};
use serde_json::{json, Value};

/// Present in every command we write; how our entries are recognised on uninstall.
pub const MARKER: &str = "/island-hook'";

pub const CLAUDE_EVENTS: [&str; 12] = [
    "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
    "PermissionRequest", "Notification", "Stop", "StopFailure", "SubagentStart", "SubagentStop",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClaudeParts {
    pub hooks: bool,
    pub statusline: bool,
}

pub fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

fn claude_group(hook: &str, event: &str) -> Value {
    let mut h = json!({"type": "command", "command": format!("{} claude 2>/dev/null || true", shell_quote(hook))});
    if event == "PermissionRequest" {
        // Approvals wait for the user; the island answers or releases the hook.
        h["timeout"] = json!(86400);
    }
    if matches!(event, "PreToolUse" | "PostToolUse" | "PostToolUseFailure" | "PermissionRequest") {
        json!({"matcher": "*", "hooks": [h]})
    } else {
        json!({"hooks": [h]})
    }
}

fn statusline_command(hook: &str, original: Option<&str>) -> String {
    match original {
        Some(o) => format!("{} statusline -- {} 2>/dev/null || sh -c {}", shell_quote(hook), shell_quote(o), shell_quote(o)),
        None => format!("{} statusline 2>/dev/null || true", shell_quote(hook)),
    }
}

fn text_of<'a>(s: &'a str, n: &Node) -> &'a str {
    &s[n.start()..n.end()]
}

pub fn install_claude(original: Option<&str>, hook: &str, parts: ClaudeParts) -> Result<String, String> {
    let mut s = original.unwrap_or("{}\n").to_string();
    let root = jsonedit::parse(&s)?;
    if !matches!(root, Node::Obj { .. }) {
        return Err("settings.json is not a JSON object".into());
    }
    let st = jsonedit::style(&s, &root);

    if parts.hooks {
        for event in CLAUDE_EVENTS {
            let root = jsonedit::parse(&s)?;
            let Some(hooks) = root.get("hooks") else {
                s = jsonedit::insert_member(&s, &root, 0, "hooks", &json!({}), &st);
                let root = jsonedit::parse(&s)?;
                s = jsonedit::insert_member(&s, root.get("hooks").unwrap(), 1, event, &json!([claude_group(hook, event)]), &st);
                continue;
            };
            match hooks.get(event) {
                Some(arr @ Node::Arr { .. }) => {
                    if !text_of(&s, arr).contains(MARKER) {
                        s = jsonedit::append_item(&s, arr, 2, &claude_group(hook, event), &st);
                    }
                }
                Some(_) => return Err(format!("hooks.{event} is not an array")),
                None => s = jsonedit::insert_member(&s, hooks, 1, event, &json!([claude_group(hook, event)]), &st),
            }
        }
    }

    if parts.statusline {
        let root = jsonedit::parse(&s)?;
        match root.get("statusLine") {
            None => {
                let v = json!({"type": "command", "command": statusline_command(hook, None)});
                s = jsonedit::insert_member(&s, &root, 0, "statusLine", &v, &st);
            }
            Some(sl) => {
                if let Some(cmd @ Node::Scalar { .. }) = sl.get("command") {
                    let current: String = serde_json::from_str(text_of(&s, cmd)).map_err(|e| e.to_string())?;
                    if !current.contains(MARKER) {
                        let wrapped = Value::String(statusline_command(hook, Some(&current))).to_string();
                        s = jsonedit::replace(&s, cmd, &wrapped);
                    }
                }
            }
        }
    }
    Ok(s)
}

/// Remove only our entries. `original` is the pre-install file (None = we created it).
/// Returns None when the file should be deleted.
pub fn uninstall_claude(current: &str, original: Option<&str>) -> Result<Option<String>, String> {
    let orig_text = original.unwrap_or("{}\n");
    let orig_root = jsonedit::parse(orig_text)?;
    let orig: Value = serde_json::from_str(orig_text).map_err(|e| e.to_string())?;
    let mut s = current.to_string();

    // Our hook groups, one at a time (spans shift after each splice).
    'outer: loop {
        let root = jsonedit::parse(&s)?;
        let Some(Node::Obj { members, .. }) = root.get("hooks") else { break };
        for (event, _, arr) in members {
            if let Node::Arr { items, .. } = arr {
                if let Some(i) = items.iter().position(|it| text_of(&s, it).contains(MARKER)) {
                    s = if items.len() == 1 && orig["hooks"].get(event).is_none() {
                        jsonedit::remove_child(&s, root.get("hooks").unwrap(), members.iter().position(|m| &m.0 == event).unwrap())
                    } else {
                        jsonedit::remove_child(&s, arr, i)
                    };
                    continue 'outer;
                }
            }
        }
        break;
    }
    let root = jsonedit::parse(&s)?;
    if let (Some(Node::Obj { members, .. }), None) = (root.get("hooks"), orig.get("hooks")) {
        if members.is_empty() {
            s = remove_member(&s, &root, "hooks");
        }
    }

    let root = jsonedit::parse(&s)?;
    if let Some(sl) = root.get("statusLine") {
        if text_of(&s, sl).contains(MARKER) {
            s = match orig_root.get("statusLine") {
                Some(o) => jsonedit::replace(&s, sl, text_of(orig_text, o)),
                None => remove_member(&s, &root, "statusLine"),
            };
        }
    }

    if original.is_none() && serde_json::from_str::<Value>(&s).ok() == Some(json!({})) {
        return Ok(None);
    }
    Ok(Some(s))
}

fn remove_member(s: &str, obj: &Node, key: &str) -> String {
    match obj {
        Node::Obj { members, .. } => match members.iter().position(|m| m.0 == key) {
            Some(i) => jsonedit::remove_child(s, obj, i),
            None => s.to_string(),
        },
        _ => s.to_string(),
    }
}
