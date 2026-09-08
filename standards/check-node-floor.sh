#!/usr/bin/env bash
# check-node-floor.sh <repo-dir> <floor-major>
#
# Fails (exit 1) if any Node.js version pin in the repo names a major below
# <floor-major>. Sources scanned:
#   - .github/workflows/*.yml|*.yaml : `node-version:` literals and
#     `node-version-file:` indirections
#   - .nvmrc, .node-version           : bare versions ("20", "20.19.4", "v18")
#   - package.json                    : engines.node lower bound (">=14.0.0")
# Named aliases (lts/*, node, latest, current) are accepted: they float and
# are never below the floor. Expressions (${{ ... }}) are skipped with a
# notice because they cannot be resolved statically.
set -euo pipefail

repo="${1:?usage: check-node-floor.sh <repo-dir> <floor-major>}"
floor="${2:?usage: check-node-floor.sh <repo-dir> <floor-major>}"
[[ "${floor}" =~ ^[0-9]+$ ]] || { echo "::error::floor must be an integer major, got '${floor}'"; exit 2; }

errors=0

# _major <version-string> -> prints the major, or nothing for aliases/unparseable.
# Always returns 0: "no major here" is a valid answer (lts/*, node, latest),
# not an error, and a nonzero status would be masked inside "$(_major ...)".
_major() {
  local v="${1}"
  v="${v#v}"; v="${v%%.*}"
  if [[ "${v}" =~ ^[0-9]+$ ]]; then printf '%s' "${v}"; fi
  return 0
}

# _check <major-or-empty> <where>
_check() {
  local major="${1}" where="${2}"
  [[ -z "${major}" ]] && return 0
  if (( major < floor )); then
    echo "::error::${where}: Node ${major} is below the supported floor (${floor})"
    errors=$((errors + 1))
  fi
}

# _version_from_file <path> -> first non-empty, non-comment line, trimmed
_version_from_file() {
  grep -vE '^\s*(#|$)' "${1}" | head -1 | tr -d '[:space:]'
}

for f in "${repo}/.nvmrc" "${repo}/.node-version"; do
  [[ -f "${f}" ]] || continue
  raw="$(_version_from_file "${f}")"
  major="$(_major "${raw}")"
  _check "${major}" "${f#"${repo}"/}: ${raw}"
done

if [[ -f "${repo}/package.json" ]] && command -v jq >/dev/null; then
  eng="$(jq -r '.engines.node // empty' "${repo}/package.json" 2>/dev/null || true)"
  if [[ -n "${eng}" ]]; then
    # Lower bound: first numeric token after an optional >= / ^ / ~ prefix.
    low="$(printf '%s' "${eng}" | grep -oE '[0-9]+(\.[0-9]+)*' | head -1 || true)"
    major="$(_major "${low}")"
    _check "${major}" "package.json engines.node: ${eng}"
  fi
fi

# Literal opening delimiter of a GitHub Actions expression, built by
# concatenation so no single-quoted "${{" appears in the source (SC2016).
expr_open='$'"{{"

shopt -s nullglob
for wf in "${repo}"/.github/workflows/*.yml "${repo}"/.github/workflows/*.yaml; do
  rel="${wf#"${repo}"/}"
  while IFS= read -r line; do
    val="$(printf '%s' "${line}" | sed -E 's/.*node-version:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^["'"'"']//; s/["'"'"']$//')"
    if [[ "${val}" == *"${expr_open}"* ]]; then
      echo "::notice::${rel}: node-version is an expression (${val}); not checked"
      continue
    fi
    major="$(_major "${val}")"
    _check "${major}" "${rel}: node-version: ${val}"
  done < <(grep -E '^\s*node-version:' "${wf}" || true)
  while IFS= read -r line; do
    vf="$(printf '%s' "${line}" | sed -E 's/.*node-version-file:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^["'"'"']//; s/["'"'"']$//')"
    if [[ -f "${repo}/${vf}" ]]; then
      raw="$(_version_from_file "${repo}/${vf}")"
      major="$(_major "${raw}")"
      _check "${major}" "${rel}: node-version-file ${vf} -> ${raw}"
    fi
  done < <(grep -E '^\s*node-version-file:' "${wf}" || true)
done

if (( errors > 0 )); then
  echo "::error::${errors} Node pin(s) below floor ${floor}. Node 20 reached EOL 2026-04-30."
  exit 1
fi
echo "Node floor ${floor}: OK"
