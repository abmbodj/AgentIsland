# Agent Island (repo: AgentShelf2): plan

## Context
A calm, notch-style status light for local AI coding agents: Claude Code and Codex, both CLI and Desktop, on macOS and then Windows. It detects sessions through the agents' official hooks and shows each state in a Dynamic-Island pill. Approvals and questions can be answered inline, and clicking a row jumps to the exact terminal tab or pane. It is a status light, not a dashboard. The user's original prompt is the spec (v1 scope, states table, UI, acceptance criteria 1–8, slices 1–5). This plan records every decision from the interview (D1–D38) and the build order.

## Environment (verified)
- MacBook Air M2 (notched), macOS 26.5.1 arm64. Xcode 26.2, Swift 6.2.3, Node 22, Homebrew. Rust is not installed.
- Installed: Terminal, VS Code, Cursor, Claude desktop, Codex Desktop (`/Applications/ChatGPT.app`, `com.openai.codex`), NotchNook (the user will quit it). Not installed: iTerm2, Ghostty, tmux.
- Claude Code 2.1.296. Codex CLI 0.162.1 (`approval_policy="never"`, so Codex approvals won't fire for this user today).
- gh is logged in as `abmbodj`. Desktop is not iCloud-synced. Signing: Apple Development cert only for now; a paid Developer Program membership exists.
- AgentShelf v1 (`~/Desktop/AgentShelf`) is **ignored entirely** (D3). Its hooks are removed up front with its own uninstaller (D4).

## Decisions

**Stack & repo**
- D1 (implementation note: the shell boundary is a 4-function C ABI exchanging JSON, `core/island-core/include/island_core.h`, used by Swift now and C# later; this replaced UniFFI, which has no first-party C# binding): Rust core library (session store, state machine, adapters, socket server, installer, Codex app-server client), plus a tiny static Rust `island-hook` CLI. macOS shell is Swift/AppKit+SwiftUI, linked through UniFFI. The core keeps a stable C ABI for Windows.
- D2/D36: `~/Desktop/AgentShelf2` is a real git repo, with a **public** GitHub repo `abmbodj/AgentShelf2`. Commits go straight to main. **I pause for the user's OK after each slice.**
- D5: At slice 0, `brew install rustup tmux xcodegen` and `brew install --cask iterm2 ghostty`. rustup gets the aarch64 and x86_64 darwin targets.
- D6: macOS 14+. Liquid Glass on 26+, NSVisualEffectView fallback.
- D7: Developer ID signing, hardened runtime plus the apple-events entitlement, notarize, staple, DMG, and a Sparkle 2 EdDSA appcast on GitHub Releases (`scripts/release.sh`). The first-run toggle "Automatically check for updates" defaults ON and is labelled as the only network request. Not the Mac App Store. The user creates the Developer ID cert and notarytool credentials.
- D20: Name **Agent Island**, bundle `com.abmbodj.agentisland`, support dir `~/Library/Application Support/AgentIsland/`. We draw our own agent glyphs; no vendor logos.
- D27: Windows shell is C# WPF on .NET 8 over the Rust C ABI, confirmed by a 1-day spike at the start of slice 5. Testing happens on the user's separate Windows PC (D26). Windows release builds come from GitHub Actions.

**Detection & integration**
- D24: Hooks are the single source of truth. A declined agent is shown as "not connected". There is no transcript or process fallback.
- D25: The hook connects with a 50 ms deadline. If the app is absent, it exits 0 with empty stdout (fail open). The command is wrapped `… 2>/dev/null || true`, so a missing binary exits silently. Any event creates a session lazily, and terminal identity is captured on every event.
- D16: The hook reports the agent PID. The core watches it with kqueue `NOTE_EXIT` on macOS (process handle wait on Windows). Exit without SessionEnd becomes Ended, or Error if mid-turn, and the row is removed after 10 s. Sessions with no known PID that see no events for 30 min while Working become Stale, which is dropped after 2 h.
- D28: Only settings, the install manifest (backups plus SHA-256) and the Ghostty binding cache are persisted. The session store is in-memory. Debug logging is opt-in, redacted, rotating at 5 MB, and off by default.
- D11: Uninstall removes our text spans surgically. If nothing drifted, the result must hash-equal the install-time backup. If something drifted, show a diff, keep the foreign changes, and offer a secondary "Restore exact backup from <date>".
- D10: The Claude statusLine becomes `island-hook statusline -- <original cmd>`. It tees the JSON fire-and-forget, then execs the original command with the same stdin.
- D12: The Codex installer writes our hooks.json entries plus their `trusted_hash` span-edits in config.toml, all shown in the diff. If hooks are detected as untrusted, show a "run /hooks" card.
- D30 (slice-4 spike result: Codex Desktop 26.1002 starts a private app-server with config overrides even with `CODEX_APP_SERVER_USE_LOCAL_DAEMON=1`, so the LaunchAgent was not built; Desktop and daemon-less TUIs instead hold the PermissionRequest hook for inline allow/deny while the user is away and release it to Codex's own prompt as soon as they look; questions hand off): Codex inline answers go through the shared app-server daemon.
  - Connection: `~/.codex/app-server-control/app-server-control.sock`, WebSocket over a Unix socket, JSON-RPC without the `"jsonrpc"` field. Send `initialize{experimentalApi:true}`, then `initialized`.
  - Lifecycle: on a Codex SessionStart, call `thread/resume{threadId, excludeTurns:true}`. On SessionEnd, call `thread/unsubscribe`.
  - Answering: reply by request id. Clear the card on `serverRequest/resolved`. Usage comes from `account/rateLimits/updated`.
  - For daemon-attached threads, the Codex PermissionRequest hook returns empty immediately, and we answer through the app-server (accept / acceptForSession / decline). For unattached sessions the hook blocks (allow/deny only), and questions get an "Open in Codex" handoff (`codex://threads/<id>`).
  - Codex Desktop: a consented LaunchAgent runs `launchctl setenv CODEX_APP_SERVER_USE_LOCAL_DAEMON 1` at login. A slice-4 spike verifies it, and uninstall removes it.
- D14: A bundled companion VSIX is auto-installed into VS Code and Cursor at consent. It registers a URI handler `vscode://…/jump?pid=`, matches `terminal.processId` against the agent's ancestor PIDs, and calls `terminal.show()`. Fallback is `code -r <cwd>`.
- D15: For Ghostty, at SessionStart query the focused terminal and bind its id if its `working directory` equals the cwd. Otherwise use a unique cwd match, otherwise just activate the app. Never write to the tty.
- tmux: capture `TMUX`/`TMUX_PANE`. To jump, focus the outer client's terminal tab (`tmux list-clients` client_tty), then `select-window` and `select-pane`. iTerm2 `-CC` mode is best-effort.
- D34: Permissions are requested just in time. The Automation prompt appears on the first jump into each terminal, and declining falls back to activating the app.

**State machine (single source of truth, in core)**

| From | Event | To |
|---|---|---|
| (none) | any event | Idle (or the event's target) |
| any live | UserPromptSubmit / PreToolUse / PostToolUse | Working (activity label updated) |
| any live | PermissionRequest; PreToolUse(AskUserQuestion); Codex requestApproval/requestUserInput | NeedsInput (attention item queued) |
| NeedsInput | last item answered/resolved/hook-cancelled | Working |
| Working | Stop / Codex turn complete | Finished |
| Working | StopFailure | Error |
| Finished | viewed (jump, row visible ≥1.5 s in panel) / UserPromptSubmit | Idle / Working |
| any | SessionEnd / PID exit | Ended (Error if mid-turn), removed after 10 s |
| Working (no PID) | 30 min with no events | Stale, removed after 2 h; any event restores |

Subagents (SubagentStart/Stop, agent_id) are children of the session and never change the parent's Finished state. Every transition gets a unit test.

**UI**
- D19: With 0 sessions the pill is pure black and notch-sized, so it's invisible. The right wing has one 6 pt glyph per top-level session, up to 6 then "+N". The left wing (● + count) appears only when something is amber. Non-notch displays, external displays and Windows get a slim floating pill at top center, hidden at 0 sessions. D18: the hover zone is the whole notch.
- D31: Working is a neutral off-white dot with a 1.6 s breathing opacity (a static ring under reduced motion). Idle is the same dot at 35% opacity. Amber is used only for Needs input, and green only for Finished. Every state pairs a glyph with its color.
- D32: The panel is always dark glass (Liquid Glass dark / `.hudWindow`), and grows out of the notch as one object.
- D23: Hover opens after 350 ms (adjustable 0–1000). Click pins it open. Needs input auto-expands without taking focus. It collapses 400 ms after the pointer leaves, unless pinned, a card is pending, or it was summoned. An auto-expanded card stays until answered or until a click outside, then collapses to the amber wing.
- D22: The island follows the active screen. Settings offers: Follow active / Built-in only / Specific / All.
- Rows show project (cwd basename), agent glyph, activity, elapsed and state.
  - Activity labels: "Editing auth.ts", "Reading x", "Running `npm test`" (truncated), "Searching", "Delegating to Explore".
  - Elapsed is the turn duration while Working, otherwise the time since the last change.
- D33: A collapsed parent shows a "↳ 3" chip. Expanded subagent rows are indented. On stop they show a check for 1.5 s, then fade out. A subagent's approval surfaces on the parent's card and auto-expands the group.
- D37: The usage strip is one line at the bottom, e.g. `Claude 5h 42% · 7d 18%   Codex 5h 98% · wk 15%`. A window shows until its `resets_at` passes. A muted "as of Xm ago" appears if the data is older than 15 min. ≥90% is shown in bold, never amber, and values are never extrapolated.
- Cards:
  - **Approval card:** tool, command or file, a +N −M diff preview that expands, and Allow / Deny / Allow for session (Claude: `updatedPermissions` from `permission_suggestions`; Codex: acceptForSession).
  - **Question card:** numbered options, with an "Other" free-text field when supported, and multi-question "Q 1 of 2".
  - **Handoff card:** a single "Open session" button.
  - Multiple items are shown one at a time with "1 of 3", oldest first. After an answer, a "✓ Approved" receipt shows.
- D8/D38/D9: Focus and keyboard.
  - The overlay is never key unless summoned. Cards accept first-mouse clicks without taking focus.
  - The summon hotkey ⌥⌘I (rebindable; Ctrl+Alt+I on Windows) makes the panel key without activating the app. In summoned mode, ⌘Y / ⌘N / ⌘1–9, J/K, free text and Esc all work, and focus returns to the previous app afterwards.
  - A click answer turns the button into "Undo" with a 2 s depleting ring. Esc undo works only when summoned.
- D35 (revised after the slice-0 spike, see docs/spike-slice0-claude-permission-race.md): the approval hook always blocks; if the session's own tab is frontmost the island only skips auto-expand and chime, and Claude answers stay inline after switching away. Original text: If the session's own tab is frontmost, the hook returns immediately so the native prompt handles it. The pill shows the amber wing only, with no expansion and no chime. If the user switches away while it's still pending, the card appears: inline for Codex-daemon sessions, or handoff for Claude, depending on the result of the slice-0 race spike.
- D21: Sound. The Needs-input chime is ON by default, and the Finished sound is also ON by default, each with its own toggle. A picker offers macOS system sounds, plus a volume control. Sounds are suppressed when that session's app or tab is frontmost, and limited to one per 10 s.
- D34: First run opens one regular window listing every change, each with a checkbox and an expandable unified diff:
  - Claude: hooks and the statusLine wrapper
  - Codex: hooks.json and trust hashes
  - The VSIX for VS Code and Cursor
  - The Codex Desktop LaunchAgent
  - Launch at login (default on)
  - Update check

  A single "Set up" button applies everything checked.
- Menu bar icon: Settings…, Pause monitoring, Check for Updates…, Uninstall integrations…, Quit. Settings covers agents, auto-expand, chime and finished sound, hover delay, display, hotkey, uninstall and debug log.

## Architecture
```
~/Desktop/AgentShelf2/
  core/                 cargo workspace
    island-core/        model, state machine, store, adapters/{claude,codex}.rs, socket server,
                        codex_appserver.rs, pidwatch.rs, installer/{claude,codex,vsix,launchagent}.rs,
                        diff.rs, usage.rs, uniffi exports
    island-hook/        static bin: read stdin + env + tty + PID chain → NDJSON to socket → (block) → stdout
  macos/                XcodeGen project.yml; AgentIsland/{App, Overlay(NSPanel), Views, Cards, Jump, Onboarding, Settings}
  vscode-ext/           ~50-line TS URI-handler extension (VSIX)
  windows/              slice 5 (WPF)
  fixtures/             captured real hook payloads (Claude, Codex), app-server transcripts
  scripts/              build.sh, dev.sh, e2e.sh, release.sh
  PRODUCT.md, DESIGN.md, README.md
```
- Wire protocol: NDJSON over a 0600 Unix socket at `…/AgentIsland/island.sock` (Windows: per-user named pipe). The hook is dumb and sends `{agent, raw_payload, env subset, tty, pid_chain}`; the core normalizes. Blocking events wait for one reply line holding the exact stdout to print.
- The hook binary is copied from the app bundle to `…/AgentIsland/bin/island-hook` and refreshed on launch, so hook paths survive app moves and updates.
- The core runs the socket server on std threads (no async runtime) and pushes immutable snapshots to the shell through a UniFFI callback. Jump execution is shell-side (AppleScript / Win32 UIA). The core stores the terminal identity.
- Codex rate limits come from app-server notifications when attached. At startup, and when the daemon is absent, fall back to the newest rollout's last `token_count`, using FSEvents on `~/.codex/sessions`.

## Slices (pause for the user's OK after each)
0. **Setup & spike.** With OK, run v1's uninstallers (D4). Install the tools (D5). `git init`, then `gh repo create abmbodj/AgentShelf2 --public`. Run `/impeccable teach` to write PRODUCT.md and DESIGN.md from these decisions. **Spike:** does Claude 2.1.296 show the terminal permission dialog while a PermissionRequest hook blocks, and does the first answer win? Capture real payload fixtures.
1. **Claude detection and collapsed pill (macOS).** Core: store, state machine (TDD), Claude adapter, socket, pidwatch, installer and uninstaller with diff and hash. `island-hook`. NSPanel pill (notch-flush and floating), menu bar, onboarding window, launch at login, Sparkle plus release.sh, CI (`cargo test` and the Swift build on macOS). Checks: criterion 1, plus 6, 7 and 8 for Claude files.
2. **Expanded panel and jump.** Rows, subagents, the Claude usage strip, and jump for Terminal, iTerm2, Ghostty, tmux, VS Code/Cursor via the VSIX, and the Claude Desktop app. Checks: 4, 5, 6.
3. **Approvals and questions (Claude).** Cards, diff, allow-for-session, ⌘1–9 and free text, undo, receipts, the queue, the summon hotkey, sounds, and frontmost deferral. Checks: 2, 3, 7.
4. **Codex.** Hooks plus trust-hash installer, app-server client, the Desktop LaunchAgent spike, `codex://` jump, Codex usage and subagents. Checks: criteria 1–8 re-run for Codex CLI and Desktop.
5. **Windows (deferred 2026-10-14: no Windows PC available yet; resume with the WPF spike when it is).** WPF spike, then the shell. Named pipe, Windows paths, Windows Terminal jump (spike: map `WT_SESSION` to a tab via UI Automation, then `wt focus-tab`), VS Code/Cursor, tray, CI release. Checks: 1–8 on the user's PC.

## Verification (D29, every slice)
1. Rust unit tests written test-first: every state-machine transition, adapter normalization against real fixtures, installer install→uninstall byte-hash round-trip (criterion 8) including the drift case, the diff builder, and the usage-window expiry.
2. `scripts/e2e.sh`: the real `island-hook` binary fed captured payloads, through the socket, into a headless core. It asserts the resulting state, latency under 1 s (criterion 1), blocking-reply correctness and fail-open when no app is running.
3. Real-agent scripted checks:
   - Launch `claude` in iTerm2 via AppleScript.
   - Trigger a permission, answer through the core's test entry point, and assert the agent proceeded (criterion 2).
   - Then a manual checklist, screen-recorded: focus is never stolen while typing in TextEdit (criterion 7), the jump lands on the exact tab or pane, including tmux (criterion 4), and 5 idle or working sessions never expand the pill or change its color (criterion 6).
4. Footprint check: under 100 MB RSS with 5 sessions (`footprint`), and about 0% idle CPU in Activity Monitor and `sample`.

## Skills to use during build
`mattpocock-skills:tdd` (core and state machine), `/impeccable teach`, then `craft` (pill, panel, cards), `superpowers:verification-before-completion` before calling any slice done.
