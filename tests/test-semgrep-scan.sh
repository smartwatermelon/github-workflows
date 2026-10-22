#!/usr/bin/env bash
# Hermetic tests for semgrep/run-semgrep.sh, plus checks that the
# workflow, caller stub, and README.md agree.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../semgrep/run-semgrep.sh"
workflow="${here}/../.github/workflows/semgrep-scan.yml"
stub_file="${here}/../semgrep/caller-stub.yml"
readme="${here}/../README.md"
stub="${here}/stub-semgrep/semgrep"
unset BASH_ENV
# Isolate from the developer's global git config (hooks, signing, identity).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
pass=0; fail=0
tmp_dirs=()
trap 'rm -rf "${tmp_dirs[@]}"' EXIT
_ok() { echo "  ok   $1"; pass=$((pass + 1)); }
_bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

# A throwaway caller repo with two commits; base is the first.
repo="$(mktemp -d)"; tmp_dirs+=("${repo}")
git -C "${repo}" init -q
git -C "${repo}" commit -q --allow-empty -m one
base="$(git -C "${repo}" rev-parse HEAD)"
git -C "${repo}" commit -q --allow-empty -m two
absent="0123456789abcdef0123456789abcdef01234567"

# run [VAR=value ...]: sets rc, err, argv (the stub's argv, one per line).
run() {
  STUB_DIR="$(mktemp -d)"; tmp_dirs+=("${STUB_DIR}")
  rc=0
  (cd "${repo}" && env -u SEMGREP_APP_TOKEN STUB_DIR="${STUB_DIR}" SEMGREP_BIN="${stub}" \
    RULESETS="p/default p/python" "$@" bash "${script}") 2>"${STUB_DIR}/err" || rc=$?
  err="$(cat "${STUB_DIR}/err")"
  argv="$(cat "${STUB_DIR}/argv.log" 2>/dev/null || true)"
}
called() { [[ -f "${STUB_DIR}/argv.log" ]]; }
nl=$'\n'

# 1. pull_request, no token: diff-aware scan against the base
run EVENT_NAME=pull_request BASE_SHA="${base}"
want="scan${nl}--error${nl}--metrics=off${nl}--config${nl}p/default${nl}--config${nl}p/python${nl}--baseline-commit${nl}${base}"
if [[ "${rc}" -eq 0 && "${argv}" == "${want}" ]]; then _ok "pull_request runs scan --error with --baseline-commit"; else _bad "pull_request: rc=${rc} argv=${argv} err=${err}"; fi

# 2. push and workflow_dispatch: full scan, no baseline
for ev in push workflow_dispatch; do
  run EVENT_NAME="${ev}" BASE_SHA="${base}"
  want="scan${nl}--error${nl}--metrics=off${nl}--config${nl}p/default${nl}--config${nl}p/python"
  if [[ "${rc}" -eq 0 && "${argv}" == "${want}" ]]; then _ok "${ev} runs a full scan"; else _bad "${ev}: rc=${rc} argv=${argv} err=${err}"; fi
done

# 3. newline-separated rulesets split the same as spaces
run EVENT_NAME=push RULESETS=$'p/default\n  p/ruby\n'
want="scan${nl}--error${nl}--metrics=off${nl}--config${nl}p/default${nl}--config${nl}p/ruby"
if [[ "${rc}" -eq 0 && "${argv}" == "${want}" ]]; then _ok "newline-separated rulesets"; else _bad "newline rulesets: rc=${rc} argv=${argv}"; fi

# 4. token set: semgrep ci, no --config, token only in the environment
run EVENT_NAME=pull_request BASE_SHA="${base}" SEMGREP_APP_TOKEN=tok-123
token="$(cat "${STUB_DIR}/token.log")"
if [[ "${rc}" -eq 0 && "${argv}" == "ci" && "${token}" == "tok-123" ]] &&
  grep -q 'platform policies replace' <<<"${err}"; then
  _ok "token runs semgrep ci with the token in env, not argv"
