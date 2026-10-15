#!/usr/bin/env bash
# Picks the tag auto-tag.yml puts on TARGET_SHA, in the repo at cwd.
# Prints version=vX.Y.Z on stdout, for GITHUB_OUTPUT.

# Prints version= (empty) if TARGET_SHA already has a vX.Y.Z tag.

# Env: TARGET_SHA, FLOOR (X.Y.Z, no v). Exit 0 = decided, 2 = bad input.

# Only strict vX.Y.Z tags count (no leading zeros, no suffix).
# next = highest (sort -V) with PATCH+1. Result: max(next, vFLOOR).
set -euo pipefail

TARGET_SHA="${TARGET_SHA:-}"
FLOOR="${FLOOR:-}"
if [[ -z "${TARGET_SHA}" ]]; then
  echo "::error::TARGET_SHA is required" >&2
  exit 2
fi

num='(0|[1-9][0-9]*)'
semver_re="^v${num}\.${num}\.${num}\$"

if [[ ! "v${FLOOR}" =~ ${semver_re} ]]; then
  echo "::error::floor '${FLOOR}' is not MAJOR.MINOR.PATCH (e.g. 1.0.0, no leading v)" >&2
  exit 2
fi
if ! git rev-parse --verify --quiet "${TARGET_SHA}^{commit}" >/dev/null; then
  echo "::error::TARGET_SHA '${TARGET_SHA}' is not a commit in this checkout" >&2
  exit 2
fi

# grep exits 1 on no match; that is a normal empty list here.
existing="$(git tag --points-at "${TARGET_SHA}" | { grep -E "${semver_re}" || true; } | sort -V | tail -n 1)"
if [[ -n "${existing}" ]]; then
  echo "::notice::${TARGET_SHA} is already tagged ${existing}; nothing to do." >&2
  echo "version="
  exit 0
fi

floor_tag="v${FLOOR}"
highest="$(git tag --list | { grep -E "${semver_re}" || true; } | sort -V | tail -n 1)"
if [[ -z "${highest}" ]]; then
  echo "version=${floor_tag}"
  exit 0
fi

IFS=. read -r major minor patch <<<"${highest#v}"
next="v${major}.${minor}.$((patch + 1))"
greater="$(printf '%s\n' "${next}" "${floor_tag}" | sort -V | tail -n 1)"
echo "version=${greater}"
