//! Small, counted diff previews for approval cards ("+3 −1").
use serde::Serialize;
use serde_json::Value;
use similar::{ChangeTag, TextDiff};

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DiffPreview {
    pub added: usize,
    pub removed: usize,
    /// Unified hunks (no file headers), capped for display.
    pub text: String,
}

const MAX_LINES: usize = 400;
const MAX_FILE: u64 = 1 << 20;

fn nl(s: &str) -> String {
    if s.is_empty() || s.ends_with('\n') { s.to_string() } else { format!("{s}\n") }
}

fn diff_pair(old: &str, new: &str) -> DiffPreview {
    let (old, new) = (nl(old), nl(new));
    let d = TextDiff::from_lines(&old, &new);
    let (mut added, mut removed) = (0, 0);
    for c in d.iter_all_changes() {
        match c.tag() {
            ChangeTag::Insert => added += 1,
            ChangeTag::Delete => removed += 1,
            ChangeTag::Equal => {}
        }
    }
    let text = d.unified_diff().context_radius(2).to_string();
    DiffPreview { added, removed, text }
}

fn merge(parts: Vec<DiffPreview>) -> DiffPreview {
    let mut out = DiffPreview { added: 0, removed: 0, text: String::new() };
    for p in parts {
        out.added += p.added;
        out.removed += p.removed;
        out.text.push_str(&p.text);
    }
    let lines: Vec<&str> = out.text.lines().collect();
    if lines.len() > MAX_LINES {
        out.text = format!("{}\n… {} more lines\n", lines[..MAX_LINES].join("\n"), lines.len() - MAX_LINES);
    }
    out
}

fn read_capped(path: &str) -> String {
    match std::fs::metadata(path) {
        Ok(m) if m.len() <= MAX_FILE => std::fs::read_to_string(path).unwrap_or_default(),
        _ => String::new(),
    }
}

/// Preview for file-changing tools; None for everything else.
pub fn preview(tool: &str, input: &Value) -> Option<DiffPreview> {
    let s = |v: &Value| v.as_str().unwrap_or_default().to_string();
    match tool {
        "Edit" => {
            let mut d = merge(vec![diff_pair(&s(&input["old_string"]), &s(&input["new_string"]))]);
            if input["replace_all"] == true {
                // One hunk shown, but every occurrence counted.
                let old = s(&input["old_string"]);
                let n = if old.is_empty() { 1 } else { read_capped(input["file_path"].as_str()?).matches(old.as_str()).count().max(1) };
                (d.added, d.removed) = (d.added * n, d.removed * n);
            }
            Some(d)
        }
        "MultiEdit" => Some(merge(
            input["edits"].as_array()?.iter().map(|e| diff_pair(&s(&e["old_string"]), &s(&e["new_string"]))).collect(),
        )),
        "Write" => Some(merge(vec![diff_pair(&read_capped(input["file_path"].as_str()?), &s(&input["content"]))])),
        _ => None,
    }
}
