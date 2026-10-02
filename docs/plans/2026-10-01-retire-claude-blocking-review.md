# Retire the CI Claude reviewer (#154, Phase 5)

Status: PLAN, 2026-10-01. Step 1 done (smartwatermelon/repo-template#11,
smartwatermelon/.github#19). Step 2 done (25 caller PRs merged 2026-10-02).
Phases 1–4 of #154 are done: `standards-check.yml` exists (#162, #164, #165)
and W3 flipped the required check fleet-wide.

## Decisions already made

- **No judgment reviewer in CI** (2026-09-08, dev-env `STATUS.md`). This
  answers #154's decision questions 1 and 2: no advisory CI reviewer either.
- **`claude-assistant.yml` is out of scope.** It is `@claude`-triggered, not a
  merge gate, and it keeps `CLAUDE_CODE_OAUTH_TOKEN`.
- **`nightowl-restore-blocking-review.sh` retires** with W3.
- **kebab-tax and kebab-tax-netlify are out of scope.** Do not touch them.
- **`networth-agent` stays on `claude-review`** (`IGNORED` by decision, finish
  line plan §141).
- **Never zero required checks.** No caller comes out of a repo that still
  requires `claude-review / run-review`.

## Survey (measured 2026-10-01, not estimated)

Read-only, all three owners, non-archived, non-fork. 33 repos visible.

| Group | Count |
| --- | --- |
| Caller present, `claude-review` NOT required | 26 |
| Caller present, `claude-review` still required | 2 |
| No caller | 4 |
| The reusable workflow itself (`github-workflows`) | 1 |

- Still required (2): `crazy-larry`, `networth-agent`.
- No caller (4): `smartwatermelon/.github`, `claude-config-backup`,
  `infinite-yaks`, `twistedmelonman/parmesan`.
- `github-workflows` also runs the reviewer on itself via `self-review.yml`.

The 26: `mac-server-setup`, `swift-progress-indicator`, `homebrew-tap`,
`claude-config`, `claude-wrapper`, `smartwatermelon-marketplace`,
`vpn-lan-bridge`, `mac-dev-server-setup`, `dotfiles`, `projectinsomnia`,
`archive-resolver`, `slack-mcp`, `spokane-snow`, `dev-env`, `scripts`,
`lock-sync`, `qwen-sidebar`, `personify`, `pr-review`,
`claude-code-workflows-agents`, `repo-template`, `huddle-transcribe`,
`gmail-newsletter-filter` (all `smartwatermelon`), and `tnjcleaning`,
`amelia-boone`, `.github` (all `nightowlstudiollc`).

Every caller pins `claude-blocking-review.yml@v3`. The kebab-tax repos did not
appear in any token's `nightowlstudiollc` listing; they are out of scope.

### What the survey changes in the plan

1. **The reusable workflow stays.** `crazy-larry`, `networth-agent` and
   possibly the kebab-tax repos still call it, and two of them require its
   check. Deleting it breaks them. Keep the file and mark it deprecated.
2. **`v3` is shared** with `claude-assistant.yml`. Moving `v3` for the
   assistant keeps the reviewer working as long as the file still exists on
   `main`. So "keep the file" is enough; no new major is needed now.
3. **smartwatermelon/github-workflows#177 is not moot.** The handoff called
   it moot, but `claude-assistant.yml` also uses `claude-code-action` at the
   same pin. Review and merge it on its own merits.
4. **The secret mostly stays.** Every caller repo except `dev-env` also has
   `claude.yml` (the assistant), which needs `CLAUDE_CODE_OAUTH_TOKEN`. Only
   `dev-env` can drop it.

## Steps

### 1. Stop new repos being born with the reviewer — AGENT

- `repo-template`: delete `.github/workflows/claude-blocking-review.yml`;
  fix `README.md` lines 20–21 and 37.
- `smartwatermelon/.github`: delete
  `workflow-templates/claude-blocking-review.yml` and its
  `.properties.json`.

Do these first, so no new repo picks up a caller during the sweep.

### 2. Fleet sweep — AGENT (one agent, Sonnet, scripted)

For each of the other 25 repos (the 26 minus `repo-template`, done in
step 1). `nightowlstudiollc/.github` has a real caller, so it is in the sweep.

1. Re-read required checks. **Skip the repo** if `claude-review / run-review`
   is required (guards against drift since the survey).
2. Branch, `git rm .github/workflows/claude-blocking-review.yml`, commit,
   push, open a PR. Title: `ci: retire the CI Claude reviewer`. Body names
   #154.
3. Stop at PR open. The main session polls CI and asks Andrew for one batch
   merge-lock (`merge-lock auth owner/a#1,owner/b#2 "ok"`).

Merge order: `claude-config` is `strict`, so its PR merges alone. Others in
any order.

### 3. github-workflows itself — AGENT

- `self-review.yml`: remove the `claude-review` job; keep
  `guard-no-checkout`.
- `claude-blocking-review.yml`: add a header saying DEPRECATED, which callers
  remain, and "do not delete while any caller exists".
- Retire `bulk-install-claude-review.sh`, `claude-review-audit.sh`,
  `nightowl-restore-blocking-review.sh`; fix `README.md` and `zizmor.yml`.

### 4. References elsewhere — AGENT

- `dotfiles`: `zizmor/zizmor.yml:93` ignore entry; comment at
  `git/hooks/pre-push:93`.
- `dev-env`: `README.md:35,44`; `docs/STATUS.md` (with the end-of-stint
  update); `docs/token-rotation.md` (the reviewer is no longer a token user).
- `claude-wrapper`: `CLAUDE.md:181`.
- Leave `claude-config` test fixtures alone: they are recorded API responses.

### 5. Secret — HUMAN

Delete `CLAUDE_CODE_OAUTH_TOKEN` from `smartwatermelon/dev-env` only. Agent
tokens get HTTP 403 on the secrets API, so this is Andrew's.

### 6. Verify — AGENT

Re-run the survey (`survey154.sh` in the session scratchpad; commit it under
`scripts/` if it is worth keeping). Expect: callers only in `crazy-larry`
and `networth-agent` (plus kebab-tax, unseen); no repo requires
`claude-review` except those two.

### 7. Close #154 — AGENT

Comment with the survey before/after, the holdouts and why, and a pointer to
this plan. Close it. Leave a note that the reusable file can be deleted once
the last caller is gone.

## Decided

`crazy-larry` stays on `claude-review`, like `networth-agent` (Andrew,
2026-10-01).

## Cost and size

- Agent time: about 1–1.5 h for steps 1–4, mostly mechanical.
- Andrew: one batch merge-lock (about 30 PRs), one sequential lock for
  `claude-config`, and one secret deletion.
- Saves one Claude CI run per PR on 26 repos, and the fleet's dependency on
  `claude-code-action` being up for merges (#133).
