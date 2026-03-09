# Centralize Claude Assistant Workflow

> **Status: COMPLETE** — All tasks done as of 2026-03-09. See "Post-deployment fixes" below for lessons learned.

**Goal:** Extract the Claude Code Action invocation into a reusable `workflow_call` workflow so all 10 repos share one implementation, keeping the security-critical `author_association` guard as a thin per-repo caller.

**Architecture:** Create `claude-assistant.yml` in `smartwatermelon/github-workflows` with a `workflow_call` trigger. Each repo's `claude.yml` becomes a ~25-line caller: `on:` triggers, `if:` guard, `permissions:`, `uses:`, `secrets:`. The reusable workflow owns `runs-on`, `permissions`, checkout, and the Claude Code Action step. Sequencing is critical — advance the `v1` tag before updating callers, or callers will 404 on the missing file.

**Tech Stack:** GitHub Actions reusable workflows (`workflow_call`), GitHub API (`gh api`), bash, base64

---

## GitHub Actions constraints (read before implementing)

- A job using `uses:` (reusable workflow) **cannot** also have `runs-on`, `steps`, or `environment` — those live in the reusable workflow only.
- A job-level `if:` **is** supported on reusable workflow caller jobs. This is how the security guard stays in the caller.
- `permissions:` in the reusable workflow job **overrides** (does not inherit) caller permissions. Any permission the reusable workflow needs must be declared in its own `permissions:` block — the caller's block alone is not sufficient.
- `permissions:` in the caller job **does** still need to be declared explicitly to satisfy security scanners (`actions/missing-workflow-permissions`) and to grant `id-token: write` for OIDC.
- **`actions: read` is NOT in the default GITHUB_TOKEN read scope.** Requesting it in the reusable workflow `permissions:` block causes `startup_failure` (zero jobs, zero logs) when callers don't have it. Pass it via `additional_permissions` to `claude-code-action` instead — the action handles it through its own auth.
- `id-token: write` **must** appear in the reusable workflow's `permissions:` block (not just the caller's) for `claude-code-action` to fetch an OIDC token.
- Secrets must be explicitly passed via `secrets:` in the caller (or `secrets: inherit`). Explicit is preferred.
- The reusable workflow runs in the calling repo's context — `actions/checkout` checks out the calling repo, not `github-workflows`.

---

## File contents

### Reusable workflow (`github-workflows/.github/workflows/claude-assistant.yml`)

```yaml
name: Claude Code Assistant

# Reusable workflow: invokes Claude Code Action when @claude is mentioned.
# The caller workflow is responsible for event triggers and the
# author_association guard that restricts who can invoke Claude.
#
# Usage in a caller workflow:
#
#   jobs:
#     claude:
#       if: |
#         (github.event_name == 'issue_comment' && contains(github.event.comment.body, '@claude') && contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.comment.author_association)) ||
#         (github.event_name == 'pull_request_review_comment' && contains(github.event.comment.body, '@claude') && contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.comment.author_association)) ||
#         (github.event_name == 'pull_request_review' && contains(github.event.review.body, '@claude') && contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.review.author_association)) ||
#         (github.event_name == 'issues' && (contains(github.event.issue.body, '@claude') || contains(github.event.issue.title, '@claude')) && contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.issue.author_association))
#       permissions:
#         contents: read
#         issues: read
#         pull-requests: read
#         id-token: write # required by claude-code-action for internal authentication
#       uses: smartwatermelon/github-workflows/.github/workflows/claude-assistant.yml@v1
#       secrets:
#         claude_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}

on:
  workflow_call:
    secrets:
      claude_oauth_token:
        description: 'Claude Code OAuth token (CLAUDE_CODE_OAUTH_TOKEN secret)'
        required: false

jobs:
  run:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: read
      issues: read
      id-token: write # required by claude-code-action for internal authentication
    steps:
      - name: Checkout repository
        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4
        with:
          fetch-depth: 1

      - name: Run Claude Code
        id: claude
        uses: anthropics/claude-code-action@26ec041249acb0a944c0a47b6c0c13f05dbc5b44 # v1
        with:
          claude_code_oauth_token: ${{ secrets.claude_oauth_token }}

          # Required for Claude to read CI results on PRs
          additional_permissions: |
            actions: read

          # Optional: Give a custom prompt to Claude. If not specified, Claude
          # performs the instructions in the comment that tagged it.
          # prompt: 'Update the pull request description to include a summary of changes.'

          # Optional: restrict which tools Claude can use
          # claude_args: '--allowed-tools Bash(gh pr:*)'
```

### Thin caller (all 10 repos — `claude.yml`)

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
    permissions:
      contents: read
      issues: read
      pull-requests: read
      id-token: write # required by claude-code-action for internal authentication
    uses: smartwatermelon/github-workflows/.github/workflows/claude-assistant.yml@v1
    secrets:
      claude_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

---

## Affected repos

