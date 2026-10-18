# Native motion verification — 18 October 2026

Status: implementation and functional checks complete; **performance/release gate unresolved**. Do not merge or install this branch. No claim of sustained 60 fps.

## Changes and ownership

AppKit/Core Animation owns island geometry, window bounds, content clipping and repeating indicators. SwiftUI uses shared 120 ms feedback, 220 ms details and 250 ms navigation presets. Reduce Motion uses static geometry/indicators and short opacity transitions; disclosure layout changes immediately.

The island coordinator uses a deterministic critical spring (omega 24, 600 ms settling window), building 73 keyframes only when geometry changes. Interruptions recover visible presentation geometry and retain analytic velocity. Compatible path topology spans notched and non-notched displays. Swept bounds include momentum; window bounds only grow during an active trajectory and shrink on current-generation completion. Unchanged targets do no trajectory work. No application frame loop was added.

Content reversals sample current opacity/translation. Plan navigation retains conversation/draft state. Streaming follows without repeated scroll animations, explicit Latest has a short transition, and user scrolling suspends follow. The undo ring uses a Core Animation stroke with an independent action deadline. Decorative Ultracode breathing was removed. Live accessibility notifications cancel native motion; SwiftUI reads the live environment.

Measured synchronous window layout and first-use sound work motivated monotonic window fitting, avoiding redundant window ordering, and serial background sound creation/playback. Polling lifecycle is unchanged: the traces do not isolate synchronous core reads/decoding as the primary long-hitch source, so no speculative polling-worker refactor was made.

## Comparable measurements

Hardware: M2 MacBook Air, 8 GB; macOS 26.5.1; Xcode 26 toolchain; built-in display. Debug app bundles run directly from build output through isolated copies. No branch build was installed. Baseline source is commit 586ec3d; after source includes a89dbfa plus the final presentation-path/window/sound fixes. All six captures used the same corrected growing-text fixture.

Time Profiler plus Hitches, 26 seconds per capture, three successive before runs then three after runs. Actions last roughly 14–19 seconds; the remaining recording is an idle tail. No concurrent builds or manual UI work during these six captures.

| Run | Before events | After events | Before total ms | After total ms | Before maximum ms | After maximum ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 24 | 11 | 916.641 | 783.304 | 233.332 | 249.990 |
| 2 | 24 | 10 | 633.316 | 466.656 | 116.666 | 150.000 |
| 3 | 23 | 10 | 816.642 | 416.652 | 199.992 | 116.662 |
| Total | 71 | 31 | 2366.599 | 1666.612 | — | — |

These are app-attributed **Hitches instrument events**, not all displayed frames or a frame-rate measurement. Event count fell 56.3%; reported total duration fell 29.6%. Events above 16.7 ms increased from 14 (5/4/5) to 17 (8/4/5). Fewer single-refresh events account for the overall count improvement. The worst outlier increased. A count of missed display deadlines and frame-time distribution could not be established reliably; neither improvement establishes the release gate.

| Main-thread inclusive sample weight | Before ms | After ms |
| --- | ---: | ---: |
| Total main-thread samples | 5232 | 4875 |
| Window fitting | 85 | 28 |
| IslandController.render | 144 | 364 |
| SwiftUI layout | 2837 | 2767 |
| CoreBridge.call | 160 | 183 |
| pollChat | 85 | 119 |
| Sounds.play | 31 | 0 |

Sampling weights are 1 ms; inclusive groups overlap and must not be summed. Main-thread sampled CPU fell 6.8%. New keyframe construction contributes 39 inclusive sampled ms across the three after runs. The render increase primarily contains CA transaction commit/hosting layout (233/231 inclusive ms), so reduced fitting work does not mean all rendering became cheaper.

Remaining composer stalls contain NSTextView text replacement, text-storage editing and native Writing Tools selection updates (83 inclusive sampled ms in each variant). During the first-run 233/250 ms outliers, ComposerField appears in 73/68 main samples and GraphHost flushing in 97/94. This identifies work during the stalls, not sole causation for their full duration. SwiftUI layout dominates other navigation stalls. Further isolation of native text editing and hosting layout is required before release; disabling native editing features merely to improve these numbers was not done.

## Instrument limitations

The full Animation Hitches template produced excessive kernel staging data and several failed captures. One original baseline survives at build/motion-profile/baseline-final/run-1.trace, but is not mixed into the six-run comparison. Frame Lifetimes exports contained sentinel/wrapped timestamps and no display-swap rows, so they were rejected. The local Core Animation FPS instrument is disabled on macOS. Time Profiler plus Hitches produced valid, compact captures but does not prove presentation cadence. Host scheduling, initialization, compression, profiler overhead and non-interleaved ordering limit causal comparison. Exact fixture step boundaries lack signposts.

Raw traces and XML are local ignored artifacts; they can contain process environment metadata and were not uploaded. Some kernel providers ignore TMPDIR: task-owned global staging files require manual inspection/cleanup after saving traces. Never delete unrelated Instruments staging files.