else
  _bad "token: rc=${rc} argv=${argv} err=${err}"
fi

# 5. empty token: falls back to scan mode
run EVENT_NAME=push SEMGREP_APP_TOKEN=
if [[ "${rc}" -eq 0 && "${argv}" == scan* ]]; then _ok "empty token falls back to scan"; else _bad "empty token: rc=${rc} argv=${argv}"; fi

# 6. findings: Semgrep's exit code passes through
run EVENT_NAME=pull_request BASE_SHA="${base}" STUB_RC=1
if [[ "${rc}" -eq 1 ]]; then _ok "semgrep exit 1 (findings) propagates"; else _bad "findings: rc=${rc}"; fi

# 7. refusals: exit 2 and semgrep never runs
refuse() { # refuse LABEL PATTERN VAR=value ...
  local label="$1" pattern="$2"; shift 2
  run "$@"
  if [[ "${rc}" -eq 2 ]] && ! called && grep -q -- "${pattern}" <<<"${err}"; then
    _ok "${label}"
  else
    _bad "${label}: rc=${rc} argv=${argv} err=${err}"
  fi
}
refuse "pull_request without BASE_SHA exits 2" "valid BASE_SHA" EVENT_NAME=pull_request
refuse "malformed BASE_SHA exits 2" "valid BASE_SHA" EVENT_NAME=pull_request BASE_SHA=main
refuse "base not in history exits 2 and names fetch-depth" "fetch-depth: 0" EVENT_NAME=pull_request BASE_SHA="${absent}"
refuse "pull_request_target exits 2" "not 'pull_request_target'" EVENT_NAME=pull_request_target
refuse "empty RULESETS exits 2" "RULESETS is empty" EVENT_NAME=push RULESETS=" "
refuse "ruleset starting with - exits 2" "not a valid" EVENT_NAME=push RULESETS="p/default --dangerous"
refuse "missing semgrep exits 2" "semgrep not found" EVENT_NAME=push SEMGREP_BIN=/nonexistent/semgrep

# 8. the rulesets default agrees across the workflow, the stub, and README
wf_default="$(grep -A6 '^      rulesets:' "${workflow}" | sed -n 's/^ *default: *//p')"
stub_default="$(sed -n 's/^ *#   rulesets: \(.*\)  # the default$/\1/p' "${stub_file}")"
if [[ "${wf_default}" == "p/default p/javascript p/typescript p/python p/ruby" &&
  "${stub_default}" == "${wf_default}" ]] && grep -qF "| \`rulesets\` | string | \`${wf_default}\` |" "${readme}"; then
  _ok "rulesets default matches in workflow, caller stub, and README"
else
  _bad "rulesets drift: workflow='${wf_default}' stub='${stub_default}'"
fi

# 9. the names the daily digest keys on stay stable
if grep -q '^  semgrep-scan:$' "${stub_file}" &&
  grep -qF 'uses: smartwatermelon/github-workflows/.github/workflows/semgrep-scan.yml@semgrep-scan-v1' "${stub_file}" &&
  [[ -f "${workflow}" ]]; then
  _ok "caller job name and uses: ref are the stable names"
else
  _bad "caller stub names changed"
fi

# 10. the README setup example has the stub's triggers
stub_on="$(awk '/^on:$/{f=1} /^permissions:$/{f=0} f && !/^ *#/' "${stub_file}")"
readme_on="$(awk '/^## `semgrep-scan.yml`$/{m=1} m && /^### Setup$/{s=1}
  s && /^```yaml$/{y=1; next} y && /^```$/{exit}
  y && /^on:$/{f=1} y && /^permissions:$/{f=0} f && !/^ *#/' "${readme}")"
if [[ -n "${stub_on}" && "${stub_on}" == *"push:"* && "${stub_on}" == "${readme_on}" ]]; then
  _ok "README setup example has the caller stub's triggers"
else
  _bad "trigger drift: stub='${stub_on}' README='${readme_on}'"
fi

echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
