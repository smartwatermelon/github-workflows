# github-workflows

Reusable GitHub Actions workflows.

## `claude-blocking-review`

Runs a Claude Code Review on every PR and **blocks merges** when Claude finds
bugs, reliability regressions, security vulnerabilities, or data-loss risks.

### What triggers a BLOCK

| Category | Examples |
| ---------- | --------- |
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

Review parameters are estimated automatically from the PR diff size. The
reviewer prompt is BLOCK-only (bug / reliability regression / security /
async-error / data-loss), not a full code review — local reviewers are
expected to cover style, test coverage, and documentation concerns. v3
removed the `--max-turns` cap; reviews are now bounded only by the
wall-clock timeout, the prompt's scope discipline, and the OAuth
subscription quota.

| Parameter   | Logic                         | Range               |
| ----------- | ----------------------------- | ------------------- |
| **Model**   | Sonnet (callers can override) | `claude-sonnet-4-6` |
| **Timeout** | `10 + lines/100` minutes      | 10–30 minutes       |

Callers can override any parameter:

```yaml
with:
  pr_number: ${{ github.event.pull_request.number }}
  model: claude-sonnet-4-6     # force sonnet for all diffs
  timeout_minutes: 15          # override timeout estimate
```

Pass `0` for `timeout_minutes` to use auto-estimation (the default).
Pass `auto` for `model` to use auto-selection (the default).

**v3 (2026-04-28):** the `max_turns` input was removed and the
`--max-turns` flag is no longer passed to the Claude agent. Reviews are
now bounded only by the wall-clock `timeout_minutes` (the hard safety
net), the prompt's own scope discipline, and the OAuth subscription
quota. The previous "Review did not complete (likely exceeded turn
limit)" failure mode is gone. **Caller migration:** remove `max_turns:`
from your caller workflow when bumping to `@v3`; it will fail
workflow validation if left in place.

If the review times out before rendering a verdict, the check **fails**
(INCOMPLETE) instead of silently passing. Use the escape hatch below to
bypass if needed.

### Escape hatch

Add `[skip-claude-review: reason]` to the PR body to bypass enforcement.
The override is logged in the step summary for audit.

This unscoped form is honored unconditionally on **every** subsequent run
for the life of the PR — it's a deliberate, visible opt-out, not scoped to
any particular commit. That's intentional grandfathered behavior for
markers already in use; see below for a way to bound the bypass to a
single commit.

**Scoping a skip to one commit (v3.1.0+):** add
`[skip-claude-review sha=<short-sha>: reason]` instead, where `<short-sha>`
is a prefix (7+ characters) of the commit SHA you want to bypass review
for — use the PR's head commit SHA, e.g. from `gh pr view <PR> --json
headRefOid -q .headRefOid`. The marker is only honored while it matches
the **current** head SHA of the PR. If the PR is pushed to again, the head
SHA changes and the marker stops applying automatically — a visible
`::notice::` in the step summary calls this out so it isn't only
discoverable by diffing raw run logs. Markers with a `sha=` value shorter
than 7 characters are rejected as invalid (prevents a trivial bypass like
`sha=a` matching anything) and the review proceeds normally.

**Important: to make a `sha=`-scoped marker take effect, use `gh run rerun
<run-id>` on the existing failed/blocked run — do not push a new commit.**
Editing the PR body does not retrigger this workflow (there's no `edited`
event in the trigger list), so the only way to get a fresh check run
against the same commit is `gh run rerun`. A new commit/push changes the
head SHA and immediately invalidates a marker scoped to the old SHA — that
is the intended anti-staleness behavior, not a bug to work around.

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
    uses: YOUR_ORG/github-workflows/.github/workflows/claude-blocking-review.yml@v3
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
| ----- | --------- |
| `@v3` | Current stable major version (floating — gets minor updates). v3 dropped the `max_turns` input; remove it from caller workflows when bumping. |
| `@v2` | Previous stable major (still supported for callers that haven't migrated; passes `--max-turns` to the agent and accepts `max_turns:` input) |
| `@v1` | Initial release line |
| `@main` | Latest (may include breaking changes) |

---

## `dependabot-auto-merge`

Reusable workflow: approves and auto-merges Dependabot PRs for patch and
minor version updates once CI passes. Major-version bumps are left open
for manual review.

### Setup

`.github/workflows/dependabot-auto-merge.yml` in your repo:

```yaml
name: Dependabot Auto-Merge

