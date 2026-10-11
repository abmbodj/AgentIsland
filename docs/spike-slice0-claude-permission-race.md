# Slice 0 spike: Claude Code 2.1.296 hook behaviour

Method: `claude --settings /tmp/spike/settings.json` in tmux, every hook event routed to a dump script; replies injected per event/tool. Fixtures from this run live in `fixtures/claude/`.

| Question | Result |
|---|---|
| Does the terminal permission dialog show while a `PermissionRequest` hook blocks? | **Yes.** Dialog is visible and usable immediately. |
| User answers "Yes" in terminal while hook blocks | Tool runs. **Hook process is NOT killed**; it keeps running until it exits on its own (its later output is ignored). `PostToolUse` fires for the tool. |
| User presses Esc (deny/interrupt) in terminal while hook blocks | **Hook process is killed.** No `PostToolUse`, no `Stop`. |
| Hook returns `allow` while dialog is visible | Dialog dismisses, tool runs ("Allowed by PermissionRequest hook"). First answer wins both ways. |
| `AskUserQuestion` | Fires `PreToolUse` then **`PermissionRequest`** (tool_name `AskUserQuestion`). |
| Answer a question from `PermissionRequest` | Works: `decision{behavior:"allow", updatedInput:{questions:<original>, answers:{"<question text>":"<label>"}}}` while the dialog is visible. `allow` without `answers` has no effect (dialog stays). |
| Answer a question from `PreToolUse` | Works too, but `PreToolUse` runs before the dialog, so blocking there hides the terminal prompt. Not used. |
| Allow for session | `updatedPermissions:[{type:"addRules",rules:[{toolName:"Bash",ruleContent:"<cmd>"}],behavior:"allow",destination:"session"}]` → identical later call does not prompt. |

Other observations:
- Hook env includes `CLAUDE_PID` (agent PID) and `__CFBundleIdentifier` (launching app; stale inside tmux, use `TMUX` first).
- Background subagents: parent `Stop` fires with `background_tasks[]` still running; later a synthetic `UserPromptSubmit` (`<task-notification>`) starts a new turn.
- `SubagentStop` also fires for internal agents with `agent_type: ""` and no prior `SubagentStart`: ignore unknown agent ids.
- `PermissionRequest` has no `tool_use_id`; correlate with the preceding `PreToolUse` (same session, tool_name, tool_input).

## Consequences for design (supersedes D35 detail)
- The approval/question hook **always blocks** (even when the session's tab is frontmost); frontmost only suppresses auto-expand and chime. Claude answers stay inline after switching away; no handoff needed for Claude.
- A pending card clears when: our answer is sent; the hook socket closes (Esc/interrupt killed it); or a `PostToolUse`/`PostToolUseFailure` for the same tool arrives (answered in terminal) → core replies empty to release the orphaned hook; or any later turn event (`UserPromptSubmit`, `Stop`, `SessionEnd`).
