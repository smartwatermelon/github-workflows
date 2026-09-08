#!/usr/bin/env bash
# Install the standards-check.yml caller stub across the fleet.
#
# Classifies every non-archived repo of --owners (plus --extra-repos) as
# MISSING / CURRENT / DIFFERS / IGNORED / ARCHIVED / ERROR and, with --apply,
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
GH="${BULK_GH:-gh}"
STUB_FILE="${BULK_STUB_FILE:-${here}/standards/caller-stub.yml}"
IGNORE_FILE="${BULK_IGNORE_FILE:-${here}/.standards-check-ignore}"
INSTALL_PATH=".github/workflows/standards-check.yml"
BRANCH="chore/standards-check-stub"
SESSION="https://claude.ai/code/session_019HDRKLQNv82SEBd4zGpcXf"

APPLY=false
MODE="pr"
ONLY=""
OWNERS="smartwatermelon,nightowlstudiollc"
EXTRA="twistedmelonman/dotfiles,twistedmelonman/claude-config,twistedmelonman/personify,twistedmelonman/huddle-transcribe,twistedmelonman/projectinsomnia"

usage() {
  cat <<EOF
Usage: ${0##*/} [--apply] [--mode=pr|push] [--only owner/repo] [--owners a,b] [--extra-repos o/r,...]
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

is_ignored() {
  [[ -f "${IGNORE_FILE}" ]] || return 1
  grep -v '^[[:space:]]*#' "${IGNORE_FILE}" | grep -qx "$1"
}

# Emits "owner/repo<TAB>archived(true|false)" lines.
list_repos() {
  local owner r
  local -a owners extras
  IFS=',' read -r -a owners <<<"${OWNERS}"
  for owner in "${owners[@]}"; do
    [[ -n "${owner}" ]] || continue
    "${GH}" repo list "${owner}" --json name,isArchived --limit 200 |
      jq -r --arg o "${owner}" '.[] | "\($o)/\(.name)\t\(.isArchived)"'
  done
  if [[ -n "${EXTRA}" ]]; then
    IFS=',' read -r -a extras <<<"${EXTRA}"
    for r in "${extras[@]}"; do
      [[ -n "${r}" ]] && printf '%s\tfalse\n' "${r}"
    done
  fi
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
  body="$("${GH}" api "repos/$1/contents/${INSTALL_PATH}" 2>&1)" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    if [[ "${body}" == *"(HTTP 404)"* ]]; then
      return 1
    fi
    printf '%s' "${body}"
    return 2
  fi
  jq -r '.content' <<<"${body}" | tr -d '\n' | base64 -d | base64 | tr -d '\n'
}

default_branch() { "${GH}" api "repos/$1" --jq .default_branch; }

put_file() { # owner/repo branch [blob-sha]
  local -a sha_arg=()
  # The Contents API requires the current blob sha to overwrite an existing
  # file. A retry after a partial run finds the file already on the branch.
  [[ -n "${3:-}" ]] && sha_arg=(-f "sha=$3")
  "${GH}" api -X PUT "repos/$1/contents/${INSTALL_PATH}" \
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
  local db sha blob=""
  db="$(default_branch "$1")" || return 1
  [[ -n "${db}" ]] || return 1
  if "${GH}" api "repos/$1/git/ref/heads/${BRANCH}" >/dev/null 2>&1; then
    # The branch already exists; the file may too, in which case the PUT needs
    # its blob sha. A 404 here just means the branch is empty of the stub.
    # The ref goes in the query string, not in -f: `gh api` switches the method
    # to POST as soon as any -f parameter is added (`gh api --help`), which
    # would turn this read into a failing write and silently drop the sha.
    blob="$("${GH}" api "repos/$1/contents/${INSTALL_PATH}?ref=${BRANCH}" --jq .sha 2>/dev/null)" || blob=""
  else
    sha="$("${GH}" api "repos/$1/git/ref/heads/${db}" --jq .object.sha)" || return 1
    [[ -n "${sha}" ]] || return 1
    "${GH}" api -X POST "repos/$1/git/refs" -f ref="refs/heads/${BRANCH}" -f sha="${sha}" >/dev/null || return 1
  fi
  put_file "$1" "${BRANCH}" "${blob}" || return 1
  "${GH}" pr create --repo "$1" --head "${BRANCH}" --base "${db}" \
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

# Enumerate once into a file: a process substitution here would mask
# list_repos' exit status, so a `gh repo list` failure would read as an empty
# fleet and the script would exit 0 having done nothing.
repo_list="$(mktemp)"
trap 'rm -f "${repo_list}"' EXIT
list_repos >"${repo_list}"

rc=0
while IFS=$'\t' read -r repo archived; do
  [[ -n "${repo}" ]] || continue
  if [[ -n "${ONLY}" && "${repo}" != "${ONLY}" ]]; then continue; fi
  if [[ "${archived}" == "true" ]]; then
    printf 'ARCHIVED  %s\n' "${repo}"
    continue
  fi
  if is_ignored "${repo}"; then
    printf 'IGNORED   %s\n' "${repo}"
    continue
  fi
  lookup_rc=0
  current="$(existing_b64 "${repo}")" || lookup_rc=$?
  case "${lookup_rc}" in
    0)
      if [[ "${current}" == "${STUB_B64}" ]]; then
        printf 'CURRENT   %s\n' "${repo}"
      else
        printf 'DIFFERS   %s  (has a non-canonical stub; not touched)\n' "${repo}"
      fi
      continue
      ;;
    1) : ;; # confirmed 404: the file is absent, fall through to MISSING
    *)
      # One line per repo is the output contract; API errors are multi-line.
      printf 'ERROR     %s  %s\n' "${repo}" "${current//$'\n'/ }"
      rc=1
      continue
      ;;
  esac
  if ! ${APPLY}; then
    printf 'MISSING   %s  (dry run; would %s)\n' "${repo}" "${MODE}"
    continue
  fi
  if out="$(install_repo "${MODE}" "${repo}" 2>&1)"; then
    printf 'MISSING   %s  -> %s\n' "${repo}" "${out}"
  else
    printf 'ERROR     %s  %s\n' "${repo}" "${out//$'\n'/ }"
    rc=1
  fi
done <"${repo_list}"
exit "${rc}"
