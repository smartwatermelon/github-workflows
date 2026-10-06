#!/usr/bin/env bash
# Hermetic tests for netlify/wait-for-production.sh against
# tests/stub-netlify/curl.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../netlify/wait-for-production.sh"
# An exported gh/curl function or BASH_ENV would shadow the PATH stubs.
unset -f gh curl 2>/dev/null || true
unset BASH_ENV
pass=0; fail=0
_ok() { echo "  ok   $1"; pass=$((pass + 1)); }
_bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

sha="0123456789abcdef0123456789abcdef01234567"
other="fedcba9876543210fedcba9876543210fedcba98"
token="nfp_TESTTOKEN_must_never_be_printed"

_fixture() {
  STUB_DIR="$(mktemp -d)"; export STUB_DIR
  : >"${STUB_DIR}/calls.log"
  printf '%s' "${token}" >"${STUB_DIR}/token"
  printf '{"name":"examplesite","url":"http://example.com","ssl_url":"https://example.com"}' >"${STUB_DIR}/site.json"
}
# _deploys N JSON-ARRAY: body of the nth deploys-list poll
_deploys() { printf '%s' "$2" >"${STUB_DIR}/deploys.$1.json"; }
_d() { # _d CONTEXT SHA STATE [ERROR]: one deploy record
  jq -nc --arg c "$1" --arg r "$2" --arg s "$3" --arg e "${4-}" \
    '{context: $c, commit_ref: $r, state: $s, error_message: (if $e == "" then null else $e end)}'
}
run() {
  rc=0
  out="$(PATH="${here}/stub-netlify:${PATH}" NETLIFY_SITE=examplesite COMMIT_SHA="${sha}" \
    NETLIFY_AUTH_TOKEN="${TOKEN-${token}}" \
    NETLIFY_POLL_INTERVAL=0.1 NETLIFY_POLL_DEADLINE="${DEADLINE:-3}" \
    bash "${script}" 2>"${STUB_DIR}/err")" || rc=$?
  err="$(cat "${STUB_DIR}/err")"
}

# 1. ready on first poll: prints ssl_url, and only that, on stdout
_fixture
_deploys 1 "[$(_d deploy-preview "${sha}" ready),$(_d production "${sha}" ready)]"
run
if [[ "${rc}" -eq 0 && "${out}" == "https://example.com" ]]; then _ok "ready prints the site ssl_url"; else _bad "ready case: rc=${rc} out='${out}' err=${err}"; fi
if grep -qF -- "${token}" "${STUB_DIR}/calls.log" || grep -qF -- "${token}" <<<"${out}${err}"; then _bad "token leaked into argv or output"; else _ok "token absent from argv and output"; fi

# 2. error: fails at once and prints error_message
_fixture
_deploys 1 "[$(_d production "${sha}" error "Build script returned non-zero exit code: 2")]"
run
if [[ "${rc}" -eq 1 && -z "${out}" ]] && grep -q 'non-zero exit code: 2' <<<"${err}"; then _ok "error fails with error_message"; else _bad "error case: rc=${rc} out='${out}' err=${err}"; fi

# 3. absent, building, then ready. A same-SHA deploy-preview is not production.
_fixture
_deploys 1 "[$(_d deploy-preview "${sha}" ready),$(_d production "${other}" ready)]"
_deploys 2 "[$(_d production "${sha}" building),$(_d production "${other}" ready)]"
_deploys 3 "[$(_d production "${sha}" ready),$(_d production "${other}" ready)]"
run
polls="$(cat "${STUB_DIR}/deploys.count")"
if [[ "${rc}" -eq 0 && "${out}" == "https://example.com" && "${polls}" -eq 3 ]]; then _ok "not-yet-present, building, then ready (3 polls)"; else _bad "late case: rc=${rc} polls=${polls} out='${out}' err=${err}"; fi

# 4. missing token: exits 2 with a clear message, no API call
_fixture
TOKEN="" run
if [[ "${rc}" -eq 2 && ! -s "${STUB_DIR}/calls.log" ]] && grep -q 'NETLIFY_AUTH_TOKEN is empty' <<<"${err}"; then _ok "missing token fails clearly, no API call"; else _bad "missing-token case: rc=${rc} err=${err}"; fi

# 5. timeout names the states it saw
_fixture
_deploys 1 "[$(_d production "${other}" ready)]"
_deploys 2 "[$(_d production "${sha}" building)]"
# 2s: SECONDS is whole seconds, so 1s can end after one poll; this needs two.
DEADLINE=2 run
if [[ "${rc}" -eq 1 ]] && grep -q 'States seen: not-yet-present,building\.' <<<"${err}"; then _ok "timeout lists states seen"; else _bad "timeout case: rc=${rc} err=${err}"; fi

# 6. a wrong token reads as request-failed in the timeout, not a silent hang
_fixture
_deploys 1 "[$(_d production "${sha}" ready)]"
TOKEN="wrong" DEADLINE=1 run
if [[ "${rc}" -eq 1 ]] && grep -q 'States seen: request-failed\.' <<<"${err}"; then _ok "rejected token surfaces as request-failed"; else _bad "wrong-token case: rc=${rc} err=${err}"; fi

# 7. no ssl_url: falls back to url
_fixture
printf '{"name":"examplesite","url":"https://examplesite.netlify.app","ssl_url":null}' >"${STUB_DIR}/site.json"
_deploys 1 "[$(_d production "${sha}" ready)]"
run
if [[ "${rc}" -eq 0 && "${out}" == "https://examplesite.netlify.app" ]]; then _ok "falls back to url when ssl_url is absent"; else _bad "fallback case: rc=${rc} out='${out}' err=${err}"; fi

# 8. newest record for the SHA wins: a retried deploy after an error
_fixture
_deploys 1 "[$(_d production "${sha}" ready),$(_d production "${sha}" error "old failure")]"
run
if [[ "${rc}" -eq 0 ]]; then _ok "newest production record for the SHA wins"; else _bad "retry case: rc=${rc} err=${err}"; fi

echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
