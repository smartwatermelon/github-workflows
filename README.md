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
Claude Code Review / claude-review
```

The check name is always `{caller workflow name} / {caller job name}`.
If you name your caller workflow `Claude Code Review` and job `claude-review`,
the check name matches the example above regardless of which repo you're in.

### Threshold calibration

The BLOCK criteria are in the workflow prompt. To adjust:

- Fork this repo and point your callers at your fork
- Or open a PR with updated criteria

### Versioning

| Tag | Meaning |
|-----|---------|
| `@v1` | Current stable major version (floating — gets minor updates) |
| `@v1.0.0` | Pinned release |
| `@main` | Latest (may include breaking changes) |
