# Native motion design

Approved in the planning conversation and explicitly authorized for implementation on October 17, 2026.

Agent Island keeps its native AppKit/Core Animation shell and SwiftUI content. All animated surfaces share restrained presets: a critically damped silhouette, 120 ms feedback, 220 ms detail changes, 250 ms navigation, and 100–120 ms accessibility crossfades. Actions update state immediately. Forward and Back remain spatially opposed. No animation gates input.

The silhouette uses a consistent path topology for notched and non-notched displays. A focused coordinator retains analytic geometry trajectories, carries position and velocity when interrupted, ignores unchanged targets, submits bounded keyframes to Core Animation, and owns completion. Window bounds cover the active trajectory and shrink only for the current generation. Content opacity and translation retarget from presentation values.

Reduce Motion changes apply live: cancel active movement and breathing, use static state indicators and short fades. Countdown presentation runs in Core Animation independently of the Undo deadline. Streaming follows incremental text without restarting scroll animation; explicit Latest remains animated and user scrolling interrupts follow.

Profile ordinary and rapid open/close/resize, navigation, plan review, disclosures, approval/undo, and streaming. Address synchronous core work only when profiling identifies a bottleneck; background results must reject stale conversations and overlapping pulls. No public API or core protocol change.

## Budgets and acceptance

No new dependencies, launch processes/I/O, settings, screens, idle polling, or application frame loop. Collapsed idle remains 0% CPU with no new wakeups across 12-second samples. Resident memory stays below 60 MB and bundle below 15 MB. The cost is bounded transition bookkeeping in exchange for interruption continuity and less per-frame application work.

Collect three comparable before/after traces on this M2 Air, including frame timing and attributable hitches against 16.7 ms. Missing evidence leaves the merge gate unresolved; do not claim 60 fps from visual inspection. Run core and Swift checks, build macOS, commit and review until zero findings, open a PR against main, squash merge only after gates pass, then reinstall from merged main. Never install a branch build.
