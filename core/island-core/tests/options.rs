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
fn claude_names_carry_their_version_and_any_cased_default_is_dropped() {
    // Some CLI builds report a bare family ("Opus") as displayName and put "Opus 5.5" in the description,
    // and spell their own default entry "Default".
    let v = read("claude-initialize-short-names.jsonl");
    let m = parse_claude(&v["response"]["response"]);
    let ids: Vec<&str> = m.iter().map(|m| m.id.as_str()).collect();
    assert!(!ids.iter().any(|id| id.eq_ignore_ascii_case("default")), "{ids:?}");
    let names: Vec<&str> = m.iter().map(|m| m.name.as_str()).collect();
    assert_eq!(names, ["Opus 5.5", "Fable 5", "Sonnet 5.5", "Haiku 5.5"]);
}

#[test]
fn only_the_newest_model_of_each_claude_family_counts_as_latest() {
    let v = read("claude-initialize.jsonl");
    let models = parse_claude(&v["response"]["response"]);
    let latest: Vec<(&str, bool)> = models.iter().map(|m| (m.id.as_str(), m.latest)).collect();
    // Opus 5.5 beats the pinned Opus 4.6; Haiku 4.5 is the only Haiku listed, so it stays.
    assert_eq!(latest, [("opus", true), ("fable", true), ("claude-haiku-4-5-20251001", true), ("claude-opus-4-6", false)]);
    let v = read("claude-initialize-short-names.jsonl");
    assert!(parse_claude(&v["response"]["response"]).iter().all(|m| m.latest));
    assert!(parse_codex(&read("codex-models.json")).iter().all(|m| m.latest), "Codex already lists only what its own picker shows");
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

use island_core::options::{fetch, Options};
use island_core::pr::Tools;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::time::{Duration, Instant};

fn bin(name: &str, scripts: &[(&str, String)]) -> (Tools, PathBuf) {
    let root = std::env::temp_dir().join(format!("island-options-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("bin")).unwrap();
    for (n, body) in scripts {
        let p = root.join("bin").join(n);
        std::fs::write(&p, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    (Tools { dirs: vec![root.join("bin")] }, root)
}

fn settled(opts: &Options, tools: &Tools) -> Value {
    let end = Instant::now() + Duration::from_secs(10);
    loop {
        let v = opts.get(tools, false);
        if v["claude"]["loading"] == false && v["codex"]["loading"] == false {
            return v;
        }
        assert!(Instant::now() < end, "never settled: {v}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn options_fetch_both_agents_in_the_background_and_cache_them() {
    // The fake claude answers initialize, then keeps running like the real one: the fetch must kill it.
    let claude = format!("echo \"$@\" > \"$0.args\"\nread l\necho \"$l\" > \"$0.in\"\necho 'not json'\ncat '{}'\nsleep 30", fx("claude-initialize.jsonl"));
    let codex = format!("cat '{}'", fx("codex-models.json"));
    let (tools, root) = bin("ok", &[("claude", claude), ("codex", codex)]);
    let opts = Options::default();
    assert_eq!(opts.get(&tools, true)["claude"]["loading"], true);
    let v = settled(&opts, &tools);
    assert_eq!(v["claude"]["models"][0]["id"], "opus");
    assert_eq!(v["codex"]["models"].as_array().unwrap().len(), 2);
    assert!(v["claude"]["error"].is_null());
    let args = std::fs::read_to_string(root.join("bin/claude.args")).unwrap();
    assert!(args.contains("disableAllHooks"), "the probe must not fire the user's hooks: {args}");
    assert!(std::fs::read_to_string(root.join("bin/claude.in")).unwrap().contains("\"initialize\""));
    assert_eq!(opts.get(&tools, true)["claude"]["loading"], false, "a fresh cache starts no new fetch");
}

#[test]
fn a_missing_cli_reports_an_error_and_is_retried_on_the_next_refresh() {
    let (tools, _) = bin("missing", &[]);
    let opts = Options::default();
    opts.get(&tools, true);
    let v = settled(&opts, &tools);
    assert!(v["codex"]["models"].as_array().unwrap().is_empty());
    assert!(v["codex"]["error"].as_str().unwrap().contains("codex"));
    assert_eq!(opts.get(&tools, true)["codex"]["loading"], true, "a failed fetch is not cached for an hour");
}

#[test]
fn a_probe_that_never_answers_is_killed_at_the_timeout() {
    let (tools, _) = bin("hang", &[("claude", "sleep 30".to_string())]);
    let start = Instant::now();
    let err = fetch(&tools, "claude", Duration::from_millis(300)).unwrap_err();
    assert!(start.elapsed() < Duration::from_secs(5), "took {:?}", start.elapsed());
    assert!(err.contains("too long"), "{err}");
}

#[test]
fn with_two_installs_the_newest_version_wins_whatever_the_search_order() {
    let (old, old_root) = bin("old-cli", &[("claude", "echo '2.1.185 (Claude Code)'".to_string())]);
    let (new, new_root) = bin("new-cli", &[("claude", "echo '2.1.299 (Claude Code)'".to_string())]);
    let tools = Tools { dirs: [old.dirs, new.dirs].concat() };
    assert_eq!(tools.find("claude"), Some(new_root.join("bin/claude")));
    // A copy that can't report a version never beats one that can.
    let (odd, _) = bin("odd-cli", &[("claude", "echo nonsense".to_string())]);
    let tools = Tools { dirs: [odd.dirs, vec![old_root.join("bin")]].concat() };
    assert_eq!(tools.find("claude"), Some(old_root.join("bin/claude")));
}

#[test]
fn git_and_gh_keep_search_order_and_never_run_version() {
    // Both copies would hang on --version; search order must answer without running either.
    let (a, a_root) = bin("git-a", &[("git", "sleep 30".to_string())]);
    let (b, _) = bin("git-b", &[("git", "sleep 30".to_string())]);
    let start = Instant::now();
    assert_eq!(Tools { dirs: [a.dirs, b.dirs].concat() }.find("git"), Some(a_root.join("bin/git")));
    assert!(start.elapsed() < Duration::from_secs(1));
}

#[test]
fn a_family_is_the_word_before_the_version() {
    let v: Value = serde_json::json!({"models": [
        {"value": "a", "displayName": "Claude Opus 5.5"}, {"value": "b", "displayName": "Claude Sonnet 5.5"},
        {"value": "c", "displayName": "Claude Opus 4.6"}]});
    let latest: Vec<bool> = parse_claude(&v).iter().map(|m| m.latest).collect();
    assert_eq!(latest, [true, true, false]);
}
