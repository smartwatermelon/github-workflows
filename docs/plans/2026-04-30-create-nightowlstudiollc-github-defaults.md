# Create `nightowlstudiollc/.github` with org-level defaults

`nightowlstudiollc` is an actual GitHub organization (team plan, 9 private repos, created 2026-01-22) — unlike `smartwatermelon`, which is a user account. This means the full `.github` community-defaults + workflow-templates feature set works, including the **workflow picker** that surfaces stub workflows in "Actions → New workflow" for every repo in the org.

## Goal

Stand up `nightowlstudiollc/.github` mirroring the structure of `smartwatermelon/.github`, so:

1. New repos in the org get FUNDING.yml, profile/README.md, and dependabot config fallbacks automatically.
2. The Claude blocking review and Dependabot auto-merge templates appear in the Actions picker for every repo in the org.
3. The `claude-review-audit.sh` script (which already audits both orgs) stays accurate as templates spread.

This addresses the "new repos automatically inherit" half of the original question for the org side. Existing repos still need bulk-install (separate plan).

## Non-goals

- Forcing the workflow on every repo (that's the [org-wide enforcement plan](2026-04-30-required-workflows-nightowlstudiollc.md) using Repository Rulesets — separate decision).
- Mirroring **everything** from `smartwatermelon/.github`. Only mirror what's still load-bearing — drop or refresh anything stale.

## Preconditions

- Org admin access to `nightowlstudiollc`.
- `CLAUDE_CODE_OAUTH_TOKEN` is provisioned **per-repo** by Claude Code CLI's `/install-github-app`. There is no org-level installation scope. Andrew's working baseline is that every repo he owns already has the App installed; a missing secret on a specific repo is a remediation gap to flag, not an org-level config item. `claude-review-audit.sh` reports which repos lack the secret.
- The `smartwatermelon/.github` template fix (PR `smartwatermelon/.github#7`) merged. The mirror should land at `@v3.0.0`, not stale `@v2.0.1`.

## Phases

### Phase 0 — Inventory and decisions

- Enumerate what's in `smartwatermelon/.github`:
  - `.github/FUNDING.yml`
  - `.github/dependabot.yml`
  - `.github/workflows/claude.yml`  ← only applies to the .github repo itself
  - `profile/README.md`
  - `workflow-templates/claude-blocking-review.yml` + `.properties.json`
  - `workflow-templates/dependabot-auto-merge.yml`
- Decisions to make before creating files:
  - **FUNDING.yml** — does NightOwl Studio want sponsor links visible on every public repo? Probably no for an LLC. Either omit or include with appropriate links. Default: omit.
  - **profile/README.md** — yes, this becomes the org landing page at <https://github.com/nightowlstudiollc>. Worth investing 30min on a real page.
  - **claude.yml** (the `@claude` mention handler) — yes, mirror it. Same security `if:` guard.
  - **claude-blocking-review template** — yes. Same content as smartwatermelon's, pinned `@v3.0.0`.
  - **dependabot-auto-merge template** — yes. Identical content; the workflow doesn't reference org-specific paths.
  - **dependabot.yml in .github itself** — yes, same minimal config.

### Phase 1 — Create the repo

```bash
gh repo create nightowlstudiollc/.github \
  --private \  # or --public if you want the profile page indexed
  --description "Organization-level defaults: workflow templates, community files" \
  --clone
```

Decision: **private vs public**. The org's other repos are private (9/9). `.github` repos that hold a `profile/README.md` need to be public for the profile to render publicly — but `.github` *workflow-templates* work fine in a private `.github` repo. Three sub-options:

- **All-private**: profile README won't render publicly. Internal-only org. Reasonable if NightOwl doesn't need a public landing page.
- **All-public**: profile renders, but FUNDING/SECURITY/etc become public defaults. Fine, just be deliberate.
- **Two repos**: separate `.github-private` for workflow-templates if you want the public/private split. GitHub supports both: `.github-private` is the org-internal-only equivalent, surfaced only to org members.

Recommend **all-public** unless there's an explicit reason not to. Match the `smartwatermelon/.github` pattern.

### Phase 2 — Mirror files

Copy from `smartwatermelon/.github`:

| Source | Destination | Modifications |
|---|---|---|
| `workflow-templates/claude-blocking-review.yml` | same path | none (already at `@v3.0.0` after PR #7) |
| `workflow-templates/claude-blocking-review.properties.json` | same path | none |
| `workflow-templates/dependabot-auto-merge.yml` | same path | none |
| `.github/workflows/claude.yml` | same path | none |
| `.github/dependabot.yml` | same path | none |
| `profile/README.md` | same path | rewrite for NightOwl |
| `CLAUDE.md` | same path | rewrite for the new repo's purpose |
| `README.md` | same path | rewrite |

Skip `.github/FUNDING.yml` unless decided otherwise in Phase 0.

### Phase 3 — Verify the GitHub App is installed on target repos

`CLAUDE_CODE_OAUTH_TOKEN` is provisioned per-repo by Claude Code CLI's `/install-github-app` slash command. There is no `--org` flag and no org-level installation. Two cases:

- **Every existing nightowl repo:** Andrew's working baseline is that the App is already installed everywhere. Confirm with `claude-review-audit.sh` — any nightowl repo lacking the secret is a one-off gap to fix by running `/install-github-app` from a Claude Code CLI session in that repo.
- **The newly-bootstrapped `nightowlstudiollc/.github` repo itself:** the App did not auto-install, since the repo was created in this session. Run `/install-github-app` against it specifically before the `claude.yml` (`@claude` mention handler) inside it can fire.

When a repo later scaffolds the Claude Blocking Review template via the picker, the workflow only runs cleanly if `/install-github-app` has already been run against that repo. The `.github` repo's existence does not propagate the secret to consumers — it just makes the picker stub available.

### Phase 4 — Bellwether

Pick one existing `nightowlstudiollc/*` repo. Use the Actions UI: New workflow → "By Night Owl Studio" section → select Claude Blocking Review. Verify:

- Template populates with `@v3.0.0` pin.
- Commit it via the UI.
- Open a test PR. The `claude-review / run-review` check fires.
- Result is sane.

If the template doesn't show up in the picker: check that the `.github` repo is the org's actual `.github` repo (not `nightowlstudiollc/dot-github` or similar), and that the `workflow-templates/` directory has the right structure (`*.yml` + `*.properties.json` pairs, not nested folders).

### Phase 5 — Document and close out

- Update this repo's README to mention NightOwl scaffolding works via the org workflow picker.
- Update `claude-review-audit.sh` if it doesn't already cover NightOwl repos. (It does — verified at script line ~30.)
- Close out: the original question's "do new repos inherit?" is now **yes for nightowlstudiollc**, **no for smartwatermelon** (and won't change without org migration).

## Risks and rollback

| Risk | Mitigation |
|---|---|
| Template appears in picker but secret missing on the consuming repo → first run fails | Phase 3 explicit; `claude-review-audit.sh` is the per-repo check. Remediate with `/install-github-app` on the repo. |
| Free-tier features (auto-merge, branch protection rules) silently no-op on the `.github` repo if it lands on the wrong tier | NightOwl is on `team` plan per `gh api orgs/nightowlstudiollc`; no concern. Cross-check anyway |
| `profile/README.md` placeholder gets indexed before real content lands | Land Phase 2 commits in one PR or one direct push, not piecemeal |
| Existing nightowl repos with bespoke claude-review configs collide with the new template at install time | The template only affects *new* installs. Existing repos are bulk-install territory and untouched by this plan |

Rollback: `gh repo delete nightowlstudiollc/.github` removes everything cleanly. No fleet-wide impact since this only adds opt-in scaffolding for new workflows.

## Acceptance criteria

- `nightowlstudiollc/.github` exists, public, with the file inventory above.
- `CLAUDE_CODE_OAUTH_TOKEN` accessible to all org repos.
- Picker test from Phase 4 produces a working PR with green `claude-review / run-review`.
- `profile/README.md` renders at <https://github.com/nightowlstudiollc>.
- README in this repo (github-workflows) mentions both org sources.

## Open questions

- Should NightOwl have a different `extra_instructions` block in its template (e.g. domain-specific guidance for the LLC's product code)? Probably yes eventually — leave as comment placeholder, fill in once a NightOwl repo accumulates feedback patterns.
- Public vs private profile decided in Phase 1.
- Once this lands, do we want to split `claude-config`-style automation (an `install.sh` for `.github` repos)? Probably not — two orgs is the entire fleet; manual sync is fine.

## Postscript — 2026-04-30 closeout

Phases 1-3 and 5 complete. Phase 4 (bellwether picker test) effectively skipped:
the picker template was confirmed to surface under "By Night Owl Studio" in two
repos, but every active NightOwl repo already has `claude-blocking-review.yml`
installed (blocking the picker commit with "file already exists"). The audit
script verified all non-ignored NightOwl repos run `claude-review / run-review`
green. The picker's remaining hypothetical value (validating end-to-end on a
truly-fresh repo) is deferred until a new NightOwl repo is created.

Decisions recorded:

- Visibility: **public** (matches `smartwatermelon/.github` pattern; profile renders at <https://github.com/nightowlstudiollc>).
- FUNDING.yml: **omitted** (LLC, no sponsor links).
- `CLAUDE_CODE_OAUTH_TOKEN` installed on `nightowlstudiollc/.github` itself via `/install-github-app` (only repo-level gap surfaced by audit on the NightOwl side).
