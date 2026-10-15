# Chat handoff verification

User authorized real test messages, computer use, and fallback automated checks when Computer Use denied access to Terminal, iTerm2, Ghostty, and Codex Desktop. No branch build was installed; the Debug app ran directly from derived data.

## Native session history

- Claude Desktop: the production launcher opened native session `a7e633e5-b8db-4a72-9dd1-4e4bf42f38c9`. Computer Use inspected all four messages: original INDIGO marker, Saved reply, recall question, and INDIGO recall reply. A separate GUI continuation in session `8ca97236-da97-49ba-855f-cb7fd59b838e` returned SILVER-BIRCH-417 from its notch message.
- Codex Desktop: Computer Use created two turns in ONE notch chat (RIVER-ONE-821 / First saved; RIVER-TWO-822 / Second saved), clicked Codex Desktop, and observed the notch become read-only. A read-only request to the native Codex app-server verified that exact thread `01a13d5a-79c7-7900-b0ea-06449f21dc55` contains both user messages and both assistant replies. The installed desktop app's URL parser accepts the exact `codex://threads/<id>` route. Desktop pixels and typing were unavailable through Computer Use.
- Terminal: notch menu launches produced native Claude `--resume cb079210-f7fb-4986-a565-4ddf4e2150ef` and Codex `resume 01a13d53-3dec-78f0-b8ad-dda7139de300` processes on terminal TTYs. The user supplied a screenshot showing the Codex session's original message and reply, and confirmed the history is present. A native Claude resume recalled AMBER-PINE-714.
- Ghostty: the notch menu launched Claude `--resume 9de6e89a-ac35-4135-afe1-827050918c03`; a native resume recalled GOLD-OWL-316. The final production launcher also started Codex on a Ghostty TTY with the exact original `01a13d53-3dec-78f0-b8ad-dda7139de300` ID.
- iTerm2: the initial command-document approach hit an iTerm run-file warning (user screenshot). Replaced it with iTerm's native create-window command. This Mac denies Agent Island's Automation permission for iTerm, so successful native launch remains permission-gated. The real notch UI displayed the permission error, restored its composer, and accepted a same-session follow-up returning VIOLET-CREEK-619. Full iTerm UI verification remains unavailable; no global warning suppression or permission bypass was applied.

Different test chats are separate native sessions. The user clarified that apparent missing newer messages were messages from other test chats, and confirmed same-session history works.

## Automated checks

- Rust workspace: 134 tests passed, including 16 chat tests covering queued handoffs after process exit, cancellation, concurrent/single claims, reply blocking, initial failure recovery, late error read-only preservation, stale attempt callbacks, missing executable/folder/session, symlink runtime PATH, failed reopen, and Codex multi-turn history with repeated native item IDs.
- Swift executable harness: exact resume arguments and cwd, shell and AppleScript string injection/quoting, missing cwd, self-removing wrapper and exit receipt, desktop pseudo-TTY and propagated failure status, and delayed terminal failure notification after initial dispatch.
- xcodebuild Debug: passed on arm64 macOS. The final merged install builds Release through scripts/install.sh.

## Issues found and corrected during the loop

1. LaunchServices acceptance alone did not prove a terminal command started: added process receipts and ongoing error observation.
2. Claude --desktop refuses redirected output: provide a pseudo-TTY with script -q -e and preserve its exit status.
3. Older Homebrew Claude lacked --desktop while a newer user-local CLI supported it: probe installed candidates for capability.
4. Canonicalizing an executable symlink dropped its runtime directory from PATH: preserve the discovered directory.
5. Codex reused item IDs across processes, replacing earlier notch history: namespace transcript item keys per turn.
6. Late failures could reopen archived notch history: preserve read-only ownership after successful dispatch and expose external retry.
7. Stale terminal callbacks could affect a newer attempt: include per-attempt tokens.

Independent branch review and final merge/install evidence are recorded in the PR and conversation.