## Functional checks

- Standalone Swift checks pass: position/velocity continuity; current presentation-path recovery; compatible path topology; momentum/window bounds; unchanged targets; envelope changes; stale completion rejection; cancellation; countdown geometry/deadline; session title persistence.
- Full fixture: normal open/close/resize, twelve reversals at 75 ms, 81-entry history, composer, 32 growing streamed-text updates at 80 ms, long plan, approval/allow/undo and collapse. All six runs completed within their recording windows.
- Native UI: long-plan reader/back retained a typed draft. Scrolling up exposed Latest; explicit Latest followed by upward scrolling left the user at their selected position. Controls remained reachable; no focus or first-click regression was observed in the exercised flows. This is scoped manual coverage, not exhaustive accessibility certification.
- System Reduce Motion was enabled live during repeated active transitions and was enabled before a fresh Debug launch. Both remained functional; native layout/indicators were inspected. The original Off setting was restored. Unit checks establish cancellation semantics; still screenshots alone do not prove every animation frame.
- cargo test: 180 passed, zero failures (core/); final log /tmp/agent-island-final-cargo-2.log.
- Final Debug and Release xcodebuild succeeded; logs /tmp/agent-island-after-build.log and /tmp/agent-island-release-build.log. No installed app replacement.

## Budgets

No dependencies, public API/Rust protocol changes, settings, screens, startup processes or launch I/O were added. The serial sound queue is used on demand. Transition bookkeeping and bounded path allocation buy continuity; Core Animation performs intermediate frames. The collapsed elapsed-time timeline now starts at distantFuture, eliminating its previous hourly wakeup.

Release bundle logical file size: **10,532,583 bytes (10.533 MB)**, below 15 MB. Resident memory is reported separately from physical footprint and can change with compression. Settled empty collapsed Debug samples (12 seconds each) recorded zero user/system CPU counter growth and zero interrupt/package wakeups in two samples; a third had raw CPU deltas 2106/26247 with zero wakeups. Resident size was 15.1–16.2 MB after compression. Do not generalize two zero samples to a proof of zero work in every environment.

Fresh empty Release samples recorded 1 and 2 interrupt wakeups and small nonzero raw CPU deltas (5881/13121 and 2698/8352); package wakeups were zero. Resident bytes fell from 69,976,064 to 64,520,192 over those samples, **above the 60 MB resident budget**, despite a 19,563,336-byte physical footprint. A Debug full-workload sample spanned 97,206,272 to 50,561,024 resident bytes. These are point samples, not a peak-memory profile; compression strongly affects residency. The fresh-launch/active memory budget and strict idle behavior therefore remain unresolved, in addition to frame timing. No budget exception is approved or asserted.

Raw samples: build/motion-profile/final-ui/*metrics.json, final-reduced-idle/*metrics.json and release-idle-verified/*metrics.json. The first final-ui sample overlaps workload and must not be labeled idle. Reduce Motion was enabled at launch for final-reduced-idle, then restored Off before its settled normal-idle samples.

## Reproduction and artifacts

Build Debug baseline and after separately with xcodebuild and xcodegen; never install either. Then, from repo root:

```sh
python3 scripts/dev/motion-profile.py --app 'build/baseline/Build/Products/Debug/Agent Island.app' --label before-growing --runs 3 --template 'Time Profiler' --instrument Hitches
python3 scripts/dev/motion-profile.py --app 'build/after/Build/Products/Debug/Agent Island.app' --label after-growing --runs 3 --template 'Time Profiler' --instrument Hitches
```

Use new labels when captures already exist. The driver creates unique bundle preferences, home/support directories, socket, fake local agent executable and transcript. No real CLI/network authentication is used. Non-idle workloads require a responding DEBUG state hook. Isolated launch declines the move-to-Applications prompt.

Per-run trace/XML/summary/workload files: build/motion-profile/{before-growing,after-growing}/run-{1,2,3}*. Export each schema separately because xctrace can omit later schemas in a multi-table export:

```sh
xcrun xctrace export --input build/motion-profile/after-growing/run-1.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="hitches"]' --output /tmp/after-hitches.xml
python3 scripts/dev/motion-summary.py /tmp/after-hitches.xml
```

Repeat with schema time-profile. Detailed extracted comparison: build/motion-profile/growing-comparison-analysis.{json,md}. For native checks use --drive-only; metadata identifies the unique fixture app and notification suffix. For idle use --workload idle. Build the read-only process sampler with clang scripts/dev/process-metrics.c -o /tmp/island-process-metrics, then sample the isolated PID for 12 seconds after settling. CPU counters are retained raw; zero deltas need no platform-specific unit conversion.

## Delivery

Draft PR only while the 16.7 ms performance gate and active resident-memory verification remain unresolved. Functional review can be clean while performance remains insufficient. Squash merge and scripts/install.sh from merged main are intentionally pending those gates.
