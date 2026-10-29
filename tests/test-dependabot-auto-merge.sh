#!/usr/bin/env bash
# Tests dependabot-auto-merge.yml's policy, gate, merge and label run:
# blocks, extracted with yq, against tests/stub-dependabot/gh.
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
policy_sh="$(_step 'Decide if PR can be evaluated')"
gate_sh="$(_step 'Wait for all checks')"
merge_sh="$(_step 'Approve and merge')"
label_sh="$(_step 'Label blocked PR')"
for s in "${policy_sh}" "${gate_sh}" "${merge_sh}" "${label_sh}"; do
  [[ -n "${s}" && "${s}" != "null" ]] || { echo "could not extract run blocks"; exit 1; }
done

_fixture() {
  STUB_DIR="$(mktemp -d)"; export STUB_DIR
  tmp_dirs+=("${STUB_DIR}")
  : >"${STUB_DIR}/calls.log"
  : >"${STUB_DIR}/out"
}
_out() { sed -n "s/^$1=//p" "${STUB_DIR}/out"; }
_called() { grep -qF -- "$1" "${STUB_DIR}/calls.log"; }

# --- policy step -------------------------------------------------------
# policy PREV NEW DEPS [ALLOW] [TRUSTED] -> sets decision, reason, out
policy() {
  _fixture
  rc=0
  out="$(PREV_VERSION="$1" NEW_VERSION="$2" DEP_NAMES="$3" ALLOW_MAJOR="${4-false}" \
    TRUSTED_NAMESPACES="${5-}" GITHUB_OUTPUT="${STUB_DIR}/out" \
    bash -c "${policy_sh}" 2>&1)" || rc=$?
  decision="$(_out decision)"; reason="$(_out reason)"
}
_expect_policy() { # label expected-decision [notice-substring]
  if [[ "${rc}" -eq 0 && "${decision}" == "$2" ]] && grep -qF -- "${3-}" <<<"${out}"; then
    _ok "$1"
  else
    _bad "$1: rc=${rc} decision='${decision}' out=${out}"
  fi
}

policy 5.9.3 6.0.3 typescript
_expect_policy "single untrusted major -> gate (was skip in v2)" gate "major v5 -> v6"
policy 5.9.3 6.0.3 "typescript, eslint"
_expect_policy "grouped PR -> gate (was skip in v2)" gate "group of 2"
policy 5.9.3 5.10.0 typescript
_expect_policy "single minor -> gate, not --auto" gate "patch/minor within v5"
policy abc def typescript
_expect_policy "unparseable versions -> gate" gate "unparseable version change"
policy 1.0.0 2.0.0 smartwatermelon/thing true smartwatermelon
_expect_policy "v2 inputs are accepted and reported as ignored" gate "ignored since v3"
policy 1.0.0 2.0.0 ""
_expect_policy "empty dependency-names -> blocked" blocked "empty dependency-names"
if [[ "${reason}" == "cannot-evaluate" ]]; then _ok "empty deps reason is cannot-evaluate"; else _bad "empty deps reason='${reason}'"; fi
policy 1.0.0 2.0.0 "  "
_expect_policy "whitespace-only dependency-names -> blocked" blocked

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
    REPO=acme/site BASE_REF=main \
    SELF_WORKFLOW="Dependabot Auto-Merge" SETTLE_SECONDS=0 POLL_SECONDS=0.1 \
    WAIT_SECONDS="${WAIT:-3}" bash -c "${gate_sh}" 2>&1)" || rc=$?
  result="$(_out gate)"; reason="$(_out reason)"
}
_expect_gate() { # label expected [reason] [notice-substring]
  if [[ "${rc}" -eq 0 && "${result}" == "$2" && "${reason}" == "${3-}" ]] \
    && grep -qF -- "${4-}" <<<"${out}"; then
    _ok "$1"
  else
    _bad "$1: rc=${rc} gate='${result}' reason='${reason}' out=${out}"
  fi
}

# 1. pending, then all green: passes only after two identical finished polls
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "build|pending"
_checks 2 self "build|pass" "Pages changed|skipping"
gate
_expect_gate "pending then green (NEUTRAL/skipped allowed) -> pass" pass "" "All 2 other checks"
polls="$(<"${STUB_DIR}/checks.count")"
if [[ "${polls}" -ge 3 ]]; then _ok "needs two identical finished polls"; else _bad "passed after ${polls} polls"; fi

# 2. a failing non-required check blocks, and names it; main is green
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "build|fail" "standards|pass"
gate
_expect_gate "failing build, green main -> red-check" blocked red-check "failing or cancelled checks (red-check): build"

# 3. cancelled counts as bad
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "build|cancel"
gate
_expect_gate "cancelled check -> red-check" blocked red-check "build"

# 4. cannot see its own check run -> fail closed even though the rest is green
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 "build|pass"
gate
_expect_gate "own check run not visible -> cannot-evaluate" blocked cannot-evaluate "cannot see its own check run"

# 5. still pending at the deadline
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "build|pending"
WAIT=1 gate
_expect_gate "pending past the deadline -> timeout" blocked timeout "checks still running"

# 6. only this workflow's own checks present: never passes on nothing
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "dependabot-auto-merge / other|pass|Dependabot Auto-Merge"
WAIT=1 gate
_expect_gate "no other checks -> no-checks at deadline, not pass" blocked no-checks "add a required check"

