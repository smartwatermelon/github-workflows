# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Testing and linting

- `bash tests/run-tests.sh` runs the standards suites (`test-run-standards.sh`, `test-check-node-floor.sh`).
  Requires `shellcheck`, `yamllint`, `actionlint`, `zizmor`, and `markdownlint-cli2` (all via Homebrew), plus `jq`.
- `bash standards/run-standards.sh --repo <dir>` runs the exact same standards
  check CI runs, against a local checkout — this is the command
  `standards-check.yml` calls in CI, so a clean local run predicts a clean
  self-check.
