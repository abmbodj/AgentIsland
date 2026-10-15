# Chat handoff implementation plan

**Goal:** Continue notch-created conversations, including native history, in terminal and desktop applications.
**Architecture:** Rust owns queued/launching/opened handoff state. Swift claims ready handoffs even when the panel is closed and launches exact native sessions, then reports success or failure. SwiftUI renders the destination menu and read-only receipt.
**Tech stack:** Rust, Swift/AppKit/SwiftUI, native AppleScript terminal APIs.

## Global constraints
- Resume the exact native session with full native conversation history and original working folder.
- Destinations: Apple Terminal, iTerm2, Ghostty; Claude Desktop for Claude and Codex Desktop for Codex.
- Wait for the current answer to finish before launching; queued handoff can be cancelled.
- Core rejects replies while queued/launching/opened; launch failure restores replies.
- Never install a branch build. Test derived-data app, merge reviewed branch, install merged main.

### Task 1: Core lifecycle
Files: core/island-core/src/chat.rs, src/server.rs, tests/chat.rs.
- [ ] Add failing behavior tests for queue while running, claim only after process exit, single claim, cancellation, send rejection, failure recovery, successful read-only state, agent/destination mismatch, deletion, and missing session.
- [ ] Run cargo test -p island-core --test chat and observe failure.
- [ ] Implement request_handoff(id,target), cancel_handoff(id), claim_handoffs(tools), finish_handoff(id,error). Expose chatHandoff, chatHandoffCancel, chatHandoffClaim, chatHandoffFinish operations.
- [ ] Summaries/transcripts contain handoff {target,status} or null and handoffError. States: queued, launching, opened. Claims return [{id,agent,cwd,sessionId,target,bin,path}]. Reopen uses request_handoff after opened to the SAME target and remains read-only on reopen failure.
- [ ] Validate destination values terminal,iterm,ghostty,claudeDesktop,codexDesktop, matching agent. Resolve executable and folder at claim time; missing session/executable/folder clears pending handoff and records a useful error.
- [ ] Keep status/send reservation atomic under state mutex. Existing transcript unchanged by handoff.
- [ ] Run chat tests and full cargo test; commit core changes.

### Task 2: macOS launcher and UI
Files: macos/AgentIsland/ChatHandoff.swift (new), Chat.swift, ChatView.swift, PanelView.swift; scripts/dev/handoff-tests.swift (new).
- [ ] Write runnable Swift tests executing generated shell commands against a recording binary, covering spaces, quotes, newlines, dollar/backtick injection, exact session arguments, and cwd preservation; observe missing feature failure.
- [ ] Implement destination names/bundle IDs, installed detection, exact-session launcher. Terminal do script; iTerm create window with command; Ghostty new window with surface configuration command. Claude Desktop runs absolute binary --desktop --resume session ID off main with bounded output and timeout; Codex opens codex://threads/session ID via NSWorkspace completion.
- [ ] Keep all quoting in pure helpers tested by the harness. Launch terminal resume commands using original folder and supplied bin/path.
- [ ] Add handoff fields to chat models, menu to header, waiting/cancel, progress/error, and read-only Continue in footer. Suppress retry after handoff. Poll pending handoffs even when panel closes and preserve error receipts across navigation.
- [ ] Build with xcodebuild and run Swift tests.

### Task 3: Real-app loop and finish
- [ ] Launch branch app from derived data without installing it.
- [ ] Use computer use to create chats, send marker messages, click each Open in… option, inspect history, and send recall follow-ups in each destination. Fix failures and repeat.
- [ ] Exercise queued launch/cancel, collapse, read-only, and launch failure recovery.
- [ ] Record results with limitations; cargo test, xcodebuild, commit.
- [ ] Independent whole-branch review; fix, commit, and review until zero issues.
- [ ] Create/link PR, squash merge, install from main with scripts/install.sh; verify installed app.
