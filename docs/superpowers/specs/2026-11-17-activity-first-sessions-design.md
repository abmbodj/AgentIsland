# Activity-first sessions

When several agents are running across projects, opening Agent Island should answer which ones need input and which ones finished. A developer should also be able to return to any chat in Island's current session snapshot or saved chat list, even with a large history.

## Notch and panel

- Keep the notch bounded. Retain the dedicated request count and the existing six-dot limit with overflow. Give working and finished sessions priority over quiet sessions in the visible dots. Saved history alone contributes no dots.
- Keep the existing approval and question card above the scrolling list. Its queue remains global and oldest first. A project disclosure, search query, or running-list limit cannot remove a request from that queue. Sessions reporting that they need input stay above running sessions, including when the existing answer surface is inside the chat.
- Show up to four running sessions by default, with the total and a **View all running** action when there are more. Keep their order stable while ordinary progress events arrive. Show recently finished sessions below them using the core's finished state. Keep errors and other exceptional states reachable with their existing status.
- A finished row counts as seen after the existing dwell period only if the row is actually visible, or when the user explicitly opens or jumps to that session. Opening the panel must not clear completions below the viewport or while browsing search or history.
- Put remaining tracked chats under collapsed project rows with counts. Expand one project at a time and show up to three chats inline. **Browse all** opens that project's list in the same bounded panel. The existing usage strip, composer, and session actions remain available where users expect them.

## Search and navigation

Search covers displayed chat titles and project names across the current snapshot and saved chat list. Match query words case- and diacritic-insensitively. Search is explicitly invoked by click or keyboard from the summoned panel. A hover preview never takes keyboard focus.

Search results identify the project and provider. Arrow keys move between results, Return opens the selected result, and Escape returns to the previous list. Back from a conversation restores its source list, query, and selection when that row still exists. Collapsing the Island resets the panel to the activity view for the next opening.

Use the existing conversation entry points and their loading and error states. When a session leaves the snapshot before it can be opened, use its saved counterpart if one is still available. Otherwise, remove the stale result and keep the user in the source list. Preserve rename, delete confirmation, plan access, terminal and desktop handoff, and subagent disclosure through the existing row actions.

## Data and ownership

Derive the panel's lists from the existing session snapshot, saved chat summaries, and title overrides. Join a saved chat to a live session using provider and session ID. Use the saved chat's ID before a session ID is assigned. Each tracked chat gets one list row, with current state from the live session when present. An unmatched Island chat reported as running belongs in activity. A session acknowledged as finished remains findable for as long as it is in the snapshot or saved chat list.

Group by a project root path already present in metadata, falling back to the reported working directory. The current generic session payload exposes a working directory and a display string that can be a conversation title. Use the working directory where a true root is unavailable. Keep identical folder names distinct and show a path hint when needed to tell them apart. Worktrees share a group when existing metadata provides the same root. A missing path falls under **No project**. Keep the existing retention rules for session snapshots and Island chats.

Have the panel model own grouping, search, and navigation state. Reuse the existing session and chat rows. Derive list data only from changed inputs while the panel is open, and instantiate long browse and result lists lazily. Load transcript contents only when a chat opens.

## Cost and verification

The feature adds project disclosures, search, and browse states in the existing panel. A compact default costs one extra action to browse older chats or the full running list. It adds in-memory metadata processing while open. There are no new dependencies, launch-time processes or I/O, background polling, or transcript indexing. Measure the open-panel cost and check it against the existing idle, memory, and bundle budgets in `PRODUCT.md`.

Verify three tracked chats, 100 across 10 projects, and 20 running at once. Cover same-named folders, duplicate provider IDs, saved-to-live transitions, custom titles, empty search, stable keyboard selection during updates, and Back from a chat. Check that hidden completions remain unacknowledged and an approval stays reachable while browsing a collapsed project. Run `cargo test` in `core/` and build the macOS app with `xcodebuild`. Verify the scroll limit, focus behavior, and VoiceOver labels in the built app.
