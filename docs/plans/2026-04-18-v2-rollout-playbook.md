# Rollout playbook: shipping a v2 of a shared tool across a fleet of consumer repos

Captures the pattern used for the 2026-04-17 → 2026-04-18 rollout of
`smartwatermelon/github-workflows` v2.0.0 → v2.0.1 across 27 consumer
repos. Written as a reusable playbook for future tool rollouts
(e.g., `ralph-burndown`).

## Preconditions

- **One source repo** ships the tool (reusable workflow, library, CLI, config package).
- **N consumer repos** reference it by version pin (`@v1`, `@v1.2.0`, git SHA).
- You own both sides of the fence.
- A CI gate exists in consumers that will execute when the pin changes. Know how it reacts to self-modification of the caller file — it's usually a silent failure mode and you'll discover it via bellwether. Build this knowledge into your plan.

## Phases (in order)

### Phase 0 — Harden the source repo first

Before rolling to anyone:

- Fix all bugs currently producing noise in consumer CI. (We shipped #39 first — a one-line grep fix — before any new feature work. It was the bypass-mechanism that Phase 1 would need.)
- Ship new features / behavior changes as independent PRs, each with local + CI review passing. Squash-merge, one atomic PR per logical change.
- Dogfood: ensure the source repo's own PRs exercise the tool against itself (`self-review.yml` pattern). This catches issues before consumers do.
- When behavior changes significantly, tag **both** a specific semver (`v2.0.0`) and a floating major-version tag (`v2`). Ship a GitHub Release with full migration notes.
- Backport critical fixes to the prior major (`v1.x.4`) for consumers who won't migrate immediately.

### Phase 1 — Bellwether migration via PR flow

Pick **3 actively-developed consumer repos** plus any org-wide template repo. Migrate them via the normal PR flow. Purpose:

- Catch first-time friction the source-repo dogfood missed (for us: the `claude-code-action` workflow-validation-skip behavior).
- Validate that local + CI review still passes on realistic diffs.
- Build evidence to show the fleet the migration is safe.

Timebox: 15-30 min per PR including manual observation. Plan on ~2 hours total.

### Phase 2 — Admin direct-push batch

Once Phase 1 confirms clean:

- Use the GitHub REST Contents API (`PUT /repos/{owner}/{repo}/contents/{path}`) with `branch: main` to push changes directly. No branch, no PR, no CI cycle on the migration commit itself.
- Script it. Expect to fix one or two things (for us: BSD sed `\b` didn't work, used `perl` instead; one repo had a non-standard filename).
- Protocol 1 ("never commit to main") is deliberately bypassed here — admin authorization is explicit and documented in the plan.
- Verify idempotency: script should detect `[SKIP]` when the target is already at the intended version.

Timebox: 5-10 min for a batch of 20-30 repos.

### Phase 3 — Optional cleanup (renames, filename normalization)

If the fleet has accumulated naming inconsistency (we had legacy `claude-code-review.yml` vs current `claude-blocking-review.yml`), clean it up now. Contents API doesn't support rename, so use: `PUT /new/path` + `DELETE /old/path` = two commits per repo.

### Phase 4 — Lock to specific versions + enable Dependabot

The final state. Three sub-steps:

- **4a — Ship any fix needed to make Dependabot PRs pass cleanly.** Dependabot auto-modifies caller workflow files, which triggers self-modification security skips in most review tooling. Source repo needs to handle this gracefully (skip, not fail). For us: `v2.0.1` shipped with a `.github/workflows/*.yml` auto-skip branch.
- **4b — Bump every consumer to the specific semver** (`@v2` → `@v2.0.1`). Admin direct-push again.
- **4c — Add `.github/dependabot.yml`** to each consumer. Fresh file if absent; skip-with-warning if present (don't touch existing YAML programmatically). Minimal config:

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    commit-message:
      prefix: "chore"
```

After this, new versions of the source repo auto-PR themselves to consumers within a week. No more manual batch migrations.

### Phase 5 — Auto-merge Dependabot PRs (optional but strongly recommended)

Enabling Dependabot without auto-merge produces a backlog problem: the first fleet-wide scan revealed 100+ pending dependency updates that had accumulated over months. Manually merging each is painful.

Solution: a narrow-scope auto-merge workflow in every consumer that fires **only** for Dependabot PRs, **only** for patch + minor bumps (majors still require manual review).

Two steps per repo:

- **5a — Enable `allow_auto_merge: true`** via `PATCH /repos/{owner}/{repo}`. Idempotent.
- **5b — Install `.github/workflows/dependabot-auto-merge.yml`** via Contents API:

```yaml
name: Dependabot Auto-Merge
on:
  pull_request_target:
    types: [opened, synchronize, reopened]
permissions:
  contents: write
  pull-requests: write
jobs:
  auto-merge:
    if: github.actor == 'dependabot[bot]'
    runs-on: ubuntu-latest
    steps:
      - uses: dependabot/fetch-metadata@v2
        id: metadata
      - if: steps.metadata.outputs.update-type == 'version-update:semver-patch' || steps.metadata.outputs.update-type == 'version-update:semver-minor'
        env:
          PR_URL: ${{ github.event.pull_request.html_url }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh pr review --approve "$PR_URL"
          gh pr merge --auto --squash --delete-branch "$PR_URL"
```

Safety: `pull_request_target` runs the base-branch version of the workflow (PR can't bypass itself); `github.actor` is set by GitHub (not spoofable); the `update-type` check bounds the blast radius to patch + minor.

## Pitfalls encountered

| Pitfall | How we found it | How we handled it |
|---|---|---|
| BSD sed `\b` is a no-op | Phase 2 first run reported "sed made no change" on all 23 repos | Switched to `perl -pe` for word-boundary regex |
| Bypass marker grep mismatch | Docs said `[skip-claude-review: reason]` but code matched `[skip-claude-review]` | Fixed in Phase 0 (PR #39) before anything else |
| `gh api` in wrapper scripts doesn't forward `--repo` | Phase 1 merges failed from wrong CWD | `cd` into each clone before calling `gh pr merge` |
| `claude-code-action` refuses to run when caller workflow changes | Phase 1 bellwethers failed with "exceeded turn limit" after 30s | Phase 4a ships a skip for the specific failure mode |
| Unanchored `VERDICT: X` grep false-matches review prose | PR #47 self-review's text quoted the grep pattern | Anchor to line start/end in the Check verdict step |
| Content-adjacent config files in "doc-only" allowlist | Local reviewer flagged CODEOWNERS, dependabot.yml | Explicit NON-DOC exclusion for security-adjacent meta files |
| `allow_auto_merge: true` silently rejected on some repos | Phase 5 PATCH returned 200 OK but the field stayed `false` | **Private + GitHub Free tier repos can't enable auto-merge.** Only paid (Pro/Team) or public repos accept the setting. Either upgrade the repo, make it public, or skip auto-merge there. User enables manually via UI (Settings → General → Pull Requests) as workaround. |
| Enabling Dependabot exposes backlog | Fleet-wide Dependabot turn-on produced 100+ PRs on day 1 | Expected — it's catching months of drift. Bulk-enable `--auto` on the backlog (`gh pr merge --auto` in a loop) or merge through them manually. Subsequent weeks stay quiet. |

## Timings observed

| Phase | Operations | Wall clock |
|---|---|---|
| Phase 0 (source hardening) | 7 PRs shipped | 4-6 hours spread over session |
| Phase 1 (4 bellwether PRs) | 4 PR/merge cycles | ~45 min including bypass-marker diagnosis |
| Phase 2 (23 repo batch) | 23 admin direct-pushes | 30 seconds |
| Phase 3 (4 renames) | 8 API calls (create + delete per repo) | 15 seconds |
| Phase 4 (27 pins + 27 dependabot.yml) | 54 admin direct-pushes | 45 seconds |
| Phase 5 (27 auto-merge workflows + 27 PATCH calls) | 54 API calls | 30 seconds |

The PR-flow phases dominate. The admin batch phases are nearly free.

## Key decisions to make upfront (not mid-rollout)

- **Semver bump size** — major (v2) if behavior changes visibly, minor (v1.3) if purely additive. We chose major because the narrow-prompt behavior shift was user-visible.
- **Keep the prior major maintained** — yes/no. We shipped `v1.2.4` as a terminal backport for the grep fix.
- **Floating tag vs. specific tag + Dependabot** — floating is simpler short-term, Dependabot + specific is cleaner long-term. We chose Dependabot + specific once everything was migrated.
- **Who reviews the source repo's own workflow-file edits after the skip lands** — local reviewers are the primary safety net. CI review will self-skip on workflow-file changes. Accept this before shipping v2.0.1.

## Not to reuse blindly

- The specific bypass marker `[skip-claude-review: reason]` is github-workflows specific.
- The `claude-code-action` workflow-validation security skip is an upstream action's behavior; other tools won't have this exact issue but may have analogous self-modification concerns.
- File-path allowlists (`*.md`, `docs/`, image extensions, etc.) are context-specific. `ralph-burndown` will have its own set of "doc-only" equivalents.

## Adapting for ralph-burndown (or any other tool)

The structural pattern transfers. To port:

1. **Identify the source repo.** What ships the tool? What's its current version contract?
2. **Enumerate consumers.** `gh search code "uses: OWNER/REPO"` is a good start. Store the inventory in a comment or `.claude-review-ignore`-like file.
3. **Identify the self-modification failure mode.** If the tool runs on PR events that touch its caller, confirm how it behaves. Often: skip with non-zero exit (needs Phase 4a fix). Occasionally: silent success (no fix needed).
4. **Write the source-side fix.** What's the equivalent of the `.github/workflows/*.yml` skip? Same shape: detect the condition, short-circuit with a clear verdict/output, exit 0.
5. **Pick bellwethers.** Three active repos + any template. Same rationale.
6. **Run the Phases.** Mechanical once the adaptations above are in place.

The time-spent profile will look similar: most time in Phase 0 (source work) and Phase 1 (bellwether diagnosis); Phases 2–4 are scripted batch operations.
