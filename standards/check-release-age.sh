#!/usr/bin/env bash
# check-release-age.sh <repo-dir> <floor-days>
# Exit 1 if a set npm, pnpm or bun release age is under the floor. Unset passes.
set -euo pipefail

repo="${1:?usage: check-release-age.sh <repo-dir> <floor-days>}"
floor="${2:?usage: check-release-age.sh <repo-dir> <floor-days>}"
[[ "${floor}" =~ ^[0-9]+$ ]] || { echo "::error::floor must be a whole number of days, got '${floor}'"; exit 2; }

errors=0
checked=0

# check FILE KEY UNIT PER-DAY: compare the last KEY value (the one that wins)
# to the floor in UNIT.
check() {
  local file="$1" key="$2" unit="$3" per_day="$4" where line val want
  where="${file#"${repo}"/}"
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*[:=]" "${file}" | tail -n 1)" || return 0
  val="${line#*[:=]}"
  val="${val%%#*}"
  val="$(tr -d " \t\"'\r" <<<"${val}")"
  want=$((floor * per_day))
  checked=$((checked + 1))
  if [[ ! "${val}" =~ ^[0-9]+$ ]]; then
    echo "::error::${where}: ${key} is '${val}', not a whole number of ${unit}"
    errors=$((errors + 1))
  elif ((val < want)); then
    echo "::error::${where}: ${key} is ${val} ${unit}, below the ${floor}-day floor (${want} ${unit})"
    errors=$((errors + 1))
  fi
}

while IFS= read -r -d '' f; do
  case "${f##*/}" in
    .npmrc) check "${f}" 'min-release-age' days 1 ;;
    pnpm-workspace.yaml) check "${f}" 'minimumReleaseAge' minutes 1440 ;;
    bunfig.toml) check "${f}" 'minimumReleaseAge' seconds 86400 ;;
    *) ;;
  esac
done < <(
  # Tracked files only in a git checkout, so local worktrees are not read.
  if git -C "${repo}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "${repo}" ls-files -z -- '.npmrc' '*/.npmrc' 'pnpm-workspace.yaml' \
      '*/pnpm-workspace.yaml' 'bunfig.toml' '*/bunfig.toml' |
      while IFS= read -r -d '' p; do printf '%s\0' "${repo}/${p}"; done
  else
    find "${repo}" \( -name node_modules -o -name .git \) -prune -o -type f \
      \( -name .npmrc -o -name pnpm-workspace.yaml -o -name bunfig.toml \) -print0
  fi
)

if ((errors > 0)); then exit 1; fi
if ((checked == 0)); then
  echo "::notice::no npm, pnpm or bun release age is set"
else
  echo "release age: ${checked} setting(s), each at least ${floor} days"
fi
