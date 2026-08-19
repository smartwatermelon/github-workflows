#!/usr/bin/env bash
# EMERGENCY RESTORATION: re-install per-repo claude-blocking-review.yml on
# every active NightOwl repo. This undoes today's removal-side cleanup so that
# Claude blocking review fires on PRs again — independent of the (still-broken)
# org ruleset, which remains disabled.
#
# Strategy: local clone + branch + push + PR + auto-merge for each repo. The
# workflow file is added in the PR head, GitHub runs it on the PR (same-repo
# PRs use head workflows), the resulting `claude-review / run-review` check
# satisfies the per-repo branch protection, auto-merge fires.

set -euo pipefail

ORG="nightowlstudiollc"
BRANCH="chore/restore-claude-blocking-review"
WORK_DIR="/tmp/restore-blocking-review"
IGNORE_FILE="/Volumes/extra-vieille/Workspaces/github-workflows/.claude-review-ignore"

# Canonical workflow content (matches nightowlstudiollc/.github/workflow-templates/claude-blocking-review.yml)
read -r -d '' WORKFLOW_CONTENT <<'YML' || true
name: Claude Blocking Review

on:
  pull_request:
    types: [opened, synchronize, ready_for_review, reopened]

permissions:
  contents: read
  pull-requests: write
  issues: write
  id-token: write

jobs:
  claude-review:
    # Floating @v3, not an exact @v3.x.y pin. Exact pins are immutable, so a
    # caller pinned to one silently opts out of every security fix published
    # afterwards — that is how ~19 smartwatermelon repos kept resolving to a
    # claude-code-action vulnerable to GHSA-8q5r-mmjf-575q. This template
    # previously carried @v3.0.0 and would have deployed that same defect
    # across every NightOwl repo it touched.
    uses: smartwatermelon/github-workflows/.github/workflows/claude-blocking-review.yml@v3
    with:
      pr_number: ${{ github.event.pull_request.number }}
    secrets:
      claude_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
YML

mkdir -p "$WORK_DIR"

