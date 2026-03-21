# Migration Plan: All Repos to Blocking Review

**Date:** 2026-03-20
**Author:** Claude (session with Andrew)
**Status:** Planned

## Context

The Anthropic `code-review` plugin (`code-review@claude-code-plugins`) has no
turn limits, timeout, or scope constraints. On transmission-filebot PR #23, this
caused a 20-turn, $1.00, 11-minute review of a 109-line diff.

PR #17 (merged 2026-03-20) hardened `claude-blocking-review.yml` with cost
guards (`max_turns: 6`, `timeout_minutes: 4`, input validation, scope
constraints). PR #25 migrated transmission-filebot as proof-of-concept —
review dropped to 30 seconds / ~$0.03.

**Goal:** Migrate all 19 remaining plugin-based repos to the blocking review
workflow, across both orgs.

## Scope

### Repos to Migrate (19 total)

#### smartwatermelon org (14 repos)

| Repo | Has CLAUDE.md | Has claude.yml (assistant) | Other CI |
|------|:---:|:---:|----------|
| claude-wrapper | no | yes (direct) | — |
| crazy-larry | no | yes (direct) | — |
| dotfiles | no | yes (direct) | — |
| homebrew-tap | no | yes (direct) | test-casks.yml |
| lock-sync | no | yes (direct) | — |
| mac-dev-server-setup | no | yes (direct) | ci.yml |
| mac-server-setup | yes | yes (direct) | ci.yml |
| pre-commit-testing | no | yes (direct) | — |
| projectinsomnia | no | yes (direct) | — |
| slack-mcp | yes | yes (direct) | ci.yml |
| smartwatermelon-marketplace | no | yes (direct) | — |
| swift-progress-indicator | no | yes (direct) | release.yml |
| tensegrity | yes | yes (direct) | ci.yml |
| tilsit-caddy | yes | yes (direct) | — |

#### nightowlstudiollc org (5 repos)

| Repo | Has CLAUDE.md | Has claude.yml (assistant) | Other CI |
|------|:---:|:---:|----------|
| amelia-boone | yes | yes (direct) | ci.yml |
| financial-agent | yes | yes (direct) | — |
| juliet-cleaning | yes | yes (direct) | html-validation.yml |
| vpn-lan-bridge | yes | yes (direct) | — |
| yesteryear | yes | yes (direct) | ci.yml |

### Already Migrated (reference)

| Repo | Org | Status |
|------|-----|--------|
| kebab-tax | nightowlstudiollc | blocking review + extra_instructions |
| transmission-filebot | nightowlstudiollc | blocking review (PR #25, 2026-03-20) |

## What Changes Per Repo

Each repo needs up to 3 file changes:

### 1. Replace `claude-code-review.yml` (required)

**Before** (plugin-based, ~45 lines):

```yaml
name: Claude Code Review
on:
  pull_request:
    types: [opened, synchronize, ready_for_review, reopened]
jobs:
  claude-review:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: read
      issues: read
      id-token: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 1
      - uses: anthropics/claude-code-action@v1
        with:
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          plugin_marketplaces: 'https://github.com/anthropics/claude-code.git'
          plugins: 'code-review@claude-code-plugins'
          prompt: '/code-review:code-review ...'
```

**After** (blocking review caller, ~20 lines):

```yaml
name: Claude Code Review

permissions:
  contents: read
  pull-requests: write
  issues: write
  id-token: write

on:
  pull_request:
    types: [opened, synchronize, ready_for_review, reopened]

jobs:
  claude-review:
    uses: smartwatermelon/github-workflows/.github/workflows/claude-blocking-review.yml@v1
    with:
      pr_number: ${{ github.event.pull_request.number }}
      # extra_instructions: |
      #   Repo-specific guidance here.
    secrets:
      claude_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

### 2. Replace `claude.yml` assistant workflow (recommended)

Most repos have a direct `claude.yml` that inlines the full claude-code-action
config (~50 lines). Replace with a reusable workflow call (~15 lines).

**Before** (direct, ~50 lines):

```yaml
name: Claude Code
on:
  issue_comment: ...
  pull_request_review_comment: ...
  # etc
jobs:
  claude:
    if: ... author_association guard ...
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: anthropics/claude-code-action@v1
```

**After** (reusable workflow caller, ~15 lines):

```yaml
name: Claude Code
on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]
  issues:
    types: [opened, assigned]
  pull_request_review:
    types: [submitted]

