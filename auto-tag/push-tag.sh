#!/usr/bin/env bash
# Tags TARGET_SHA as VERSION in the repo at cwd and pushes the tag to origin.

# Env: VERSION (from next-version.sh), TARGET_SHA. Nonzero exit = refused.

# Lightweight: an annotated tag needs a tagger identity on the runner, and
# `git describe --tags` reads both kinds.

# No --force: a name already on the remote fails the push. A tag never moves.
set -euo pipefail

VERSION="${VERSION:-}"
TARGET_SHA="${TARGET_SHA:-}"
if [[ -z "${VERSION}" || -z "${TARGET_SHA}" ]]; then
  echo "::error::VERSION and TARGET_SHA are required" >&2
  exit 2
fi

git tag "${VERSION}" "${TARGET_SHA}"
git push origin "refs/tags/${VERSION}"
