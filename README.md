# github-workflows

Reusable GitHub Actions workflows.

## `claude-blocking-review`

Runs a Claude Code Review on every PR and **blocks merges** when Claude finds
bugs, reliability regressions, security vulnerabilities, or data-loss risks.

### What triggers a BLOCK

| Category | Examples |
|----------|---------|
| Clear bug | Wrong calculation, inverted condition, off-by-one affecting real data |
| Reliability regression | Previously working path may now fail due to this PR |
| Security | Hardcoded credentials, auth bypass, unvalidated input to privileged op |
| Async error handling | Missing `await` causing silent failure or raw exception to surface |
| Data loss | Risk of corrupting or deleting user data |

Style issues, coverage gaps, performance concerns, and docs are always **PASS**.
When uncertain, Claude defaults to **PASS**.

Regression BLOCKs require a **line-level code path trace** — Claude must identify
the specific file, line, and execution path that causes the failure. Assertions about
test failures without traceable evidence default to PASS.

### Escape hatch

Add `[skip-claude-review: reason]` to the PR body to bypass enforcement.
The override is logged in the step summary for audit.

### Setup

#### 1. Add the secret

Add `CLAUDE_CODE_OAUTH_TOKEN` to your repository or organization secrets.

#### 2. Create the caller workflow

`.github/workflows/claude-code-review.yml` in your repo:

```yaml
name: Claude Code Review

on:
  pull_request:
    types: [opened, synchronize]
    paths-ignore:         # optional: skip docs-only PRs
      - '**.md'
      - 'docs/**'

jobs:
  claude-review:
    uses: YOUR_ORG/github-workflows/.github/workflows/claude-blocking-review.yml@v1
    with:
      pr_number: ${{ github.event.pull_request.number }}
      # extra_instructions: |
      #   Repo-specific guidance for Claude here.
    secrets:
      claude_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

#### 3. Add the required status check

In **Settings → Branches → Branch protection rules → [your branch]**,
add this required status check:

```
claude-review / run-review
```

With reusable workflows, GitHub reports the **inner job** as the status check.
The check name is `{caller job name} / {inner job name}`. If you name your
caller job `claude-review`, the check name will always be
`claude-review / run-review` regardless of which repo you're in.

### Threshold calibration

The BLOCK criteria are in the workflow prompt. To adjust:

- Fork this repo and point your callers at your fork
- Or open a PR with updated criteria

### Versioning

| Tag | Meaning |
|-----|---------|
| `@v1` | Current stable major version (floating — gets minor updates) |
| `@v1.1.0` | Latest pinned release |
| `@v1.0.0` | Previous pinned release |
| `@main` | Latest (may include breaking changes) |

---

## `claude.yml` — Claude Code Assistant

Enables `@claude` mentions in issues, PR review comments, and PR reviews to
invoke Claude Code interactively.

### Security requirement

The workflow **must** restrict triggers to trusted contributors using
`author_association`. Without this guard, any GitHub user can open an issue
with injected instructions and Claude will execute them
([clinejection-style attack](https://grith.ai/blog/clinejection-when-your-ai-tool-installs-another)).

The correct `if:` condition:

```yaml
if: |
  (github.event_name == 'issue_comment' && contains(github.event.comment.body, '@claude') && contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.comment.author_association)) ||
  (github.event_name == 'pull_request_review_comment' && contains(github.event.comment.body, '@claude') && contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.comment.author_association)) ||
  (github.event_name == 'pull_request_review' && contains(github.event.review.body, '@claude') && contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.review.author_association)) ||
  (github.event_name == 'issues' && (contains(github.event.issue.body, '@claude') || contains(github.event.issue.title, '@claude')) && contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.issue.author_association))
```

Do not grant `id-token: write` unless the workflow uses OIDC authentication.

---

## Audit script

`claude-review-audit.sh` audits Claude Review configuration across all
non-archived repos under `smartwatermelon` and `nightowlstudiollc`. Read-only —
reports gaps but makes no changes.

```bash
./claude-review-audit.sh [--verbose]
```

Requires: `gh` CLI (authenticated), `jq`, `bash` 4.0+.
