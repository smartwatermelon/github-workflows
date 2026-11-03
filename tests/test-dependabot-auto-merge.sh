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
# _dep NAME PREV NEW: one updated-dependencies-json entry, as fetch-metadata writes it.
_dep() { jq -cn --arg n "$1" --arg p "$2" --arg v "$3" '{dependencyName: $n, prevVersion: $p, newVersion: $v}'; }
# _file NAME PATCH: one entry of the PR files API. PATCH "-" means no patch (too large).
_file() {
  if [[ "$2" == "-" ]]; then jq -cn --arg f "$1" '{filename: $f}'; return; fi
  jq -cn --arg f "$1" --arg p "$2" '{filename: $f, patch: $p}'
}
_deps() { # _deps NAME PREV NEW ...: an updated-dependencies-json array
  local all="[]"
  while (($# >= 3)); do
    all="$(jq -c --arg n "$1" --arg p "$2" --arg v "$3" '. + [{dependencyName: $n, prevVersion: $p, newVersion: $v}]' <<<"${all}")"
    shift 3
  done
  printf '%s\n' "${all}"
}
_files() { # _files NAME PATCH ...: a PR files API body
  local all="[]" one
  while (($# >= 2)); do
    one="$(_file "$1" "$2")"
    all="$(jq -c --argjson o "${one}" '. + [$o]' <<<"${all}")"
    shift 2
  done
  printf '%s\n' "${all}"
}
default_files="$(_files package.json $'@@ -1 +1 @@\n-  "x": "1.0.0"\n+  "x": "1.0.1"')"
# policy PREV NEW DEPS: sets decision, reason, out. Env: DEPS_JSON, FILES (files API body), FILES_FAIL=1.
policy() {
  _fixture
  local deps_json="${DEPS_JSON-}" name
  if [[ -z "${DEPS_JSON+x}" ]]; then
    deps_json="$(
      tr ',' '\n' <<<"$3" | sed -E 's@^[[:space:]]+|[[:space:]]+$@@g' | { grep -v '^$' || true; } \
        | while IFS= read -r name; do _dep "${name}" "$1" "$2"; done | jq -sc .
    )"
  fi
  printf '%s\n' "${FILES-${default_files}}" >"${STUB_DIR}/files.json"
  if [[ -n "${FILES_FAIL-}" ]]; then : >"${STUB_DIR}/fail.api"; fi
  rc=0
  out="$(PATH="${here}/stub-dependabot:${PATH}" GH_TOKEN=ambient REPO=acme/site PR_NUMBER=7 \
    PREV_VERSION="$1" NEW_VERSION="$2" DEP_NAMES="$3" ALLOW_MAJOR="${4-false}" \
    DEPS_JSON="${deps_json}" SANITY_CHECKS="${SANITY-tests}" PR_BODY="${BODY-}" \
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
_expect_reason() { # label reason [notice-substring]: blocked with that reason
  if [[ "${rc}" -eq 0 && "${decision}" == blocked && "${reason}" == "$2" ]] \
    && grep -qF -- "${3-}" <<<"${out}"; then
    _ok "$1"
  else
    _bad "$1: rc=${rc} decision='${decision}' reason='${reason}' out=${out}"
  fi
}
_expect_downgrade() { # label [notice-substring]: blocked, reason downgrade
  _expect_reason "$1" downgrade "${2-}"
}

policy 5.9.3 6.0.3 typescript
_expect_policy "single untrusted major -> gate (was skip in v2)" gate "major v5 -> v6"
policy 5.9.3 6.0.3 "typescript, eslint"
_expect_policy "grouped PR -> gate (was skip in v2)" gate "group of 2"
policy 5.9.3 5.10.0 typescript
_expect_policy "single minor -> gate, not --auto" gate "patch/minor within v5"
if _called "api repos/acme/site/pulls/7/files --paginate [token=ambient]"; then
  _ok "policy reads the PR's changed files through the API"
else
  _bad "files API not read: $(<"${STUB_DIR}/calls.log")"
fi
policy abc def typescript
_expect_downgrade "unparseable versions -> downgrade (fail closed, was gate in v3.1)" "typescript abc -> def"

# --- downgrade: metadata check (v3.2) ---
# The 2026-11-02 PRs: tag dependabot-auto-merge-v2.1.0 read as newer than v3.1.0.
gate_pin=smartwatermelon/github-workflows/.github/workflows/dependabot-auto-merge.yml
policy dependabot-auto-merge-v3.1.0 2.1.0 "${gate_pin}"
_expect_downgrade "dependabot-auto-merge-v3.1.0 -> 2.1.0 -> downgrade" \
  "${gate_pin} dependabot-auto-merge-v3.1.0 -> 2.1.0"
# fetch-metadata's "from v?\d" regex drops a prefixed tag, so prev may arrive empty.
policy "" 2.1.0 "${gate_pin}"
_expect_downgrade "empty previous version -> downgrade" "${gate_pin}"
policy 1.0.0 "" foo
_expect_downgrade "empty new version -> downgrade" "foo 1.0.0 -> "
fx="$(_deps typescript 5.9.3 5.10.0 eslint 9.1.0 9.0.5 vite 8.2.2 8.3.4)"
DEPS_JSON="${fx}" policy 5.9.3 5.10.0 "typescript, eslint, vite"
_expect_downgrade "group with one dependency going down -> downgrade" "eslint 9.1.0 -> 9.0.5"
policy v3 dependabot-auto-merge-v3 foo
_expect_downgrade "tag prefix change -> downgrade" "foo v3 -> dependabot-auto-merge-v3"
policy v3.1.0 dependabot-auto-merge-v3.1.0 foo
_expect_downgrade "equal versions, different prefixes -> downgrade"
policy dependabot-auto-merge-v3.1.0 dependabot-auto-merge-v3.0.9 foo
_expect_downgrade "same prefix, lower version -> downgrade"
policy 2.0.0 1.9.9 foo
_expect_downgrade "plain lower version -> downgrade"
policy 1.10.0 1.9.0 foo
_expect_downgrade "1.10.0 -> 1.9.0 is numeric, not lexical -> downgrade"
policy 1.0.0 1.0.0 foo
_expect_downgrade "equal versions -> downgrade (no increase)"
policy 1.2.0 1.2.0-rc1 foo
_expect_downgrade "release -> prerelease of the same base -> downgrade"
policy 1.2.0-rc2 1.2.0-rc1 foo
_expect_downgrade "later prerelease -> earlier prerelease -> downgrade"
policy 5fda3b95a4ea91299a34e894583c3862153e4b97 6d4fd22b20465ccc0f7354476588e8df7c9ca0e0 actions/setup-python
_expect_downgrade "commit SHAs are not comparable -> downgrade"
policy abcdef1 abcdef2 foo
_expect_downgrade "short SHAs with shared leading letters are not versions -> downgrade"
policy eef6144 b4ffde6 foo
_expect_downgrade "short SHAs starting with letters -> downgrade"
# "Removes `uuid`" PRs (tensegrity#136): the parent upgrade drops uuid; fetch-metadata gives it no versions.
rm_body=$'Removes [uuid](https://x). It\'s no longer used.\n\nRemoves `uuid`\nUpdates `@expo/config-plugins` from 54.0.4 to 54.0.6'
fx="$(_deps uuid "" "" @expo/config-plugins 54.0.4 54.0.6)"
BODY="${rm_body}" DEPS_JSON="${fx}" policy "" "" "uuid, @expo/config-plugins"
_expect_policy "removed dependency named in a Removes line -> gate" gate "uuid removed"
DEPS_JSON="${fx}" policy "" "" "uuid, @expo/config-plugins"
_expect_downgrade "no versions and no Removes line -> downgrade" "uuid"
BODY=$'Removes `lodash`' DEPS_JSON="${fx}" policy "" "" "uuid, @expo/config-plugins"
_expect_downgrade "Removes line names another package -> downgrade" "uuid"
BODY=$'see Removes `uuid` above' DEPS_JSON="${fx}" policy "" "" "uuid, @expo/config-plugins"
_expect_downgrade "Removes text not on its own line -> downgrade" "uuid"
fx="$(_deps uuid "" "" @expo/config-plugins 54.0.6 54.0.4)"
BODY="${rm_body}" DEPS_JSON="${fx}" policy "" "" "uuid, @expo/config-plugins"
_expect_downgrade "removal plus a parent going down -> downgrade" "@expo/config-plugins 54.0.6 -> 54.0.4"
BODY=$'Removes `foo`' policy "" 2.1.0 foo
_expect_downgrade "Removes line does not excuse an empty previous version" "foo  -> 2.1.0"
BODY=$'Removes `foo`' policy 1.0.0 "" foo
_expect_downgrade "Removes line does not excuse a lone empty new version" "foo 1.0.0 -> "
DEPS_JSON="not json" policy 1.0.0 1.0.1 foo
if [[ "${decision}" == blocked && "${reason}" == cannot-evaluate ]]; then
  _ok "unreadable updated-dependencies-json -> cannot-evaluate"
else
  _bad "unreadable deps json: decision='${decision}' reason='${reason}' out=${out}"
fi
fx="[]"
DEPS_JSON="${fx}" policy 1.0.0 1.0.1 foo
if [[ "${decision}" == blocked && "${reason}" == cannot-evaluate ]]; then
  _ok "empty updated-dependencies-json -> cannot-evaluate"
else
  _bad "empty deps json: decision='${decision}' reason='${reason}' out=${out}"
fi
SANITY="" policy 2.0.0 1.0.0 foo
_expect_downgrade "a downgrade is labeled downgrade even with no sanity_checks"
for pair in 7.0.0:7.1.0 v4:v5 1.0.261:1.0.262 2026.8.19:2026.10.21 83.0.0:84.1.0 1.3.3:1.4.2 \
  1.2.0-rc1:1.2.0 1.2.0-rc1:1.2.0-rc2 1.2.0:1.3.0-rc1 dependabot-auto-merge-v3.1.0:dependabot-auto-merge-v3.2.0; do
  policy "${pair%%:*}" "${pair#*:}" foo
  _expect_policy "upgrade ${pair%%:*} -> ${pair#*:} still reaches the gate" gate "foo ${pair%%:*} -> ${pair#*:}"
done
# The same name twice with two version pairs (tensegrity#125): each pair is checked.
fx="$(_deps fflate 0.8.2 0.8.3 fflate 0.6.10 0.6.11)"
DEPS_JSON="${fx}" policy 0.8.2 0.8.3 "fflate, fflate"
_expect_policy "same dependency twice, both up -> gate" gate "fflate 0.6.10 -> 0.6.11"

# --- downgrade: diff check (v3.2) -------------------------------------
pin_old="    uses: ${gate_pin}@dependabot-auto-merge-v3.1.0"
pin_new="    uses: ${gate_pin}@dependabot-auto-merge-v3.2.0"
fx="$(_files .github/workflows/dependabot-auto-merge.yml $'@@ -1 +1 @@\n-'"${pin_old}"$'\n+'"${pin_new}")"
FILES="${fx}" policy dependabot-auto-merge-v3.1.0 dependabot-auto-merge-v3.2.0 "${gate_pin}"
_expect_reason "first-party pin going up -> first-party-pin, never labeled downgrade (v3.3)" first-party-pin \
  "${gate_pin} dependabot-auto-merge-v3.1.0 -> dependabot-auto-merge-v3.2.0"
fx="$(_files .github/workflows/ci.yml $'@@ -1 +1 @@\n-      - uses: "SmartWatermelon/github-workflows@v1"\n+      - uses: "SmartWatermelon/github-workflows@v2"')"
FILES="${fx}" policy 1.0.0 2.0.0 foo
_expect_reason "first-party pin match is case-insensitive, quoted, repo-root action" first-party-pin

# --- first-party pins, name/vX.Y.Z tags (v3.3, dev-env#229) ---
_fp() { # _fp OLD_REF NEW_REF [OLD_COMMENT NEW_COMMENT]: a files body moving the gate pin
  local o="    uses: ${gate_pin}@$1" n="    uses: ${gate_pin}@$2"
  [[ -n "${3-}" ]] && o+=" # $3" && n+=" # $4"
  _files .github/workflows/dependabot-auto-merge.yml $'@@ -1 +1 @@\n-'"${o}"$'\n+'"${n}"
}
policy dependabot-auto-merge/v3.3.0 dependabot-auto-merge/v3.4.0 foo
_expect_policy "metadata: name/v3.3.0 -> name/v3.4.0 is an upgrade -> gate" gate
policy dependabot-auto-merge/v3.3.0 dependabot-auto-merge/v3.2.0 foo
_expect_downgrade "metadata: name/v3.3.0 -> name/v3.2.0 -> downgrade"
policy dependabot-auto-merge-v3.2.0 dependabot-auto-merge/v3.3.0 foo
_expect_downgrade "metadata: old name-v tag -> new name/v tag changes family -> downgrade"
fx="$(_fp dependabot-auto-merge/v3.3.0 dependabot-auto-merge/v3.4.0)"
FILES="${fx}" policy 3.3.0 3.4.0 "${gate_pin}"
_expect_reason "diff: name/v pin goes up -> first-party-pin" first-party-pin \
  "${gate_pin} dependabot-auto-merge/v3.3.0 -> dependabot-auto-merge/v3.4.0"
fx="$(_fp dependabot-auto-merge/v3.4.0 dependabot-auto-merge/v3.3.0)"
FILES="${fx}" policy 3.3.0 3.4.0 "${gate_pin}"
_expect_downgrade "diff: name/v pin goes down while metadata says up -> downgrade" "first-party pin down"
fx="$(_fp dependabot-auto-merge-v3.2.0 dependabot-auto-merge/v3.3.0)"
FILES="${fx}" policy 3.2.0 3.3.0 "${gate_pin}"
_expect_downgrade "diff: old -> new tag scheme is another family -> downgrade"
fx="$(_fp dependabot-auto-merge/v3.3.0 dependabot-auto-merge/v3.4.0 v9 v1)"
FILES="${fx}" policy 3.3.0 3.4.0 "${gate_pin}"
_expect_reason "diff: a first-party pin is judged by its ref, not a trailing comment" first-party-pin
fx="$(_fp dependabot-auto-merge/v3.4.0 dependabot-auto-merge/v3.3.0 v1 v9)"
FILES="${fx}" policy 3.3.0 3.4.0 "${gate_pin}"
_expect_downgrade "diff: a rising comment cannot hide a first-party ref going down"
fx="$(_fp 5fda3b95a4ea91299a34e894583c3862153e4b97 6d4fd22b20465ccc0f7354476588e8df7c9ca0e0)"
FILES="${fx}" policy 3.3.0 3.4.0 "${gate_pin}"
_expect_reason "diff: first-party SHA pins have no direction -> cannot-evaluate" cannot-evaluate
fx="$(_fp dependabot-auto-merge/v3.3.0 dependabot-auto-merge/v3.3.0)"
FILES="${fx}" policy 3.3.0 3.4.0 "${gate_pin}"
_expect_reason "diff: first-party pin unchanged but rewritten -> cannot-evaluate" cannot-evaluate
fx="$(_files .github/workflows/x.yml $'@@ -1 +1,2 @@\n+    uses: '"${gate_pin}"$'@dependabot-auto-merge/v3.4.0')"
FILES="${fx}" policy 3.3.0 3.4.0 "${gate_pin}"
_expect_reason "diff: a first-party pin added with no removed pin -> cannot-evaluate" cannot-evaluate
fx="$(_files .github/workflows/a.yml $'@@ -1 +1 @@\n-    uses: '"${gate_pin}"$'@dependabot-auto-merge/v3.3.0' \
  .github/workflows/b.yml $'@@ -1 +1 @@\n+    uses: '"${gate_pin}"$'@dependabot-auto-merge/v3.4.0')"
FILES="${fx}" policy 3.3.0 3.4.0 "${gate_pin}"
_expect_reason "diff: first-party removal and addition in different files do not pair -> cannot-evaluate" cannot-evaluate
fx="$(_files .github/workflows/ci.yml $'@@ -1,2 +1,2 @@\n-    uses: '"${gate_pin}"$'@dependabot-auto-merge/v3.3.0\n+    uses: '"${gate_pin}"$'@dependabot-auto-merge/v3.4.0\n-    - uses: actions/checkout@v5\n+    - uses: actions/checkout@v4')"
FILES="${fx}" policy 3.3.0 3.4.0 "${gate_pin}"
_expect_downgrade "diff: first-party up plus a third-party down -> downgrade" "actions/checkout v5 -> v4"
up_patch=$'@@ -19,7 +19,7 @@\n         with:\n-      - uses: actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97 # v7.0.0\n+      - uses: actions/setup-python@6d4fd22b20465ccc0f7354476588e8df7c9ca0e0 # v7.1.0'
fx="$(_files .github/workflows/ci.yml "${up_patch}")"
FILES="${fx}" policy 7.0.0 7.1.0 actions/setup-python
_expect_policy "SHA pin with a rising version comment -> gate" gate
down_patch=$'@@ -1 +1 @@\n-      - uses: actions/setup-python@6d4fd22b20465ccc0f7354476588e8df7c9ca0e0 # v7.1.0\n+      - uses: actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97 # v7.0.0'
fx="$(_files .github/workflows/ci.yml "${down_patch}")"
FILES="${fx}" policy 7.0.0 7.1.0 actions/setup-python
_expect_downgrade "version comment goes down in the diff, metadata says up -> downgrade" "actions/setup-python v7.1.0 -> v7.0.0"
fx="$(_files .github/workflows/ci.yml $'@@ -1 +1 @@\n-    - uses: actions/checkout@v5\n+    - uses: actions/checkout@v4')"
FILES="${fx}" policy 4 5 actions/checkout
_expect_downgrade "tag ref goes down in the diff -> downgrade" "actions/checkout v5 -> v4"
two_pins=$'@@ -1,4 +1,4 @@\n-  - uses: actions/setup-node@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v7.0.0\n+  - uses: actions/setup-node@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # v7.1.0\n   x\n-  - uses: actions/setup-node@cccccccccccccccccccccccccccccccccccccccc # v6.0.0\n+  - uses: actions/setup-node@dddddddddddddddddddddddddddddddddddddddd # v6.1.0'
fx="$(_files .github/workflows/ci.yml "${two_pins}")"
FILES="${fx}" policy 7.0.0 7.1.0 actions/setup-node
_expect_policy "two pins of one action, both up, are paired in order -> gate" gate
fx="$(_files .github/workflows/ci.yml -)"
FILES="${fx}" policy 1.0.0 1.0.1 foo
if [[ "${decision}" == blocked && "${reason}" == cannot-evaluate ]]; then
  _ok "YAML file with no readable patch -> cannot-evaluate"
else
  _bad "yaml without patch: decision='${decision}' reason='${reason}' out=${out}"
fi
fx="$(_files package-lock.json - package.json $'@@ -1 +1 @@\n-1\n+2')"
FILES="${fx}" policy 1.0.0 1.0.1 foo
_expect_policy "large lockfile with no patch is not a workflow -> gate" gate
FILES_FAIL=1 policy 1.0.0 1.0.1 foo
if [[ "${decision}" == blocked && "${reason}" == cannot-evaluate ]]; then
  _ok "unreadable PR files -> cannot-evaluate"
else
  _bad "files API failure: decision='${decision}' reason='${reason}' out=${out}"
fi
FILES="not json" policy 1.0.0 1.0.1 foo
if [[ "${decision}" == blocked && "${reason}" == cannot-evaluate ]]; then
  _ok "PR files not JSON -> cannot-evaluate"
else
  _bad "files not json: decision='${decision}' reason='${reason}' out=${out}"
fi
fx="[]"
FILES="${fx}" policy 1.0.0 1.0.1 foo
if [[ "${decision}" == blocked && "${reason}" == cannot-evaluate ]]; then
  _ok "PR with no changed files -> cannot-evaluate"
else
  _bad "no files: decision='${decision}' reason='${reason}' out=${out}"
fi
policy 1.0.0 2.0.0 smartwatermelon/thing true smartwatermelon
_expect_policy "v2 inputs are accepted and reported as ignored" gate "ignored since v3"
policy 1.0.0 2.0.0 ""
_expect_policy "empty dependency-names -> blocked" blocked "empty dependency-names"
if [[ "${reason}" == "cannot-evaluate" ]]; then _ok "empty deps reason is cannot-evaluate"; else _bad "empty deps reason='${reason}'"; fi
policy 1.0.0 2.0.0 "  "
_expect_policy "whitespace-only dependency-names -> blocked" blocked
SANITY="" policy 5.9.3 5.10.0 typescript
_expect_policy "no sanity_checks -> blocked before any wait" blocked "names no sanity_checks"
if [[ "${reason}" == "no-sanity-check" ]]; then _ok "reason is no-sanity-check"; else _bad "reason='${reason}'"; fi
SANITY=" , " policy 5.9.3 5.10.0 typescript
_expect_policy "blank sanity_checks entries -> blocked" blocked "names no sanity_checks"

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
    REPO=acme/site BASE_REF=main SANITY_CHECKS="${SANITY-build}" GH_TOKEN="${TOKEN-checks-token}" \
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
if _called "pr checks https://github.com/acme/site/pull/7 --json name,workflow,bucket,link [token=checks-token]" \
  && _called "headRefOid [token=checks-token]" \
  && ! grep -qvF "[token=checks-token]" "${STUB_DIR}/calls.log"; then
  _ok "every gate read runs as the App token, so private repos can see checks"
else
  _bad "gate tokens: $(<"${STUB_DIR}/calls.log")"
fi

# 1b. no App token for the reads -> merge-failed before any wait, never a GITHUB_TOKEN read
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "build|pass"
TOKEN="" gate
_expect_gate "no App token for check reads -> merge-failed" blocked merge-failed "No App token to read checks"
if [[ ! -s "${STUB_DIR}/calls.log" ]]; then _ok "no gh call without the App token"; else _bad "calls: $(<"${STUB_DIR}/calls.log")"; fi

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
if _called "commits/main/status" && ! grep -F "[token=" "${STUB_DIR}/calls.log" | grep -qvF "[token=checks-token]"; then
  _ok "base-branch reads run as the App token"
else
  _bad "base-branch tokens: $(<"${STUB_DIR}/calls.log")"
fi

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

# 15. matrix job name matches its sanity entry
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "test (3.11)|pass" "test (3.12)|pass" "standards|pass"
SANITY="test" gate
_expect_gate "matrix 'test (3.12)' satisfies sanity 'test'" pass "" "All 3 other checks"

# 16. all green, but the named sanity check never ran -> no-sanity-check at the deadline
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "standards|pass"
SANITY="build, tests" WAIT=1 gate
_expect_gate "sanity checks missing -> no-sanity-check" blocked no-sanity-check "sanity checks never passed: build, tests"

# 17. sanity check skipped -> it never passed
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "build|skipping" "standards|pass"
WAIT=1 gate
_expect_gate "skipped sanity check -> no-sanity-check" blocked no-sanity-check "build"

# 18. sanity check registers late -> keeps polling, then passes
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "standards|pass"
_checks 3 self "standards|pass" "build|pass"
WAIT=5 gate
_expect_gate "late sanity check -> pass" pass "" "All 2 other checks"

# 19. a prefix that is not a matrix suffix does not match
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "build-docs|pass"
WAIT=1 gate
_expect_gate "'build-docs' does not satisfy 'build'" blocked no-sanity-check "build"

# 20. a multi-line sanity_checks (YAML block scalar) splits on newlines too
_fixture; echo "${sha}" >"${STUB_DIR}/head"
_checks 1 self "build|pass" "tests|pass"
SANITY=$'build\ntests\n' gate
_expect_gate "multi-line sanity_checks -> pass" pass "" "All 2 other checks"

# --- merge step --------------------------------------------------------
merge() {
  rc=0
  out="$(PATH="${here}/stub-dependabot:${PATH}" GITHUB_OUTPUT="${STUB_DIR}/out" \
    PR_URL=https://github.com/acme/site/pull/7 HEAD_SHA="${sha}" \
    GH_TOKEN=ambient APP_TOKEN="${APP-app-token}" \
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
if _called "--match-head-commit ${sha} https://github.com/acme/site/pull/7 [token=app-token]"; then
  _ok "merge runs as the App, so push workflows start on main"
else
  _bad "merge token: $(<"${STUB_DIR}/calls.log")"
fi
if _called "pr review --approve https://github.com/acme/site/pull/7 [token=ambient]"; then
  _ok "only the merge uses the App token"
else
  _bad "approve token: $(<"${STUB_DIR}/calls.log")"
fi

_fixture
APP="" merge
if [[ "${rc}" -eq 0 && "${reason}" == "merge-failed" ]] && ! _called "pr merge" \
  && grep -qF "No merge App token" <<<"${out}"; then
  _ok "no App token -> merge-failed, never a GITHUB_TOKEN merge"
else
  _bad "no App token: rc=${rc} reason='${reason}' calls=$(<"${STUB_DIR}/calls.log")"
fi

_fixture; : >"${STUB_DIR}/fail.pr-merge"
merge
if [[ "${rc}" -eq 0 && "${reason}" == "merge-failed" ]]; then _ok "merge failure -> merge-failed, never red"; else _bad "merge failure: rc=${rc} reason='${reason}'"; fi
if _called "pr edit"; then _bad "unexpected pr edit"; else _ok "no label edit when none are stale"; fi

# --- label step --------------------------------------------------------
label() { # label REASON
  rc=0
  out="$(PATH="${here}/stub-dependabot:${PATH}" GH_REPO=acme/site GH_TOKEN=ambient \
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
label no-sanity-check
if _called "--add-label dependabot-blocked,dependabot-blocked:no-sanity-check"; then
  _ok "no-sanity-check is a known reason"
else
  _bad "no-sanity-check label: $(<"${STUB_DIR}/calls.log")"
fi

_fixture
label 'bogus;reason'
if _called "--add-label dependabot-blocked,dependabot-blocked:cannot-evaluate"; then
  _ok "unknown reason -> cannot-evaluate"
else
  _bad "unknown reason: $(<"${STUB_DIR}/calls.log")"
fi

_fixture
label downgrade
if _called "--add-label dependabot-blocked,dependabot-blocked:downgrade"; then
  _ok "downgrade is a known reason"
else
  _bad "downgrade label: $(<"${STUB_DIR}/calls.log")"
fi

_fixture
label first-party-pin
if _called "--add-label dependabot-blocked,dependabot-blocked:first-party-pin"; then
  _ok "first-party-pin is a known reason"
else
  _bad "first-party-pin label: $(<"${STUB_DIR}/calls.log")"
fi

_fixture; : >"${STUB_DIR}/fail.pr-edit"; : >"${STUB_DIR}/fail.label-create"
label timeout
if [[ "${rc}" -eq 0 ]] && grep -qF "::warning::Could not label" <<<"${out}"; then
  _ok "label failures warn, never red"
else
  _bad "label failure: rc=${rc} out=${out}"
fi

# --- workflow wiring (v3.2) --------------------------------------------
_yq() { yq "$1" "${wf}"; }
steps_q='.jobs.auto-merge.steps'
idx() { _yq "${steps_q} | to_entries | map(select(.value.name == \"$1\")) | .[0].key"; }
i_policy="$(idx 'Decide if PR can be evaluated')"
i_read="$(idx 'Mint App token for check reads')"
i_gate="$(idx 'Wait for all checks')"
i_merge_tok="$(idx 'Mint merge App token')"
i_merge="$(idx 'Approve and merge')"
if [[ "${i_policy}" =~ ^[0-9]+$ && "${i_read}" =~ ^[0-9]+$ && "${i_gate}" =~ ^[0-9]+$ ]] \
  && ((i_policy < i_read && i_read < i_gate && i_gate < i_merge_tok && i_merge_tok + 1 == i_merge)); then
  _ok "downgrade checks, read token, wait, then a fresh merge token right before the merge"
else
  _bad "step order: policy=${i_policy} read=${i_read} gate=${i_gate} merge-token=${i_merge_tok} merge=${i_merge}"
fi
for v in i_policy i_read i_gate i_merge_tok i_merge; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || printf -v "${v}" '%s' 0
done
read_id="$(_yq "${steps_q}[${i_read}].id")"
merge_tok_id="$(_yq "${steps_q}[${i_merge_tok}].id")"
gate_token="$(_yq "${steps_q}[${i_gate}].env.GH_TOKEN")"
merge_token="$(_yq "${steps_q}[${i_merge}].env.APP_TOKEN")"
if [[ "${read_id}" != "${merge_tok_id}" ]] \
  && [[ "${gate_token}" == "\${{ steps.${read_id}.outputs.token }}" ]] \
  && [[ "${merge_token}" == "\${{ steps.${merge_tok_id}.outputs.token }}" ]]; then
  _ok "the wait reads checks with the read token; the merge uses the re-minted token"
else
  _bad "token wiring: read=${read_id} merge=${merge_tok_id} gate=${gate_token} merge=${merge_token}"
fi
read_with="$(_yq "${steps_q}[${i_read}].with | to_entries | map(.key + \"=\" + .value) | join(\" \")")"
if [[ " ${read_with} " == *" permission-checks=read "* \
  && " ${read_with} " == *" permission-statuses=read "* \
  && " ${read_with} " == *" permission-actions=read "* \
  && " ${read_with} " == *" repositories=\${{ github.event.repository.name }} "* ]]; then
  _ok "read token is scoped to this repository with checks, statuses and actions: read"
else
  _bad "read token permissions: ${read_with}"
fi
secret_steps="$(_yq "[${steps_q}[] | select(tostring | test(\"secrets\\.MERGE_APP\")) | .name] | join(\",\")")"
if [[ "${secret_steps}" == "Mint App token for check reads,Mint merge App token" ]]; then
  _ok "only the two token steps read the App secrets"
else
  _bad "steps reading App secrets: ${secret_steps}"
fi
settle="$(_yq "${steps_q}[${i_gate}].env.SETTLE_SECONDS")"
wait_s="$(_yq "${steps_q}[${i_gate}].env.WAIT_SECONDS")"
if [[ "${settle}" =~ ^[0-9]+$ && "${wait_s}" =~ ^[0-9]+$ ]] && ((wait_s <= 3600 - 300)) && ((settle < wait_s)); then
  _ok "the wait (${wait_s}s, settle included) ends at least 5 min before the 1-hour read token expires"
else
  _bad "wait ${wait_s}s settle ${settle}s outlives the 1-hour App token"
fi
gate_if="$(_yq "${steps_q}[${i_gate}].if")"
if [[ "${gate_if}" == *"steps.policy.outputs.decision == 'gate'"* ]]; then
  _ok "the wait runs only after both downgrade checks pass"
else
  _bad "gate if: ${gate_if}"
fi
policy_deps="$(_yq "${steps_q}[${i_policy}].env.DEPS_JSON")"
if [[ "${policy_deps}" == *"updated-dependencies-json"* ]]; then
  _ok "metadata check reads every dependency from updated-dependencies-json"
else
  _bad "policy DEPS_JSON not wired: ${policy_deps}"
fi

echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
