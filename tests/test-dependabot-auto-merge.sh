#!/usr/bin/env bash
# Tests dependabot-auto-merge.yml's policy and gate run: blocks,
# extracted with yq, against tests/stub-dependabot/gh.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wf="${here}/../.github/workflows/dependabot-auto-merge.yml"
unset -f gh 2>/dev/null || true
unset BASH_ENV
pass=0; fail=0
tmp_dirs=()
trap 'rm -rf "${tmp_dirs[@]}"' EXIT
_ok() { echo "  ok   $1"; pass=$((pass + 1)); }
_bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

_step() { # _step NAME: the run: block of the named step
  yq ".jobs.auto-merge.steps[] | select(.name == \"$1\") | .run" "${wf}"
}
policy_sh="$(_step 'Decide if PR is auto-mergeable')"
gate_sh="$(_step 'Wait for all checks (major, opt-in)')"
[[ -n "${policy_sh}" && -n "${gate_sh}" ]] || { echo "could not extract run blocks"; exit 1; }

_fixture() {
  STUB_DIR="$(mktemp -d)"; export STUB_DIR
  tmp_dirs+=("${STUB_DIR}")
  : >"${STUB_DIR}/calls.log"
  : >"${STUB_DIR}/out"
}

# --- policy step -------------------------------------------------------
# policy PREV NEW DEPS ALLOW [TRUSTED] -> sets decision
policy() {
  _fixture
  rc=0
  PREV_VERSION="$1" NEW_VERSION="$2" DEP_NAMES="$3" ALLOW_MAJOR="$4" \
    TRUSTED_NAMESPACES="${5-}" GITHUB_OUTPUT="${STUB_DIR}/out" \
    bash -c "${policy_sh}" >/dev/null 2>&1 || rc=$?
  decision="$(sed -n 's/^decision=//p' "${STUB_DIR}/out")"
}
_expect_policy() { # label expected
  if [[ "${rc}" -eq 0 && "${decision}" == "$2" ]]; then _ok "$1"; else _bad "$1: rc=${rc} decision='${decision}'"; fi
}

policy 5.9.3 6.0.3 typescript false
_expect_policy "single untrusted major, allow_major off -> skip (unchanged)" skip
policy 5.9.3 6.0.3 typescript true
_expect_policy "single untrusted major, allow_major on -> major-gate" major-gate
policy 5.9.3 6.0.3 "typescript, eslint" true
_expect_policy "grouped PR with allow_major on -> skip (groups unchanged)" skip
policy 5.9.3 5.10.0 typescript true
_expect_policy "single minor -> merge (unchanged)" merge
policy abc def typescript true
_expect_policy "unparseable versions with allow_major on -> skip" skip
policy 1.0.0 2.0.0 smartwatermelon/thing true smartwatermelon
_expect_policy "trusted single major keeps the --auto path -> merge" merge
policy 1.0.0 2.0.0 "" true
_expect_policy "empty dependency-names with allow_major on -> skip" skip

# --- gate step ---------------------------------------------------------
sha="0123456789abcdef0123456789abcdef01234567"
run_id="4242"
self_link="https://github.com/acme/site/actions/runs/${run_id}/job/1"
# _checks N SPEC...: nth checks call. SPEC: "self" or NAME|BUCKET[|WORKFLOW].
_checks() {
  local n="$1"; shift
  local spec name bucket wfname rows="[]"
  for spec in "$@"; do
    if [[ "${spec}" == "self" ]]; then
      rows="$(jq -c --arg l "${self_link}" \
        '. + [{name: "dependabot-auto-merge / auto-merge", workflow: "Dependabot Auto-Merge", bucket: "pending", link: $l}]' \
        <<<"${rows}")"
      continue
    fi
    IFS='|' read -r name bucket wfname <<<"${spec}"
    rows="$(jq -c --arg n "${name}" --arg b "${bucket}" --arg w "${wfname:-CI}" \
      '. + [{name: $n, workflow: $w, bucket: $b, link: "https://github.com/acme/site/actions/runs/99/job/2"}]' \
      <<<"${rows}")"
  done
  printf '%s\n' "${rows}" >"${STUB_DIR}/checks.${n}.json"
}
_raw_checks() { printf '%s\n' "$2" >"${STUB_DIR}/checks.$1.json"; }
gate() {
  rc=0
  out="$(PATH="${here}/stub-dependabot:${PATH}" GITHUB_OUTPUT="${STUB_DIR}/out" \
    PR_URL=https://github.com/acme/site/pull/7 HEAD_SHA="${sha}" RUN_ID="${run_id}" \
    SELF_WORKFLOW="Dependabot Auto-Merge" SETTLE_SECONDS=0 POLL_SECONDS=0.1 \
    WAIT_SECONDS="${WAIT:-3}" bash -c "${gate_sh}" 2>&1)" || rc=$?
  result="$(sed -n 's/^gate=//p' "${STUB_DIR}/out")"
}
_expect_gate() { # label expected [notice-substring]
  if [[ "${rc}" -eq 0 && "${result}" == "$2" ]] && grep -qF -- "${3-}" <<<"${out}"; then
    _ok "$1"
  else
    _bad "$1: rc=${rc} gate='${result}' out=${out}"
  fi
}

# 1. pending, then all green: passes only after two identical finished polls
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "build|pending"
_checks 2 self "build|pass" "Pages changed|skipping"
gate
_expect_gate "pending then green (NEUTRAL/skipped allowed) -> pass" pass "All 2 other checks"
polls="$(<"${STUB_DIR}/checks.count")"
if [[ "${polls}" -ge 3 ]]; then _ok "needs two identical finished polls"; else _bad "passed after ${polls} polls"; fi

# 2. a failing non-required check blocks, and names it
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "build|fail" "standards|pass"
gate
_expect_gate "failing build -> skip" skip "failing or cancelled checks: build"

# 3. cancelled counts as bad
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "build|cancel"
gate
_expect_gate "cancelled check -> skip" skip "build"

# 4. cannot see its own check run -> fail closed even though the rest is green
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 "build|pass"
gate
_expect_gate "own check run not visible -> skip" skip "cannot see its own check run"

# 5. still pending at the deadline
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "build|pending"
WAIT=1 gate
_expect_gate "pending past the deadline -> skip" skip "checks still running"

# 6. only this workflow's own checks present: never passes on nothing
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "dependabot-auto-merge / other|pass|Dependabot Auto-Merge"
WAIT=1 gate
_expect_gate "no other checks -> skip at deadline, not pass" skip "checks still running"

# 7. head moved -> the new run decides
_fixture; echo "fedcba9876543210fedcba9876543210fedcba98" >"${STUB_DIR}/head"
_checks 1 self "build|pass"
gate
_expect_gate "head moved -> skip" skip "the run for the new head decides"

# 8. unreadable checks output -> skip, not pass
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_raw_checks 1 "not json"
gate
_expect_gate "unreadable checks -> skip" skip "could not read"

# 9. an unknown bucket counts as pending, not as pass
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "build|pass" "odd|weird"
WAIT=1 gate
_expect_gate "unknown bucket never passes" skip "checks still running"

echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
