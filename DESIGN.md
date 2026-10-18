---
name: Agent Island
description: A calm notch-style status light for local AI coding agents.
---
<!-- SEED — re-run /impeccable document once there's code to capture the actual tokens and components. -->

# Design

## 1. Overview: The Night Instrument

A single dark object that grows out of the notch. Restrained color, system typography, quick un-bouncy motion. It should feel like part of the Mac's hardware, the way the Dynamic Island feels like part of the iPhone. References: Apple Dynamic Island, macOS Control Center glass, a car's instrument cluster at night (indicators that stay dark until they matter). Anti-reference: observability dashboards and notification centers.

Physical scene: a developer at a MacBook, eyes on an editor in whatever light the room has, catching the notch in peripheral vision for under a second. The pill must be invisible against the notch when nothing is happening; the expanded panel is the same solid notch black, so the island reads as one physical object (D32, chosen over Liquid Glass after an on-screen review).

## 2. Colors: The Indicator Rule

**The Indicator Rule.** Tinted near-black surfaces and warm off-white text carry everything. Exactly two signal hues exist and each has one meaning: amber = needs input (the only urgent state), green = finished. Working is neutral and signalled by motion only. Values `[to be resolved during implementation]` in OKLCH; neutrals tinted slightly warm, never pure #000/#fff except the pill body, which must match the physical notch.

## 3. Typography

Single sans: the system font (SF Pro / Segoe UI Variable on Windows), SF Mono for commands and file names. Small, dense sizes; hierarchy by weight and opacity rather than size jumps, because the panel is compact. `[exact sizes resolved at implementation]`

## 4. Elevation

Flat. The whole island is opaque notch black (no glass, no blur, no shadow); hierarchy inside the panel comes from text weight and faint white lifts (6–8%) for hover and inset blocks.

## 5. Components

Omitted until built (pill, session row, approval card, question card, handoff card, usage strip).

### Chat (composer and conversation)

**Entry.** The session list is status-only; a chat icon in its footer (trailing edge, beside the usage line) opens the new-chat screen: composer, Claude/Codex toggle and working folder, with Back to the list. With no sessions and no chats the panel opens on that screen by itself and keeps the "No agent sessions" prompt above the composer. Sending slides into the conversation; Back slides out.

**Motion.** Screens slide 28pt with a fade, forward from the trailing side and back from the leading side, on ease-out-quint (250ms, no bounce); the island's own shape springs to the new size underneath. Small changes (a message settling in, a tool row opening, the send/stop glyph swapping) use the same curve at 220ms; press feedback uses 120ms. Reduce Motion replaces slides with short cross-fades and applies disclosure geometry immediately. The silhouette carries position and velocity across reversals using a critically damped trajectory submitted to Core Animation; unchanged targets do not restart it. Window fitting follows the current transition’s completion. Incremental stream-follow is immediate; explicit Latest navigation uses a short transition. Undo’s countdown runs in Core Animation from the original decision deadline.

The panel grows from 440 to 640 wide while a conversation is open and returns to the list on Back (⌘[, or Esc with an empty draft). The message column is 560 max and centered; the composer is pinned at the bottom. Your messages sit in a faint lifted block (white 8%); the agent's reply is plain text with no container. Tool calls are one compact collapsible row each. Code is a monospaced block with a Copy button. Errors and failed sessions use a triangle glyph and neutral text: amber stays "needs you" (a tool row waiting on approval) and green stays "finished", so neither appears in chat otherwise. Auto-scroll follows the stream until you scroll up; a "Latest" pill brings it back.

### Plan review

Plans appear as rendered Markdown in the conversation. Long plans use a bounded inline preview with **Expand plan**, which opens a focused reader inside the same Island. The reader keeps its header and decision footer visible while the document scrolls; Back returns to the conversation at its previous position. Both views show the same version and decision state.

**Writing plan…** is neutral. **Ready for review** is an input-needed state. Implement plan is the primary action, Revise plan opens feedback, and Reject plan leaves the conversation open. Historical versions remain readable without decision buttons. Implementation exits Plan mode and preserves the existing execution permissions. Connected plans use **Continue in Claude/Codex** when the source session must handle the decision. Merely opening that app does not accept a plan.

The renderer uses system text, selectable source, and native controls. Headings, lists, task lists, tables, quotes and code convey document structure; wide code and tables scroll within the reader. No separate plan window or editable task dashboard.

## 6. Do's and Don'ts

- Do keep the collapsed pill unchanged when nothing needs the user (acceptance criterion 6).
- Do pair every state color with a glyph (dot, check, ring, exclamation).
- Do use spring motion ~200–300 ms, critically damped for routine changes; cross-fade under Reduce Motion.
- Don't use amber or green for anything except their one meaning; usage ≥90% is bold, not amber.
- Do identify agents by their official marks: the Claude spark in brand clay (#D97757, the only non-signal hue, used nowhere else) and the Codex knot in off-white. In rows the state glyph sits on the mark as a corner badge.
- Do use Claude Code's own Ultracode violet (#d0b4ff) only on the composer's model chip while Ultracode is on: a static tinted fill and hairline with its sparkle icon. It marks a mode the user chose, never a status, so it appears nowhere else.
- Don't add cards inside cards, metric tiles, gradients, or glow.
- Don't use em dashes in UI copy.
