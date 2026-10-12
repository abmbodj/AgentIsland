use island_core::installer::{append_block, codex_config_block, codex_trust_keys, install_codex_hooks, remove_block, uninstall_claude, CODEX_EVENTS};
use serde_json::Value;

const HOOK: &str = "/Users/me/Library/Application Support/AgentIsland/bin/island-hook";

fn fixture(name: &str) -> String {
    std::fs::read_to_string(format!("{}/../../fixtures/settings/{name}", env!("CARGO_MANIFEST_DIR"))).unwrap()
}

#[test]
fn codex_hooks_json_gets_one_fail_open_group_per_event() {
    let after = install_codex_hooks(None, HOOK).unwrap();
    let v: Value = serde_json::from_str(&after).unwrap();
    for e in CODEX_EVENTS {
        assert_eq!(v["hooks"][e][0]["hooks"][0]["command"], format!("'{HOOK}' codex 2>/dev/null || true"), "{e}");
    }
    assert_eq!(v["hooks"]["PermissionRequest"][0]["matcher"], "*");
    assert_eq!(v["hooks"]["PermissionRequest"][0]["hooks"][0]["timeout"], 86400);
    assert!(v["hooks"]["SessionEnd"][0].get("matcher").is_none());
}

#[test]
fn foreign_codex_hooks_are_kept_and_our_trust_keys_point_at_our_groups() {
    let before = r#"{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "say done"
          }
        ]
      }
    ]
  }
}
"#;
    let after = install_codex_hooks(Some(before), HOOK).unwrap();
    let v: Value = serde_json::from_str(&after).unwrap();
    assert_eq!(v["hooks"]["Stop"][0]["hooks"][0]["command"], "say done");
    let keys = codex_trust_keys(&after, "/Users/me/.codex/hooks.json");
    assert!(keys.contains(&("stop".to_string(), "/Users/me/.codex/hooks.json:stop:1:0".to_string())), "{keys:?}");
    assert!(keys.contains(&("pre_tool_use".to_string(), "/Users/me/.codex/hooks.json:pre_tool_use:0:0".to_string())));
    assert_eq!(keys.len(), CODEX_EVENTS.len());
    // And uninstall restores the original bytes.
    assert_eq!(uninstall_claude(&after, Some(before)).unwrap().as_deref(), Some(before));
}

#[test]
fn trust_block_appends_and_removes_cleanly() {
    let before = fixture("codex-config.toml");
    let block = codex_config_block(&[("/u/.codex/hooks.json:stop:0:0".into(), "sha256:abc".into())]);
    assert_eq!(block, "\n[hooks.state.\"/u/.codex/hooks.json:stop:0:0\"]\ntrusted_hash = \"sha256:abc\"\n");
    let after = append_block(Some(&before), &block);
    assert!(after.starts_with(&before));
    assert_eq!(remove_block(&after, &block).as_deref(), Some(before.as_str()));
    // A config without a trailing newline still gets a well-formed table.
    let odd = append_block(Some("model = \"x\""), &block);
    assert!(odd.starts_with("model = \"x\"\n\n[hooks.state."));
}

/// The real thing: Codex's own app-server must report our hooks as trusted.
#[test]
fn real_codex_trusts_the_hashes_we_write() {
    let Some(codex) = island_core::install::find_codex() else { return };
    let home = std::path::PathBuf::from(format!("/tmp/isl-trust-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    let hooks = install_codex_hooks(None, HOOK).unwrap();
    let hashes = island_core::install::codex_hashes(&codex, &hooks, &home.join("scratch")).expect("hooks/list");
    assert_eq!(hashes.len(), CODEX_EVENTS.len());
    std::fs::write(home.join("hooks.json"), &hooks).unwrap();
    let path = std::fs::canonicalize(home.join("hooks.json")).unwrap().to_string_lossy().to_string();
    let entries: Vec<(String, String)> = codex_trust_keys(&hooks, &path).into_iter().map(|(label, key)| (key, hashes[&label].clone())).collect();
    std::fs::write(home.join("config.toml"), append_block(None, &codex_config_block(&entries))).unwrap();
    let status = island_core::install::codex_hook_status(&codex, &home).expect("status");
    assert_eq!(status.len(), CODEX_EVENTS.len());
    assert!(status.iter().all(|s| s == "trusted"), "{status:?}");
}
