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
  mkdir -p "${STUB_DIR}/repos" "${STUB_DIR}/files" "${STUB_DIR}/protection" "${STUB_DIR}/types"
  cat >"${STUB_DIR}/repos/acme.json" <<'EOF'
[{"full_name":"acme/alpha","owner":{"login":"acme"},"archived":false,"fork":false,"default_branch":"main"},
 {"full_name":"acme/beta","owner":{"login":"acme"},"archived":false,"fork":false,"default_branch":"main"},
 {"full_name":"acme/old","owner":{"login":"acme"},"archived":true,"fork":false,"default_branch":"main"}]
EOF
  cat >"${STUB_DIR}/repos/nite.json" <<'EOF'
[{"full_name":"nite/gamma","owner":{"login":"nite"},"archived":false,"fork":false,"default_branch":"main"}]
EOF
  cp "${stub}" "${STUB_DIR}/files/acme__beta"          # beta already CURRENT
  printf 'name: Different\n' >"${STUB_DIR}/files/nite__gamma"  # gamma DIFFERS
  _required acme__beta
  _required nite__gamma
  printf 'acme/alpha-ignored  # fixture reason\n' >"${STUB_DIR}/ignore"
  : >"${STUB_DIR}/calls.log"
}

_required() { # <owner>__<repo>: protection lists the standards check
  printf '{"required_status_checks":{"contexts":["standards-check / run-standards-check"],"checks":[{"context":"standards-check / run-standards-check"}]}}\n' \
    >"${STUB_DIR}/protection/$1"
}

# Floor 1: the real floor is sized for the real fleet. Case 14 tests it.
run() { BULK_GH="${here}/stub-gh/gh" BULK_STUB_FILE="${stub}" BULK_IGNORE_FILE="${STUB_DIR}/ignore" BULK_MIN_REPOS="${MIN:-1}" bash "${script}" --owners "${OWNERS:-acme,nite}" --extra-repos "" "$@"; }

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
printf 'acme/alpha   # kept out on purpose\n' >"${STUB_DIR}/ignore"
out="$(run 2>&1)" || true
if grep -q '^IGNORED   *acme/alpha  kept out on purpose$' <<<"${out}"; then _ok "ignore file honored, reason printed"; else _bad "ignore file: ${out}"; fi
_fixture
out="$(run --only nite/gamma 2>&1)" || true
if grep -q 'acme/' <<<"${out}"; then _bad "--only leaked other repos"; else _ok "--only restricts"; fi

# 6. a non-404 API failure is ERROR, not MISSING, and writes nothing
# A 403 or a rate-limit must never read as "the file is absent", because in
# --apply --mode=push that would PUT the stub onto the default branch of a
# repo whose real state is unknown.
_fixture
mkdir -p "${STUB_DIR}/fail"
: >"${STUB_DIR}/fail/acme__alpha"
rc=0
out="$(run --apply --mode=push 2>&1)" || rc=$?
if grep -q '^ERROR  *acme/alpha' <<<"${out}"; then _ok "non-404 failure is ERROR"; else _bad "non-404 classification: ${out}"; fi
if grep -q 'PUT repos/acme/alpha' "${STUB_DIR}/calls.log"; then _bad "ERROR repo was written"; else _ok "ERROR repo not written"; fi
if [[ "${rc}" == "1" ]]; then _ok "non-404 failure exits 1"; else _bad "exit status ${rc}, expected 1"; fi

# 7. pr mode is retry-safe: an existing branch is reused, not re-created
_fixture
mkdir -p "${STUB_DIR}/branch-exists"
: >"${STUB_DIR}/branch-exists/acme__alpha"
rc=0
out="$(run --apply --mode=pr 2>&1)" || rc=$?
if grep -q 'POST repos/acme/alpha/git/refs' "${STUB_DIR}/calls.log"; then _bad "existing branch was re-created"; else _ok "existing branch reused"; fi
if grep 'PUT repos/acme/alpha' "${STUB_DIR}/calls.log" | grep -q 'branch=chore/standards-check-stub'; then _ok "retry: PUT goes to the existing branch"; else _bad "retry: PUT branch"; fi
if grep -q '^pr create' "${STUB_DIR}/calls.log"; then _ok "retry: PR opened"; else _bad "retry: no PR"; fi
if [[ "${rc}" == "0" ]]; then _ok "retry run exits 0"; else _bad "retry exit status ${rc}: ${out}"; fi

