# Bulk-install script for existing smartwatermelon repos

Adds a script to this repo that installs (or refreshes) the `claude-blocking-review` caller workflow across all eligible repos under the `smartwatermelon` user account. Closes the gap left by GitHub's workflow-templates feature being **organization-only** — `smartwatermelon` is a user account, so `smartwatermelon/.github/workflow-templates/` is decorative; the templates never appear in the "New workflow" picker for `smartwatermelon/*` repos.

## Goal

A repeatable, idempotent way to roll the current pinned version (today: `@v3.0.0`) into every `smartwatermelon/*` repo that doesn't yet have it, without per-repo manual work.

## Non-goals

- Installing into archived repos.
- Installing into repos listed in `.claude-review-ignore`.
- Force-overwriting an existing caller workflow that's already on the pinned version (idempotent skip).
- Touching `nightowlstudiollc/*` — that's covered by [the org defaults plan](2026-04-30-create-nightowlstudiollc-github-defaults.md) plus the [org-wide enforcement plan](2026-04-30-required-workflows-nightowlstudiollc.md) (Repository Rulesets).

## Preconditions

- `gh` CLI authenticated as a user with write access to all targets.
- `claude-review-audit.sh` already exists in this repo and enumerates the fleet correctly. The new script reuses its repo-discovery logic.
- A canonical caller-stub file exists somewhere we can copy from. Two options (Phase 0 chooses):
  - **A:** Pull from `smartwatermelon/.github/workflow-templates/claude-blocking-review.yml` at HEAD (single source of truth — same file the workflow-template feature would have used in an org).
  - **B:** Inline the stub in the script itself.

  Recommend **A** so the stub-and-the-script can't drift.

## Phases

### Phase 0 — Decide caller stub source and pin policy

- Confirm the canonical stub file path (`smartwatermelon/.github/workflow-templates/claude-blocking-review.yml`).
- Confirm pin policy: specific semver from the stub (e.g. `@v3.0.0`), not floating. Matches the release-strategy convention; lets Dependabot drive future bumps.
- If the stub references a tag that doesn't have a GitHub Release yet (currently true for `v3.0.0`), publish the release first so consumers have something to reference in their UI.

### Phase 1 — Write `bulk-install-claude-review.sh`

Lives next to `claude-review-audit.sh` at the repo root. Modeled on the audit script's repo-discovery + ignore-list handling.

Behavior:

1. Discover candidate repos: all non-archived repos owned by `smartwatermelon`, minus those in `.claude-review-ignore`.
2. For each candidate, classify state:
   - **MISSING** — no `claude-code-review.yml` (or any equivalent) under `.github/workflows/`.
   - **STALE** — present, but pin doesn't match the current target (`@v3.0.0`).
   - **CURRENT** — present and on target. Skip silently.
   - **CUSTOMIZED** — present, on target, but with non-trivial caller-side modifications (e.g. `paths-ignore`, `extra_instructions`). Skip with warning; flag for human review.
3. For MISSING repos: open a PR adding `.github/workflows/claude-code-review.yml` with the canonical stub. Branch name: `claude/install-blocking-review-<short-sha>`.
4. For STALE repos: open a PR bumping the pin. Branch name: `claude/bump-blocking-review-to-<target-version>`.
5. Report: per-repo status summary at end.

Idempotency: re-running the script when nothing's changed should produce zero PRs and a clean report.

Flags:

- `--dry-run` — classify and print intended action; open no PRs. **Default**.
- `--apply` — actually open PRs.
- `--only <repo>` — single-repo mode for testing.
- `--verbose` — verbose logging (matches audit script convention).

PR body should:

- Link to `github-workflows` release notes for the target version.
- Link to this plan.
- Include `[skip-claude-review: bulk-install]` in the body so the PR doesn't recursively trigger blocking review on itself before being merged.

### Phase 2 — Bellwether

Pick 2-3 actively-developed `smartwatermelon/*` repos (non-archived, recent commits) and run with `--apply --only <repo>`. Watch each PR through CI before continuing.

Acceptance for moving to Phase 3:

- Bellwether PRs CI-green.
- Caller stub renders correctly (no schema errors).
- The `claude-review / run-review` check appears on subsequent PRs in the bellwether repos.

### Phase 3 — Fleet rollout

Run `--apply` against the full eligible set. Expect 5-15 PRs (most repos either already have it from prior `claude-review-audit.sh`-driven manual installs, or are in `.claude-review-ignore`).

Auto-merge: don't enable. Each install PR should land via the normal review path. If volume becomes a problem, this is where we'd consider scripted self-merge — but on a one-time rollout, manual review is fine.

### Phase 4 — Wire up Dependabot in newly-installed repos

Only matters for MISSING-class repos that didn't have `dependabot.yml` for `github-actions`. Defer this to a follow-up — same pattern that already shipped to existing fleet.

Two sub-options:

- **A:** Bundle Dependabot config into the install PR. Risk: makes the install PR more invasive.
- **B:** Separate "add github-actions Dependabot" PR after the install PR merges.

Recommend **B** — smaller, easier to review, and identical to the pattern used in Phase 4c of the v2 rollout playbook.

## Risks and rollback

| Risk | Mitigation |
|---|---|
| Free-tier repos silently reject parts of the install (per [github billing tier](../../../../../../Users/andrewrich/.claude/projects/-Volumes-extra-vieille-Workspaces-github-workflows/memory/github-billing-fleet.md) — not relevant for the install itself, but Phase 4 auto-merge wouldn't work) | Don't enable auto-merge on free-tier repos; surface the limitation in the report |
| Repo has bespoke caller workflow we don't recognize | CUSTOMIZED classifier flags it; human reviews |
| Repo branch protection blocks PR merge until checks pass — and `claude-review / run-review` is a required check that can't run yet because the workflow's not installed | The install PR adds the workflow; first run is on the install PR itself. Tested in bellwether. If branch protection wedge happens, temporarily relax via gh API |
| `.github/workflows/claude-code-review.yml` filename clashes with an existing unrelated workflow | Classifier checks for *any* file referencing `smartwatermelon/github-workflows/.github/workflows/claude-blocking-review.yml@`, not just the canonical filename |

Rollback: PR-based, so `gh pr close --delete-branch` per-PR if needed. No commits to main.

## Acceptance criteria

- Script lives at `bulk-install-claude-review.sh` in repo root.
- Shellcheck (`-S info`) clean, including no `# shellcheck disable` directives.
- `--dry-run` is default and produces no side effects.
- Re-running after a successful rollout produces an all-CURRENT report.
- README updated with a "Bulk install" section pointing at the new script.
- Audit script (`claude-review-audit.sh`) updated if its CURRENT-version constant moves to `@v3.0.0`. (Verify both scripts read from the same constant or comment-block to prevent drift.)

## Open questions

- Should the canonical stub source be the `.github` repo, or should we move it into this repo (e.g. `templates/claude-code-review.yml`) and have `.github` reference *this* repo as the source? Slight DX win — keeps everything about this tool in one repo. Decide in Phase 0.
- Do we want a parallel `bulk-uninstall` mode for emergencies (mass-remove the workflow if a v4 has a critical bug)? Probably not — the existing `[skip-claude-review]` escape hatch already lets individual PRs bypass without removal. Skip unless evidence demands it.
