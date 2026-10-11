// Print a settings.json containing only Agent Island's hooks (for `claude --settings` test runs).
fn main() {
    let hook = std::env::args().nth(1).expect("hook path");
    let parts = island_core::installer::ClaudeParts { hooks: true, statusline: true };
    print!("{}", island_core::installer::install_claude(None, &hook, parts).unwrap());
}
