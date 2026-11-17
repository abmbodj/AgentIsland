# Activity-first Sessions Implementation Plan

**Goal** Make requests and completions easy to spot, and make large collections of tracked chats easy to browse or search.

**Architecture** Build a metadata-only list from the snapshot and saved chats while the panel is open. Keep the existing approval and conversation entry points, and scope completion acknowledgement to visible finished rows.

**Tech stack** Swift 5, SwiftUI, AppKit, and the existing Rust core.

## Constraints

- Cover the current session snapshot and saved Island chats across Codex and Claude Code.
- Show four running rows by default and three saved rows in one expanded project. Keep the six-dot notch and a separate request count.
- Group by an available project root or working directory, and keep missing paths searchable.
- Keep the panel's current size budget, keyboard focus policy, and existing row actions.
- Use no new dependencies, launch work, background polling, or transcript reads. Users gain a bounded activity view and pay one additional action to browse older chats or the full running list. The app pays for metadata joins and search while the panel is open.

## Tasks

### 1. Tracked-chat list

Create `macos/AgentIsland/SessionList.swift` with provider-scoped session identity, metadata inputs, grouped entries, running and finished sections, and title/project search. Make it possible to test the join and grouping without opening a SwiftUI window.

- [ ] Add standalone assertions in `macos/Tests/SessionListTests.swift` for provider-scoped ID collisions, saved-to-live linking, directory grouping, 100 tracked rows across 10 projects, 20 running sessions, and insensitive search. Run them with `swiftc -parse-as-library` before the implementation and confirm the missing model failure.
- [ ] Merge linked rows by provider and session ID. Keep the saved row ID stable after linking. Build project keys from normalized paths without resolving the filesystem. Prepare search text from displayed metadata and maintain deterministic ordering.
- [ ] Run the standalone list tests and confirm they pass.

### 2. Bounded panel and navigation

Add `SessionListView.swift` for list rendering. Modify `PanelView.swift` and `Chat.swift` to cache the list while open, hand off results to existing row actions, and retain the list state while a conversation is open. Modify `ChatView.swift` only where the saved row needs project or selection context.

- [ ] Keep the approval card above the scrolling content. Compose lazy running, finished, and project rows from the list. Add overflow and project browse actions within the panel, preserving the existing usage strip and composer.
- [ ] Add search with a model-owned query, result selection by ID, and search results displaying provider and project. Wire click and Command-F to search in summoned mode, arrows to selection, Return to open, and Escape to Back in `IslandWindow.swift`. Keep the approval shortcuts available.
- [ ] Keep the list route, query, and selection when opening a result. Reset them only on collapse or explicit Back within the list. Resolve a row against current metadata before opening, preferring the saved chat when its session has left.
- [ ] Build the app and check the search, project browsing, and live row flows with small and crowded examples.

### 3. Completion and notch

Modify `IslandView.swift` to prioritize finished and working sessions within the existing dot cap. Replace `IslandWindow.swift`'s panel-wide completion timer with a cancellable dwell per visible finished row, backed by the current snapshot for identity and completion time validation.

- [ ] Start the 1.5-second dwell when the row fits in the list viewport. Cancel it when scrolling hides the row, navigation leaves activity, or the panel closes. Explicitly opening or jumping to a finished session acknowledges it with the existing event. Include the original completion timestamp for row acknowledgements so a re-completion during transit stays visible.
- [ ] Verify hidden rows keep their completion signal. Use `cargo test` in `core/` and `xcodebuild` in `macos/`. Check keyboard focus, VoiceOver labels, and the 460-point panel cap.
- [ ] Commit on the feature branch, run the branch review loop, squash-merge the PR into `main`, and reinstall from merged `main` using `scripts/install.sh`.
