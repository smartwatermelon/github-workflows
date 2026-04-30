#!/usr/bin/env bash
# bulk-install-claude-review.sh
#
# Bulk-installs (or refreshes) the claude-blocking-review caller workflow
# across all eligible repos under the smartwatermelon user account.
#
# Workaround for the fact that GitHub's workflow-templates picker is
# org-only — smartwatermelon is a user account, so workflow-templates
# in smartwatermelon/.github never appear in the picker UI for
# smartwatermelon/* repos. This script closes that gap by opening
# install/refresh PRs.
#
# Behavior:
#   - DRY-RUN BY DEFAULT. Use --apply to actually open PRs.
#   - Classifies each repo as MISSING / STALE / CURRENT / CUSTOMIZED.
#   - Opens at most one PR per repo per invocation.
#   - Idempotent: re-running with no changes produces no PRs.
#
# Source of truth for the canonical caller stub:
#   smartwatermelon/.github/workflow-templates/claude-blocking-review.yml
# at HEAD. The script extracts the @vX.Y.Z pin from that file and uses
# it as the target version.
#
# Requirements: gh CLI (authenticated, repo + workflow scopes), jq,
# base64, bash 4.0+, GNU grep/sed via PATH (works fine on macOS with
# stock /usr/bin/grep).
#
# Usage:
#   ./bulk-install-claude-review.sh [--dry-run|--apply] [--only owner/repo] [--verbose]

set -uo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  printf "Error: bash 4.0+ required (found %s). Run as: ./%s\n" \
    "${BASH_VERSION}" "${0##*/}" >&2
  exit 1
fi

# ── config ─────────────────────────────────────────────────────────────────────
TARGET_OWNER="smartwatermelon"
CANONICAL_REPO="smartwatermelon/.github"
CANONICAL_PATH="workflow-templates/claude-blocking-review.yml"
INSTALL_PATH=".github/workflows/claude-code-review.yml"
IGNORE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.claude-review-ignore"
PLAN_LINK="https://github.com/smartwatermelon/github-workflows/blob/main/docs/plans/2026-04-30-bulk-install-smartwatermelon-fleet.md"

# ── flag parsing ────────────────────────────────────────────────────────────────
APPLY=false
ONLY=""
VERBOSE=false

while [[ "$#" -gt 0 ]]; do
  case "${1}" in
    --dry-run) APPLY=false ;;
    --apply) APPLY=true ;;
    --only)
      shift
      ONLY="${1:-}"
      ;;
    --verbose) VERBOSE=true ;;
    -h | --help)
      sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      printf "Error: unknown argument '%s'\n" "${1}" >&2
      exit 2
      ;;
  esac
  shift
done

# ── formatting ──────────────────────────────────────────────────────────────────
ok() { printf "  ✅ %s\n" "${*}"; }
fail() { printf "  ❌ %s\n" "${*}"; }
warn() { printf "  ⚠️  %s\n" "${*}"; }
info() { ${VERBOSE} && printf "  ℹ  %s\n" "${*}" || true; }
note() { printf "  → %s\n" "${*}"; }

