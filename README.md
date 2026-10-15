# Agent Island

A calm, notch-style status light for local AI coding agents (Claude Code and Codex). It sits in your MacBook's notch, shows each agent session as a quiet dot, expands when an agent needs your approval or an answer, and jumps to the exact terminal tab when you click a session.

Fully local: no accounts, no telemetry. The only network request is the optional update check.

Status: under construction. See [`docs/PLAN.md`](docs/PLAN.md).

## Using it

- Hover the notch (or click it) to see sessions; click a row to jump to its terminal tab or pane.
- When an agent needs you the island opens a card: **Allow / Deny / Allow for session**, or the numbered answers to its question. Every response has a 2-second undo.
- **⌥⌘I** gives the island the keyboard: ⌘Y allow, ⌘N deny, ⌘1–9 answer, J/K move, Esc undo or close. Rebind it in Settings.

## Install

Download [`AgentIsland.dmg`](https://github.com/abmbodj/AgentIsland/releases/latest/download/AgentIsland.dmg), drag the app to Applications, open it. First launch offers to move itself to Applications, then one **Set Up** button connects Claude Code and Codex, turns on open-at-login and automatic updates. Updates then arrive from GitHub Releases on their own.

## Releasing

One-time: `xcrun notarytool store-credentials AgentIsland` (Apple ID, team `ZC5949HH2P`, app-specific password). Then:

```sh
scripts/release.sh 0.1.0      # build, sign, notarize, DMG + appcast, publish the GitHub release
```

`--dry-run` builds without publishing; `--unsigned` skips notarization (never publishable).

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