# Enumerate active NightOwl repos dynamically (excludes archived, .github,
# and any repo in .claude-review-ignore). Using dynamic discovery so a repo
# added in the last hours isn't silently skipped.
# Declare before mapfile so the array exists unconditionally, matching the
# ALL_REPOS handling below. mapfile does declare an empty array even when its
# input is empty (verified), so this is belt-and-braces rather than a fix for
# a live unbound-variable path -- but it makes the invariant independent of
# that bash subtlety, which is what the loop below relies on under `set -u`.
IGNORED=()
mapfile -t IGNORED < <(grep -v '^#' "$IGNORE_FILE" 2>/dev/null | grep -v '^$' || true)
is_ignored() {
  local repo="$1"
  # Return early rather than looping over "${IGNORED[@]:-}": on an empty array
  # that expands to a single empty string, not to nothing, so the loop ran one
  # spurious iteration with i="". Never a false positive (no repo is named "")
  # but wrong, and the `:-` obscured that the array is always set. See #139.
  if [[ ${#IGNORED[@]} -eq 0 ]]; then
    return 1
  fi
  for i in "${IGNORED[@]}"; do
    [[ "$i" == "${ORG}/${repo}" ]] && return 0
  done
  return 1
}

REPO_LIST=$(gh repo list "$ORG" --limit 1000 --json name,isArchived --jq '.[] | select(.isArchived | not) | .name')
[[ -z "$REPO_LIST" ]] && {
  echo "ERROR: gh repo list returned no repos for ${ORG}"
  exit 1
}
mapfile -t ALL_REPOS <<<"$REPO_LIST"
[[ ${#ALL_REPOS[@]} -eq 1 && -z "${ALL_REPOS[0]}" ]] && ALL_REPOS=()

REPOS=()
for r in "${ALL_REPOS[@]}"; do
  [[ "$r" == ".github" ]] && continue
  is_ignored "$r" && continue
  REPOS+=("$r")
done
echo "Active candidate repos (${#REPOS[@]}): ${REPOS[*]}"

OPENED=()
SKIPPED=()
RECOVERED=()
FAILED=()

# Per-repo restoration as a function — runs with `set -e` (inherited);
# failures inside cause the function to return non-zero, and the for-loop's
# `if !` keeps the script alive across repos.
restore_repo() {
  local repo="$1"
  local default_branch existing_pr clone

  default_branch=$(gh repo view "${ORG}/${repo}" --json defaultBranchRef --jq '.defaultBranchRef.name')

  # Idempotency check #1: file already on default branch
  if gh api "repos/${ORG}/${repo}/contents/.github/workflows/claude-blocking-review.yml?ref=${default_branch}" --jq '.path' >/dev/null 2>&1; then
    echo "  already restored on ${default_branch} (skip)"
    SKIPPED+=("${ORG}/${repo}")
    return 0
  fi

  # Idempotency check #2: PR already open from a prior partial run
  existing_pr=$(gh pr list --repo "${ORG}/${repo}" --head "$BRANCH" --state open --json url --jq '.[0].url' 2>/dev/null || true)
  if [[ -n "$existing_pr" ]]; then
    echo "  PR already exists: ${existing_pr} — re-attempting auto-merge"
    if ! merge_err=$(command gh pr merge --auto --squash --delete-branch "$existing_pr" 2>&1); then
      if [[ "$merge_err" == *"already has auto-merge enabled"* ]]; then
        echo "    auto-merge already enabled (idempotent)"
      else
        echo "    auto-merge re-attempt FAILED: ${merge_err}"
        FAILED+=("${ORG}/${repo} (auto-merge-retry)")
        return 1
      fi
    fi
    RECOVERED+=("$existing_pr")
    return 0
  fi

  # Idempotency check #3: branch exists on remote but no open PR (orphan from
  # a previous failed run). Delete it so the fresh-clone path below works.
  if gh api "repos/${ORG}/${repo}/git/ref/heads/${BRANCH}" --jq '.object.sha' >/dev/null 2>&1; then
    echo "  orphan remote branch detected — deleting before fresh attempt"
    gh api -X DELETE "repos/${ORG}/${repo}/git/refs/heads/${BRANCH}" >/dev/null
  fi

  # Fresh path: clone, branch, write file, commit, push, PR, auto-merge
  #
  # Guard before the rm: `set -u` catches an *unset* variable but not an
  # *empty* one, and ALL_REPOS is built from command output (see the
  # empty-element check at the top). An empty $repo would make clone
  # "${WORK_DIR}/" and this rm would wipe the whole work dir instead of one
  # clone. Refuse rather than delete a path we did not intend to build.
  if [[ -z "${WORK_DIR:-}" || -z "${repo:-}" ]]; then
    echo "  FATAL: refusing to remove clone dir — WORK_DIR or repo is empty" >&2
    return 1
  fi
  # Reject any repo name that is not a single plain path segment. A textual
  # "starts with $WORK_DIR/" check is not enough: "../escape" satisfies it
  # while resolving outside the work dir entirely. GitHub repo names are
  # limited to [A-Za-z0-9._-], so anything else is either a bug upstream or
  # an attempt to traverse.
  if [[ ! "$repo" =~ ^[A-Za-z0-9._-]+$ || "$repo" == "." || "$repo" == ".." ]]; then
    echo "  FATAL: refusing to remove clone dir — unsafe repo name '${repo}'" >&2
    return 1
  fi
  clone="${WORK_DIR}/${repo}"
  rm -rf -- "$clone"
  git clone --depth=1 "git@github.com:${ORG}/${repo}.git" "$clone" --quiet
  git -C "$clone" checkout -b "$BRANCH" --quiet
  mkdir -p "${clone}/.github/workflows"
  printf '%s\n' "$WORKFLOW_CONTENT" >"${clone}/.github/workflows/claude-blocking-review.yml"
  git -C "$clone" add .github/workflows/claude-blocking-review.yml
  # Commit normally — hooks are NOT bypassed here. This previously passed a
  # verify-skipping flag, which the repo's own policy forbids and which
  # silently disabled any commit hooks the target repo installs. The content
  # is a fixed template, so there is nothing a hook would legitimately need
  # to reject; if one does reject it, that is signal worth seeing rather
  # than suppressing.
  git -C "$clone" commit --quiet -m "chore: restore claude-blocking-review caller

Restoring per-repo blocking-review caller after the org ruleset rollout was
paused. Until the ruleset's workflow firing behavior is validated, the per-repo
file is the reliable mechanism for ensuring Claude reviews PRs."
  git -C "$clone" push -u origin "$BRANCH" --quiet

  # gh pr create does NOT support --json; capture combined stdout+stderr
  # and grep out the URL line. On success the URL appears on its own line.
  local pr_url create_out
  if ! create_out=$(gh pr create --repo "${ORG}/${repo}" --base "$default_branch" --head "$BRANCH" \
    --title "chore: restore claude-blocking-review caller" \
    --body "Restoring per-repo Claude blocking review after today's org-ruleset rollout was paused. The org ruleset (id 15802253) is currently disabled pending investigation; until then, the per-repo caller is the reliable gate." \
    2>&1); then
    echo "  gh pr create FAILED: ${create_out}"
    FAILED+=("${ORG}/${repo} (pr-create)")
    return 1
  fi
  pr_url=$(printf '%s\n' "$create_out" | grep -oE "https://github\\.com/${ORG}/${repo}/pull/[0-9]+" | tail -1)
  if [[ -z "$pr_url" ]]; then
    echo "  gh pr create succeeded but no URL found in output:"
    echo "${create_out}" | sed 's/^/    /'
    FAILED+=("${ORG}/${repo} (pr-url-not-found)")
    return 1
  fi
  echo "  PR: ${pr_url}"
  OPENED+=("$pr_url")

  if ! merge_err=$(command gh pr merge --auto --squash --delete-branch "$pr_url" 2>&1); then
    if [[ "$merge_err" == *"already has auto-merge enabled"* ]]; then
      :
    else
      echo "  auto-merge FAILED: ${merge_err}"
      FAILED+=("${ORG}/${repo} (auto-merge)")
      return 1
    fi
  fi
}

FIRST_REPO_DONE=0
for repo in "${REPOS[@]}"; do
  echo
  echo "=== ${ORG}/${repo} ==="
  if ! restore_repo "$repo"; then
    if [[ $FIRST_REPO_DONE -eq 0 ]]; then
      echo
      echo "ABORT: first repo failed — likely a systemic bug, not a per-repo issue."
      echo "Investigate before re-running. Subsequent repos NOT attempted."
      break
    fi
    echo "  → continuing to next repo"
  fi
  FIRST_REPO_DONE=1
  # Pace writes to avoid GitHub secondary rate limit on content mutations
  sleep 2
done

echo
echo "=== Done ==="
echo "PRs opened (${#OPENED[@]}):"
printf '  %s\n' "${OPENED[@]:-(none)}"
if [[ ${#RECOVERED[@]} -gt 0 ]]; then
  echo
  echo "Pre-existing PRs recovered (${#RECOVERED[@]}):"
  printf '  %s\n' "${RECOVERED[@]}"
fi
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo
  echo "Already restored, skipped (${#SKIPPED[@]}):"
  printf '  %s\n' "${SKIPPED[@]}"
fi
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo
  echo "FAILED (${#FAILED[@]}) — investigate before re-running:"
  printf '  %s\n' "${FAILED[@]}"
fi
echo
echo "Auto-merge will fire on each PR once its claude-review / run-review check passes."
echo "Workspace: ${WORK_DIR} — safe to delete after runs."
