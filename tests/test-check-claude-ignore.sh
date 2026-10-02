#!/usr/bin/env bash
# Validation for standards/check-claude-ignore.sh on throwaway git repos.
# It only warns, so cases assert on output and exit 0.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="${here}/../standards/check-claude-ignore.sh"
# Isolate from the developer's global git config (hooks, excludes).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
pass=0; fail=0
_ok() { echo "  ok   $1"; pass=$((pass + 1)); }
_bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

# _repo NAME GITIGNORE-CONTENT [TRACKED-FILE...]: build a fixture repo.
_repo() {
  local name="$1" ign="$2" d f
  shift 2
  d="${tmp}/${name}"
  git init -q "${d}"
  if [[ -n "${ign}" ]]; then printf '%b' "${ign}" >"${d}/.gitignore"; fi
  mkdir -p "${d}/.claude"
  for f in "$@"; do echo x >"${d}/${f}"; done
  git -C "${d}" add -f -A
}

# _run NAME: run the checker; sets out and requires exit 0.
_run() {
  out="$("${checker}" "${tmp}/$1" 2>&1)" || { _bad "$1: exit status nonzero"; return 1; }
}
_warns() { grep -q '^::warning title=claude-ignore::' <<<"${out}"; }

_repo nogi ""
_run nogi && { if _warns; then _ok "no .gitignore warns"; else _bad "no .gitignore did not warn"; fi; }

_repo clean '.claude/\n'
_run clean && { if _warns; then _bad "'.claude/' ignored warned"; else _ok "'.claude/' ignored is clean"; fi; }

_repo shared '.claude/*\n!.claude/pre-launch.sh\n' .claude/pre-launch.sh
_run shared && { if _warns; then _bad "negated shared file warned"; else _ok "'.claude/*' + negation + tracked shared file is clean"; fi; }

_repo tracked '.claude/\n' .claude/README.md
_run tracked && { if _warns && grep -q '\.claude/README\.md' <<<"${out}"; then _ok "tracked file under ignored .claude/ warns and is named"; else _bad "tracked file case missing warning or name"; fi; }

_repo nonegate '.claude/*\n' .claude/pre-launch.sh
_run nonegate && { if _warns && grep -q '\.claude/pre-launch\.sh' <<<"${out}"; then _ok "'.claude/*' without negation warns and names file"; else _bad "no-negation case missing warning or name"; fi; }

# A global excludes file must not mask a missing rule.
_repo masked ""
printf '.claude/\n' >"${tmp}/global-ignore"
printf '[core]\n\texcludesFile = %s\n' "${tmp}/global-ignore" >"${tmp}/gitconfig"
out="$(GIT_CONFIG_GLOBAL="${tmp}/gitconfig" "${checker}" "${tmp}/masked" 2>&1)"
if _warns; then _ok "global excludes does not mask a missing rule"; else _bad "global excludes masked the check"; fi

echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
