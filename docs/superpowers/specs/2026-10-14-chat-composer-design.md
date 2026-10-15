# Chat composer in the island panel

## Context
Today Agent Island only *observes* sessions (hooks + Codex app-server). The request: type a message in the panel to start a new agent session, then converse with it (streaming, tool rows, Stop, error states). The prompt called the panel "Shelf view" and assumed a reusable session-start path; neither exists as named. "Shelf" = the expanded `PanelView`. Core has no launch / send / stop / transcript capability, so this is new core work plus a new UI surface.

## Decisions (settled in the interview)
1. Surface: **inside the notch panel** (not a separate window). Amend PRODUCT.md / DESIGN.md: island can start and converse with sessions; panel becomes key only on composer click/summon.
2. Agents: **Claude Code and Codex**, small remembered toggle beside Send (agent choice only, no model picker, locked after start).
3. cwd: last-active session's project (fallback `~`), shown as a label under the composer, click to change via NSOpenPanel, remembered.
4. Permissions: reuse existing approval cards (hooks keep firing for Claude; Codex app-server approvals already handled).
5. Lifetime: background, in-memory transcript, appears as a normal session row, re-openable from the row, child processes killed on app quit, no resume.
6. Transport: new `island_call` op with cursor pull (`transcript {id, since}`), polled only while a chat is open. No new FFI callback.
7. Panel: list mode stays 440x460; chat mode grows to ~640x640 (screen-capped), message column ~560pt centered; key focus only on composer click/summon; hover-out must not collapse while composer is focused or a turn is running.
8. Theme: keep notch-black (D32); chat built with semantic colors, VoiceOver labels, keyboard nav, Reduce Motion respected. Amber/green keep their single meanings (amber for "waiting for approval", green never used for chat).
9. Markdown: fenced code blocks (monospaced, Copy button, no highlighting) + inline via `AttributedString(markdown:)`; unclosed fence while streaming renders as code.
10. Follow-ups: same composer in chat; Send becomes Stop during a turn; Enter held until turn ends, drafting still allowed. Shift+Enter = newline.
11. Verification: env override for agent binaries (extends `Tools` in `pr.rs`) + fake script emitting scripted stream-json; real Claude for streaming screenshot, fake for error. Same fake drives cargo tests.

12. Navigation (added mid-interview): the session list remains the home view. Chat is pushed on top with a **Back** header button (chevron + "Sessions", VoiceOver "Back to sessions"), also Esc (when the composer is empty) and ⌘[. Back never stops the agent. Each composer-started row in the list shows a live status and reopens its chat on click; sessions observed only through hooks keep today's behavior (click jumps to the terminal). Panel returns to 440x460 on Back. The composer sits at the bottom of the list too, so you can start another session from there.

## Files I plan to touch
Core (`core/island-core/`):
- `src/chat.rs` (new): session manager: spawn child (reuse `Tools::standard` / `search_path` from `src/pr.rs`), Claude `-p --input-format stream-json --output-format stream-json`, Codex via app-server turn/start, normalize to one `Entry` enum (user, assistantText, toolCall{name,input,result,status}, error), in-memory transcript with cursor, stop = interrupt/kill.
- `src/server.rs`: new ops `chatStart`, `chatSend`, `chatStop`, `transcript` in `Core::call` (~line 461); app-quit cleanup; join the started session with the hook-reported row by session id.
- `src/pr.rs`: only the `Tools` env override (small).
- `src/lib.rs`: `mod chat;`
- `src/codex_appserver.rs`: only if turn/start + delta subscription needs a small addition (currently opts out of deltas).
- `tests/chat.rs` (new) + fake-agent script in `tests/common/`.

macOS (`macos/AgentIsland/`):
- `CoreBridge.swift`: new call wrappers and mirrored `Decodable` transcript types.
- `ChatView.swift` (new): conversation column, message styling (subtle, no bubbles), collapsible tool rows, code block + Copy, auto-scroll that stops when the user scrolls up, states (empty / error / failed / disconnected), shared `Composer`.
- `PanelView.swift`: composer pinned at bottom of list mode, agent toggle, cwd label; mode switch list <-> chat in `PanelModel`.
- `IslandWindow.swift`: chat-mode resize, key-on-click, hover-out guard.
- `IslandView.swift`: only if `panelWidth/panelMaxHeight` need to become dynamic.
- Docs: `PRODUCT.md`, `DESIGN.md` (components section for chat).
- No new dependencies; `project.yml` unchanged unless sources are not globbed.

## Risks to settle early (spike before building)
- Codex multi-turn streaming over app-server (deltas are currently opted out); if it proves large, Claude ships first behind the same `Entry` type.
- Claude `-p` stream-json hooks: confirm hooks fire and session id matches so the chat session and the hook row merge into one.
- A non-key panel accepting text (first responder / activation policy).

## Process (AGENTS.md)
Brainstorm spec -> `docs/superpowers/specs/2026-10-14-chat-composer-design.md` (committed) -> plan -> TDD for core (fake binaries) -> branch (current: `ab/shelf-chat-composer-6ea08a`), `cargo test` in `core/`, `xcodegen` + `xcodebuild` in `macos/`, code-review loop until zero findings, PR + squash merge, `scripts/install.sh` from merged main.

## Verification
- `cd core && cargo test` (new chat tests with fake agents: stream, tool call, stop, crash, bad binary).
- `xcodebuild -project AgentIsland.xcodeproj -scheme AgentIsland -configuration Debug build CODE_SIGNING_ALLOWED=NO` in `macos/`.
- Launch built app, screenshots: empty chat, streaming (real Claude), error (fake binary exiting non-zero); check Enter/Shift+Enter, Stop, scroll-up stops follow, VoiceOver labels, Reduce Motion.
