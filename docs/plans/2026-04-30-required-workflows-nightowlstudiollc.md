# Org-wide enforcement of `claude-blocking-review` on `nightowlstudiollc` via Repository Rulesets

GitHub's "Required Workflows" feature, the obvious-sounding answer, was **deprecated and removed** — the functionality moved into **Repository Rulesets** in 2023, and the standalone Required Workflows API/UI is gone. This plan uses Rulesets, the current mechanism, to force `claude-blocking-review` to run (and optionally pass) on every PR in selected NightOwl repos.

References:

- [GitHub Changelog: Required Workflows moved to Rules](https://github.blog/changelog/2023-08-02-github-actions-required-workflows-will-move-to-repository-rules/)
- [REST API endpoints for organization rules](https://docs.github.com/en/rest/orgs/rules)

## Goal

Decide whether to enforce `claude-blocking-review` on every NightOwl repo via an org-level Repository Ruleset with a `workflows` rule, and if so, roll it out safely.

## Background

Three competing mechanisms for spreading a workflow across an org:

| Mechanism | Coverage | Live updates? | Per-repo opt-out? | Status |
|---|---|---|---|---|
| `workflow-templates/` in `.github` repo | New repos via picker, opt-in only | No (one-time copy) | n/a | Live |
| Bulk-install script + `uses:` reference | Existing repos opt-in via PR | Yes (via Dependabot bumps) | Yes (delete the file) | Plan: [bulk-install](2026-04-30-bulk-install-smartwatermelon-fleet.md) |
| **Repository Ruleset with `workflows` rule** | All repos in scope, mandatory | Yes (org-config edit) | Only by admin removing the rule or granting bypass | Live (replaces deprecated Required Workflows) |

Rulesets are org-or-repo scoped, support targeting all/selected repos, support **bypass actors** (specific users or teams), can be run in **evaluation mode** (audit-only, no enforcement) before turning on, and integrate with branch protection rather than competing with it.

This is org-only — useful for NightOwl, irrelevant to smartwatermelon (user account; no rulesets).

## Goal qualifiers

How strong should the gate be?

- **Strong** → ruleset enforced + the `claude-review / run-review` check is required. PR cannot merge without Claude pass. Trade: every PR pays review cost; depends on Claude OAuth uptime/quota.
- **Moderate** → ruleset enforced (workflow runs), but check not coupled to merge. Trade: zero blocked-merge risk, but humans can ignore the verdict.
- **Audit-only** → ruleset in **evaluation mode** for a calibration window. No enforcement; you collect data on cost, false positives, and blast radius before deciding.

Recommend **Audit-only first**, then **Moderate**, escalating to **Strong** only after a clean window.

## Preconditions

- `nightowlstudiollc/.github` exists. (See [defaults plan](2026-04-30-create-nightowlstudiollc-github-defaults.md).)
- The reusable workflow being enforced is reachable from NightOwl repos. Two sub-options:
  - **A:** Reference `smartwatermelon/github-workflows` directly. Cross-org reference works only if that repo is **public** (it is today).
  - **B:** Mirror the reusable workflow into a NightOwl-owned repo (e.g. `nightowlstudiollc/github-workflows-internal`). Adds a sync step; gains independence.

  Recommend **A** until smartwatermelon goes private or NightOwl needs divergent thresholds.

- `CLAUDE_CODE_OAUTH_TOKEN` provisioned at org level (Phase 3 of the defaults plan).
- Org admin permission to create rulesets (`admin:org` scope on `gh` token; check with `gh auth status`).
- Decision recorded: which gate strength tier to start at.

## Phases

### Phase 0 — Decide gate strength and bypass policy

- Choose starting tier: **Audit-only** unless there's a strong reason to skip the calibration window.
- Decide **bypass actors**:
  - You (org admin) — yes, always.
  - Bots (`dependabot[bot]`, `claude[bot]`, `github-actions[bot]`) — case-by-case. The current `dependabot-auto-merge.yml` workflow expects to merge Dependabot PRs without further gates; if it's coupled to a check, decide whether to bypass for `dependabot[bot]` or to leave the dep-bump path going through full review.
  - Specific users for emergency bypass — yes, document who.
- Capture decisions inline in the ruleset's description so they're discoverable later.

### Phase 1 — Create the caller stub

The ruleset references a workflow file by path. The file lives in a designated repo (typically `.github`). Create:

`nightowlstudiollc/.github/.github/workflows/claude-required-review.yml`:

```yaml
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
```

Same content as the workflow-templates stub. Difference is *how* it gets invoked — via ruleset config, not per-repo file.

### Phase 2 — Create the ruleset (audit mode)

Via UI: `Settings → Rules → Rulesets → New ruleset → New organization ruleset` with a `Require workflows to pass before merging` rule, **enforcement status: Evaluate**. Or via REST:

```bash
gh api -X POST orgs/nightowlstudiollc/rulesets \
  --input ruleset.json
```

Where `ruleset.json` is a payload along the lines of:

```json
{
  "name": "Claude blocking review (eval)",
  "target": "branch",
  "enforcement": "evaluate",
  "conditions": {
    "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] },
    "repository_name": { "include": ["~ALL"], "exclude": [], "protected": true }
  },
  "rules": [
    {
      "type": "workflows",
      "parameters": {
        "workflows": [
          {
            "repository_id": <id of nightowlstudiollc/.github>,
            "path": ".github/workflows/claude-required-review.yml",
            "ref": "refs/heads/main"
          }
        ]
      }
    }
  ],
  "bypass_actors": []
}
```

Field names taken from [GitHub's ruleset REST docs](https://docs.github.com/en/rest/orgs/rules); confirm exact shape before applying. Validate with `--method GET` against an existing ruleset on a personal account first if uncertain.

`enforcement: evaluate` means the ruleset runs but does not block. Insights tab shows what *would* have happened.

### Phase 3 — Bellwether (1 repo, 1 week, audit mode)

Restrict the ruleset's `conditions.repository_name.include` to a single bellwether repo for the first week. Watch:

- PRs opened during the week trigger the workflow via the ruleset.
- The Insights → Rule insights view shows pass/fail counts.
- No silent self-collision with existing per-repo `claude-code-review.yml` — the ruleset and a per-repo file produce **two runs** of the same review. Decide: remove per-repo files (preferred) or accept double-runs.
- Quota cost and run duration are reasonable.

Acceptance for moving to Phase 4:

- Clean week, no surprises.
- Claude OAuth quota intact.
- Verdict pass-rate matches expectations.

### Phase 4 — Expand scope (audit) → Active

Two-axis expansion:

1. **Scope axis:** bellwether repo → 3 active repos → all repos. Spread over 2-3 weeks.
2. **Enforcement axis:** `evaluate` → `active` once the audit data looks clean.

If gate strength = **strong**, after `enforcement: active` lands, also wire branch protection to require the `claude-review / run-review` check via a *second* ruleset rule (`required_status_checks`) or per-repo branch protection.

### Phase 5 — Reconcile with bulk-install

Once the ruleset covers `~ALL` NightOwl repos in `active` mode, the [bulk-install script](2026-04-30-bulk-install-smartwatermelon-fleet.md) becomes redundant for NightOwl — every repo is gated automatically. Action items:

- Bulk-install script should accept `--owner` and default to `smartwatermelon` only.
- Per-repo `claude-code-review.yml` files in NightOwl repos are deletable (the ruleset replaces them). Optional cleanup PR per repo.
- Document in this repo's README that NightOwl uses the ruleset, smartwatermelon uses per-repo files.

## Risks and rollback

| Risk | Mitigation |
|---|---|
| Strong gate blocks merges org-wide during a Claude OAuth outage | Audit-only first; stay moderate (no branch-protection coupling) until quota+uptime confidence is high; `bypass_actors` includes admin |
| Quota burn surprise — every PR in every repo runs Claude | Audit week measures empirically. Set org-level budget; switch to `evaluate` if breaching |
| Double-runs in repos that already have per-repo `claude-code-review.yml` | Phase 3 acceptance gate; cleanup PRs as part of Phase 5 |
| Cross-org reference (`smartwatermelon/github-workflows@v3.0.0`) breaks if that repo is taken private | Move to mirror (option B in Preconditions). Ruleset references the workflow file by path in the *NightOwl* `.github` repo — the cross-org dep is in the stub's `uses:` line, swappable later without touching the ruleset |
| Ruleset misconfiguration silently no-ops (e.g. wrong workflow path) | Audit week catches this — Insights tab shows zero runs |
| Dependabot PRs blocked by the gate | Phase 0 bypass-actors decision; alternatively, ensure the auto-merge workflow uses an authorized actor that can satisfy the gate |
| GitHub keeps iterating on Rulesets — payload shape may shift | Pin to a documented API version (`X-GitHub-Api-Version` header) when scripting; UI configuration insulates you from API changes |

Rollback at any phase: set `enforcement: disabled` on the ruleset, or delete it via `gh api -X DELETE orgs/nightowlstudiollc/rulesets/<id>`. Per-PR check disappears immediately. No code changes required.

## Acceptance criteria

- Decision recorded (strong/moderate/audit-only/skip) with timestamp in the ruleset description.
- If `audit-only` (calibration phase): ruleset active in `evaluate` mode org-wide, Insights data captured.
- If `moderate`: `enforcement: active`, no branch-protection coupling.
- If `strong`: `enforcement: active` + `required_status_checks` rule on the same ruleset (or paired branch protection).
- Audit/bellwether window written up as a postscript to this plan.
- Bulk-install script's owner-scoping confirmed not to overlap NightOwl.
- README in this repo updated with a "Org-wide enforcement (NightOwl)" subsection if the rollout proceeds.

## Open questions

- Does NightOwl want different BLOCK thresholds than smartwatermelon? If yes, that's a fork of `claude-blocking-review.yml` (or a new `extra_instructions` knob) — not a Ruleset decision. Note for follow-up.
- Should the ruleset target `~DEFAULT_BRANCH` only (default), or also include long-lived release branches if NightOwl uses them? Decide once branch conventions stabilize.
- Worth a parallel conversation: are there other rules NightOwl wants org-wide (e.g. linear history, signed commits, required reviewers)? Bundling them into one ruleset is cheaper than discovering them piecemeal. Out of scope for this plan, but flag it during Phase 0.
