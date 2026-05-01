#!/usr/bin/env bash
# Phases 1-2 of docs/plans/2026-04-30-required-workflows-nightowlstudiollc.md
#
# Creates the caller stub workflow in nightowlstudiollc/.github and an
# org-level Repository Ruleset in `evaluate` (audit-only) mode targeting
# a single bellwether repo. Safe to re-run idempotently for the workflow
# file; ruleset creation is one-shot (manage subsequent edits in the UI
# or via `gh api -X PUT orgs/.../rulesets/<id>`).
#
# Requires: gh CLI authenticated with `admin:org` scope on nightowlstudiollc.
# Verify with: gh auth status   (look for "admin:org" in scopes)

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG — review and adjust before running
# ---------------------------------------------------------------------------
ORG="nightowlstudiollc"
DOTGITHUB_REPO="${ORG}/.github"
DOTGITHUB_LOCAL="$HOME/Developer/nightowlstudiollc.github" # ← local clone path
BELLWETHER_REPO="juliet-cleaning"                          # ← set the single repo for the audit week
RULESET_NAME="Claude blocking review (eval)"
WORKFLOW_PATH=".github/workflows/claude-required-review.yml"
WORKFLOW_REF="refs/heads/main"
# Reusable workflow pin: @v3.0.0 (hardcoded in the heredoc below).
# Gate strength: audit-only (this script wires evaluate mode). Moderate/strong
# are the next steps after the audit week — flip enforcement to 'active', and
# for strong, add a required_status_checks rule on the ruleset.

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
echo "[preflight] verifying gh auth scopes…"
if ! gh auth status 2>&1 | grep -q "admin:org"; then
  echo "  ERROR: gh token lacks admin:org scope. Run:"
  echo "         gh auth refresh -h github.com -s admin:org"
  exit 1
fi
echo "  OK"

echo "[preflight] verifying ${DOTGITHUB_REPO} exists…"
gh repo view "$DOTGITHUB_REPO" --json name >/dev/null
echo "  OK"

echo "[preflight] verifying bellwether ${ORG}/${BELLWETHER_REPO} exists and has CLAUDE_CODE_OAUTH_TOKEN…"
gh repo view "${ORG}/${BELLWETHER_REPO}" --json name >/dev/null
if ! gh secret list -R "${ORG}/${BELLWETHER_REPO}" | grep -q CLAUDE_CODE_OAUTH_TOKEN; then
  echo "  ERROR: ${ORG}/${BELLWETHER_REPO} missing CLAUDE_CODE_OAUTH_TOKEN."
  echo "         Run /install-github-app from a Claude Code CLI session in that repo."
  exit 1
fi
echo "  OK"

# ---------------------------------------------------------------------------
# Phase 1 — Create caller stub in nightowlstudiollc/.github (via local clone)
# ---------------------------------------------------------------------------
echo "[phase 1] verifying local clone at ${DOTGITHUB_LOCAL}…"
if [[ ! -d "${DOTGITHUB_LOCAL}/.git" ]]; then
  echo "  ERROR: ${DOTGITHUB_LOCAL} is not a git repo. Clone it first:"
  echo "         git clone git@github.com:${DOTGITHUB_REPO}.git ${DOTGITHUB_LOCAL}"
  exit 1
fi

# Verify clean state and on main
git -C "$DOTGITHUB_LOCAL" fetch origin --quiet
CURRENT_BRANCH=$(git -C "$DOTGITHUB_LOCAL" branch --show-current)
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  echo "  ERROR: local clone is on '${CURRENT_BRANCH}', not main. Switch first."
  exit 1
fi
DIRTY=$(git -C "$DOTGITHUB_LOCAL" status --porcelain)
if [[ -n "$DIRTY" ]]; then
  echo "  ERROR: local clone has uncommitted changes. Stash or commit them first."
  exit 1
fi
git -C "$DOTGITHUB_LOCAL" pull --ff-only --quiet
echo "  OK (on main, clean, up to date)"

