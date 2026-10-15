# Plan review implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Render and review versioned plans inline and in a focused reader, then revise, reject, or implement through a validated provider adapter.

**Architecture:** Rust owns versioned plan state and decisions; provider-specific code captures proposals and resumes the correct session. Swift shares one Markdown renderer and action component between inline and focused views. Connected sessions expose readable proposals with honest source-app handoff when control is unavailable.

**Tech stack:** Existing Rust/serde core, SwiftUI/AppKit macOS application, Claude stream-json, Codex app-server events.

## Global constraints

- Follow `docs/superpowers/specs/2026-10-15-plan-review-design.md`.
- Work on `feat/plan-review`; never commit on `main` or install a branch build.
- Preserve current permissions and unrelated model settings. A chat started in Plan returns to Default for implementation.
- Only the latest completed plan can accept decisions. Never turn a Codex execution checklist into a proposal.
- Match the existing opaque notch-black UI, system typography, native controls, accessibility and Reduce Motion.
- Run core tests and xcodebuild, review/fix/re-review to zero findings, PR and squash merge, install merged main, then test the real notch UI with computer use.

## Task 1: Versioned plans and Island chat adapter

**Ownership/files:** create `core/island-core/src/plan.rs`; modify `chat.rs`, `lib.rs`, and `server.rs`; add `core/island-core/tests/plans.rs` and plan integration cases in `tests/chat.rs`.

**Interface:** transcript JSON includes `plans: [{version: u64, markdown: String, status: String, entryIndex: usize, error: Option<String>}]`. Status values: `writing`, `ready`, `revising`, `implementing`, `rejected`, `superseded`, `unavailable`. Plan transcript entries have `kind: "plan"` and their stable entry index anchors the inline component. Bridge operation `chatPlan` takes `id`, `version`, `action` (`implement`, `revise`, `reject`) and optional `feedback`, returning null or the normal error envelope. Existing `settings` in transcript must reflect mode changes.

- [ ] Add failing model tests for full source preservation, version increments, latest-ready validation, superseding, rejecting, and duplicate decision rejection. Representative contract:
  ```rust
  assert_eq!(book.latest().unwrap().markdown, source);
  assert!(book.decide(old_version, "implement", "").is_err());
  assert!(book.decide(version, "revise", "  ").is_err());
  ```
- [ ] Run the new tests and confirm failure before implementation. Implement the small plan model, then rerun until green.
- [ ] Add fake-Claude integration tests that emit streamed plan output and a completed plan; revise then implement through `Chats::plan_action`. Inspect captured argv and stdin to assert revision stays in `plan`, implementation restores previous/default permissions and includes the reviewed Markdown, and duplicate actions create no second subprocess.
- [ ] Implement capture for explicit planning turns and `ExitPlanMode` content, with success completion required for readiness. A waiting native request must be settled without execution before the planning subprocess is allowed to finish; do not leave it blocked while starting another turn. Keep full content independent of tool-summary truncation. Verify actual installed CLI protocol using local primary sources/help and an isolated live probe if necessary.
- [ ] Serialize validation and turn reservation under the chat mutex. Preserve non-plan settings and previous execution mode. Return errors for stale versions, handoff ownership, active turns, empty feedback, and unknown actions. Failed generation remains unavailable; failed launch retains a retriable ready plan where safe. Expose plan snapshots even when transcript revision is unchanged.
- [ ] Run `cargo test --test plans --test chat`, self-review the diff, and commit only owned files.

## Task 2: Shared Markdown presentation and A + B review flow

**Ownership/files:** create `macos/AgentIsland/PlanView.swift` and `MarkdownDocument.swift`; modify `Chat.swift`, `ChatView.swift`, `PanelView.swift`, and `Cards.swift`. XcodeGen includes the new Swift sources automatically.

**Interface consumed:** Task 1's `plans` and `chatPlan` contract. Swift `ChatPlan` mirrors the exact JSON. `PanelModel` owns current plans, selected expanded plan, feedback and action errors; shared views read the current snapshot rather than keeping divergent copies.