jobs:
  claude:
    if: |
      (github.event_name == 'issue_comment' && contains(github.event.comment.body, '@claude') && contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.comment.author_association)) ||
      (github.event_name == 'pull_request_review_comment' && contains(github.event.comment.body, '@claude') && contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.comment.author_association)) ||
      (github.event_name == 'pull_request_review' && contains(github.event.review.body, '@claude') && contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.review.author_association)) ||
      (github.event_name == 'issues' && (contains(github.event.issue.body, '@claude') || contains(github.event.issue.title, '@claude')) && contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.issue.author_association))
    uses: smartwatermelon/github-workflows/.github/workflows/claude-assistant.yml@v1
    secrets:
      claude_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

**Note:** The `if:` guard MUST stay in the caller workflow — the reusable
workflow cannot enforce it. Removing it would let any GitHub user inject
instructions via issues.

### 3. Add `extra_instructions` for repos with CLAUDE.md (optional)

For the 10 repos with project-specific CLAUDE.md files, extract key review
guidance into `extra_instructions`. Keep it brief — the reviewer already reads
CLAUDE.md from the checkout. Only add instructions that are specifically
relevant to code review (not general development guidance).

## Execution Strategy

### Approach: Batched PRs with scripted migration

A script can automate the mechanical parts. Each repo gets a branch + PR.

### nightowlstudiollc token requirement

The 5 nightowlstudiollc repos require a different GitHub token. Options:

1. **Separate session** — run the migration script with the nightowlstudiollc
   token configured
2. **Manual** — Andrew creates the PRs directly for those 5 repos
3. **Org-level secret** — if `CLAUDE_CODE_OAUTH_TOKEN` is already an org
   secret visible to all repos, no token change needed for the workflow itself;
   only the `gh` CLI needs access to create PRs

### Migration script outline

```bash
#!/usr/bin/env bash
# migrate-to-blocking-review.sh
#
# Usage: ./migrate-to-blocking-review.sh <repo-path> [extra_instructions]
#
# Creates a branch, replaces claude-code-review.yml and claude.yml,
# commits, pushes, and opens a PR.

set -euo pipefail

REPO_PATH="$1"
EXTRA="${2:-}"
REPO_NAME=$(basename "$REPO_PATH")
BRANCH="claude/migrate-blocking-review-$(date +%Y%m%d)"

cd "$REPO_PATH"
git checkout -b "$BRANCH" origin/main

# 1. Replace claude-code-review.yml
cat > .github/workflows/claude-code-review.yml << 'WORKFLOW'
name: Claude Code Review

permissions:
  contents: read
  pull-requests: write
  issues: write
  id-token: write

on:
  pull_request:
    types: [opened, synchronize, ready_for_review, reopened]

jobs:
  claude-review:
    uses: smartwatermelon/github-workflows/.github/workflows/claude-blocking-review.yml@v1
    with:
      pr_number: ${{ github.event.pull_request.number }}
    secrets:
      claude_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
WORKFLOW

# 2. Replace claude.yml with reusable workflow caller
cat > .github/workflows/claude.yml << 'WORKFLOW'
name: Claude Code

on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]
  issues:
    types: [opened, assigned]
  pull_request_review:
    types: [submitted]

jobs:
  claude:
    if: |
      (github.event_name == 'issue_comment' && contains(github.event.comment.body, '@claude') && contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.comment.author_association)) ||
      (github.event_name == 'pull_request_review_comment' && contains(github.event.comment.body, '@claude') && contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.comment.author_association)) ||
      (github.event_name == 'pull_request_review' && contains(github.event.review.body, '@claude') && contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.review.author_association)) ||
      (github.event_name == 'issues' && (contains(github.event.issue.body, '@claude') || contains(github.event.issue.title, '@claude')) && contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.issue.author_association))
    uses: smartwatermelon/github-workflows/.github/workflows/claude-assistant.yml@v1
    secrets:
      claude_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
WORKFLOW

# 3. Commit and push
git add .github/workflows/claude-code-review.yml .github/workflows/claude.yml
git commit -m "feat: migrate to centralized Claude workflows

Replace plugin-based claude-code-action with reusable workflows from
smartwatermelon/github-workflows:
- claude-blocking-review.yml: cost-guarded review with BLOCK/PASS verdicts
- claude-assistant.yml: @claude interactive assistant

Adds max_turns limit (6), timeout (4min), and scope constraints to
prevent runaway API costs."

git push -u origin "$BRANCH"
gh pr create --fill
```

