#!/usr/bin/env bash
# Known-bad validation for standards/run-standards.sh: one fixture per
# linter that MUST fail, one clean fixture that MUST pass, and a --skip case
# proving the toggle really disables a linter. Requires the five tools on
# PATH (brew install shellcheck yamllint actionlint zizmor markdownlint-cli2).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runner="${here}/../standards/run-standards.sh"
cfg="${here}/../standards"
for tool in shellcheck yamllint actionlint zizmor markdownlint-cli2 jq; do
  command -v "${tool}" >/dev/null || { echo "SKIP: ${tool} not on PATH"; exit 0; }
done
tmp="$(mktemp -d)"
# Hermetic fixtures: the user's global init.templateDir scaffolds
# .editorconfig/.gitignore/.claude into every `git init`, which leaks real
# files into fixtures that are supposed to be empty. An explicit empty
# --template overrides it, so a bare fixture really is bare.
tmpl="$(mktemp -d)"
trap 'rm -rf "${tmp}" "${tmpl}"' EXIT
pass=0; fail=0
_ok() { echo "  ok   $1"; pass=$((pass + 1)); }
_bad() { echo "  FAIL $1"; fail=$((fail + 1)); }
_mk() { mkdir -p "${tmp}/$1"; git -C "${tmp}/$1" init -q --template="${tmpl}"; }
_expect_fail() { # name dir
  if bash "${runner}" --repo "${tmp}/$2" --config-dir "${cfg}" >"${tmp}/$2.log" 2>&1; then _bad "$1 (accepted; see ${tmp}/$2.log)"; else _ok "$1"; fi
}
_expect_pass() {
  if bash "${runner}" --repo "${tmp}/$2" --config-dir "${cfg}" >"${tmp}/$2.log" 2>&1; then _ok "$1"; else _bad "$1 (rejected; see ${tmp}/$2.log)"; cat "${tmp}/$2.log"; fi
}

# Fixture literals that must contain "$1" / "${{ }}" verbatim. They are
# assembled from a lone "$" plus the rest so the source carries no
# single-quoted expression for shellcheck to warn about (SC2016).
d='$'

_mk bad-sh; printf '#!/usr/bin/env bash\necho %s1\n' "${d}" >"${tmp}/bad-sh/x.sh"; git -C "${tmp}/bad-sh" add -A
_expect_fail "shellcheck: unquoted \$1 (SC2086) rejected" bad-sh

_mk bad-yaml; printf 'a: 1\n  b: 2\n' >"${tmp}/bad-yaml/x.yml"; git -C "${tmp}/bad-yaml" add -A
_expect_fail "yamllint: bad indentation rejected" bad-yaml

_mk bad-action; mkdir -p "${tmp}/bad-action/.github/workflows"
printf 'on: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n        uses: actions/checkout@v7\n' >"${tmp}/bad-action/.github/workflows/ci.yml"
git -C "${tmp}/bad-action" add -A
_expect_fail "actionlint: run+uses in one step rejected" bad-action

_mk bad-zizmor; mkdir -p "${tmp}/bad-zizmor/.github/workflows"
printf 'on: pull_request_target\npermissions: write-all\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v7\n        with:\n          ref: %s{{ github.event.pull_request.head.ref }}\n' "${d}" >"${tmp}/bad-zizmor/.github/workflows/ci.yml"
git -C "${tmp}/bad-zizmor" add -A
_expect_fail "zizmor: pwn-request / unpinned third-party rejected" bad-zizmor

_mk bad-md; printf '#Bad heading\n\n\n\nx\n' >"${tmp}/bad-md/README.md"; git -C "${tmp}/bad-md" add -A
_expect_fail "markdownlint: MD018/MD012 rejected" bad-md

_mk bad-node; echo "20" >"${tmp}/bad-node/.nvmrc"; git -C "${tmp}/bad-node" add -A
_expect_fail "node-floor: .nvmrc 20 rejected" bad-node

_mk clean; mkdir -p "${tmp}/clean/.github/workflows"
printf '#!/usr/bin/env bash\nset -euo pipefail\necho "%s{1:-}"\n' "${d}" >"${tmp}/clean/ok.sh"
printf '# Title\n\nBody.\n' >"${tmp}/clean/README.md"
printf 'key: value\n' >"${tmp}/clean/x.yml"
printf 'on: push\npermissions:\n  contents: read\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n' >"${tmp}/clean/.github/workflows/ci.yml"
echo "lts/krypton" >"${tmp}/clean/.nvmrc"
git -C "${tmp}/clean" add -A
_expect_pass "clean repo passes every linter" clean

if bash "${runner}" --repo "${tmp}/bad-sh" --config-dir "${cfg}" --skip shellcheck >/dev/null 2>&1; then _ok "--skip shellcheck disables the linter"; else _bad "--skip shellcheck did not disable it"; fi

_mk empty; git -C "${tmp}/empty" add -A
_expect_pass "empty repo passes (nothing to lint is not a failure)" empty

# A --repo that is not a git repository must fail loudly with exit 2, not
# report a clean pass. Every file-based linter enumerates via `git ls-files
# || true`, so without the guard an unreadable directory lints as empty and
# the check goes green over nothing.
mkdir -p "${tmp}/not-a-repo"
set +e
bash "${runner}" --repo "${tmp}/not-a-repo" --config-dir "${cfg}" >"${tmp}/not-a-repo.log" 2>&1
rc=$?
set -e
if [[ "${rc}" -eq 2 ]]; then _ok "non-repo --repo exits 2"; else _bad "non-repo --repo exited ${rc}, expected 2 (see ${tmp}/not-a-repo.log)"; fi

echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