# 7. head moved -> the new run decides, no label reason
_fixture; echo "fedcba9876543210fedcba9876543210fedcba98" >"${STUB_DIR}/head"
_checks 1 self "build|pass"
gate
_expect_gate "head moved -> superseded" superseded "" "the run for the new head decides"

# 8. unreadable checks output -> blocked, not pass
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_raw_checks 1 "not json"
gate
_expect_gate "unreadable checks -> cannot-evaluate" blocked cannot-evaluate "could not read"

# 9. an unknown bucket counts as pending, not as pass
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "build|pass" "odd|weird"
WAIT=1 gate
_expect_gate "unknown bucket never passes" blocked timeout "checks still running"

# 10. every failing check also fails on main -> main-red (check-runs and statuses)
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "build (20.x, ubuntu)|fail" "netlify/site/deploy-preview|fail" "standards|pass"
printf '%s\n' "build (20.x, ubuntu)" "lint" >"${STUB_DIR}/main-runs"
printf '%s\n' "netlify/site/deploy-preview" >"${STUB_DIR}/main-statuses"
gate
_expect_gate "failures all red on main too -> main-red" blocked main-red "build (20.x, ubuntu), netlify/site/deploy-preview"
if _called "commits/main/check-runs"; then _ok "main-red reads the base branch"; else _bad "base branch not read"; fi

# 11. one failure is only on the PR -> red-check
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "build|fail" "test|fail"
printf '%s\n' "build" >"${STUB_DIR}/main-runs"
gate
_expect_gate "a failure not on main -> red-check" blocked red-check "build, test"

# 12. base branch unreadable -> red-check, never main-red
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "build|fail"
printf '%s\n' "build" >"${STUB_DIR}/main-runs"
: >"${STUB_DIR}/fail.api"
gate
_expect_gate "base branch unreadable -> red-check" blocked red-check "build"

# 13. unreadable head -> labeled, never an unlabeled superseded
_fixture; : >"${STUB_DIR}/head"
_checks 1 self "build|pass"
gate
_expect_gate "unreadable head -> cannot-evaluate" blocked cannot-evaluate "could not read the PR head"

# 14. every other check skipped -> no-checks once settled, not timeout
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "build|skipping" "deploy|skipping"
WAIT=30 gate
_expect_gate "all other checks skipped -> no-checks" blocked no-checks "all 2 other checks were skipped"

# --- merge step --------------------------------------------------------
merge() {
  rc=0
  out="$(PATH="${here}/stub-dependabot:${PATH}" GITHUB_OUTPUT="${STUB_DIR}/out" \
    PR_URL=https://github.com/acme/site/pull/7 HEAD_SHA="${sha}" \
    bash -c "${merge_sh}" 2>&1)" || rc=$?
  reason="$(_out reason)"
}
_fixture
printf '%s\n' "dependencies" "dependabot-blocked" "dependabot-blocked:timeout" >"${STUB_DIR}/labels"
merge
if [[ "${rc}" -eq 0 && -z "${reason}" ]] \
  && _called "pr merge --squash --delete-branch --match-head-commit ${sha}" \
  && ! _called "--auto"; then
  _ok "merge pins the head commit, never --auto"
else
  _bad "merge call: rc=${rc} reason='${reason}' calls=$(<"${STUB_DIR}/calls.log")"
fi
if _called "--remove-label dependabot-blocked,dependabot-blocked:timeout"; then
  _ok "merge clears blocked labels from earlier runs"
else
  _bad "stale labels kept: $(<"${STUB_DIR}/calls.log")"
fi

_fixture; : >"${STUB_DIR}/fail.pr-merge"
merge
if [[ "${rc}" -eq 0 && "${reason}" == "merge-failed" ]]; then _ok "merge failure -> merge-failed, never red"; else _bad "merge failure: rc=${rc} reason='${reason}'"; fi
if _called "pr edit"; then _bad "unexpected pr edit"; else _ok "no label edit when none are stale"; fi

# --- label step --------------------------------------------------------
label() { # label REASON
  rc=0
  out="$(PATH="${here}/stub-dependabot:${PATH}" GH_REPO=acme/site \
    PR_URL=https://github.com/acme/site/pull/7 REASON="$1" \
    bash -c "${label_sh}" 2>&1)" || rc=$?
}
_fixture
printf '%s\n' "dependabot-blocked" "dependabot-blocked:timeout" >"${STUB_DIR}/labels"
label red-check
if [[ "${rc}" -eq 0 ]] && _called "label create dependabot-blocked:red-check" \
  && _called "pr edit https://github.com/acme/site/pull/7 --add-label dependabot-blocked,dependabot-blocked:red-check --remove-label dependabot-blocked:timeout"; then
  _ok "labels the reason and drops the stale reason"
else
  _bad "label: rc=${rc} calls=$(<"${STUB_DIR}/calls.log")"
fi

_fixture
label 'bogus;reason'
if _called "--add-label dependabot-blocked,dependabot-blocked:cannot-evaluate"; then
  _ok "unknown reason -> cannot-evaluate"
else
  _bad "unknown reason: $(<"${STUB_DIR}/calls.log")"
fi

_fixture; : >"${STUB_DIR}/fail.pr-edit"; : >"${STUB_DIR}/fail.label-create"
label timeout
if [[ "${rc}" -eq 0 ]] && grep -qF "::warning::Could not label" <<<"${out}"; then
  _ok "label failures warn, never red"
else
  _bad "label failure: rc=${rc} out=${out}"
fi

echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
