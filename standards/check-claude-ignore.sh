#!/usr/bin/env bash
# check-claude-ignore.sh <repo-dir>: warn-only (never fails); see dev-env#178.
set -euo pipefail

repo="${1:?usage: check-claude-ignore.sh <repo-dir>}"
probe=".claude/__standards_probe__"
ref="smartwatermelon/dev-env#178"
fix="Add '.claude/' to .gitignore (or '.claude/*' plus '!.claude/<path>' for shared files),"
fix+=" then 'git rm --cached' any tracked file listed. See ${ref}."

# Blank global excludes. .git/info/exclude still applies.
_git() { git -C "${repo}" -c core.excludesFile=/dev/null "$@"; }

# Encode %, CR, LF for annotations.
_esc() {
  local s="$1"
  s="${s//'%'/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "${s}"
}

if ! git -C "${repo}" rev-parse --git-dir >/dev/null 2>&1; then
  echo "::error::${repo} is not a git repository"
  exit 2
fi

warned=0

# check-ignore: 0 ignored, 1 not, else error.
rc=0
_git check-ignore -q --no-index -- "${probe}" || rc=$?
if ((rc == 1)); then
  echo "::warning title=claude-ignore::$(_esc ".claude/ is not ignored by the committed .gitignore. ${fix}")"
  warned=1
elif ((rc != 0)); then
  echo "::warning title=claude-ignore::git check-ignore failed (exit ${rc}); not checked"
  exit 0
fi

# Tracked files matching an ignore rule.
lsrc=0
tracked="$(_git ls-files -ci --exclude-standard -- .claude/)" || lsrc=$?
if ((lsrc != 0)); then
  echo "::warning title=claude-ignore::git ls-files failed (exit ${lsrc}); tracked files not checked"
  exit 0
fi
if [[ -n "${tracked}" ]]; then
  echo "::warning title=claude-ignore::$(_esc "Tracked file(s) under .claude/ match an ignore rule:"$'\n'"${tracked}"$'\n'"${fix}")"
  warned=1
fi

if ((warned == 0)); then echo ".claude/ ignore policy: OK"; fi
exit 0
