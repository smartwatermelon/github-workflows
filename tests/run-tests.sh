#!/usr/bin/env bash
# Runs every tests/test-*.sh; exits nonzero if any fails.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0
for t in "${here}"/test-*.sh; do
  echo "== ${t##*/}"
  if bash "${t}"; then
    echo "PASS ${t##*/}"
  else
    echo "FAIL ${t##*/}"
    failed=$((failed + 1))
  fi
done
echo "${failed} test file(s) failed"
[[ "${failed}" -eq 0 ]]
