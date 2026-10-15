//! Model menus: parsing what each CLI reports, and fetching it in the background.
use island_core::options::{parse_claude, parse_codex};
use serde_json::Value;

fn fx(name: &str) -> String {
    format!("{}/../../fixtures/options/{name}", env!("CARGO_MANIFEST_DIR"))
}

fn read(name: &str) -> Value {
    serde_json::from_str(std::fs::read_to_string(fx(name)).unwrap().trim()).unwrap()
}

#[test]
fn claude_initialize_lists_models_with_their_effort_levels() {
    let v = read("claude-initialize.jsonl");
    let m = parse_claude(&v["response"]["response"]);
    let ids: Vec<&str> = m.iter().map(|m| m.id.as_str()).collect();
    assert_eq!(ids, ["opus", "fable", "claude-haiku-4-5-20251001", "claude-opus-4-6"], "Claude's own \"default\" entry is dropped");
    assert_eq!(m[0].name, "Opus 5.5");
    assert!(m[0].fast && m[0].auto);
    assert!(!m[1].fast);
    assert!(m[2].efforts.is_empty(), "a model without effort support lists no levels");
    assert_eq!(m[3].efforts, ["low", "medium", "high", "max"]);
}

#[test]
fn codex_models_keep_only_listed_ones_with_their_reasoning_levels() {
    let m = parse_codex(&read("codex-models.json"));
    let ids: Vec<&str> = m.iter().map(|m| m.id.as_str()).collect();
    assert_eq!(ids, ["gpt-6-sol", "gpt-6-luna"], "hidden models are left out");
    assert_eq!(m[0].name, "GPT-6-Sol");
    assert_eq!(m[0].efforts.last().map(String::as_str), Some("ultra"));
    assert_eq!(m[1].efforts.last().map(String::as_str), Some("max"));
    assert!(!m[0].fast && !m[0].auto);
}
