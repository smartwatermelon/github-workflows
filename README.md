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

### Auto-sizing

Review parameters are estimated automatically from the PR diff size:

| Parameter | Logic | Range |
|-----------|-------|-------|
| **Model** | Sonnet (callers can override) | `claude-sonnet-4-6` |
| **Max turns** | `6 + lines/150`, +20% buffer | 8–50 |
| **Timeout** | `turns × 30s × 1.2` | 4–30 minutes |

Callers can override any parameter:

```yaml
with:
  pr_number: ${{ github.event.pull_request.number }}
  model: claude-sonnet-4-6   # force sonnet for all diffs
  max_turns: 30               # override turn estimate
  timeout_minutes: 15          # override timeout estimate
```

Pass `0` for `max_turns` or `timeout_minutes` to use auto-estimation (the default).
Pass `auto` for `model` to use auto-selection (the default).

If the review runs out of turns or times out before rendering a verdict, the
check **fails** (INCOMPLETE) instead of silently passing. Use the escape hatch
below to bypass if needed.

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
| `@v1.2.0` | Latest pinned release |
| `@v1.1.0` | Previous pinned release |
| `@v1.0.0` | Initial release |
| `@main` | Latest (may include breaking changes) |

---

## `claude-assistant`

Reusable workflow that invokes Claude Code Action. The caller handles triggers
and the `author_association` auth guard; this workflow handles the Claude
invocation itself.

### Setup

Create `.github/workflows/claude.yml` in your repo:

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

Add `CLAUDE_CODE_OAUTH_TOKEN` to your repository or organization secrets.

### Security note

The `author_association` guard in the `if:` condition **must stay in the caller**
and must not be removed. Without it, any GitHub user can open an issue with
injected instructions and Claude will execute them
([clinejection-style attack](https://grith.ai/blog/clinejection-when-your-ai-tool-installs-another)).
The reusable workflow cannot enforce this guard itself — it must be in the
calling workflow's job condition.

### Compatibility

Requires `CLAUDE_CODE_OAUTH_TOKEN`. Repos using `anthropic_api_key` directly
are not compatible with this reusable workflow.

---

## Audit script

`claude-review-audit.sh` audits Claude Review configuration across all
non-archived repos under `smartwatermelon` and `nightowlstudiollc`. Read-only —
reports gaps but makes no changes.

```bash
./claude-review-audit.sh [--verbose]
```

Requires: `gh` CLI (authenticated), `jq`, `bash` 4.0+.

### Excluding repos

Add repos to `.claude-review-ignore` (one `owner/repo` per line) to skip them
in audits. Useful for repos that should never have the review installed.
