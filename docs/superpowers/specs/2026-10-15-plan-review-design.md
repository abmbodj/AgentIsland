# Rendered plans and plan review

## Goal and approved direction

Developers can read a complete Markdown plan in Agent Island, request a revision, reject it, or start implementation. The first release covers Island-owned chats and connected Claude Code/Codex sessions wherever their integrations expose plan content. Unsupported remote actions use an explicit source-session handoff.

Combine two views of the same plan: a rendered inline plan in the conversation (B), and an expanded, focused Island reader (A). A separate reading window (C) is excluded.

The user approved this design in conversation, including streaming previews and the computer-use acceptance test below. Implementation starts only after review of this written spec.

## Existing behavior and constraints

- `core/island-core/src/chat.rs` supports Claude Plan mode but denies permission requests other than `AskUserQuestion`. It has no plan document or review lifecycle.
- `core/island-core/src/store.rs` captures connected Claude `ExitPlanMode` requests. It deliberately marks these as handoffs because the hook approval response does not authorize execution in that integration.
- `macos/AgentIsland/Cards.swift` currently shows a short raw detail preview and opens the originating session.
- `ChatView.swift` and `Chat.swift` render inline Markdown and fenced code, without full document structure.
- Connected Codex currently opts out of plan notifications in `codex_appserver.rs`. Its structured progress checklist is not automatically a full implementation proposal.
- Island's Codex runner uses `codex exec`, which currently has no native Plan-mode selector. Do not invent a mode or infer a reviewable proposal from arbitrary prose.
- Island chat transcripts are currently in memory. This feature preserves plan history for the same lifetime; persistence across app restarts is outside this release.

## User experience

### Inline plan

A recognized plan appears in the conversation as a document with a title, version, rendered body, state, and actions. Render headings, paragraphs, emphasis, ordered/unordered lists, task lists, links, tables, block quotes, and fenced code. Preserve all source Markdown for copying. Task-list checkboxes reflect document content and are not an editable execution tracker.

While the provider streams recognizable plan content, render it with “Writing plan…”. Review actions remain unavailable until the provider reports completion or an authoritative decision request. Providers that only supply a completed plan show it on arrival. Never fabricate streaming from a completed response.

The inline view uses a bounded preview for long documents and an “Expand plan” button. No plan content is discarded; the expanded reader provides the full document. The footer provides “Reject plan”, “Revise plan”, and the primary “Implement plan” action when supported.

### Focused reader

“Expand plan” opens a dedicated reader within Island, using the existing conversation width, opaque black surface, system typography, and restrained theme. The header identifies the project, agent, plan version, and Back action. The document scrolls independently; review actions remain pinned at the bottom.

Back returns to the conversation at its prior position. Closing Island or leaving the reader changes no plan decision. Connected session rows with a plan open this reader directly. Preserve document scroll position when switching between inline and expanded views where practical; never force readers back to the beginning on unrelated state updates.

### Revision

“Revise plan” reveals a labelled feedback field with “Send feedback” and “Cancel”. Require nonempty feedback. Sending it keeps the agent in planning mode and requests an updated plan using the reviewed version as context. Retain the feedback while sending or after an error; clear it only once accepted.

The previous version remains readable and is marked as being revised. The agent's completed revision becomes the new reviewable version. Older versions remain accessible from a compact version selector in the plan header. Historical versions have no decision actions. If revision fails, retain the previous plan and feedback and allow retry; do not silently treat a partial revision as ready.

### Implementation

“Implement plan” starts work immediately without another confirmation dialog. For Island-owned chats, exit Plan mode and send an implementation instruction tied to the exact reviewed version. The visible transcript message can say “Implement the plan.” Include the authoritative version/content in the agent's context so the instruction cannot accidentally refer to an older proposal.

Restore the session's previous non-planning permission mode when known; if the chat started in Plan mode, use Default. Preserve model, effort, Fast, Ultracode, and other unrelated settings. Do not silently select Auto, Accept edits, Bypass, or a broader sandbox to make the work run.

Resolve any outstanding native plan-decision request before starting/resuming the implementation turn. The adapter must avoid two simultaneously running turns. Use a supported native decision protocol when required, rather than blindly sending a message into a blocked request.

Only mark the plan as implementing once the adapter accepts the operation. Progress remains visible in the normal conversation/tool stream. The plan's status describes its decision, not task completion: accepting a plan does not mean the work is finished.

### Rejection

“Reject plan” ends that proposal without starting implementation and leaves the conversation open for another direction. Keep the rejected document in history with a clear label. Feedback is optional and does not block rejection. Rejection is distinct from requesting a revision.

### Connected sessions and capability limits

Plan content and plan control are separate capabilities. A connected session can expose a readable plan without supporting remote implementation, revision, or rejection. Render the available full plan and replace unavailable actions with “Continue in Claude” or “Continue in Codex”, with concise copy explaining that the decision must be completed there.

Do not present working-looking buttons that merely dismiss a local card. Opening the source app does not mark a plan accepted, revised, or rejected. When a decision is made externally, reconcile using provider events; if the outcome is unavailable, indicate that the request is no longer active without inventing a decision.