# ── load ignore list ────────────────────────────────────────────────────────────
declare -A IGNORED_REPOS=()
if [[ -f "${IGNORE_FILE}" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line// /}"
    [[ -z "${line}" ]] && continue
    IGNORED_REPOS["${line}"]=1
  done <"${IGNORE_FILE}"
fi

# ── fetch canonical stub & extract target version ─────────────────────────────
fetch_file() {
  local full="${1}" path="${2}"
  gh api "repos/${full}/contents/${path}" --jq '.content' 2>/dev/null \
    | tr -d '\n' | base64 -d 2>/dev/null
}

CANONICAL_CONTENT="$(fetch_file "${CANONICAL_REPO}" "${CANONICAL_PATH}")"
if [[ -z "${CANONICAL_CONTENT}" ]]; then
  fail "Could not fetch canonical stub from ${CANONICAL_REPO}/${CANONICAL_PATH}"
  exit 3
fi

TARGET_VERSION="$(echo "${CANONICAL_CONTENT}" \
  | grep -m1 -oE 'claude-blocking-review\.yml@[^[:space:]]+' \
  | sed 's/^.*@//')"

if [[ -z "${TARGET_VERSION}" ]]; then
  fail "Canonical stub does not contain a @version pin — aborting"
  exit 3
fi

# ── accumulators ─────────────────────────────────────────────────────────────────
declare -a REPOS_MISSING=()
declare -a REPOS_STALE=()
declare -a REPOS_CURRENT=()
declare -a REPOS_CUSTOMIZED=()
declare -a REPOS_LOCAL=()
declare -a REPOS_SKIPPED=()
declare -a REPOS_ERROR=()
declare -a PR_URLS=()

# ── helpers ─────────────────────────────────────────────────────────────────────
strip_comments() { echo "${1}" | grep -v '^[[:space:]]*#'; }

uses_blocking_review() {
  strip_comments "${1}" | grep -q "claude-blocking-review\.yml"
}

# Extract the @version pin from a workflow file (first match in non-comment lines)
extract_pin() {
  strip_comments "${1}" | grep -m1 -oE 'claude-blocking-review\.yml@[^[:space:]]+' \
    | sed 's/^.*@//'
}

# Detect local-path caller (uses ./<path> rather than a tagged reference)
uses_local_path() {
  strip_comments "${1}" | grep -qE 'uses:[[:space:]]*\./'
}

# Detect customization: caller has any of these non-trivial extras
has_customization() {
  echo "${1}" | grep -qE '^\s*(paths-ignore|paths|extra_instructions|model|timeout_minutes|env):' \
    || echo "${1}" | grep -q '\[skip-claude-review:'
}

# Find the workflow file referencing the blocking review (returns "path|sha")
find_caller_file() {
  local full="${1}"
  local files
  files="$(gh api "repos/${full}/contents/.github/workflows" \
    --jq '.[] | "\(.name)|\(.sha)"' 2>/dev/null || echo "")"
  while IFS='|' read -r name sha; do
    [[ -z "${name}" ]] && continue
    local content
    content="$(fetch_file "${full}" ".github/workflows/${name}")"
    if uses_blocking_review "${content}"; then
      printf "%s|%s\n" ".github/workflows/${name}" "${sha}"
      return 0
    fi
  done <<<"${files}"
  return 1
}

# ── PR-creation primitives ──────────────────────────────────────────────────────
# Open a PR adding/updating the install file. Args: full_repo, branch_name,
# commit_title, pr_title, pr_body, file_path, file_content, [existing_sha]
open_install_pr() {
  local full="${1}" branch="${2}" commit_title="${3}" pr_title="${4}" pr_body="${5}"
  local file_path="${6}" file_content="${7}" existing_sha="${8:-}"

  if ! ${APPLY}; then
    note "[dry-run] Would open PR: ${full} | branch=${branch} | file=${file_path}"
    return 0
  fi

  # Determine base branch
  local default_branch
  default_branch="$(gh api "repos/${full}" --jq '.default_branch' 2>/dev/null || echo "main")"

  # Get base SHA
  local base_sha
  base_sha="$(gh api "repos/${full}/git/refs/heads/${default_branch}" \
    --jq '.object.sha' 2>/dev/null)"
  if [[ -z "${base_sha}" ]]; then
    fail "Could not resolve base SHA for ${full}@${default_branch}"
    return 1
  fi

  # Create branch
  if ! gh api -X POST "repos/${full}/git/refs" \
    -f ref="refs/heads/${branch}" -f sha="${base_sha}" >/dev/null 2>&1; then
    # Already exists? Fail loudly so we don't accidentally re-push.
    fail "Branch ${branch} already exists on ${full} — aborting this repo"
    return 1
  fi

  # PUT file contents on the new branch
  local b64_content
  b64_content="$(printf "%s" "${file_content}" | base64 | tr -d '\n')"
  local put_payload
  if [[ -n "${existing_sha}" ]]; then
    put_payload="$(jq -n \
      --arg msg "${commit_title}" \
      --arg branch "${branch}" \
      --arg content "${b64_content}" \
      --arg sha "${existing_sha}" \
      '{message:$msg, branch:$branch, content:$content, sha:$sha}')"
  else
    put_payload="$(jq -n \
      --arg msg "${commit_title}" \
      --arg branch "${branch}" \
      --arg content "${b64_content}" \
      '{message:$msg, branch:$branch, content:$content}')"
  fi

  if ! gh api -X PUT "repos/${full}/contents/${file_path}" \
    --input - <<<"${put_payload}" >/dev/null 2>&1; then
    fail "Failed to PUT ${file_path} on ${full}@${branch}"
    return 1
  fi

  # Open PR
  local pr_url
  pr_url="$(gh pr create --repo "${full}" \
    --base "${default_branch}" \
    --head "${branch}" \
    --title "${pr_title}" \
    --body "${pr_body}" 2>/dev/null)"
  if [[ -z "${pr_url}" ]]; then
    fail "Failed to open PR on ${full} (${branch} created and file pushed; PR creation failed)"
    return 1
  fi
  ok "Opened ${pr_url}"
  PR_URLS+=("${pr_url}")
}

pr_body_template() {
  local action="${1}"
  cat <<EOF
[skip-claude-review: bulk-install]

This PR was generated by \`bulk-install-claude-review.sh\` from
[smartwatermelon/github-workflows](https://github.com/smartwatermelon/github-workflows).

**Action:** ${action}
**Target version:** \`${TARGET_VERSION}\`
**Plan:** ${PLAN_LINK}

The escape-hatch tag in this PR body causes the blocking-review workflow
to skip itself when it runs against this PR — necessary because the
workflow being installed/updated is what would otherwise gate the merge.

After merge, future PRs in this repo will be reviewed by the workflow
at the new version. Dependabot (if installed) will detect future bumps
via the github-actions ecosystem.
EOF
}

# ── per-repo processing ─────────────────────────────────────────────────────────
process_repo() {
  local repo="${1}"
  local full="${TARGET_OWNER}/${repo}"

  printf "\n── %s\n" "${full}"

  if [[ -n "${IGNORED_REPOS["${full}"]:-}" ]]; then
    note "Skipped (in .claude-review-ignore)"
    REPOS_SKIPPED+=("${full}")
    return
  fi

  # Find existing caller file (if any)
  local found
  found="$(find_caller_file "${full}" || true)"

  if [[ -z "${found}" ]]; then
    fail "MISSING — no workflow references claude-blocking-review.yml"
    REPOS_MISSING+=("${full}")
    if ${APPLY}; then
      local body
      body="$(pr_body_template "Install missing caller workflow")"
      open_install_pr "${full}" \
        "claude/install-blocking-review" \
        "ci: install claude-blocking-review caller (${TARGET_VERSION})" \
        "ci: install claude-blocking-review caller (${TARGET_VERSION})" \
        "${body}" \
        "${INSTALL_PATH}" \
        "${CANONICAL_CONTENT}"
    else
      note "[dry-run] Would open install PR (file: ${INSTALL_PATH}, version: ${TARGET_VERSION})"
    fi
    return
  fi

  local file_path file_sha
  IFS='|' read -r file_path file_sha <<<"${found}"

  local current_content
  current_content="$(fetch_file "${full}" "${file_path}")"

  if uses_local_path "${current_content}"; then
    ok "LOCAL — caller uses a local path reference (no remote pin to bump)"
    REPOS_LOCAL+=("${full}")
    return
  fi

  local current_pin
  current_pin="$(extract_pin "${current_content}")"

  if [[ -z "${current_pin}" ]]; then
    warn "ERROR — caller references claude-blocking-review.yml but no @version pin found"
    REPOS_ERROR+=("${full}")
    return
  fi

  if [[ "${current_pin}" == "${TARGET_VERSION}" ]]; then
    if has_customization "${current_content}"; then
      warn "CUSTOMIZED — on target (${current_pin}) but has caller-side customizations; skipping"
      REPOS_CUSTOMIZED+=("${full}")
    else
      ok "CURRENT — already on ${TARGET_VERSION}"
      REPOS_CURRENT+=("${full}")
    fi
    return
  fi

  fail "STALE — pinned at ${current_pin}, target is ${TARGET_VERSION}"
  REPOS_STALE+=("${full}")

  # Build new content: replace the pin in the existing file (preserves any
  # caller-side customizations that we'd otherwise overwrite). This is
  # different from MISSING, which uses the canonical stub verbatim.
  local new_content
  new_content="$(echo "${current_content}" \
    | sed -E "s|claude-blocking-review\.yml@[^[:space:]]+|claude-blocking-review.yml@${TARGET_VERSION}|")"

  if ${APPLY}; then
    local body
    body="$(pr_body_template "Bump pin from \`${current_pin}\` → \`${TARGET_VERSION}\`")"
    open_install_pr "${full}" \
      "claude/bump-blocking-review-${TARGET_VERSION}" \
      "ci: bump claude-blocking-review to ${TARGET_VERSION}" \
      "ci: bump claude-blocking-review to ${TARGET_VERSION}" \
      "${body}" \
      "${file_path}" \
      "${new_content}" \
      "${file_sha}"
  else
    note "[dry-run] Would open bump PR (file: ${file_path}, ${current_pin} → ${TARGET_VERSION})"
  fi
}

# ── main ────────────────────────────────────────────────────────────────────────
mode="DRY-RUN"
${APPLY} && mode="APPLY"

printf "\n══════════════════════════════════════════════════════════\n"
printf "  Bulk-install Claude Review (%s mode)\n" "${mode}"
printf "  Owner: %s\n" "${TARGET_OWNER}"
printf "  Canonical source: %s/%s\n" "${CANONICAL_REPO}" "${CANONICAL_PATH}"
printf "  Target version: %s\n" "${TARGET_VERSION}"
printf "══════════════════════════════════════════════════════════\n"

if [[ -n "${ONLY}" ]]; then
  if [[ "${ONLY}" != ${TARGET_OWNER}/* ]]; then
    fail "--only must be in form ${TARGET_OWNER}/<repo>; got '${ONLY}'"
    exit 2
  fi
  process_repo "${ONLY#"${TARGET_OWNER}/"}"
else
  repos="$(gh repo list "${TARGET_OWNER}" --no-archived --json name --limit 300 \
    --jq '.[].name' 2>/dev/null || echo "")"
  if [[ -z "${repos}" ]]; then
    fail "Could not list repos for ${TARGET_OWNER}"
    exit 3
  fi
  while IFS= read -r repo; do
    [[ -z "${repo}" ]] && continue
    process_repo "${repo}"
  done <<<"${repos}"
fi

# ── final summary ───────────────────────────────────────────────────────────────
printf "\n\n══════════════════════════════════════════════════════════\n"
printf "  SUMMARY (%s)\n" "${mode}"
printf "══════════════════════════════════════════════════════════\n"
printf "  CURRENT     (no action): %d\n" "${#REPOS_CURRENT[@]}"
printf "  CUSTOMIZED  (skipped):   %d\n" "${#REPOS_CUSTOMIZED[@]}"
printf "  LOCAL       (no pin):    %d\n" "${#REPOS_LOCAL[@]}"
printf "  SKIPPED     (ignore):    %d\n" "${#REPOS_SKIPPED[@]}"
printf "  STALE       (will bump): %d\n" "${#REPOS_STALE[@]}"
printf "  MISSING     (will add):  %d\n" "${#REPOS_MISSING[@]}"
printf "  ERROR:                   %d\n" "${#REPOS_ERROR[@]}"

list_section() {
  local title="${1}"
  shift
  local -a items=("${@}")
  [[ "${#items[@]}" -eq 0 ]] && return
  printf "\n  %s:\n" "${title}"
  for r in "${items[@]}"; do printf "    - %s\n" "${r}"; done
}

list_section "MISSING" "${REPOS_MISSING[@]+"${REPOS_MISSING[@]}"}"
list_section "STALE" "${REPOS_STALE[@]+"${REPOS_STALE[@]}"}"
list_section "CUSTOMIZED" "${REPOS_CUSTOMIZED[@]+"${REPOS_CUSTOMIZED[@]}"}"
list_section "ERROR" "${REPOS_ERROR[@]+"${REPOS_ERROR[@]}"}"

if [[ "${#PR_URLS[@]}" -gt 0 ]]; then
  printf "\n  PRs opened:\n"
  for u in "${PR_URLS[@]}"; do printf "    %s\n" "${u}"; done
fi

if ! ${APPLY} && [[ "${#REPOS_MISSING[@]}" -gt 0 || "${#REPOS_STALE[@]}" -gt 0 ]]; then
  printf "\n  Re-run with --apply to actually open PRs.\n"
fi

printf "\n══════════════════════════════════════════════════════════\n\n"