### The source repo (PR-based change)

- `smartwatermelon/github-workflows` — create `claude-assistant.yml`, update `claude.yml` in same PR

### 9 consumer repos (GitHub API direct-to-main)

- `smartwatermelon/claude-wrapper`
- `nightowlstudiollc/juliet-cleaning`
- `nightowlstudiollc/vpn-lan-bridge`
- `nightowlstudiollc/yesteryear`
- `nightowlstudiollc/financial-agent`
- `nightowlstudiollc/amelia-boone`
- `nightowlstudiollc/kebab-tax`
- `nightowlstudiollc/kebab-tax-netlify`
- `nightowlstudiollc/night-owl-studio`

(`photo-game-poc` uses `anthropic_api_key`, not `claude_code_oauth_token`, so it is excluded.)

---

## Tasks

### ✅ Task 1: Create `claude-assistant.yml` and update `claude.yml` in `github-workflows` (PR)

Completed via PRs #9, #11, #12, #14. See "Post-deployment fixes" for the full history.

Final tag: `v1.2.2` / `v1` → `2437108`

---

### ✅ Task 2: Update 9 consumer repos to the thin caller (GitHub API)

Initial thin caller deployed via API after PR #9. Permissions block added via API after PR #14.

**Script to apply the current thin caller to all 9 repos (for future re-runs):**

```bash
THIN_CALLER=$(cat .github/workflows/claude.yml)
ENCODED=$(printf '%s' "$THIN_CALLER" | base64)

REPOS=(
  "smartwatermelon/claude-wrapper"
  "nightowlstudiollc/juliet-cleaning"
  "nightowlstudiollc/vpn-lan-bridge"
  "nightowlstudiollc/yesteryear"
  "nightowlstudiollc/financial-agent"
  "nightowlstudiollc/amelia-boone"
  "nightowlstudiollc/kebab-tax"
  "nightowlstudiollc/kebab-tax-netlify"
  "nightowlstudiollc/night-owl-studio"
)

for repo in "${REPOS[@]}"; do
  SHA=$(gh api repos/$repo/contents/.github/workflows/claude.yml --jq '.sha')
  gh api repos/$repo/contents/.github/workflows/claude.yml \
    --method PUT \
    --field message="fix(claude): sync thin caller with github-workflows template" \
    --field content="$ENCODED" \
    --field sha="$SHA"
  echo "✅ $repo"
done
```

**Verify:**

```bash
for repo in "${REPOS[@]}"; do
  uses=$(gh api repos/$repo/contents/.github/workflows/claude.yml \
    --jq '.content' | base64 -d | grep "uses:")
  echo "$repo: $uses"
done
```

---

### ✅ Task 3: README and release

Completed as part of PR #10 / v1.2.0. Post-deployment fixes documented in PRs #12 and #14 release notes.

---

## Post-deployment fixes

Two issues surfaced after initial deployment (PR #9 / v1.2.0) that were not anticipated in the original plan:

### Fix 1: `actions: read` causes `startup_failure` (PR #12 → v1.2.1)

**Symptom:** All consumer repos showed `startup_failure` with zero jobs, zero logs.

**Root cause:** `actions: read` is not included in GitHub's default GITHUB_TOKEN read scope. When a reusable workflow requests a scope the caller cannot provide, GitHub fails the entire run before creating any jobs — producing no log output and no check runs.

**Fix:** Remove `actions: read` from `claude-assistant.yml`'s `permissions:` block. CI result reading still works via `additional_permissions: actions: read` passed to `claude-code-action`, which uses its own authentication rather than GITHUB_TOKEN.

**Also in PR #12:** Added explicit `permissions:` block to the thin caller `claude.yml` to address `actions/missing-workflow-permissions` security scanner alert.

### Fix 2: `id-token: write` missing from reusable workflow (PR #14 → v1.2.2)

**Symptom:** Job now ran (no more `startup_failure`) but failed with: `Could not fetch an OIDC token. Did you remember to add id-token: write to your workflow permissions?`

**Root cause:** The reusable workflow's `permissions:` block overrides (not inherits) the caller's permissions. `id-token: write` was declared in the caller but not in `claude-assistant.yml`'s job block, so it was silently dropped.

**Fix:** Add `id-token: write` to `claude-assistant.yml`'s `permissions:` block.

**Key distinction from Fix 1:** `id-token: write` does not cause `startup_failure` — it is a standard permission supported in reusable workflows. Only non-default scopes like `actions: read` trigger the pre-job failure.

---

## Sequencing summary (as executed)

```
PR #9:  Create claude-assistant.yml + thin callers → v1.2.0
         ↓ startup_failure discovered in all consumer repos
PR #12: Remove actions: read + add permissions to caller → v1.2.1
         ↓ OIDC failure discovered
PR #14: Add id-token: write to reusable workflow → v1.2.2
         ↓ confirmed working ✅
API:    Push permissions block to all 9 consumer repos
```
