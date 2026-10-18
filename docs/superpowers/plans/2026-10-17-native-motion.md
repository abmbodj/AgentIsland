# Native Motion System Implementation Plan

Goal: improve every animated macOS surface with interruptible native motion and measured performance.
Architecture: AppKit/Core Animation owns shell and repeating effects; SwiftUI owns content transitions. No dependencies or public protocol changes.

- [x] Record approved design, validate clean baseline, create isolated profiling fixtures and capture three baseline runs.
- [x] Add shared presets and a tested critical-spring trajectory/coordinator; unify path topology and completion-driven window sizing.
- [x] Standardize navigation, disclosures, feedback, glyphs, countdowns and mode indicators; live Reduce Motion cancels movement.
- [x] Remove repeated animated streaming follow; profile and fix attributable rendering/layout/main-thread bottlenecks.
- [x] Test continuity, cancellation, unchanged targets and stale completion; verify normal and 50–100 ms repeated input.
- [ ] Capture three comparable after traces, 12-second idle CPU/wakeups, resident memory and bundle size; document evidence and limitations.
- [ ] Run cargo test, Swift checks and xcodebuild; commit, review/fix/review until zero findings.
- [ ] Open PR against main, squash merge only when the performance gate passes, reinstall from merged main.

Budgets: zero collapsed-idle polling/CPU work; resident memory under 60 MB; bundle under 15 MB; no launch work, dependencies, settings or screens. Tradeoff: bounded transition bookkeeping for interruption continuity and reduced per-frame application work.

The design was self-reviewed for placeholders, contradictions, scope and ambiguity before its initial commit. The user's explicit request to implement the approved plan supplies the written-design approval. Execute with the subagent-driven-development skill, preserving file ownership and reviewing the whole branch before delivery.

Verification and release status: see [measured report](../specs/2026-10-18-native-motion-verification.md). Six comparable captures complete; persistent long hitches leave the performance gate unresolved. No merge or reinstall until it passes.
