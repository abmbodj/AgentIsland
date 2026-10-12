// Point a scratch CODEX_HOME at Agent Island's hook, trusted via Codex's own hashes (test runs only).
use island_core::{install, installer};
fn main() {
    let home = std::path::PathBuf::from(std::env::args().nth(1).expect("codex home"));
    let hook = std::env::args().nth(2).expect("hook path");
    let hooks = installer::install_codex_hooks(None, &hook).unwrap();
    let codex = install::find_codex().expect("codex");
    let hashes = install::codex_hashes(&codex, &hooks, &home.with_extension("scratch")).unwrap();
    std::fs::write(home.join("hooks.json"), &hooks).unwrap();
    let path = std::fs::canonicalize(home.join("hooks.json")).unwrap().to_string_lossy().to_string();
    let entries: Vec<(String, String)> = installer::codex_trust_keys(&hooks, &path).into_iter().map(|(l, k)| (k, hashes[&l].clone())).collect();
    let config = std::fs::read_to_string(home.join("config.toml")).ok();
    std::fs::write(home.join("config.toml"), installer::append_block(config.as_deref(), &installer::codex_config_block(&entries))).unwrap();
    println!("{:?}", install::codex_hook_status(&codex, &home).unwrap());
}
