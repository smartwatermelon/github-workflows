#!/usr/bin/env bash
# Known-bad validation for standards/check-dependabot-cooldown.sh.
# The failing fixtures prove the checker can fail.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="${here}/../standards/check-dependabot-cooldown.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
pass=0; fail=0
_ok() { echo "  ok   $1"; pass=$((pass + 1)); }
_bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

# fixture NAME BODY: a repo whose .github/dependabot.yml is BODY; sets fx.
fx=""
fixture() {
  mkdir -p "${tmp}/$1/.github"
  printf '%s\n' "$2" >"${tmp}/$1/.github/dependabot.yml"
  fx="${tmp}/$1"
}
# expect LABEL WANT_RC REPO [PATTERN]: run the checker at a 3-day floor.
expect() {
  local label="$1" want="$2" repo="$3" pattern="${4:-}" out rc=0
  out="$(bash "${checker}" "${repo}" 3 2>&1)" || rc=$?
  if [[ "${rc}" -eq "${want}" && ( -z "${pattern}" || "${out}" == *"${pattern}"* ) ]]; then
    _ok "${label}"
  else
    _bad "${label}: rc=${rc} (want ${want}) out=${out}"
  fi
}

head_npm=$'version: 2\nupdates:\n  - package-ecosystem: npm\n    directory: /\n    schedule:\n      interval: weekly'

fixture ok3 "${head_npm}"$'\n    cooldown:\n      default-days: 3'
expect "3 days passes" 0 "${fx}"
fixture ok7 "${head_npm}"$'\n    cooldown:\n      default-days: 7'
expect "7 days passes" 0 "${fx}"
fixture none "${head_npm}"
expect "no cooldown fails" 1 "${fx}" "no cooldown"
fixture two "${head_npm}"$'\n    cooldown:\n      default-days: 2'
expect "2 days fails" 1 "${fx}" "below the 3-day floor"
fixture major "${head_npm}"$'\n    cooldown:\n      default-days: 3\n      semver-major-days: 1'
expect "a semver key below the floor fails" 1 "${fx}" "semver-major-days is 1"
fixture nodefault "${head_npm}"$'\n    cooldown:\n      semver-major-days: 5'
expect "cooldown without default-days fails" 1 "${fx}" "no default-days"
two_entries="${head_npm}"$'\n    cooldown:\n      default-days: 3\n  - package-ecosystem: github-actions\n    directory: /\n    schedule:\n      interval: weekly'
fixture second "${two_entries}"
expect "second entry with no cooldown fails" 1 "${fx}" "updates[1] (github-actions /)"
fixture empty 'version: 2'
expect "no updates entries fails" 1 "${fx}" "no updates entries"
fixture broken $'updates: [\n  - {'
expect "unparseable YAML is an error" 2 "${fx}" "could not parse"
mkdir -p "${tmp}/nofile"
expect "no dependabot.yml passes" 0 "${tmp}/nofile" "no .github/dependabot.yml"
mkdir -p "${tmp}/yaml/.github"
printf '%s\n' "${head_npm}" >"${tmp}/yaml/.github/dependabot.yaml"
expect ".yaml extension is read too" 1 "${tmp}/yaml" "dependabot.yaml"
rc=0; bash "${checker}" "${tmp}/ok3" x >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 2 ]]; then _ok "floor 'x' is rejected"; else _bad "floor 'x': rc=${rc}"; fi

echo "${pass} passed, ${fail} failed"
((fail == 0))
