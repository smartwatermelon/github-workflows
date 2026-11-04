#!/usr/bin/env bash
# Known-bad validation for standards/check-release-age.sh.
# The failing fixtures prove the checker can fail.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="${here}/../standards/check-release-age.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
pass=0; fail=0
_ok() { echo "  ok   $1"; pass=$((pass + 1)); }
_bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

# fixture NAME FILE BODY: a repo holding FILE (may include a subdir); sets fx.
fx=""
fixture() {
  mkdir -p "$(dirname "${tmp}/$1/$2")"
  printf '%s\n' "$3" >"${tmp}/$1/$2"
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

mkdir -p "${tmp}/empty"
expect "no settings passes" 0 "${tmp}/empty" "no npm, pnpm or bun release age"
fixture npm-other .npmrc 'save-exact=true'
expect "an .npmrc with no release age passes" 0 "${fx}"

fixture npm3 .npmrc 'min-release-age=3'
expect "npm 3 days passes" 0 "${fx}"
fixture npm2 .npmrc 'min-release-age = 2'
expect "npm 2 days fails" 1 "${fx}" "below the 3-day floor"
fixture npmlast .npmrc $'min-release-age=7\nmin-release-age=1'
expect "the last npm value wins" 1 "${fx}" "is 1 days"

fixture pnpm3 pnpm-workspace.yaml $'packages:\n  - a\nminimumReleaseAge: 4320'
expect "pnpm 4320 minutes passes" 0 "${fx}"
fixture pnpm1 pnpm-workspace.yaml 'minimumReleaseAge: 1440 # one day'
expect "pnpm 1440 minutes fails" 1 "${fx}" "below the 3-day floor (4320 minutes)"
fixture pnpmq pnpm-workspace.yaml "minimumReleaseAge: '10080'"
expect "a quoted pnpm value is read" 0 "${fx}"

fixture bun3 bunfig.toml $'[install]\nminimumReleaseAge = 259200'
expect "bun 259200 seconds passes" 0 "${fx}"
fixture bun1 bunfig.toml $'[install]\nminimumReleaseAge = 86400'
expect "bun 86400 seconds fails" 1 "${fx}" "seconds"

fixture nested apps/web/.npmrc 'min-release-age=1'
expect "a nested .npmrc is checked" 1 "${fx}" "apps/web/.npmrc"
fixture nm node_modules/x/.npmrc 'min-release-age=0'
expect "node_modules is skipped" 0 "${fx}"
fixture junk .npmrc 'min-release-age=soon'
expect "a non-number fails" 1 "${fx}" "not a whole number"

# In a git checkout only tracked files count: an untracked copy is ignored.
fixture git .npmrc 'min-release-age=3'
fixture git .claude/worktrees/x/.npmrc 'min-release-age=1'
git -C "${fx}" init -q && git -C "${fx}" add .npmrc
expect "an untracked .npmrc is ignored in a git checkout" 0 "${fx}" "1 setting(s)"
git -C "${fx}" add -f .claude/worktrees/x/.npmrc
expect "a tracked nested .npmrc is checked" 1 "${fx}" ".claude/worktrees/x/.npmrc"

# A failing git ls-files must not read as "nothing set".
mkdir -p "${tmp}/bin"
# Stub git: rev-parse succeeds, every other command (ls-files) fails.
cat >"${tmp}/bin/git" <<'STUB'
#!/bin/sh
[ "$3" = rev-parse ] && exit 0
exit 128
STUB
chmod +x "${tmp}/bin/git"
rc=0; out="$(PATH="${tmp}/bin:${PATH}" bash "${checker}" "${fx}" 3 2>&1)" || rc=$?
if [[ "${rc}" -ne 0 && "${out}" != *"no npm, pnpm or bun"* ]]; then
  _ok "a failing git ls-files fails the check"
else
  _bad "a failing git ls-files: rc=${rc} out=${out}"
fi

out="$(bash "${checker}" "${tmp}/empty" x 2>&1)" && rc=0 || rc=$?
if [[ "${rc}" -eq 2 ]]; then _ok "floor 'x' is rejected"; else _bad "floor 'x': rc=${rc} out=${out}"; fi

echo "${pass} passed, ${fail} failed"
((fail == 0))
