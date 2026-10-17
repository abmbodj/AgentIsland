# Product

## Register

product

## Users

Developers who keep several local AI coding agents (Claude Code, Codex; CLI and desktop apps) running while they work in an editor or browser. They are mid-thought, typing somewhere else, and only want to know two things without looking away for more than half a second: does an agent need me, and which one finished.

## Product Purpose

Agent Island is a status light that lives in the MacBook notch (or a slim top-center pill elsewhere). It detects agent sessions through each agent's official hooks, shows their state at a glance, lets the developer answer approvals and questions inline, opens any session's conversation (read from the agent's own transcript) when its row is clicked, and jumps to the exact terminal tab or pane from there. A composer at the bottom of the panel starts a Claude Code or Codex session from a typed message and opens its conversation in place (a Back button returns to the session list); the island stays a status light first, never a chat client you keep open. Success: the developer forgets it is there until an agent needs them, answers in one keystroke or click, and never loses their place.

## Brand Personality

Calm, precise, trustworthy. A native instrument, not an app you visit. Quiet while work proceeds; unmistakable when a decision is needed; honest about what it can and cannot observe.

## Anti-references

- Dashboards: metric tiles, charts, activity feeds, anything you would "check".
- Notification spam: toasts, badges that never clear, alerts for routine progress.
- Decorative SaaS styling: gradients, glow, colored chrome, mascots.
- The reference products' branding (Vibe Island, One): copy interaction patterns only.

## Design Principles

- **Earn every glance.** Nothing changes visually unless it helps decide what to do next. Five busy agents look like five quiet dots.
- **Color means something.** Amber only for "needs you", green only for "done". Everything routine is neutral, and every color is paired with a shape.
- **Never take the keyboard.** The overlay never steals focus unless summoned; clicks work without focus. The composer is the one control that asks for it, and only when you click it.
- **Honest state.** Show only what hooks actually reported. No estimates, no guessed progress; stale is labelled stale.
- **Leave no trace.** Local only, consented config changes shown as diffs, byte-exact uninstall.
- **Weigh nothing.** It runs all day beside the agents it watches, so it must cost less than any of them. Low CPU and memory, instant startup, few dependencies, and a small surface come before features. See Lightweight below.

## Lightweight

Being light is a core principle, weighed against every feature. A status light that warms the laptop, slows login or grows settings screens has failed, however useful the feature.

**Budgets** (measured on the M2 Air, October 2026):

- **Idle is zero.** Collapsed, with no hook events arriving: 0% CPU, no timers, no polling. Work happens only on a hook event, a process exit (kqueue), or the core's next scheduled state deadline. Motion runs in Core Animation, outside our process. Measured: 0.0% CPU and no new wakeups across 12 s samples.
- **Memory under 60 MB resident.** Measured 31 to 51 MB.
- **Startup spawns nothing.** Launch binds the socket, refreshes the bundled hook binary and starts idle threads. No child processes, no folder scans, and no network beyond Sparkle's own scheduled update check when it's due. Anything a screen needs is loaded when that screen opens.
- **The hook stays tiny.** One short-lived process per agent event, std plus `libc` and `serde_json`, failing open at once when the island isn't running. It must never slow the agent down.
- **Polling only while it's visible.** A screen that has to pull from the core (an open conversation) stops pulling the moment it closes, and asks only for what changed.
- **Few dependencies.** Swift: Sparkle only. Rust core: `libc`, `serde`, `serde_json`, `sha2`, `similar`. Bundle under 15 MB (measured 9.9 MB).
- **A small surface.** Prefer a good default to a setting, and a row or card to a new screen.

**Evaluating a feature.** Before building it, answer in its plan or PR:

1. What does it cost while collapsed and idle? Anything above zero needs a strong reason.
2. Does it add work, processes or I/O at launch? Move it to first use.
3. What does it add to memory, binary size and dependencies? A new dependency must replace more code than it costs to carry, and the PR names it.
4. What does it add to the UI: a setting, a screen, a state the user has to learn?
5. The tradeoff, in one sentence: what the user gains, and what every user pays for it.

When a feature can't meet a budget, either shrink it until it can or record the exception and its cost here.

## Accessibility & Inclusion

Follow native macOS conventions: VoiceOver labels on every dot and card, visible keyboard focus in summoned mode, ≥4.5:1 text contrast on the dark panel, state never conveyed by color alone, and the system Reduce Motion setting replaces breathing/spring motion with static or cross-fade equivalents.
