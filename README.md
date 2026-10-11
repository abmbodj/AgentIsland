# Agent Island

A calm, notch-style status light for local AI coding agents (Claude Code and Codex). It sits in your MacBook's notch, shows each agent session as a quiet dot, expands when an agent needs your approval or an answer, and jumps to the exact terminal tab when you click a session.

Fully local: no accounts, no telemetry. The only network request is the optional update check.

Status: under construction. See [`docs/PLAN.md`](docs/PLAN.md).

## Build

Requires Xcode 26+, Rust (`brew install rustup && rustup default stable`), XcodeGen.

```sh
cd core && cargo test          # state machine, installer, E2E hook→socket→core
scripts/install.sh             # Release build signed with your Apple Development cert → /Applications
scripts/release.sh 0.1.0 --dry-run   # signed, notarized (with Developer ID) DMG + Sparkle appcast
```

Debug aids: `~/Library/Application Support/AgentIsland/bin/island-hook status` prints the live session snapshot.
Debug builds honour `AGENT_ISLAND_HOME` (scratch home for integrations) and `AGENT_ISLAND_RENDER=/tmp/pill.png`.

## Layout

- `core/` Rust: session store, state machine, agent adapters, local socket server, installer, `island-hook` CLI.
- `macos/` Swift/AppKit shell (XcodeGen).
- `vscode-ext/` companion extension for precise VS Code/Cursor terminal jump.
- `fixtures/` real hook payloads used by tests.