# 8. retry with the file already on the branch passes its blob sha to the PUT
_fixture
mkdir -p "${STUB_DIR}/branch-exists" "${STUB_DIR}/branch-files"
: >"${STUB_DIR}/branch-exists/acme__alpha"
printf 'name: Partial\n' >"${STUB_DIR}/branch-files/acme__alpha"
run --apply --mode=pr >/dev/null 2>&1 || true
if grep 'PUT repos/acme/alpha' "${STUB_DIR}/calls.log" | grep -q 'sha=branchblob'; then _ok "retry: blob sha passed to PUT"; else _bad "retry: no blob sha in PUT"; fi

# 9. a failing install step stops the repo instead of falling through
# install_push/install_pr run inside a command substitution in an `if`, which
# suspends `set -e`. Without an explicit guard on each step, a failed
# default-branch lookup would leave the branch empty and the PUT would still
# fire.
_fixture
mkdir -p "${STUB_DIR}/fail-repo"
: >"${STUB_DIR}/fail-repo/acme__alpha"
rc=0
out="$(run --apply --mode=push 2>&1)" || rc=$?
if grep -q '^ERROR  *acme/alpha' <<<"${out}"; then _ok "failed install step is ERROR"; else _bad "failed install: ${out}"; fi
if grep -q 'PUT repos/acme/alpha' "${STUB_DIR}/calls.log"; then _bad "PUT fired after a failed lookup"; else _ok "no PUT after a failed lookup"; fi
if [[ "${rc}" == "1" ]]; then _ok "failed install exits 1"; else _bad "failed install exit ${rc}"; fi

# 10. the same guard in pr mode: no PR is opened after a failed lookup
_fixture
mkdir -p "${STUB_DIR}/fail-repo"
: >"${STUB_DIR}/fail-repo/acme__alpha"
run --apply --mode=pr >/dev/null 2>&1 || true
if grep -q '^pr create' "${STUB_DIR}/calls.log"; then _bad "PR opened after a failed lookup"; else _ok "no PR after a failed lookup"; fi

# 11. --extra-repos adds explicit owner/repo entries outside --owners
_fixture
out="$(run --extra-repos solo/thing 2>&1)" || true
if grep -q '^MISSING   *solo/thing' <<<"${out}"; then _ok "--extra-repos included"; else _bad "--extra-repos: ${out}"; fi

# 12. forks are FORK, never MISSING, and never written
_fixture
cat >"${STUB_DIR}/repos/nite.json" <<'EOF'
[{"full_name":"nite/gamma","owner":{"login":"nite"},"archived":false,"fork":false,"default_branch":"main"},
 {"full_name":"nite/forked","owner":{"login":"nite"},"archived":false,"fork":true,"default_branch":"main"}]
EOF
out="$(run --apply --mode=push 2>&1)" || true
if grep -q '^FORK  *nite/forked' <<<"${out}"; then _ok "fork is FORK"; else _bad "fork classification: ${out}"; fi
if grep -q 'PUT repos/nite/forked' "${STUB_DIR}/calls.log"; then _bad "fork was written"; else _ok "fork not written"; fi

# 13. caller present: not required / Free plan / bare 403
_fixture
rm "${STUB_DIR}/protection/acme__beta"
out="$(run 2>&1)" || true
if grep -q '^CALLER-ONLY  *acme/beta' <<<"${out}"; then _ok "unprotected caller is CALLER-ONLY"; else _bad "caller-only: ${out}"; fi
_fixture
printf '{"required_status_checks":{"contexts":["other"],"checks":[{"context":"other"}]}}\n' >"${STUB_DIR}/protection/acme__beta"
out="$(run 2>&1)" || true
if grep -q '^CALLER-ONLY  *acme/beta' <<<"${out}"; then _ok "protected without the check is CALLER-ONLY"; else _bad "caller-only (other check): ${out}"; fi
_fixture
mkdir -p "${STUB_DIR}/protection-free"; : >"${STUB_DIR}/protection-free/acme__beta"
out="$(run 2>&1)" || true
if grep -q '^CANNOT-REQUIRE  *acme/beta' <<<"${out}"; then _ok "Free-plan private is CANNOT-REQUIRE"; else _bad "cannot-require: ${out}"; fi
_fixture
mkdir -p "${STUB_DIR}/protection-fail"; : >"${STUB_DIR}/protection-fail/acme__beta"
rc=0
out="$(run 2>&1)" || rc=$?
if grep -q '^ERROR  *acme/beta  protection lookup' <<<"${out}"; then _ok "bare 403 on protection is ERROR"; else _bad "bare 403: ${out}"; fi
if [[ "${rc}" == "1" ]]; then _ok "protection ERROR exits 1"; else _bad "protection ERROR exit ${rc}"; fi

