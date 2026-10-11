// Criterion 8 check: install → uninstall through the app's Integrations layer on a given home dir.
use island_core::install::{Integrations, UninstallMode};
fn main() {
    let home = std::path::PathBuf::from(std::env::args().nth(1).expect("home"));
    let support = std::path::PathBuf::from(std::env::args().nth(2).expect("support"));
    let it = Integrations::new(support, home);
    let ids: Vec<String> = it.plan_install().into_iter().map(|p| p.id).collect();
    println!("plan: {ids:?}");
    it.apply_install(&ids.iter().map(String::as_str).collect::<Vec<_>>()).unwrap();
    println!("uninstall drifted: {:?}", it.plan_uninstall().iter().map(|u| u.drifted).collect::<Vec<_>>());
    it.apply_uninstall(UninstallMode::Surgical).unwrap();
}
