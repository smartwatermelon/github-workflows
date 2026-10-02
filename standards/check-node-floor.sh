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
# are never below the floor. `${{ matrix.<key> }}` is resolved from the
# job's literal strategy.matrix; other expressions get a notice only.
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

if [[ -f "${repo}/package.json" ]] && ! command -v jq >/dev/null; then
  # Never skip a documented source silently: without jq an engines.node pin
  # below the floor would pass unnoticed, which is worse than a hard failure.
  echo "::error::package.json is present but jq is not installed; engines.node cannot be checked"
  exit 2
fi

if [[ -f "${repo}/package.json" ]]; then
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

# _scan_workflow <file>: one tab-separated record per node-version line,
# kind L (literal), R (resolved matrix value) or U (unresolvable).
_scan_workflow() {
  awk -v eo="${expr_open}" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    # Same cleanup as the literal reader: drop a " #" comment, one quote pair.
    function clean(s) {
      if (match(s, /[ \t]+#/)) s = substr(s, 1, RSTART - 1)
      s = trim(s)
      sub(/^["\047]/, "", s); sub(/["\047]$/, "", s)
      return s
    }
    function add(k, v,   parts, i, m) {
      if (pass != 1) return
      v = clean(v)
      if (v ~ /^\[/) {
        sub(/^\[/, "", v); sub(/\][ \t]*$/, "", v)
        m = split(v, parts, ",")
        for (i = 1; i <= m; i++) { parts[i] = clean(parts[i]); if (parts[i] != "") add(k, parts[i]) }
        return
      }
      n[job, k]++; val[job, k, n[job, k]] = v
    }
    FNR == 1 { pass++; in_jobs = 0; job = ""; job_ind = -1; mat_ind = -1 }
    /^[ \t]*(#|$)/ { next }
    {
      match($0, /^ */); ind = RLENGTH; t = substr($0, ind + 1)
      if (ind == 0) { in_jobs = (t ~ /^jobs:[ \t]*$/); job = ""; job_ind = -1; mat_ind = -1; next }
      if (in_jobs && job_ind < 0) job_ind = ind
      if (in_jobs && ind == job_ind && t ~ /^[^-][^:]*:/) { job = t; sub(/:.*/, "", job); mat_ind = -1; next }
      if (mat_ind >= 0 && ind <= mat_ind) mat_ind = -1
      if (mat_ind < 0 && t ~ /^matrix:/) {
        rest = clean(substr(t, 8))
        if (rest == "") { mat_ind = ind; child = -1; mode = "" } else if (pass == 1) mx[job] = 1
        next
      }
      if (mat_ind >= 0) {
        if (child < 0) child = ind
        if (ind == child && t ~ /^[A-Za-z0-9_-]+:/) {
          k = t; sub(/:.*/, "", k); rest = clean(substr(t, length(k) + 2))
          if (k == "include") { mode = "inc"; if (rest != "" && pass == 1) mxi[job] = 1 }
          else if (k == "exclude") mode = "exc"
          else { mode = "list"; mk = k; if (rest != "") add(k, rest) }
        } else if (ind > child || t ~ /^-[ \t]/) {
          # A sequence item may sit at the same indent as its key (indentless).
          if (mode == "list" && t ~ /^-[ \t]/) add(mk, substr(t, 3))
          else if (mode == "inc") {
            s = t; sub(/^-[ \t]+/, "", s)
            if (s ~ /^[A-Za-z0-9_-]+:/) { k = s; sub(/:.*/, "", k); add(k, substr(s, length(k) + 2)) }
          }
        }
        next
      }
      if (pass != 2 || t !~ /^node-version:/) next
      v = clean(substr(t, 14))
      inner = ""
      if (index(v, eo) == 1 && v ~ /[}][}]$/) { inner = substr(v, length(eo) + 1); sub(/[}][}]$/, "", inner); gsub(/[ \t]/, "", inner) }
      if (inner !~ /^matrix\.[A-Za-z0-9_-]+$/) { print "L\t" v; next }
      k = substr(inner, 8)
      if (mx[job]) { print "U\t" v "\tthe matrix itself is an expression"; next }
      if (n[job, k] == 0) { print "U\t" v "\tno literal matrix values for " k " in job " job; next }
      for (i = 1; i <= n[job, k]; i++) print "R\t" v "\t" val[job, k, i]
      if (mxi[job]) print "U\t" v "\tmatrix include is an expression"
    }
  ' "${1}" "${1}"
}

shopt -s nullglob
for wf in "${repo}"/.github/workflows/*.yml "${repo}"/.github/workflows/*.yaml; do
  rel="${wf#"${repo}"/}"
  # Capture first: a failed scan must stop the check, not read as "no pins".
  recs="$(_scan_workflow "${wf}")" || { echo "::error::${rel}: workflow scan failed"; exit 2; }
  while IFS=$'\t' read -r kind val mval; do
    [[ -z "${kind}" ]] && continue
    case "${kind}" in
      U)
        echo "::notice::${rel}: node-version is an expression (${val}); not checked (${mval})"
        continue ;;
      R)
        if [[ "${mval}" == *"${expr_open}"* ]]; then
          echo "::notice::${rel}: node-version ${val} takes an expression value (${mval}); not checked"
          continue
        fi
        major="$(_major "${mval}")"
        if [[ -z "${major}" && ! "${mval}" =~ ^(lts/.*|node|latest|current|\*)$ ]]; then
          echo "::notice::${rel}: node-version ${val} value '${mval}' is not a recognisable version or alias; not checked"
        fi
        _check "${major}" "${rel}: node-version: ${val} -> ${mval}"
        continue ;;
    esac
    if [[ "${val}" == *"${expr_open}"* ]]; then
      echo "::notice::${rel}: node-version is an expression (${val}); not checked"
      continue
    fi
    major="$(_major "${val}")"
    # A value that is neither a number nor a known floating alias is not
    # something this checker can vouch for; say so rather than pass silently.
    if [[ -z "${major}" && ! "${val}" =~ ^(lts/.*|node|latest|current|\*)$ ]]; then
      echo "::notice::${rel}: node-version '${val}' is not a recognisable version or alias; not checked"
    fi
    _check "${major}" "${rel}: node-version: ${val}"
  done <<<"${recs}"
  while IFS= read -r line; do
    vf="$(printf '%s' "${line}" | sed -E 's/.*node-version-file:[[:space:]]*//; s/[[:space:]]+#.*$//; s/^["'"'"']//; s/["'"'"']$//')"
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
