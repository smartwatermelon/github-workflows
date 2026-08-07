#!/usr/bin/env bash
# new-smartwatermelon-repo.sh
#
# One-command bootstrap for new smartwatermelon/* repos. Part C of the fleet
# reusable-workflows plan: smartwatermelon is a User account, so it can't use
# GitHub's org-only workflow-templates picker or Repository Rulesets to
# auto-attach workflows on repo creation. `gh repo create --template` is a
# general repo feature (not org-gated) and gets the workflow files in place
# at creation time; this script also handles the one repo-setting a template
# cannot seed (can_approve_pull_request_reviews, needed for
# dependabot-auto-merge.yml's approval step — see issue #87).
#
# What this does NOT do: install the CLAUDE_CODE_OAUTH_TOKEN secret. There is
# no way to script that — it requires running `/install-github-app` from
# Claude Code, a one-time interactive step. This script prints a reminder.
#
# Usage:
#   ./new-smartwatermelon-repo.sh <name> [--private]
#
# Examples:
#   ./new-smartwatermelon-repo.sh my-new-thing
#   ./new-smartwatermelon-repo.sh my-new-thing --private

set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  printf "Error: bash 4.0+ required (found %s). Run as: ./%s\n" \
    "${BASH_VERSION}" "${0##*/}" >&2
  exit 1
fi

TEMPLATE="smartwatermelon/repo-template"
OWNER="smartwatermelon"

usage() {
  printf "Usage: %s <name> [--private]\n" "${0##*/}" >&2
  exit 1
}

[[ $# -ge 1 ]] || usage
NAME="$1"
shift

VISIBILITY="--public"
if [[ "${1:-}" == "--private" ]]; then
  VISIBILITY="--private"
fi

REPO="${OWNER}/${NAME}"

echo "==> Creating ${REPO} from ${TEMPLATE} (${VISIBILITY#--})"
gh repo create "${REPO}" --template "${TEMPLATE}" "${VISIBILITY}"

echo "==> Setting can_approve_pull_request_reviews=true (required for dependabot-auto-merge.yml)"
gh api -X PUT "repos/${REPO}/actions/permissions/workflow" \
  -F can_approve_pull_request_reviews=true \
  -f default_workflow_permissions=read

echo ""
echo "==> ${REPO} created and configured. One manual step remains:"
echo ""
echo "    Run /install-github-app from Claude Code (or add the"
echo "    CLAUDE_CODE_OAUTH_TOKEN secret manually under Settings ->"
echo "    Secrets and variables -> Actions) so claude.yml and"
echo "    claude-code-review.yml can run."
echo ""
echo "    Optional: add 'claude-review / run-review' as a required"
echo "    status check under Settings -> Branches."