- [ ] Add a standalone Swift parser/model test harness (following existing Swift script checks when available) that asserts headings, lists/task lists, tables, quotes, fenced code, and malformed/partial Markdown remain readable. Run it red before implementing the parser. Use native SwiftUI text/AttributedString for inline formatting, without loading executable HTML or remote images.
- [ ] Implement the shared document renderer. Long code/table content scrolls horizontally. Links open on user action only; all text is selectable and source Markdown can be copied. Keep body text at readable contrast.
- [ ] Decode and poll `plans` and updated `settings`; render plan entries inline with bounded content, status/version and Expand. Hide generic duplicate plan output where the core emits a plan entry.
- [ ] Add a focused reader presented within the existing Island, preserving the chat view and its scroll state underneath. Header identifies source/version, footer pins shared actions. Back restores chat/list; do not accept on dismissal. History selector disables actions on old versions.
- [ ] Implement the feedback editor with nonempty validation, cancel/send and retained draft on error. Implement/reject execute immediately without an approval dialog. Disable competing actions while sending, streaming, disconnected or owned by handoff. Show inline errors and maintain keyboard/VoiceOver access.
- [ ] Connected Claude plan cards and session rows open the same reader directly, using full attention detail and Continue in Claude. Keep source-session liveness checked during polling. When no plan content exists, show an unavailable explanation and handoff.
- [ ] Run parser checks and `xcodebuild -project AgentIsland.xcodeproj -scheme AgentIsland -configuration Release -derivedDataPath ../build/dd build -quiet` after `xcodegen generate -q` in `macos/`. Do not install. Self-review and commit only owned files.

## Task 3: Connected Codex proposals and integration verification

**Ownership/files:** `core/island-core/src/codex_appserver.rs`, `store.rs`, `protocol.rs` only if necessary; connected fixture tests under `core/island-core/tests/`.

- [ ] Inspect installed Codex schemas/primary protocol sources for `plan` items versus `turn/plan/updated`. Add fixtures/tests proving only authoritative proposal Markdown becomes readable attention, with full text, and progress checklists remain normal activity. Run red.
- [ ] Enable only needed plan events, fold delta/completion events without duplication, and expose proposal attention as handoff-only through the same full-document reader. Reconcile cancelled/completed source requests without inventing acceptance. If the installed integration has no reliable proposal signal, preserve normal fallback behavior and document the observed limitation rather than fabricating a Plan mode.
- [ ] Run focused connected-session tests and all `cargo test` tests. Review the Task 1/2 bridge contract, mode reset, keyboard Back handling, and panel sizing together; fix integration issues before final review.

## Task 4: Review and delivery

- [ ] Run all Rust tests and the Release macOS build; save outputs in local scratch. Review branch changes against the spec and project instructions with an independent reviewer. Run CodeRabbit if installed/authenticated; otherwise report that limitation and use the independent branch review. Fix all findings, commit, and repeat review until zero issues.
- [ ] Update PRODUCT/DESIGN descriptions where the shipped flow changes existing Plan behavior. Commit verification notes without private chat content.
- [ ] Push `feat/plan-review`, open a PR against `main`, and immediately register its full URL with `mcp__t3_code__link_pull_request`. Wait for required checks, squash merge, update local `main`, and run `scripts/install.sh`. Check `list_thread_pull_requests` before finishing.

## Task 5: Required computer-use acceptance test

- [ ] Create a disposable project with a tiny text-file task. Launch the installed merged-main Agent Island app; use computer use to open the notch, choose the disposable folder, select Claude Plan, and send the task.
- [ ] Observe rendered plan completion, scroll and Expand/Back. Click Revise, enter a material requirement, send, and verify the new version contains it while no task files were written.
- [ ] Click Implement. Verify the UI switches out of Plan, sends the instruction once, and shows actual implementation activity. Read the resulting files to verify they satisfy the revised plan.
- [ ] Record screenshots and concise evidence. If a defect occurs, fix on a new branch and repeat tests/build/review/PR/merge/install before retesting. Report genuine provider/environment blockers explicitly.

## Plan self-review

Coverage: Tasks 1 and 2 cover the shared lifecycle and reader; Task 3 covers connected-provider capture/fallback; Task 4 covers repository delivery gates; Task 5 covers the user's real UI test. Cross-task JSON and action names are defined once above. No implementation starts from a historical, incomplete, or unavailable proposal.
