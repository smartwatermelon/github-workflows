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

# Matrix fixtures. _wf <name> writes stdin to <name>/.github/workflows/ci.yml;
# _expect <fail|pass> <name> <label> runs the checker against it.
_wf() { mkdir -p "${tmp}/$1/.github/workflows"; cat >"${tmp}/$1/.github/workflows/ci.yml"; }
_expect() {
  local want="$1" dir="$2" label="$3" got=pass
  bash "${checker}" "${tmp}/${dir}" 22 >/dev/null 2>&1 || got=fail
  if [[ "${got}" == "${want}" ]]; then _ok "${label}"; else _bad "${label} (got ${got}, want ${want})"; fi
}

# Fixture 10: tensegrity shape - flow list [18.x] read via the matrix expression
_wf m10 <<'EOF'
jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        node-version: [18.x]
    steps:
      - uses: actions/setup-node@abc
        with:
          node-version: ${{ matrix.node-version }}
EOF
_expect fail m10 "matrix [18.x] via matrix.node-version rejected"

# Fixture 11: every matrix entry at or above the floor -> pass
_wf m11 <<'EOF'
jobs:
  test:
    strategy:
      matrix:
        node-version: [22.x, '24.x']
    steps:
      - uses: actions/setup-node@abc
        with:
          node-version: ${{ matrix.node-version }}
EOF
_expect pass m11 "matrix [22.x, 24.x] passes"

# Fixture 12: one entry below the floor is enough to fail
_wf m12 <<'EOF'
jobs:
  test:
    strategy:
      matrix:
        node-version: [18.x, 22.x]
    steps:
      - uses: actions/setup-node@abc
        with:
          node-version: ${{ matrix.node-version }}
EOF
_expect fail m12 "matrix [18.x, 22.x] rejected"

# Fixture 13: block-style list, differently named key, spaced expression
_wf m13 <<'EOF'
jobs:
  test:
    strategy:
      matrix:
        os: [ubuntu-latest]
        node:
          - 22
          - "20" # legacy
    steps:
      - uses: actions/setup-node@abc
        with:
          node-version: ${{matrix.node}}
EOF
_expect fail m13 "block-style matrix list with a 20 entry rejected"

# Fixture 14: block-style list, all conformant -> pass
_wf m14 <<'EOF'
jobs:
  test:
    strategy:
      matrix:
        node:
          - 22
          - 24
    steps:
      - uses: actions/setup-node@abc
        with:
          node-version: ${{ matrix.node }}
EOF
_expect pass m14 "block-style matrix list 22/24 passes"

# Fixture 15: include entry adds a below-floor value (dash form)
_wf m15 <<'EOF'
jobs:
  test:
    strategy:
      matrix:
        node-version: [22]
        include:
          - node-version: 18.x
            os: windows-latest
    steps:
      - uses: actions/setup-node@abc
        with:
          node-version: ${{ matrix.node-version }}
EOF
_expect fail m15 "matrix include '- node-version: 18.x' rejected"

# Fixture 16: include entry with the key on a continuation line
_wf m16 <<'EOF'
jobs:
  test:
    strategy:
      matrix:
        include:
          - os: ubuntu-latest
            node-version: 18.x
    steps:
      - uses: actions/setup-node@abc
        with:
          node-version: ${{ matrix.node-version }}
EOF
_expect fail m16 "matrix include continuation 'node-version: 18.x' rejected"

# Fixture 17: matrix scoping is per job - job b's 18 must not leak into job a,
# and job b's own use of it must fail
_wf m17 <<'EOF'
jobs:
  a:
    strategy:
      matrix:
        node: [24]
    steps:
      - uses: actions/setup-node@abc
        with:
          node-version: ${{ matrix.node }}
  b:
    strategy:
      matrix:
        node: [18]
    steps:
      - uses: actions/setup-node@abc
        with:
          node-version: ${{ matrix.node }}
EOF
_expect fail m17 "second job's matrix [18] rejected"
_wf m17b <<'EOF'
jobs:
  a:
    strategy:
      matrix:
        node: [24]
    steps:
      - uses: actions/setup-node@abc
        with:
          node-version: ${{ matrix.node }}
  b:
    strategy:
      matrix:
        node: [18]
    steps:
      - run: echo "${{ matrix.node }}"
EOF
_expect pass m17b "another job's unused matrix [18] does not leak into job a"

# Fixture 18: matrix values behind fromJSON cannot be resolved -> notice, pass
_wf m18 <<'EOF'
jobs:
  test:
    strategy:
      matrix:
        node: ${{ fromJSON(needs.setup.outputs.nodes) }}
    steps:
      - uses: actions/setup-node@abc
        with:
          node-version: ${{ matrix.node }}
EOF
_expect pass m18 "fromJSON matrix value left as a notice"

# Fixture 19: a non-matrix expression keeps the notice behavior
_wf m19 <<'EOF'
jobs:
  test:
    steps:
      - uses: actions/setup-node@abc
        with:
          node-version: ${{ inputs.node }}
EOF
_expect pass m19 "non-matrix expression left as a notice"

# Fixture 20: strategy declared after steps still resolves
_wf m20 <<'EOF'
jobs:
  test:
    steps:
      - uses: actions/setup-node@abc
        with:
          node-version: ${{ matrix.node-version }}
    strategy:
      matrix:
        node-version: [20]
EOF
_expect fail m20 "matrix declared after steps rejected"

# Fixture 21: indentless block list (dashes at the key's indent)
_wf m21 <<'EOF'
jobs:
  test:
    strategy:
      matrix:
        node:
        - 22
        - 18
    steps:
      - uses: actions/setup-node@abc
        with:
          node-version: ${{ matrix.node }}
EOF
_expect fail m21 "indentless matrix list with an 18 entry rejected"

# Fixture 22: indentless include beside a conformant list
_wf m22 <<'EOF'
jobs:
  test:
    strategy:
      matrix:
        node: [22]
        include:
        - node: 18
          os: windows-latest
    steps:
      - uses: actions/setup-node@abc
        with:
          node-version: ${{ matrix.node }}
EOF
_expect fail m22 "indentless matrix include '- node: 18' rejected"

# Fixture 23: a failing workflow scan (awk error) must fail, not read as clean
mkdir -p "${tmp}/m23bin"
printf '#!/bin/sh\nexit 1\n' >"${tmp}/m23bin/awk"; chmod +x "${tmp}/m23bin/awk"
if env PATH="${tmp}/m23bin:${PATH}" bash "${checker}" "${tmp}/m10" 22 >/dev/null 2>&1; then
  _bad "failed workflow scan read as a clean pass"
else
  _ok "failed workflow scan fails loudly"
fi

echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