echo "[phase 1] writing ${WORKFLOW_PATH}…"
mkdir -p "${DOTGITHUB_LOCAL}/.github/workflows"
cat >"${DOTGITHUB_LOCAL}/${WORKFLOW_PATH}" <<'YML'
name: Claude Required Review

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
    uses: smartwatermelon/github-workflows/.github/workflows/claude-blocking-review.yml@v3.0.0
    with:
      pr_number: ${{ github.event.pull_request.number }}
    secrets:
      claude_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
YML

POST_WRITE_STATUS=$(git -C "$DOTGITHUB_LOCAL" status --porcelain)
if [[ -n "$POST_WRITE_STATUS" ]]; then
  git -C "$DOTGITHUB_LOCAL" add "${WORKFLOW_PATH}"
  # --no-verify: bypasses the local "no commits to main" hook. Authorized by
  # Andrew for this operational script (the .github repo's main branch is the
  # canonical location for org-level workflow files; no feature-branch flow).
  git -C "$DOTGITHUB_LOCAL" commit --no-verify -m "feat: Claude Required Review caller stub for org ruleset" --quiet
  echo "  committed"
fi

# Push if local is ahead of origin (covers both fresh commit and prior-run cases)
AHEAD=$(git -C "$DOTGITHUB_LOCAL" rev-list --count origin/main..HEAD)
if [[ "$AHEAD" -gt 0 ]]; then
  git -C "$DOTGITHUB_LOCAL" push --no-verify origin main --quiet
  echo "  OK (pushed ${AHEAD} commit(s))"
else
  echo "  OK (already in sync with origin)"
fi

# ---------------------------------------------------------------------------
# Phase 2 — Create org ruleset in evaluate mode, scoped to bellwether
# ---------------------------------------------------------------------------
DOTGITHUB_REPO_ID=$(gh api "repos/${DOTGITHUB_REPO}" --jq '.id')
echo "[phase 2] ${DOTGITHUB_REPO} repo id: ${DOTGITHUB_REPO_ID}"

# Check whether a ruleset with this name already exists
EXISTING_RULESET_ID=$(gh api "orgs/${ORG}/rulesets" --jq ".[] | select(.name == \"${RULESET_NAME}\") | .id" || true)

if [[ -n "$EXISTING_RULESET_ID" ]]; then
  echo "[phase 2] ruleset \"${RULESET_NAME}\" already exists (id=${EXISTING_RULESET_ID}); skipping creation."
  echo "         Edit at: https://github.com/organizations/${ORG}/settings/rules/${EXISTING_RULESET_ID}"
  exit 0
fi

RULESET_PAYLOAD=$(
  cat <<JSON
{
  "name": "${RULESET_NAME}",
  "target": "branch",
  "enforcement": "evaluate",
  "conditions": {
    "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] },
    "repository_name": { "include": ["${BELLWETHER_REPO}"], "exclude": [], "protected": true }
  },
  "rules": [
    {
      "type": "workflows",
      "parameters": {
        "workflows": [
          {
            "repository_id": ${DOTGITHUB_REPO_ID},
            "path": "${WORKFLOW_PATH}",
            "ref": "${WORKFLOW_REF}"
          }
        ]
      }
    }
  ],
  "bypass_actors": []
}
JSON
)

echo "[phase 2] creating ruleset (evaluate mode, scoped to ${BELLWETHER_REPO})…"
RULESET_ID=$(gh api -X POST "orgs/${ORG}/rulesets" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  --input - \
  --jq '.id' <<<"$RULESET_PAYLOAD")

echo "  OK — ruleset id: ${RULESET_ID}"
echo
echo "Manage at: https://github.com/organizations/${ORG}/settings/rules/${RULESET_ID}"
echo "Insights:  https://github.com/organizations/${ORG}/settings/rules/${RULESET_ID}/insights"
echo
echo "Next: open a PR on ${ORG}/${BELLWETHER_REPO}, watch Insights for runs."
echo "After ~1 clean week → expand scope and/or flip enforcement to 'active'."