# 14. known-bad: a listing that returns too few repos must fail, write nothing
_fixture
rc=0
out="$(MIN=10 run --apply --mode=push 2>&1)" || rc=$?
if [[ "${rc}" == "2" ]] && grep -q 'below the sanity floor' <<<"${out}"; then _ok "short listing fails the floor"; else _bad "floor: rc=${rc} ${out}"; fi
if grep -q 'PUT' "${STUB_DIR}/calls.log"; then _bad "short listing still wrote"; else _ok "short listing wrote nothing"; fi
if grep -qE '^(MISSING|CURRENT|DIFFERS) ' <<<"${out}"; then _bad "short listing still classified repos"; else _ok "short listing classified nothing"; fi

# 15. known-bad: one owner's listing is empty (wrong token) -> fatal
_fixture
printf '[]\n' >"${STUB_DIR}/repos/nite.json"
rc=0
out="$(run --apply --mode=push 2>&1)" || rc=$?
if [[ "${rc}" == "2" ]] && grep -q 'nite listing returned no repos' <<<"${out}"; then _ok "empty owner listing is fatal"; else _bad "empty listing: rc=${rc} ${out}"; fi
if grep -q 'PUT' "${STUB_DIR}/calls.log"; then _bad "empty listing still wrote"; else _ok "empty listing wrote nothing"; fi

# 16. rows owned by someone else do not count (wrong token returns other repos)
_fixture
printf '[{"full_name":"x/y","owner":{"login":"x"},"archived":false,"fork":false,"default_branch":"main"}]\n' >"${STUB_DIR}/repos/nite.json"
rc=0
out="$(run 2>&1)" || rc=$?
if [[ "${rc}" == "2" ]]; then _ok "foreign rows are filtered out"; else _bad "foreign rows: rc=${rc} ${out}"; fi

# 17. a user owner is listed through user/repos, not orgs/
_fixture
printf 'User\n' >"${STUB_DIR}/types/solo"
printf '[{"full_name":"solo/priv","owner":{"login":"solo"},"archived":false,"fork":false,"default_branch":"main"}]\n' >"${STUB_DIR}/user-repos.json"
out="$(OWNERS=acme,solo run 2>&1)" || true
if grep -q '^MISSING  *solo/priv' <<<"${out}"; then _ok "user owner listed"; else _bad "user owner: ${out}"; fi
if grep -q 'orgs/solo' "${STUB_DIR}/calls.log"; then _bad "user owner listed via orgs/"; else _ok "user owner not listed via orgs/"; fi

# 18. an ignore entry without a reason is an ERROR, not a silent skip
_fixture
printf 'acme/alpha\n' >"${STUB_DIR}/ignore"
rc=0
out="$(run 2>&1)" || rc=$?
if grep -q '^ERROR  *acme/alpha  listed in the ignore file without a reason' <<<"${out}" && [[ "${rc}" == "1" ]]; then _ok "reasonless ignore is ERROR"; else _bad "reasonless ignore: rc=${rc} ${out}"; fi

# 19. a mapped owner with no token set is fatal before any API call
_fixture
rc=0
out="$(GH_TOKEN_NOS="" OWNERS=nightowlstudiollc run 2>&1)" || rc=$?
if [[ "${rc}" == "2" ]] && grep -q 'GH_TOKEN_NOS is not set' <<<"${out}"; then _ok "missing owner token is fatal"; else _bad "missing token: rc=${rc} ${out}"; fi
if [[ -s "${STUB_DIR}/calls.log" ]]; then _bad "API called without a token"; else _ok "no API call without a token"; fi
_fixture
rc=0
out="$(GH_TOKEN_TWM="" run --extra-repos twistedmelonman/x 2>&1)" || rc=$?
if [[ "${rc}" == "2" ]] && grep -q 'GH_TOKEN_TWM is not set' <<<"${out}"; then _ok "extra repo's owner token checked"; else _bad "extra owner token: rc=${rc} ${out}"; fi

echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
