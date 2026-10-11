# Agent Island

A calm, notch-style status light for local AI coding agents (Claude Code and Codex). It sits in your MacBook's notch, shows each agent session as a quiet dot, expands when an agent needs your approval or an answer, and jumps to the exact terminal tab when you click a session.

Fully local: no accounts, no telemetry. The only network request is the optional update check.

Status: under construction. See [`docs/PLAN.md`](docs/PLAN.md).

## Layout

- `core/` Rust: session store, state machine, agent adapters, local socket server, installer, `island-hook` CLI.
- `macos/` Swift/AppKit shell (XcodeGen).
- `vscode-ext/` companion extension for precise VS Code/Cursor terminal jump.
- `fixtures/` real hook payloads used by tests.
