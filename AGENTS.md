# Agent instructions

## Before building a feature

Agent Island must stay lightweight (see Lightweight in `PRODUCT.md`). Check the feature against those budgets, and put its cost and tradeoff in the PR description (and the plan, if there is one).

## Finishing a change

1. Run the tests (`cargo test` in `core/`) and make sure the macOS app builds (`xcodebuild` on `macos/`; don't install a branch build).
2. Commit on a branch, never on `main`.
3. Review loop: run a code review of the branch, fix what it finds, commit, and review again. Repeat until a review finds zero issues.
4. Open a PR against `main`, then squash merge it.
5. Reinstall from the merged `main` with `scripts/install.sh`.
