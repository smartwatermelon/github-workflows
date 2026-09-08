#!/usr/bin/env bash
# Hermetic tests for bulk-install-standards-check.sh against tests/stub-gh/gh.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../bulk-install-standards-check.sh"
stub="${here}/../standards/caller-stub.yml"
pass=0; fail=0
_ok() { echo "  ok   $1"; pass=$((pass + 1)); }
_bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

_fixture() { # creates a fresh STUB_DIR with two owners, four repos
  STUB_DIR="$(mktemp -d)"; export STUB_DIR
  mkdir -p "${STUB_DIR}/repos" "${STUB_DIR}/files"
  cat >"${STUB_DIR}/repos/acme.json" <<'EOF'
[{"name":"alpha","isArchived":false,"defaultBranchRef":{"name":"main"}},
 {"name":"beta","isArchived":false,"defaultBranchRef":{"name":"main"}},
 {"name":"old","isArchived":true,"defaultBranchRef":{"name":"main"}}]
EOF
  cat >"${STUB_DIR}/repos/nite.json" <<'EOF'
[{"name":"gamma","isArchived":false,"defaultBranchRef":{"name":"main"}}]
EOF
  cp "${stub}" "${STUB_DIR}/files/acme__beta"          # beta already CURRENT
  printf 'name: Different\n' >"${STUB_DIR}/files/nite__gamma"  # gamma DIFFERS
  printf 'acme/alpha-ignored\n' >"${STUB_DIR}/ignore"
  : >"${STUB_DIR}/calls.log"
}

# --extra-repos "" is required: the script's default EXTRA names five real
# twistedmelonman repos, which the fixture does not know about. They would
# read as MISSING and add PUTs that the counts below do not expect.
run() { BULK_GH="${here}/stub-gh/gh" BULK_STUB_FILE="${stub}" BULK_IGNORE_FILE="${STUB_DIR}/ignore" bash "${script}" --owners acme,nite --extra-repos "" "$@"; }

# 1. dry run classifies every repo and writes nothing
_fixture
out="$(run 2>&1)" || true
if grep -q '^MISSING   *acme/alpha' <<<"${out}"; then _ok "alpha is MISSING"; else _bad "alpha classification: ${out}"; fi
if grep -q '^CURRENT   *acme/beta' <<<"${out}"; then _ok "beta is CURRENT"; else _bad "beta classification"; fi
if grep -q '^ARCHIVED  *acme/old' <<<"${out}"; then _ok "old is ARCHIVED"; else _bad "old classification"; fi
if grep -q '^DIFFERS   *nite/gamma' <<<"${out}"; then _ok "gamma is DIFFERS"; else _bad "gamma classification"; fi
if grep -q 'PUT' "${STUB_DIR}/calls.log"; then _bad "dry run wrote a file"; else _ok "dry run wrote nothing"; fi

# 2. --apply --mode=push PUTs only the MISSING repo, onto its default branch
_fixture
run --apply --mode=push >/dev/null 2>&1 || true
puts="$(grep -c 'PUT repos/' "${STUB_DIR}/calls.log" || true)"
if [[ "${puts}" == "1" ]]; then _ok "push mode: exactly one PUT"; else _bad "push mode: ${puts} PUTs"; fi
if grep -q 'PUT repos/acme/alpha/contents/.github/workflows/standards-check.yml' "${STUB_DIR}/calls.log"; then _ok "PUT targets alpha"; else _bad "PUT target"; fi
if grep 'PUT repos/acme/alpha' "${STUB_DIR}/calls.log" | grep -q 'branch=main'; then _ok "PUT goes to main"; else _bad "PUT branch"; fi
if grep -q 'git/refs' "${STUB_DIR}/calls.log"; then _bad "push mode created a branch"; else _ok "push mode: no branch"; fi

# 3. --apply --mode=pr creates a branch, PUTs onto it, opens a PR
_fixture
run --apply --mode=pr >/dev/null 2>&1 || true
if grep -q 'POST repos/acme/alpha/git/refs' "${STUB_DIR}/calls.log"; then _ok "pr mode: branch created"; else _bad "pr mode: no branch"; fi
if grep 'PUT repos/acme/alpha' "${STUB_DIR}/calls.log" | grep -q 'branch=chore/standards-check-stub'; then _ok "PUT goes to the feature branch"; else _bad "PUT branch in pr mode"; fi
if grep -q '^pr create' "${STUB_DIR}/calls.log"; then _ok "pr mode: PR opened"; else _bad "pr mode: no PR"; fi

# 4. DIFFERS is never written, in either mode
_fixture
run --apply --mode=push >/dev/null 2>&1 || true
if grep -q 'PUT repos/nite/gamma' "${STUB_DIR}/calls.log"; then _bad "DIFFERS was overwritten"; else _ok "DIFFERS left alone"; fi

# 5. ignore file honored; --only restricts
_fixture
printf 'acme/alpha\n' >"${STUB_DIR}/ignore"
out="$(run 2>&1)" || true
if grep -q '^IGNORED   *acme/alpha' <<<"${out}"; then _ok "ignore file honored"; else _bad "ignore file"; fi
_fixture
out="$(run --only nite/gamma 2>&1)" || true
if grep -q 'acme/' <<<"${out}"; then _bad "--only leaked other repos"; else _ok "--only restricts"; fi

# 6. --extra-repos adds explicit owner/repo entries outside --owners
_fixture
mkdir -p "${STUB_DIR}/repos"; printf '[]\n' >"${STUB_DIR}/repos/solo.json"
out="$(run --extra-repos solo/thing 2>&1)" || true
if grep -q '^MISSING   *solo/thing' <<<"${out}"; then _ok "--extra-repos included"; else _bad "--extra-repos: ${out}"; fi

echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
