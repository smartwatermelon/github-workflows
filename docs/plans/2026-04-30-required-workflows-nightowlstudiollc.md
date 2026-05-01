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

- `CLAUDE_CODE_OAUTH_TOKEN` present on every repo in the ruleset's scope (per-repo via `/install-github-app` — there is no org-level scope). The defaults plan's Phase 3 verifies this fleet-wide.
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

## Postscript — 2026-04-30 rollout attempt: PAUSED

A first pass at this rollout was attempted on 2026-04-30 and **paused after multiple failure modes that the plan above did not anticipate**. The fleet ended the day in its starting position (per-repo `claude-blocking-review.yml` callers on every active NightOwl repo); the org ruleset (id `15802253` on `nightowlstudiollc`) is currently **disabled**. **Do not re-enable the ruleset or re-attempt scope expansion** until the open questions below are answered empirically.

Empirical findings, all of which break assumptions in the plan above:

1. **`enforcement: "evaluate"` is Enterprise-only.** On Team plan the API silently accepts it and the ruleset enforces as `active` from the moment it's created. Phase 3's "audit week" was production from PR #1.
2. **A cleanup PR that DELETES the per-repo workflow file the PR is gated by is unmergeable.** For same-repo PRs GitHub uses workflows from the head; the head removes the file → workflow doesn't fire → required check `claude-review / run-review` never appears. The plan's Phase 5 "Per-repo `claude-code-review.yml` files in NightOwl repos are deletable" assumed admin override would handle the gap; it doesn't (see point 3).
3. **`gh pr merge --admin` bypasses branch protection but NOT rulesets.** Once the ruleset's `workflows` rule is unsatisfied, even admin cannot override without explicit `bypass_actors` configured on the ruleset itself.
4. **Expanding ruleset scope to `~ALL` does NOT retroactively trigger the required workflow on existing open PRs in newly-included repos.** `gh pr close && gh pr reopen` does not trigger it either. Apparently only an actual push to the PR head does. PRs in the new scope sit forever waiting for a check that never fires.
5. **Empirically, when the workflow does fire, the resulting check name is `claude-review / run-review`** (job-name / reusable-job-name), not `Claude Required Review` (the workflow file's `name:`). The ruleset still considers itself satisfied, but the failure mode when the workflow doesn't fire at all looks identical to a name mismatch.

Operational artifacts from the attempt are committed to this repo as `nightowl-ruleset-setup.sh`, `nightowl-restore-blocking-review.sh`, and `nightowl-ruleset-rollout.sh.broken`. The rollout artifact uses the `.broken` suffix (not `.sh`) so it can't be accidentally executed and so the shell-lint hooks ignore it — its step 1 unconditionally sets `enforcement="active"`, which re-armed the intentionally-disabled ruleset on every `--apply` re-run. Fix that bug (make state assertions conditional on current state) and rename back to `.sh` before any reuse.

Open questions to resolve on a single test PR before any future re-enable attempt:

- Does the org-level workflow (`nightowlstudiollc/.github/.github/workflows/claude-required-review.yml`) actually fire when a fresh PR is **pushed** in a ruleset-scoped repo with no per-repo caller present? Watch the run in `nightowlstudiollc/.github`'s Actions tab and the PR's check_runs. (The plan above takes "scope expansion → workflow fires on every PR" as axiomatic.)
- What event types cause the ruleset's required workflow to (re-)trigger on an existing PR? `synchronize` (push) presumably; `reopened` apparently does not.
- If the rollout will eventually require removing per-repo files, what sequence avoids both the chicken-and-egg AND the "scope-expansion-doesn't-fire-on-existing-PRs" gap simultaneously? The original plan ordered "remove per-repo files first, then expand scope" — that ordering is unworkable with both gotchas active.

Once those are answered, the plan above can be revised with a corrected Phase 4 sequence (or scrapped in favor of indefinite per-repo file maintenance).
