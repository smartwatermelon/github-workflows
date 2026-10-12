#!/usr/bin/env bash
# Install the standards-check.yml caller stub across the fleet.
#
# Classifies every repo of --owners (plus --extra-repos) by policy
# (classes: see --help) and, with --apply,
# writes the canonical stub (standards/caller-stub.yml) into MISSING repos.
#
#   --mode=pr    branch chore/standards-check-stub + Contents-API put + PR
#   --mode=push  Contents-API put straight onto the default branch. This is
#                the W2 Phase-2 mechanism Andrew authorized on 2026-09-08 for
#                this one file only (dev-env docs/superpowers/plans/
#                2026-09-08-w2-fleet-rollout.md, "Decisions"). Never extend
#                it to other content.
#
# Dry run is the default. DIFFERS repos are reported and never touched.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The real binary first: the dotfiles gh wrapper overrides a GH_TOKEN= prefix.
if [[ -n "${BULK_GH:-}" ]]; then
  GH="${BULK_GH}"
elif [[ -x /opt/homebrew/bin/gh ]]; then
  GH=/opt/homebrew/bin/gh
else
  GH=gh
fi
STUB_FILE="${BULK_STUB_FILE:-${here}/standards/caller-stub.yml}"
IGNORE_FILE="${BULK_IGNORE_FILE:-${here}/.standards-check-ignore}"
# Sanity floor for live non-fork repos. Measured 38 on 2026-10-12; fewer
# means a truncated or wrong-token listing.
MIN_REPOS="${BULK_MIN_REPOS:-35}"
INSTALL_PATH=".github/workflows/standards-check.yml"
REQUIRED_CHECK="standards-check / run-standards-check"
BRANCH="chore/standards-check-stub"
SESSION="https://claude.ai/code/session_019HDRKLQNv82SEBd4zGpcXf"

APPLY=false
MODE="pr"
ONLY=""
OWNERS="smartwatermelon,nightowlstudiollc,twistedmelonman"
EXTRA=""

usage() {
  cat <<EOF
Usage: ${0##*/} [--apply] [--mode=pr|push] [--only owner/repo] [--owners a,b] [--extra-repos o/r,...]

Policy: every non-archived, non-fork repo calls the standards-check reusable
workflow AND requires its status check, or is listed in .standards-check-ignore
as "owner/repo  # reason".

One line per repo:
  CURRENT         canonical caller stub, check required
  DIFFERS         non-canonical caller, check required (never touched)
  CALLER-ONLY     caller present, check NOT required by branch protection
  CANNOT-REQUIRE  caller present, branch protection unavailable
                  (GitHub Free plan, private repo)
  MISSING         no caller; --apply installs the canonical stub
  IGNORED         listed in the ignore file; the reason is printed
  ARCHIVED        archived; skipped
  FORK            fork; out of policy scope, skipped
  ERROR           a lookup failed without a confirmed answer (exit 1)

Tokens: each owner is read with its own token (smartwatermelon GH_TOKEN_SWM,
nightowlstudiollc GH_TOKEN_NOS, twistedmelonman GH_TOKEN_TWM). A wrong token
returns 403/404 or an empty listing, not an auth error; see dev-env
docs/runbooks/fleet-probe-token-scopes.md. Exit 2 if a token is unset, an
owner listing is empty, or fewer than BULK_MIN_REPOS (${MIN_REPOS}) live
non-fork repos are found.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    --mode=pr | --mode=push) MODE="${1#--mode=}"; shift ;;
    --only) ONLY="$2"; shift 2 ;;
    --owners) OWNERS="$2"; shift 2 ;;
    --extra-repos) EXTRA="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -f "${STUB_FILE}" ]] || {
  echo "stub file not found: ${STUB_FILE}" >&2
  exit 2
}
STUB_B64="$(base64 <"${STUB_FILE}" | tr -d '\n')"

# owner -> its token's env var name; empty means gh's default token.
token_var() {
  case "$1" in
    smartwatermelon) echo GH_TOKEN_SWM ;;
    nightowlstudiollc) echo GH_TOKEN_NOS ;;
    twistedmelonman) echo GH_TOKEN_TWM ;;
    *) echo "" ;;
  esac
}

