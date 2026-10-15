#!/usr/bin/env bash
# Git credential helper for auto-tag.yml: answers "get" with GH_TOKEN from env.

# The token stays out of .git/config and out of argv.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
if [[ "${1:-}" == "get" ]]; then
  printf 'username=x-access-token\npassword=%s\n' "${GH_TOKEN}"
fi