on: # zizmor: ignore[dangerous-triggers] required to run from base branch; no PR code executed here
  pull_request_target:
    types: [opened, synchronize, reopened]

permissions:
  contents: write
  pull-requests: write

jobs:
  dependabot-auto-merge:
    uses: smartwatermelon/github-workflows/.github/workflows/dependabot-auto-merge.yml@dependabot-auto-merge-v2
    with:
      trusted_namespaces: 'smartwatermelon' # adjust to your own org; dependabot/actions are always trusted
```

Also add `can_approve_pull_request_reviews: true` to the repo's Actions
workflow permissions (Settings → Actions → General → Workflow
permissions), or run the fleet-wide fix in this repo's
`README.md`/issue #87 history. Without it, `gh pr review --approve`
fails; the workflow degrades to a visible `::warning::` instead of a
silent stall, but auto-merge still won't proceed if the repo's branch
protection requires an approval.

**Do NOT add `secrets: inherit` to the caller.** This workflow needs no
secrets beyond the `GITHUB_TOKEN` it mints internally and declares no
`secrets:` input. Splitting this workflow out of each caller repo (so
that fixing a bug means editing one file, not 26+) creates a real
temptation: a future maintainer who hits an auth-shaped failure here
has an easy one-line "fix" available in `secrets: inherit`. That line
would hand every repo secret — `CLAUDE_CODE_OAUTH_TOKEN`, deploy keys,
anything else the repo holds — to a job that runs against
externally-authored PR content under `pull_request_target`. The
workflow's no-checkout property (see below) does not protect against
this: it only means a secret leak, if it happened, wouldn't arrive
bundled with an obvious code-execution vector. If `gh pr review` or
`gh pr merge` is failing for a reason unrelated to
`can_approve_pull_request_reviews`, debug the actual cause — don't
reach for `secrets: inherit`.

### Security invariant: no `actions/checkout`

This workflow uses `pull_request_target`, which runs with base-branch
secrets available — the trigger implicated in several real supply-chain
incidents (Ultralytics, nx, tj-actions) when combined with a checkout
of PR-controlled code. This workflow is safe today because it never
executes PR code: the only actions are API calls (`dependabot/fetch-metadata`,
`gh pr review`, `gh pr merge`). **`actions/checkout` must never be added
to this file.** Two guardrails enforce this (closes #64):

- `self-review.yml`'s `guard-no-checkout` job greps this repo's own
  copy of `dependabot-auto-merge.yml` and fails the PR if
  `actions/checkout` appears.
- `claude-review-audit.sh` performs a read-only, fleet-wide check: any
  caller stub referencing `dependabot-auto-merge.yml` that contains
  `actions/checkout` or `secrets: inherit` is flagged in the audit
  report. This check does not block or gate anything — it's audit-only,
  same as the rest of that script.

### Versioning

Tagged with a prefixed namespace — `dependabot-auto-merge-v1`,
`dependabot-auto-merge-v1.0.0`, etc. — rather than the bare `v1`/`v2`/`v3`
tags used by `claude-blocking-review` and `claude-assistant`. Git tags
are repo-scoped, not per-file; a bare `v1` on this repo already exists
and is live, consumed by `claude-assistant.yml@v1`. A second, unrelated
file can't safely "start its own v1" in the same tag namespace.

### Rollout discipline

New tags of this workflow (and behavior-changing bumps) are pointed at
from 2-3 low-traffic pilot repos first, pinned to the specific new tag
(not a floating major). Let at least one real Dependabot PR flow
through each pilot and confirm correct patch/minor-only behavior before
repointing any floating tag fleet-wide. This workflow approves and
merges PRs unattended with no fallback reviewer behind it (unlike
`claude-blocking-review`, which explicitly skips Dependabot PRs) — a
bug here ships to every repo pinned to the affected tag at once, so it
gets the same pilot-then-fleet discipline as the org-level rollout
work.

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

---

## Bulk-install script (`smartwatermelon` only)

`bulk-install-claude-review.sh` installs (or refreshes) the
`claude-blocking-review` caller workflow across all non-archived repos under
`smartwatermelon`. Workaround for the fact that GitHub's workflow-templates
picker is **organization-only** — `smartwatermelon` is a user account, so
the templates in `smartwatermelon/.github/workflow-templates/` never appear
in the "New workflow" picker for `smartwatermelon/*` repos.

```bash
./bulk-install-claude-review.sh                          # dry-run (default)
./bulk-install-claude-review.sh --apply                  # open PRs
./bulk-install-claude-review.sh --only smartwatermelon/foo --apply
```

The script classifies each repo:

| Class | Action |
| ------- | -------- |
| `CURRENT` | Already on the target version. No-op. |
| `STALE` | Different pin or floating tag. Opens a PR bumping the pin. |
| `MISSING` | No caller workflow at all. Opens a PR adding the canonical stub. |
| `CUSTOMIZED` | Has caller-side modifications (`paths-ignore`, `extra_instructions`, custom `model`/`timeout_minutes`, etc.). Skipped regardless of pin — flag for human review. |
| `LOCAL` | Uses a local-path reference (`./...`). Not bumpable; e.g. the `github-workflows` repo's own self-review. |

Target version is derived dynamically from the `@v…` pin in
`smartwatermelon/.github/workflow-templates/claude-blocking-review.yml`,
so a PR bumping that template is the single trigger to roll a new version
across the fleet.

PRs include `[skip-claude-review: bulk-install]` in the body so the
blocking-review workflow doesn't gate its own install/bump PR.

For `nightowlstudiollc`, this script is intentionally not used — that org gets
the workflow-templates picker via [`nightowlstudiollc/.github`](https://github.com/nightowlstudiollc/.github)
(mirrors `smartwatermelon/.github` workflow-templates; verified appearing under
"By Night Owl Studio" in the Actions → New workflow UI). Repository Rulesets
for org-wide enforcement were attempted once and rolled back (see
`docs/plans/2026-04-30-required-workflows-nightowlstudiollc.md`); a
re-attempt is deliberately not planned here and would need its own review
given that history.

## New-repo bootstrap script (`smartwatermelon` only)

`new-smartwatermelon-repo.sh` is the creation-time counterpart to the
bulk-install script above — for a genuinely *new* `smartwatermelon` repo,
rather than retrofitting an existing one. `smartwatermelon` being a User
account means it can't use GitHub's org-only workflow-templates picker
*or* Repository Rulesets to auto-attach anything on repo creation, so this
script is the closest available approximation: one command instead of
"create repo, then remember to run the bulk-install script, then remember
the one repo setting no template can seed."

```bash
./new-smartwatermelon-repo.sh <name> [--private]
```

This does three things:

1. `gh repo create <name> --template smartwatermelon/repo-template` — a
   real [GitHub template repository](https://github.com/smartwatermelon/repo-template)
   containing caller stubs for `claude.yml`, `claude-code-review.yml`,
   `dependabot-auto-merge.yml`, and a `.github/dependabot.yml`. Template
   repos are a general GitHub feature, not gated to Organizations, so this
   part genuinely works the same for a User account as it would for an Org.
2. Sets `can_approve_pull_request_reviews: true` via the Actions API — the
   one setting a template repo cannot seed, and the exact fix from issue
   [#87](https://github.com/smartwatermelon/github-workflows/issues/87).
3. Prints a reminder for the one step that can't be scripted at all: run
   `/install-github-app` from Claude Code (or add the
   `CLAUDE_CODE_OAUTH_TOKEN` secret manually) so the Claude workflows can
   actually run.

Plan: `docs/plans/2026-04-30-bulk-install-smartwatermelon-fleet.md`.
