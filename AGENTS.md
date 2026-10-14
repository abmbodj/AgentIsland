# Agent instructions

## Finishing a change

1. Run the tests (`cargo test` in `core/`) and build the app (`scripts/install.sh` builds and installs it).
2. Commit on a branch, never on `main`.
3. Review loop: run a code review of the branch, fix what it finds, commit, and review again. Repeat until a review finds zero issues.
4. Open a PR against `main`, then squash merge it.
5. Reinstall from the merged `main` with `scripts/install.sh`.
