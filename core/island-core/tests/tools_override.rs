//! Its own test binary: it sets AGENT_ISLAND_TOOLS, which must not race other tests' environment reads.
use island_core::pr::Tools;
use std::os::unix::fs::PermissionsExt;

#[test]
fn an_agent_island_tools_override_beats_a_newer_install() {
    let root = std::env::temp_dir().join(format!("island-override-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    for (dir, out) in [("fake", "0.1.0"), ("real", "codex-cli 9.9.9")] {
        std::fs::create_dir_all(root.join(dir)).unwrap();
        let p = root.join(dir).join("codex");
        std::fs::write(&p, format!("#!/bin/sh\necho '{out}'\n")).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    unsafe { std::env::set_var("AGENT_ISLAND_TOOLS", root.join("fake")) };
    let found = Tools { dirs: vec![root.join("fake"), root.join("real")] }.find("codex");
    assert_eq!(found, Some(root.join("fake/codex")));
}