For Codex, consume supported proposal events when available and verify their semantics. A turn progress checklist alone must not create an “Implement plan” decision. If no reliable proposal signal exists on an integration, keep the normal session behavior and source-session handoff rather than scraping arbitrary assistant text into a plan.

## Architecture and boundaries

### Core plan model

A dedicated plan module owns documents, version identity, source references, and validated decision transitions. Store the full Markdown separately from truncated tool summaries. A document identifies its owning chat/session and provider turn/request; each version has a stable identity, version number, source Markdown, completion state, and decision state.

Represent lifecycle states explicitly: writing, ready, revising, implementing, rejected, superseded, and unavailable. Keep operation-in-flight/error information separate so a failed send does not erase a valid document. Partial or failed generation never becomes ready solely because the process stopped.

Only the latest ready version with the necessary capability accepts a new decision. Validate ownership, version, source-request liveness, and decision eligibility in Rust at the bridge boundary. Repeated clicks or stale views must not start duplicate turns. Serialize decisions per plan; UI button disabling is supplementary.

### Provider adapters

Adapters translate authoritative provider events into documents and capabilities, then execute implement/revise/reject operations. Keep provider-specific mode switches, blocked-request handling, and connected-session handoffs out of the renderer.

For Island Claude chats, capture full plan content from the supported plan output/request, handle Plan-mode completion without the current generic denial message, and support resumed planning and implementation turns. Recognize terminal planning output only within an explicitly tracked planning turn and its completion contract; do not classify every assistant message as a proposal.

For connected Claude, retain the existing honest handoff unless a supported control path is verified. For Codex, distinguish implementation proposals from execution-progress notifications. Capture each proposal once even if multiple events carry the same content.

### Swift presentation

Use one shared Markdown document renderer and plan presentation model in both inline and expanded views. Keep the reader, version selection, feedback editor, and action footer focused components. The bridge exposes plan snapshots and typed version-scoped decisions; Swift does not reconstruct provider protocol messages.

Reuse Island's navigation, button styles, focus rules, and manual-scroll behavior. A new plan does not steal keyboard focus or automatically open a reader. In observed sessions, a completed undecided plan is an input-needed state; use existing attention behavior and amber semantics, without adding routine streaming notifications.

## Error handling and accessibility

- A sending operation disables competing decisions and provides immediate progress feedback. Preserve the document and feedback on failure, explain the failure inline, and offer retry where safe.
- An uncertain transport result must be reconciled before retrying an execution-starting action. Do not launch a duplicate implementation because an acknowledgement was lost.
- Cancellation, session exit, request replacement, or an external decision invalidates stale actions. Keep available content readable.
- If plan content cannot be retrieved, show an explicit unavailable state and source-session handoff. Never use an empty preview as the authoritative plan.
- Document links open only on user activation. Render generated Markdown as content, with no executable HTML or automatic remote resource loading. Long code lines and tables scroll horizontally rather than widening Island.
- Support keyboard navigation, selectable/copyable document text, visible focus, VoiceOver headings and labels, and system Reduce Motion. Review buttons remain accessible without scrolling to the document's end. Keep normal text contrast at least 4.5:1.

## Verification and delivery

Automated checks cover full-content capture, streaming/completion boundaries, revisions and historical versions, reject-without-execution, exact-version implementation, permission-mode restoration, ownership checks, stale/duplicate decisions, cancelled requests, failed operations, and source-session fallback. Use representative Claude/Codex event fixtures and fake-agent integration tests for the lifecycle. Verify Markdown structure with representative long plans, code, lists, and tables.

Run `cargo test` in `core/` and build the macOS app with `xcodebuild` in `macos/`. Work and commit on a branch. Run the required branch code-review loop, fix and commit findings, and repeat until a review reports zero issues. Open a PR against `main`, squash merge, and reinstall using `scripts/install.sh` from the merged `main`. Do not install a branch build.

After that installation, perform this required computer-use acceptance test in the actual notch app:

1. Create a disposable local project with a small file-writing task and no external effects.
2. Through the notch UI, create a Claude chat in Plan mode and request a concrete plan for the task.
3. Verify rendered Markdown, scrolling, disabled actions during generation, and enabled actions when ready. Expand the plan, then return to chat.
4. Click “Revise plan”, submit a material change, and wait for the updated version. Verify the revision reflects the change and no implementation has started.
5. Click “Implement plan”. Verify the mode changes out of Plan, the implementation instruction is sent once, and the same session proceeds with implementation.
6. Verify the expected files actually change according to the revised plan. Record the UI interactions and resulting file evidence, not merely the presence of an assistant promise.

If computer use exposes a defect, fix it on a branch and repeat the required test/build/review/merge/install sequence before retesting the installed app. Report any environment or provider limitation that prevents completing the acceptance test.

## Out of scope

Separate plan windows, inline document editing, section annotations, visual revision diffs, project-wide plan libraries, cross-launch plan persistence, automatic implementation, new permission systems, and a simulated Codex Plan mode are excluded. The review UI does not become a task dashboard.
