// Dry run: print the install diff for a settings file without writing anything.
fn main() {
    let path = std::env::args().nth(1).expect("path");
    let before = std::fs::read_to_string(&path).ok();
    let hook = "/Users/ab/Library/Application Support/AgentIsland/bin/island-hook";
    let parts = island_core::installer::ClaudeParts { hooks: true, statusline: true };
    let after = island_core::installer::install_claude(before.as_deref(), hook, parts).unwrap();
    let back = island_core::installer::uninstall_claude(&after, before.as_deref()).unwrap();
    println!("{}", similar::TextDiff::from_lines(before.as_deref().unwrap_or(""), &after).unified_diff().context_radius(1));
    println!("roundtrip identical: {}", back.as_deref() == before.as_deref());
}
