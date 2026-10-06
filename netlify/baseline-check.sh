#!/usr/bin/env bash
# Baseline check every site gets from netlify-site-checks.yml (dev-env#193).
# Usage: baseline-check.sh <base-url>

# GET / must return 200 (after redirects) with a body of at least 1024 bytes
# that contains a <title> element.

# Exit 0 = the served site is sane, 1 = it is not, 2 = usage.
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
  printf 'usage: %s <base-url>\n' "$(basename "$0")" >&2
  exit 2
fi
base_url="${1%/}"
min_bytes=1024

body="$(mktemp)"
trap 'rm -f "${body}"' EXIT

# curl exits nonzero on a connection failure but still writes 000 for the
# status, so the status check below reports it.
status="$(curl --silent --show-error --location \
  --connect-timeout 10 --max-time 30 --retry 2 --retry-delay 3 \
  --output "${body}" --write-out '%{http_code}' \
  "${base_url}/")" || true

if [[ "${status}" != "200" ]]; then
  printf 'FAIL: %s/ returned %s (expected 200)\n' "${base_url}" "${status:-000}" >&2
  exit 1
fi
printf 'ok: %s/ returned 200\n' "${base_url}"

failures=0
size="$(wc -c <"${body}")"
size="${size//[[:space:]]/}"
if ((size >= min_bytes)); then
  printf 'ok: / body is %s bytes (floor %s)\n' "${size}" "${min_bytes}"
else
  printf 'FAIL: / body is %s bytes, below the %s-byte floor (empty or truncated deploy?)\n' \
    "${size}" "${min_bytes}" >&2
  failures=$((failures + 1))
fi

if grep -Eqi '<title[^>]*>' "${body}"; then
  printf 'ok: / contains a <title> element\n'
else
  printf 'FAIL: / has no <title> element (not an HTML page?)\n' >&2
  failures=$((failures + 1))
fi

if ((failures > 0)); then
  exit 1
fi
