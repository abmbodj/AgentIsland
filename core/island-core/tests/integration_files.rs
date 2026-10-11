use island_core::install::{Integrations, UninstallMode};
use std::path::PathBuf;

fn tmp(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("island-test-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("home/.claude")).unwrap();
    d
}

fn setup(name: &str, original: Option<&str>) -> (Integrations, PathBuf) {
    let d = tmp(name);
    let settings = d.join("home/.claude/settings.json");
    if let Some(o) = original {
        std::fs::write(&settings, o).unwrap();
    }
    (Integrations::new(d.join("support"), d.join("home")), settings)
}

const ORIGINAL: &str = "{\n  \"model\": \"opus\",\n  \"permissions\": {\n    \"allow\": []\n  }\n}\n";

#[test]
fn install_then_uninstall_restores_identical_bytes() {
    let (i, settings) = setup("roundtrip", Some(ORIGINAL));
    let plan = i.plan_install();
    assert_eq!(plan.iter().map(|p| p.id.as_str()).collect::<Vec<_>>(), ["claude-hooks", "claude-statusline"]);
    assert!(plan.iter().all(|p| p.diff.contains("+")));
    i.apply_install(&["claude-hooks", "claude-statusline"]).unwrap();
    assert!(std::fs::read_to_string(&settings).unwrap().contains("island-hook"));

    let un = i.plan_uninstall();
    assert!(!un[0].drifted);
    i.apply_uninstall(UninstallMode::Surgical).unwrap();
    assert_eq!(std::fs::read(&settings).unwrap(), ORIGINAL.as_bytes());
    assert!(i.plan_uninstall().is_empty(), "nothing left to uninstall");
}

#[test]
fn uninstall_of_a_created_file_deletes_it() {
    let (i, settings) = setup("created", None);
    i.apply_install(&["claude-hooks"]).unwrap();
    assert!(settings.exists());
    i.apply_uninstall(UninstallMode::Surgical).unwrap();
    assert!(!settings.exists());
}

#[test]
fn drift_is_detected_and_foreign_changes_survive_surgical_uninstall() {
    let (i, settings) = setup("drift", Some(ORIGINAL));
    i.apply_install(&["claude-hooks", "claude-statusline"]).unwrap();
    let edited = std::fs::read_to_string(&settings).unwrap().replace("\"opus\"", "\"sonnet\"");
    std::fs::write(&settings, &edited).unwrap();

    let un = i.plan_uninstall();
    assert!(un[0].drifted);
    i.apply_uninstall(UninstallMode::Surgical).unwrap();
    assert_eq!(std::fs::read_to_string(&settings).unwrap(), ORIGINAL.replace("\"opus\"", "\"sonnet\""));
}

#[test]
fn exact_restore_returns_the_install_time_backup() {
    let (i, settings) = setup("exact", Some(ORIGINAL));
    i.apply_install(&["claude-hooks"]).unwrap();
    let edited = std::fs::read_to_string(&settings).unwrap().replace("\"opus\"", "\"sonnet\"");
    std::fs::write(&settings, edited).unwrap();
    i.apply_uninstall(UninstallMode::ExactBackup).unwrap();
    assert_eq!(std::fs::read(&settings).unwrap(), ORIGINAL.as_bytes());
}

#[test]
fn reinstall_keeps_the_very_first_backup() {
    let (i, settings) = setup("reinstall", Some(ORIGINAL));
    i.apply_install(&["claude-hooks"]).unwrap();
    i.apply_install(&["claude-hooks", "claude-statusline"]).unwrap();
    i.apply_uninstall(UninstallMode::ExactBackup).unwrap();
    assert_eq!(std::fs::read(&settings).unwrap(), ORIGINAL.as_bytes());
}

#[test]
fn already_installed_plans_no_change() {
    let (i, _) = setup("noop", Some(ORIGINAL));
    i.apply_install(&["claude-hooks", "claude-statusline"]).unwrap();
    assert!(i.plan_install().is_empty());
}