### Execution order

**Batch 1 — Low-risk repos (no CLAUDE.md, no other CI):**

1. claude-wrapper
2. crazy-larry
3. dotfiles
4. lock-sync
5. pre-commit-testing
6. projectinsomnia
7. smartwatermelon-marketplace

**Batch 2 — Repos with other CI (verify no conflicts):**
8. homebrew-tap
9. mac-dev-server-setup
10. mac-server-setup
11. swift-progress-indicator

**Batch 3 — Repos with CLAUDE.md (may want extra_instructions):**
12. slack-mcp
13. tensegrity
14. tilsit-caddy

**Batch 4 — nightowlstudiollc org (requires different token):**
15. amelia-boone
16. financial-agent
17. juliet-cleaning
18. vpn-lan-bridge
19. yesteryear

### Post-migration per repo

After each PR is merged:

1. Verify the blocking review runs on the next PR (<4 min, <=6 turns)
2. **Update branch protection** to require the new status check
3. Document the `[skip-claude-review: reason]` escape hatch in repo if needed

### Branch protection (required per-repo)

The migration changes the status check name:

- **Old** (plugin-based): `Claude Code Review / claude-review` (from step ID)
- **New** (reusable workflow): `Claude Code Review / claude-review / run-review`

Any existing branch protection referencing the old check name must be updated.
Repos without branch protection for reviews should have it added.

**Important:** The GitHub API's branch protection endpoint is a full
replacement — a PUT overwrites all settings. The migration script must
GET the current protection first, merge in the new check, and PUT back.

```bash
# Read current protection (may 404 if none exists)
CURRENT=$(gh api repos/OWNER/REPO/branches/main/protection 2>/dev/null || echo "{}")

# If protection exists: add/replace the check in the existing config
# If no protection: create minimal config with just the review check

# The script should handle both cases:
#   1. Remove old check name if present
#   2. Add new check name: "Claude Code Review / claude-review / run-review"
#   3. Preserve all other existing checks and settings
```

The migration script (above) should include a `--with-branch-protection`
flag that handles this automatically, or a separate
`update-branch-protection.sh` script that runs after merge.

**Repos that need the old check removed AND new check added:**

- Any repo that currently has `Claude Code Review / claude-review` in
  branch protection (audit with `claude-review-audit.sh`)

**Repos that need the new check added (no existing review check):**

- All other repos getting blocking enforcement for the first time

## Rollback

If a migrated repo has issues:

1. Revert the PR (creates a revert PR with the old workflow files)
2. Or: replace `claude-code-review.yml` with the original plugin version

The `[skip-claude-review: reason]` escape hatch in the blocking review
means a broken review never blocks merges permanently.

## Success Criteria

- All 19 repos use `claude-blocking-review.yml@v1` for code review
- All 19 repos use `claude-assistant.yml@v1` for @claude interactions
- All 19 repos have branch protection requiring `Claude Code Review / claude-review / run-review`
- No review takes >4 minutes or >6 turns on a typical PR
- Review cost per PR < $0.15 (down from potential $1+)
- No regressions in existing CI workflows
- Old `Claude Code Review / claude-review` check name removed from all branch protection rules

## Estimated Effort

- Script creation and testing: 1 session
- Batch 1-3 (14 smartwatermelon repos): 1 session (scripted)
- Batch 4 (5 nightowlstudiollc repos): 1 session (different token)
- Post-migration verification: ongoing as PRs land
- Branch protection setup: optional, per-repo as desired
