# Manual checks (things automation can't press or see)

Everything else is covered by `cargo test` (state machine, installer, E2E hook→socket→core) and the
scripted real-agent runs described in each slice commit.

## Keyboard mode (criteria 3, 7)
1. With a question card waiting, press **⌥⌘I**. The panel takes keyboard focus; your app stays frontmost in the menu bar.
2. Press **⌘2**. Option 2 shows *Undo* with a ring. Wait 2 s → "✓ Answered", focus returns to your app.
3. Repeat, but press **Esc** within 2 s → the answer is cancelled and the card stays.
4. Approval card: **⌘Y** allow, **⌘N** deny. **J/K** (or ↓/↑) move between "1 of N" cards.
5. Type a free-text answer: ⌥⌘I, click into "Type another answer", type, Return.

## Mouse (criteria 2, 7)
- Click **Allow** on a card while typing in another app: the click works first time, your typing keeps going to your app.
- Hover the notch: opens after ~350 ms, closes ~400 ms after you leave. Click pins it; click elsewhere closes it.

## Jump (criterion 4)
- iTerm2: two tabs running `claude`; click each row → the right tab comes forward.
- VS Code / Cursor: Set Up Integrations… → "Exact terminal jump" → click a row for a session in the integrated terminal.
- Ghostty: two tabs running `claude`; click each row.

## Look
- Panel reads as one dark object growing out of the notch; text legible; motion quick with no bounce.
- System Settings → Accessibility → Display → Reduce motion: dots stop breathing (ring instead), panel cross-fades.
