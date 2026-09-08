#!/usr/bin/env bash
# Known-bad validation for standards/check-node-floor.sh. Each fixture is a
# throwaway directory; the control case proves the checker can fail.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="${here}/../standards/check-node-floor.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
pass=0; fail=0
_ok() { echo "  ok   $1"; pass=$((pass + 1)); }
_bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

# Fixture 1: workflow pins node 20 -> must fail
mkdir -p "${tmp}/f1/.github/workflows"
cat >"${tmp}/f1/.github/workflows/ci.yml" <<'EOF'
jobs:
  build:
    steps:
      - uses: actions/setup-node@abc
        with:
          node-version: 20
EOF
if bash "${checker}" "${tmp}/f1" 22 >/dev/null 2>&1; then _bad "workflow node-version 20 accepted"; else _ok "workflow node-version 20 rejected"; fi

# Fixture 2: .nvmrc 18.20.4 -> must fail
mkdir -p "${tmp}/f2"; echo "18.20.4" >"${tmp}/f2/.nvmrc"
if bash "${checker}" "${tmp}/f2" 22 >/dev/null 2>&1; then _bad ".nvmrc 18 accepted"; else _ok ".nvmrc 18 rejected"; fi

# Fixture 3: package.json engines floor admits 14 -> must fail
mkdir -p "${tmp}/f3"; echo '{"engines":{"node":">=14.0.0"}}' >"${tmp}/f3/package.json"
if bash "${checker}" "${tmp}/f3" 22 >/dev/null 2>&1; then _bad "engines >=14 accepted"; else _ok "engines >=14 rejected"; fi

# Fixture 4: everything at or above the floor -> must pass
mkdir -p "${tmp}/f4/.github/workflows"
printf 'jobs:\n  b:\n    steps:\n      - with:\n          node-version: "24"\n' >"${tmp}/f4/.github/workflows/ci.yml"
echo "lts/krypton" >"${tmp}/f4/.nvmrc"
echo '{"engines":{"node":">=22"}}' >"${tmp}/f4/package.json"
if bash "${checker}" "${tmp}/f4" 22 >/dev/null 2>&1; then _ok "conformant repo passes"; else _bad "conformant repo rejected"; fi

# Fixture 5: no Node anywhere -> must pass
mkdir -p "${tmp}/f5"; echo "hi" >"${tmp}/f5/README.md"
if bash "${checker}" "${tmp}/f5" 22 >/dev/null 2>&1; then _ok "repo without Node passes"; else _bad "repo without Node rejected"; fi

# Fixture 6: node-version-file indirection to a bad .nvmrc -> must fail
mkdir -p "${tmp}/f6/.github/workflows"; echo "20.19.4" >"${tmp}/f6/.nvmrc"
printf 'jobs:\n  b:\n    steps:\n      - with:\n          node-version-file: .nvmrc\n' >"${tmp}/f6/.github/workflows/ci.yml"
if bash "${checker}" "${tmp}/f6" 22 >/dev/null 2>&1; then _bad "node-version-file -> 20 accepted"; else _ok "node-version-file -> 20 rejected"; fi

# Fixture 7: a real YAML inline comment (space before #) must not hide the pin
mkdir -p "${tmp}/f7/.github/workflows"
printf 'jobs:\n  b:\n    steps:\n      - with:\n          node-version: 20 # legacy\n' >"${tmp}/f7/.github/workflows/ci.yml"
if bash "${checker}" "${tmp}/f7" 22 >/dev/null 2>&1; then _bad "node-version 20 with trailing comment accepted"; else _ok "node-version 20 with trailing comment rejected"; fi

# Fixture 8: "20#c" is the YAML string "20#c", not version 20 (no space before
# the #, so YAML starts no comment). It must not be misread as a Node 20 pin.
mkdir -p "${tmp}/f8/.github/workflows"
printf 'jobs:\n  b:\n    steps:\n      - with:\n          node-version: 20#c\n' >"${tmp}/f8/.github/workflows/ci.yml"
if bash "${checker}" "${tmp}/f8" 22 >/dev/null 2>&1; then _ok "unparseable '20#c' not misread as Node 20"; else _bad "'20#c' misread as a Node 20 pin"; fi

# Fixture 9: package.json present but jq unavailable must fail loudly (exit 2),
# never skip the engines.node source in silence.
mkdir -p "${tmp}/f9/bin" "${tmp}/f9/repo"
echo '{"engines":{"node":">=14"}}' >"${tmp}/f9/repo/package.json"
for c in grep head sed printf bash cat tr; do
  p="$(command -v "${c}" || true)"
  [[ -n "${p}" ]] && ln -sf "${p}" "${tmp}/f9/bin/${c}"
done
if env PATH="${tmp}/f9/bin" bash "${checker}" "${tmp}/f9/repo" 22 >/dev/null 2>&1; then
  _bad "missing jq silently skipped engines.node"
else
  _ok "missing jq fails loudly instead of skipping engines.node"
fi

echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
