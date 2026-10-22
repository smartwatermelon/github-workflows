#!/usr/bin/env bash
# standards/markdownlint.json must equal dotfiles' canonical config (main).
# Unreadable copy: FAIL, never skip.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ours="${here}/../standards/markdownlint.json"
url="https://raw.githubusercontent.com/smartwatermelon/dotfiles/main/markdownlint-cli/.markdownlint.json"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
pass=0; fail=0
_ok() { echo "  ok   $1"; pass=$((pass + 1)); }
_bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

command -v jq >/dev/null || { echo "  FAIL jq not on PATH; cannot compare"; exit 1; }

theirs="${tmp}/dotfiles.json"
if [[ -n "${MARKDOWNLINT_DOTFILES_CONFIG:-}" ]]; then
  cp "${MARKDOWNLINT_DOTFILES_CONFIG}" "${theirs}" || { echo "  FAIL cannot read ${MARKDOWNLINT_DOTFILES_CONFIG}"; exit 1; }
elif ! curl -fsSL --max-time 30 -o "${theirs}" "${url}"; then
  echo "  FAIL cannot fetch ${url}; set MARKDOWNLINT_DOTFILES_CONFIG to a local copy"
  exit 1
fi

# _same a b: both parse, and jq -S renders them identically.
_same() {
  local a b
  a="$(jq -S . "$1" 2>/dev/null)" || return 2
  b="$(jq -S . "$2" 2>/dev/null)" || return 2
  [[ -n "${a}" && "${a}" == "${b}" ]]
}

# Known-bad control: a flipped rule must not compare equal.
jq '.MD013 = (.MD013 | not)' "${ours}" >"${tmp}/flipped.json"
if _same "${ours}" "${tmp}/flipped.json"; then _bad "known-bad: a flipped MD013 compared equal"; else _ok "known-bad: a flipped MD013 is caught"; fi

rc=0
_same "${ours}" "${theirs}" || rc=$?
if ((rc == 0)); then
  _ok "standards/markdownlint.json == dotfiles markdownlint-cli/.markdownlint.json"
elif ((rc == 2)); then
  _bad "could not parse one of the configs; that is not a match"
else
  _bad "standards/markdownlint.json has drifted from dotfiles (${MARKDOWNLINT_DOTFILES_CONFIG:-${url}})"
  diff -u <(jq -S . "${theirs}") <(jq -S . "${ours}") || true
fi

echo "markdownlint drift: ${pass} ok, ${fail} failed"
[[ "${fail}" -eq 0 ]]
