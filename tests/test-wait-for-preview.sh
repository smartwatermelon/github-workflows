#!/usr/bin/env bash
# Hermetic tests for netlify/wait-for-preview.sh against tests/stub-netlify/gh.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../netlify/wait-for-preview.sh"
# An exported gh/curl function or BASH_ENV would shadow the PATH stubs.
unset -f gh curl 2>/dev/null || true
unset BASH_ENV
pass=0; fail=0
stub_dirs=()
trap 'rm -rf "${stub_dirs[@]}"' EXIT
_ok() { echo "  ok   $1"; pass=$((pass + 1)); }
_bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

sha="0123456789abcdef0123456789abcdef01234567"
ctx="netlify/examplesite/deploy-preview"
url="https://deploy-preview-7--examplesite.netlify.app"

_fixture() { # fresh STUB_DIR; status fixtures are written by each case
  STUB_DIR="$(mktemp -d)"; export STUB_DIR
  stub_dirs+=("${STUB_DIR}")
  : >"${STUB_DIR}/calls.log"
}
# _status N STATE [TARGET]: the nth poll sees one row for the context.
_status() {
  jq -n --arg c "${ctx}" --arg s "$2" --arg t "${3-}" \
    '{state: $s, statuses: [{context: "other/check", state: "success", target_url: "x"},
      {context: $c, state: $s, target_url: (if $t == "" then null else $t end)}]}' \
    >"${STUB_DIR}/status.$1.json"
}
# run: sets rc, out (stdout), err (stderr).
run() {
  rc=0
  out="$(PATH="${here}/stub-netlify:${PATH}" GITHUB_REPOSITORY=acme/site \
    COMMIT_SHA="${sha}" NETLIFY_SITE=examplesite \
    NETLIFY_POLL_INTERVAL=0.1 NETLIFY_POLL_DEADLINE="${DEADLINE:-3}" \
    bash "${script}" 2>"${STUB_DIR}/err")" || rc=$?
  err="$(cat "${STUB_DIR}/err")"
}

# 1. success after pending: prints target_url and only that on stdout
_fixture
_status 1 pending
_status 2 success "${url}"
run
if [[ "${rc}" -eq 0 && "${out}" == "${url}" ]]; then _ok "pending then success prints the preview URL"; else _bad "success case: rc=${rc} out='${out}' err=${err}"; fi
if grep -q "repos/acme/site/commits/${sha}/status " "${STUB_DIR}/calls.log"; then _ok "polls the singular /status endpoint"; else _bad "endpoint: $(cat "${STUB_DIR}/calls.log")"; fi

# 2. failure: exits 1 at once, prints nothing on stdout
for s in failure error; do
  _fixture
  _status 1 "${s}"
  run
  if [[ "${rc}" -eq 1 && -z "${out}" ]] && grep -q "state=${s}" <<<"${err}"; then _ok "state ${s} fails"; else _bad "${s} case: rc=${rc} out='${out}' err=${err}"; fi
done

# 3. success without target_url fails loudly rather than checking nothing
_fixture
_status 1 success
run
if [[ "${rc}" -eq 1 ]] && grep -q 'no target_url' <<<"${err}"; then _ok "success with no target_url fails"; else _bad "no-target case: rc=${rc} err=${err}"; fi

# 4. timeout: never leaves pending, gives up at the deadline
_fixture
_status 1 pending
DEADLINE=1 run
if [[ "${rc}" -eq 1 ]] && grep -q 'Timed out' <<<"${err}"; then _ok "pending forever times out"; else _bad "timeout case: rc=${rc} err=${err}"; fi

# 5. no status for the context yet (other contexts only), then success
_fixture
jq -n '{state: "pending", statuses: [{context: "other/check", state: "pending"}]}' >"${STUB_DIR}/status.1.json"
_status 2 success "${url}"
run
if [[ "${rc}" -eq 0 && "${out}" == "${url}" ]]; then _ok "absent context waits, then succeeds"; else _bad "absent-context case: rc=${rc} out='${out}' err=${err}"; fi

# 6. plural-statuses regression (amelia-boone#50): two rows, newest first.
# Without head -1 this reads "success\npending" and times out.
_fixture
jq -n --arg c "${ctx}" --arg t "${url}" \
  '{statuses: [{context: $c, state: "success", target_url: $t},
               {context: $c, state: "pending", target_url: $t}]}' >"${STUB_DIR}/status.1.json"
DEADLINE=2 run
if [[ "${rc}" -eq 0 && "${out}" == "${url}" ]]; then _ok "two rows for the context: newest (success) wins"; else _bad "two-row case: rc=${rc} out='${out}' err=${err}"; fi

# 7. bad site name is refused before any API call
_fixture
rc=0
PATH="${here}/stub-netlify:${PATH}" GITHUB_REPOSITORY=acme/site COMMIT_SHA="${sha}" \
  NETLIFY_SITE='bad"site' bash "${script}" >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 2 && ! -s "${STUB_DIR}/calls.log" ]]; then _ok "invalid site name exits 2 with no API call"; else _bad "bad-site case: rc=${rc}"; fi

echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