# ghx OWNER ARGS...: gh with OWNER's token, in the child's env only.
ghx() {
  local owner="$1" var
  shift
  var="$(token_var "${owner}")"
  if [[ -n "${var}" ]]; then
    GH_TOKEN="${!var}" "${GH}" "$@"
  else
    "${GH}" "$@"
  fi
}

# An unset token would fall back to another identity and read a partial fleet.
check_tokens() {
  local owner var
  local -a owners
  IFS=',' read -r -a owners <<<"${OWNERS}"
  for owner in "${owners[@]}"; do
    var="$(token_var "${owner}")"
    if [[ -n "${var}" && -z "${!var:-}" ]]; then
      echo "FATAL: ${var} is not set; cannot read ${owner}'s repos with its own token" >&2
      exit 2
    fi
  done
}

# Prints the reason for a listed repo, or returns 1. Matches the first field
# only, so a trailing reason still matches.
ignore_reason() {
  [[ -f "${IGNORE_FILE}" ]] || return 1
  local line name rest
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    name="${line%%[[:space:]]*}"
    [[ "${name}" == "$1" ]] || continue
    rest="${line#"${name}"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    rest="${rest#\#}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    printf '%s' "${rest}"
    return 0
  done <"${IGNORE_FILE}"
  return 1
}

# Emits "owner/repo<TAB>archived<TAB>fork<TAB>default_branch" lines.
list_repos() {
  local owner r type body rows
  local -a owners extras
  # The owner reaches jq through env, not --arg, so the program has no "$".
  local jqprog='.[] | select(.owner.login == env.LIST_OWNER)
    | "\(.full_name)\t\(.archived)\t\(.fork)\t\(.default_branch)"'
  IFS=',' read -r -a owners <<<"${OWNERS}"
  for owner in "${owners[@]}"; do
    [[ -n "${owner}" ]] || continue
    type="$(ghx "${owner}" api "users/${owner}" --jq .type)" || {
      echo "FATAL: cannot look up account type of ${owner}" >&2
      return 2
    }
    # users/<o>/repos omits private repos, so a user owner reads user/repos.
    if [[ "${type}" == "User" ]]; then
      body="$(ghx "${owner}" api --paginate 'user/repos?affiliation=owner&per_page=100')" || {
        echo "FATAL: listing ${owner}'s repos failed" >&2
        return 2
      }
    else
      body="$(ghx "${owner}" api --paginate "orgs/${owner}/repos?per_page=100")" || {
        echo "FATAL: listing ${owner}'s repos failed" >&2
        return 2
      }
    fi
    # One JSON array per page; rows are filtered to the owner.
    rows="$(LIST_OWNER="${owner}" jq -r "${jqprog}" <<<"${body}")" || {
      echo "FATAL: cannot parse ${owner}'s repo listing" >&2
      return 2
    }
    # Empty usually means the wrong owner's token.
    if [[ -z "${rows}" ]]; then
      echo "FATAL: ${owner} listing returned no repos (wrong token, or no access)" >&2
      return 2
    fi
    printf '%s\n' "${rows}"
  done
  if [[ -n "${EXTRA}" ]]; then
    IFS=',' read -r -a extras <<<"${EXTRA}"
    for r in "${extras[@]}"; do
      [[ -n "${r}" ]] && printf '%s\tfalse\tfalse\t\n' "${r}"
    done
  fi
  return 0
}

# owner/repo -> prints the file's content, base64 with no newlines.
# Returns 0 with content, 1 for a confirmed HTTP 404 (the file is absent), or
# 2 with the failure message for any other failure. A 403, a rate limit, or a
# network error must NOT read as "absent": under --apply --mode=push that
# would PUT the stub onto the default branch of a repo whose state is unknown.
# Compared byte-for-byte against STUB_B64, so a
# trailing-newline difference is a real difference and shows up as DIFFERS.
#
# The API wraps .content in 60-column lines, so it is NOT comparable to
# STUB_B64 as returned. Stripping those newlines and round-tripping through
# base64 -d | base64 renormalizes it to the same single-line encoding
# STUB_B64 uses; the decode/encode pair is a canonicalization, not a
# double-encode. Comparing raw decoded text instead would not work: $(...)
# strips trailing newlines, so a correct stub could never match.
existing_b64() {
  local body rc=0
  # stderr is captured, not discarded: it carries the "(HTTP <code>)" line that
  # distinguishes a real 404 from every other failure. Real `gh api` prints
  # "gh: Not Found (HTTP 404)" there and exits 1 (measured 2026-09-08).
  body="$(ghx "${1%%/*}" api "repos/$1/contents/${INSTALL_PATH}" 2>&1)" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    if [[ "${body}" == *"(HTTP 404)"* ]]; then
      return 1
    fi
    printf '%s' "${body}"
    return 2
  fi
  jq -r '.content' <<<"${body}" | tr -d '\n' | base64 -d | base64 | tr -d '\n'
}

# -> required | not-required | unavailable, or return 2.
# A bare 403 is an error: a wrong token returns one too.
required_state() {
  local body rc=0
  body="$(ghx "${1%%/*}" api "repos/$1/branches/$2/protection" 2>&1)" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    # Classic protection only; a ruleset-only requirement reads not-required.
    if [[ "${body}" == *"Branch not protected"*"(HTTP 404)"* ]]; then
      echo not-required
      return 0
    fi
    if [[ "${body}" == *"Upgrade to GitHub Pro"*"(HTTP 403)"* ]]; then
      echo unavailable
      return 0
    fi
    printf '%s' "${body}"
    return 2
  fi
  if jq -e --arg c "${REQUIRED_CHECK}" \
    '[(.required_status_checks.contexts // [])[], ((.required_status_checks.checks // [])[] | .context)] | index($c) != null' \
    <<<"${body}" >/dev/null; then
    echo required
  else
    echo not-required
  fi
}

default_branch() { ghx "${1%%/*}" api "repos/$1" --jq .default_branch; }

put_file() { # owner/repo branch [blob-sha]
  local -a sha_arg=()
  # The Contents API requires the current blob sha to overwrite an existing
  # file. A retry after a partial run finds the file already on the branch.
  [[ -n "${3:-}" ]] && sha_arg=(-f "sha=$3")
  ghx "${1%%/*}" api -X PUT "repos/$1/contents/${INSTALL_PATH}" \
    -f message="ci: add standards-check.yml caller stub (non-required)

Installs the deterministic standards check as a non-required status.
It becomes required per repo in W3 once the repo is green.

Claude-Session: ${SESSION}" \
    -f content="${STUB_B64}" \
    "${sha_arg[@]}" \
    -f branch="$2" >/dev/null
}

# Every step below is guarded with `|| return 1`. These functions run inside a
# command substitution in an `if`, which suspends `set -e` for everything they
# call, so an unguarded failure would fall through: an empty default branch
# would still reach the PUT, and a failed ref POST would still open a PR.
install_push() { # owner/repo
  local db
  db="$(default_branch "$1")" || return 1
  [[ -n "${db}" ]] || return 1
  put_file "$1" "${db}" || return 1
  echo "pushed to ${db}"
}

# Retry-safe: a previous partial run may have left the branch, and the file on
# it, behind. Reuse both rather than failing the repo on a duplicate ref POST.
install_pr() { # owner/repo
  local db sha blob="" owner="${1%%/*}"
  db="$(default_branch "$1")" || return 1
  [[ -n "${db}" ]] || return 1
  if ghx "${owner}" api "repos/$1/git/ref/heads/${BRANCH}" >/dev/null 2>&1; then
    # The branch already exists; the file may too, in which case the PUT needs
    # its blob sha. A 404 here just means the branch is empty of the stub.
    # The ref goes in the query string, not in -f: `gh api` switches the method
    # to POST as soon as any -f parameter is added (`gh api --help`), which
    # would turn this read into a failing write and silently drop the sha.
    blob="$(ghx "${owner}" api "repos/$1/contents/${INSTALL_PATH}?ref=${BRANCH}" --jq .sha 2>/dev/null)" || blob=""
  else
    sha="$(ghx "${owner}" api "repos/$1/git/ref/heads/${db}" --jq .object.sha)" || return 1
    [[ -n "${sha}" ]] || return 1
    ghx "${owner}" api -X POST "repos/$1/git/refs" -f ref="refs/heads/${BRANCH}" -f sha="${sha}" >/dev/null || return 1
  fi
  put_file "$1" "${BRANCH}" "${blob}" || return 1
  ghx "${owner}" pr create --repo "$1" --head "${BRANCH}" --base "${db}" \
    --title "ci: add standards-check.yml caller stub (non-required)" \
    --body "Installs \`standards-check.yml\` as a NON-required check. Branch protection is unchanged; W3 flips it to required once this repo is green.

Reusable workflow: smartwatermelon/github-workflows \`standards-check.yml@standards-check-v1\`.

${SESSION}" || return 1
}

# Dispatch table: the two install functions are reached through this map, not
# by name interpolation, so a bad --mode can never name an arbitrary function.
install_repo() { # mode owner/repo
  case "$1" in
    push) install_push "$2" ;;
    pr) install_pr "$2" ;;
    *) echo "unknown mode: $1" >&2; return 2 ;;
  esac
}

line() { # class repo [detail]
  printf '%-15s %s%s\n' "$1" "$2" "${3:+  $3}"
}

check_tokens

# Enumerate once into a file: a process substitution here would mask
# list_repos' exit status, so a listing failure would read as an empty fleet
# and the script would exit 0 having done nothing.
repo_list="$(mktemp)"
trap 'rm -f "${repo_list}"' EXIT
list_repos >"${repo_list}" || exit 2

live="$(awk -F'\t' '$2 == "false" && $3 == "false"' "${repo_list}" | wc -l | tr -d ' ')"
if [[ "${live}" -lt "${MIN_REPOS}" ]]; then
  echo "FATAL: enumerated ${live} live non-fork repos, below the sanity floor of ${MIN_REPOS}." >&2
  echo "       A listing is probably truncated or used the wrong owner's token." >&2
  exit 2
fi

rc=0
while IFS=$'\t' read -r repo archived fork branch; do
  [[ -n "${repo}" ]] || continue
  if [[ -n "${ONLY}" && "${repo}" != "${ONLY}" ]]; then continue; fi
  if [[ "${archived}" == "true" ]]; then
    line ARCHIVED "${repo}" "(skipped)"
    continue
  fi
  if [[ "${fork}" == "true" ]]; then
    line FORK "${repo}" "(out of policy scope; skipped)"
    continue
  fi
  if reason="$(ignore_reason "${repo}")"; then
    if [[ -z "${reason}" ]]; then
      line ERROR "${repo}" "listed in the ignore file without a reason"
      rc=1
    else
      line IGNORED "${repo}" "${reason}"
    fi
    continue
  fi
  lookup_rc=0
  current="$(existing_b64 "${repo}")" || lookup_rc=$?
  case "${lookup_rc}" in
    0)
      if [[ "${current}" == "${STUB_B64}" ]]; then stub="canonical stub"; else stub="non-canonical caller; not touched"; fi
      if [[ -z "${branch}" ]]; then
        branch="$(default_branch "${repo}" 2>&1)" || {
          line ERROR "${repo}" "default branch lookup: ${branch//$'\n'/ }"
          rc=1
          continue
        }
      fi
      req_rc=0
      req="$(required_state "${repo}" "${branch}")" || req_rc=$?
      if [[ "${req_rc}" -ne 0 ]]; then
        line ERROR "${repo}" "protection lookup: ${req//$'\n'/ }"
        rc=1
        continue
      fi
      case "${req}" in
        required)
          if [[ "${stub}" == "canonical stub" ]]; then
            line CURRENT "${repo}" "(${stub}; check required)"
          else
            line DIFFERS "${repo}" "(${stub}; check required)"
          fi ;;
        not-required) line CALLER-ONLY "${repo}" "(${stub}; check not required on ${branch})" ;;
        unavailable) line CANNOT-REQUIRE "${repo}" "(${stub}; Free-plan private repo, no branch protection)" ;;
        *) line ERROR "${repo}" "unexpected protection state: ${req}"; rc=1 ;;
      esac
      continue
      ;;
    1) : ;; # confirmed 404: the file is absent, fall through to MISSING
    *)
      # One line per repo is the output contract; API errors are multi-line.
      line ERROR "${repo}" "${current//$'\n'/ }"
      rc=1
      continue
      ;;
  esac
  if ! ${APPLY}; then
    line MISSING "${repo}" "(dry run; would ${MODE})"
    continue
  fi
  if out="$(install_repo "${MODE}" "${repo}" 2>&1)"; then
    line MISSING "${repo}" "-> ${out}"
  else
    line ERROR "${repo}" "${out//$'\n'/ }"
    rc=1
  fi
done <"${repo_list}"
exit "${rc}"
