# github-workflows

Reusable GitHub Actions workflows.

## Bare-tag versioning (`v1`, `v2`, `v3`)

> `claude-blocking-review.yml` was retired and deleted on 2026-10-06 (follows
> [dev-env#194](https://github.com/smartwatermelon/dev-env/issues/194)). The
> required check is now `standards-check / run-standards-check`. Old tags keep
> the file at their commits; the bare `v3` tag is now used by
> `claude-assistant.yml`.

### Versioning

| Tag | Meaning |
| ----- | --------- |
| `@v3` | **Recommended for all callers.** Floating major — tracks the latest v3.x.y release, so security fixes reach you when the tag is repointed here, without a PR in your repo. |
| `@v3.1.2` | Current exact release — the GHSA-8q5r-mmjf-575q fix (`claude-code-action` v1.0.193), `persist-credentials: false`, the `github.actor` template-injection fix, and `actions/checkout` v7.0.1. Use an exact pin only if you have a specific reason to freeze; see the warning below. |
| `@v3.1.0` | Earlier v3 release — first with the in-job Dependabot skip. v3 dropped the `max_turns` input; remove it from caller workflows when bumping from v2. |
| `@v2` | Previous stable major (still supported for callers that haven't migrated; passes `--max-turns` to the agent and accepts `max_turns:` input) |
| `@v1` | **Deprecated — no longer updated.** See below. |
| `@main` | Latest (may include breaking changes) |

#### Prefer floating `@v3` over an exact pin

Exact tags like `@v3.1.0` are immutable. A caller pinned to one **silently
opts out of every fix published afterwards**, including security fixes, until
someone opens a PR in that repo.

This is not hypothetical. GHSA-8q5r-mmjf-575q (RCE and secret exfiltration via
`claude-code-action` < 1.0.74) was remediated here by bumping the action and
repointing the floating tags. **19 repos never received it**, because they
pinned `@v3.1.0` — a tag cut before the fix existed. They kept resolving to the
vulnerable action while looking perfectly conformant in their own workflow
files. Earlier guidance in this table recommended exactly that pin, which is
how it happened.

Floating `@v3` inverts this: one tag repoint here reaches every caller.

The trade-off is real — a bad release also reaches everyone at once. What
bounds it: this repo is branch-protected with a required standards check, the
reusable workflows SHA-pin every third-party action they use, `dependabot.yml`
surfaces those bumps as reviewable PRs, and floating-tag moves are manual and
human-authorized. There is no automation that repoints a floating tag.

Pin an exact version only when you have a specific reason to freeze, and treat
it as a decision to opt out of automatic security updates — so audit it
yourself.

**Auditing note:** a caller's ref cannot be checked by pattern-matching. Both
failure modes seen in this fleet looked correct in the consumer file — a raw
commit SHA annotated `# v3`, and an exact `@v3.1.0` serving months-old content.
Resolve the ref to the action version it actually delivers:

```console
$ gh api "repos/smartwatermelon/github-workflows/contents/.github/workflows/claude-assistant.yml?ref=<REF>" \
    --jq '.content' | base64 -d | grep -oE 'claude-code-action@[a-f0-9]{8}'
```

### `zizmor.yml` — required alongside the caller stubs

If you run `zizmor` (e.g. as a pre-commit hook), copy [`zizmor.yml`](./zizmor.yml)
from this repo to your repo root when you adopt the caller stubs.

Without it, zizmor's blanket hash-pin policy reports roughly **9 high findings
against a byte-identical standard stub** — the tag refs and the required
`permissions:` blocks — and the only workaround is `SKIP=zizmor` on every
commit that touches a workflow.

**That workaround is the hazard the config exists to remove.** Routinely
skipping the security linter is what let `anthropics/claude-code-action` sit at
v1.0.70 for 123 releases while carrying GHSA-8q5r-mmjf-575q. A linter people
bypass by habit protects nothing.

The config encodes two documented policy decisions and nothing else:

| Rule | Treatment | Why |
| --- | --- | --- |
| `unpinned-uses` | `ref-pin` for `smartwatermelon/github-workflows/*`, strict `hash-pin` for everything else | Reflects the two-class policy above. Third-party findings stay visible. |
| `excessive-permissions` | ignored for the three standard caller filenames | Those blocks are required by the reusable workflows; removing them causes `startup_failure`, not a narrower blast radius. |

The `excessive-permissions` ignore list matches on **caller filename**, not on
which reusable workflow the caller invokes. Use the standard names:

| Caller filename | Calls |
| --- | --- |
| `dependabot-auto-merge.yml` | `dependabot-auto-merge.yml` |
| `standards-check.yml` | `standards-check.yml` |

Name a caller anything else and zizmor reports `excessive-permissions` against
it with no indication why. Either rename it to the standard filename or add
your local name to the `ignore:` list in your copy of `zizmor.yml`.

It is deliberately **not** a blanket mute. On a representative consumer it takes
findings from 9 high to 2 — and the 2 that survive are genuine third-party
actions pinned to floating majors in that repo's own workflows, which is a real
gap worth fixing rather than policy. A repo's own workflows are still audited
normally.

#### The `v1` line is deprecated

**Tags in this repo are repo-wide, not per-file.** A git tag labels a commit,
so every tag contains *every* reusable workflow present at that commit — `@v3.1.2` and `@v1.2.6`
are byte-identical if they point at the same commit. The version "lines" are
independent release tracks, not versions of separate products.

`v1` was originally the track for `claude-assistant.yml`, with `v2`/`v3`
tracked the since-retired `claude-blocking-review.yml`. That split no longer reflects reality:
**every caller in the fleet references the assistant via the `v3` line**, and
as of 2026-08-17 no repo references `v1` at all.

Maintaining two labels for one codebase costs a release step and invites the
mistake of cutting one and not the other. So:

- **`v1` is frozen** at `v1.2.6` and will not be updated further.
- **Point every caller at the `v3` line**, including `claude-assistant.yml`
  callers. The floating `@v3` tag is the recommended ref for assistant
  callers — see "Prefer floating `@v3` over an
  exact pin" above; that guidance is not scoped to one workflow.
- If you are still on `@v1` or `@v1.2.x`, move to `@v3`. There is no
  interface change — the files are identical at equivalent commits.

Note `dependabot-auto-merge` uses a **prefixed** namespace
(`dependabot-auto-merge-v1`, etc.) precisely to avoid this problem. That is
the pattern to follow if a fourth workflow is ever added here; a new workflow
cannot safely start its own bare `v1` while one already exists.

---

## `dependabot-auto-merge`

Reusable workflow: approves and auto-merges Dependabot PRs for patch and
minor version updates once the **required** checks pass. Major-version
bumps are left open for manual review, unless the dependency is in a
trusted namespace or the caller opts in with `allow_major: true`.

"Required" means branch protection's list, not every check. `gh pr merge
--auto` waits only on required checks, and most fleet repos require only
`standards-check`. On the patch/minor path, a red `build` that is not
required does not stop the merge.

### Opt-in: `allow_major`

`allow_major: true` (default `false`) lets a **single-dependency** major
bump merge without a human, under a stricter gate than the patch/minor
path (smartwatermelon/dev-env#120):

- The job waits until **every** check on the PR head SHA has finished,
  required or not, except this workflow's own. Any failed or cancelled
  check leaves the PR for manual review. SKIPPED and NEUTRAL do not block.
- It then merges directly with `--match-head-commit`, not `--auto`, so a
  later Dependabot rebase cannot inherit an armed auto-merge.
- It gives up with a `::notice::` (never a red check) after about 40
  minutes, when the head moves, or when it cannot see its own check run.
  The job's token has no `checks` permission; on a private repo the check
  list may come back blank, and the self-visibility test turns that into
  "manual review" instead of a false "all green".
- Grouped PRs never take this path.
- Pair it with a Dependabot `cooldown` so a major is some days old before
  its PR opens. `semver-major-days` works only for ecosystems that support
  SemVer (npm, pip, uv, and others); `github-actions` honors only
  `default-days`. **Security updates ignore `cooldown`**, so with
  `allow_major: true` a security-driven major can merge on day 0 once all
  checks are green.

### Setup

`.github/workflows/dependabot-auto-merge.yml` in your repo:

```yaml
name: Dependabot Auto-Merge

on: # zizmor: ignore[dangerous-triggers] required to run from base branch; no PR code executed here
  # This suppression is only valid as long as this caller stays a thin
  # delegate: no actions/checkout, no execution of PR-controlled code.
  # See "Security invariant: no actions/checkout" below for the full
  # justification. If you add checkout or run PR content in this file,
  # remove this suppression — it would then be hiding a real risk.
  pull_request_target:
    types: [opened, synchronize, reopened]

permissions:
  contents: write
  pull-requests: write

jobs:
  # This caller stub is intentionally a thin delegate, not a full
  # implementation. The version-comparison logic, the dependabot/actions
  # always-trusted namespace defaults, and the actor-spoofing guard all
  # live in the canonical workflow (smartwatermelon/github-workflows,
  # this file) rather than here — a local diff that only shows this
  # stub shrinking will not show that logic; it moved, not disappeared.
  # See smartwatermelon/dev-env#20 for why: copy-pasting this workflow
  # into every consuming repo meant fixing a bug meant editing N repos,
  # not one. The tag pin below (not a SHA) is deliberate: reusable
  # workflows here use a repo-wide semver tag convention (see
  # "Versioning" below), not per-action SHA pinning.
  dependabot-auto-merge:
    uses: smartwatermelon/github-workflows/.github/workflows/dependabot-auto-merge.yml@dependabot-auto-merge-v2
    with:
      trusted_namespaces: 'smartwatermelon' # adjust to your own org; dependabot/actions are always trusted
      # allow_major: true  # optional; see "Opt-in: allow_major" above
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
to this file.** The guardrail below enforces this (closes #64):

- `self-review.yml`'s `guard-no-checkout` job greps this repo's own
  copy of `dependabot-auto-merge.yml`, and its caller
  `self-dependabot-auto-merge.yml`, and fails the PR if
  `actions/checkout` appears.

This repo auto-merges its own Dependabot PRs through
`self-dependabot-auto-merge.yml`. It pins `@dependabot-auto-merge-v2`
rather than a local path, so an unreleased change to the reusable
workflow never decides merges here.

### Versioning

Tagged with a prefixed namespace — `dependabot-auto-merge-v1`,
`dependabot-auto-merge-v1.0.0`, etc. — rather than the bare `v1`/`v2`/`v3`
tags used by `claude-assistant` (and formerly `claude-blocking-review`). Git tags
are repo-scoped, not per-file; a bare `v1` on this repo already exists.
A second, unrelated file can't safely "start its own v1" in the same tag
namespace. (The bare `v1` line is now frozen and deprecated — see
"The `v1` line is deprecated" under Versioning — but the tag still exists,
so the namespace collision this prefix avoids is permanent.)

### Rollout discipline

New tags of this workflow (and behavior-changing bumps) are pointed at
from 2-3 low-traffic pilot repos first, pinned to the specific new tag
(not a floating major). Let at least one real Dependabot PR flow
through each pilot and confirm correct patch/minor-only behavior before
repointing any floating tag fleet-wide. This workflow approves and
merges PRs unattended with no fallback reviewer behind it — a
bug here ships to every repo pinned to the affected tag at once, so it
gets the same pilot-then-fleet discipline as the org-level rollout
work.

---

## `standards-check.yml`

Reusable, deterministic, secret-free standards check. Per
[dev-env#60](https://github.com/smartwatermelon/dev-env/issues/60) and
[github-workflows#154](https://github.com/smartwatermelon/github-workflows/issues/154),
decided 2026-09-08, this check replaced the retired `claude-blocking-review.yml` as the
fleet's required check, with no judgment reviewer kept in CI. Rollout (W2)
and retirement of the old required check (W3) follow as separate phases; see
[`smartwatermelon/dev-env` `docs/superpowers/plans/2026-09-08-w1-standards-check.md`](https://github.com/smartwatermelon/dev-env/blob/main/docs/superpowers/plans/2026-09-08-w1-standards-check.md)
for the full plan.

It installs pinned linters and runs `standards/run-standards.sh` from this
repo, checked out at the SHA of the workflow file itself (`job.workflow_sha`),
so the script, the configs, and the running workflow always agree.

### Setup

`.github/workflows/standards-check.yml` in your repo:

```yaml
name: Standards Check
on:
  pull_request:
    types: [opened, synchronize, ready_for_review, reopened]
permissions:
  contents: read
jobs:
  standards-check:
    uses: smartwatermelon/github-workflows/.github/workflows/standards-check.yml@standards-check-v1
```

The canonical copy is `standards/caller-stub.yml`;
`bulk-install-standards-check.sh` installs it fleet-wide.

Name the caller job `standards-check`; the required check is then
`standards-check / run-standards-check` (caller job `standards-check`, inner
job `run-standards-check`). With reusable workflows, GitHub reports the
**inner job** as the status check, so the check name follows the caller job
name regardless of which repo you're in.

### Inputs

| Input | Type | Default | Description |
| ----- | ---- | ------- | ----------- |
| `shellcheck` | boolean | `true` | Run `shellcheck -S info` over shell files |
| `yamllint` | boolean | `true` | Run yamllint over YAML files |
| `actionlint` | boolean | `true` | Run actionlint over `.github/workflows` |
| `zizmor` | boolean | `true` | Run zizmor over `.github/workflows` |
| `markdownlint` | boolean | `true` | Run markdownlint-cli2 over Markdown files |
| `node_floor_check` | boolean | `true` | Fail on Node.js pins below `node_floor` |
| `node_floor` | string | `"22"` | Lowest supported Node.js major |

### Config precedence

Per linter, a config at the caller repo's root wins. Otherwise the canonical
file from **this** repo is used — `standards/markdownlint.json`,
`standards/yamllint.yml`, or root `zizmor.yml` — fetched at
`job.workflow_sha` (the SHA of the called workflow file), so the configs
always match the workflow version that's running. A dedicated step resolves
that SHA and fails loudly if it is empty, rather than letting
`actions/checkout` silently fall back to the default branch and lint the
wrong commit. This makes root [`zizmor.yml`](./zizmor.yml) the fleet-wide CI
fallback policy for any consuming repo that has no `zizmor.yml` of its own —
its `dependabot-cooldown` ignore, for example, applies fleet-wide by design.

`.github/actionlint.yaml` in this repo carries a scoped ignore for
`job.workflow_sha` on `standards-check.yml`, because actionlint 1.7.12's
context schema hasn't caught up to that (documented, GitHub-populated)
property yet. Remove the ignore once actionlint recognizes it.

### Tool versions

Pinned and checksum-verified in the workflow's `env:` block:

| Tool | Version | Verification |
| ---- | ------- | ------------- |
| shellcheck | 0.11.0 | SHA-256 |
| actionlint | 1.7.12 | SHA-256 |
| zizmor | 1.30.0 | SHA-256 |
| yamllint | 1.38.0 | pinned via `pipx install` |
| markdownlint-cli2 | 0.23.2 | pinned via `npm install -g` |

Bumps are manual PRs to this repo — Dependabot does not track these
versions (they're plain strings in a workflow `env:` block, not a manifest
Dependabot understands).

### Local command

```bash
bash standards/run-standards.sh --repo <dir>
```

Runs the same checks CI runs, against a local checkout.

### Tests

```bash
bash tests/run-tests.sh
```

Requires `shellcheck`, `yamllint`, `actionlint`, `zizmor`, and
`markdownlint-cli2` (all via Homebrew), plus `jq`.

### Validation

On 2026-09-08, a throwaway PR
([#163](https://github.com/smartwatermelon/github-workflows/pull/163)) with
a real `SC2086` was pushed against the caller workflow to confirm the gate
actually fails on a known-bad case. It did:
`standards-check / run-standards-check` failed in
[run 34267112924](https://github.com/smartwatermelon/github-workflows/actions/runs/34267112924),
with shellcheck reporting the injected problem. PR #163 was then closed
without merging.

### Versioning

| Tag | Meaning |
| ----- | --------- |
| `standards-check-v1` | **Recommended for callers.** Floating major — moved manually and human-authorized, exactly like `@v3` above. |
| `standards-check-vX.Y.Z` | Exact release. Pin only with a specific reason to freeze; see the "Prefer floating `@v3`" discussion above — the same trade-off applies here. |

This workflow uses its own prefixed tag namespace for the same reason
`dependabot-auto-merge` does: git tags in this repo are repo-scoped, not
per-file, so a fourth workflow starting a bare `v1` would collide with the
existing `claude-assistant` `v1` line.

---

## `netlify-site-checks.yml`

Reusable acceptance check for a Netlify site, run against the deploy Netlify
actually published
([dev-env#193](https://github.com/smartwatermelon/dev-env/issues/193)). It
replaces the hand-copied `verify-deploy-preview.yml` files in the site repos,
and adds a check of the production deploy after every merge, which nothing
ran before.

The triggering event picks the mode:

| Event | Mode | Waits for | Then checks |
| ----- | ---- | --------- | ----------- |
| `pull_request` | preview | The commit status Netlify posts on the PR head, context `netlify/<netlify-site>/deploy-preview` | its `target_url` |
| `push` | production | The Netlify API deploy with `context == "production"` and `commit_ref` equal to the pushed SHA, until `state` is `ready` | the site's `ssl_url` (primary custom domain), else `url` |

Once the deploy is ready, the workflow runs the [baseline check](#baseline-check)
against it, then the caller's check script if there is one.

Any other event fails. Both waits give up after 10 minutes. A production
deploy in `error` state fails at once and prints Netlify's `error_message`;
a timeout prints every state it saw (`not-yet-present`, `building`,
`request-failed`, ...). Production mode exists because Netlify posts no
commit status for production deploys.

The wait logic is `netlify/wait-for-preview.sh` and
`netlify/wait-for-production.sh`, checked out from this repo at
`job.workflow_sha`, as `standards-check.yml` does with its scripts. The
baseline check and the check-script selection (`netlify/baseline-check.sh`,
`netlify/select-check-script.sh`) come from the same checkout.

### Baseline check

Every caller gets `netlify/baseline-check.sh <base-url>`, run before the
caller's own script. It fails unless `GET /` returns HTTP 200 (redirects
followed; 30-second timeout, 2 retries) with a body of at least 1024 bytes
that contains a `<title>` element. It catches an empty, truncated, or
non-HTML deploy. It knows nothing about the site, so a site that can say
more about itself should still ship a check script.

A site with no check script of its own (a static site that never changes,
such as smartwatermelon/crazy-larry) gets the baseline check alone. It needs
no `check-script` input: see the default-path rule in [Setup](#setup).

### How the waits work

**Preview** is a port of the poll in nightowlstudiollc/amelia-boone's
`verify-deploy-preview.yml`. It reads the commit status rather than building
the preview URL by hand: that tells "still building" from "deploy failed",
and the checks run against the deploy Netlify published for this commit. A
`success` with no `target_url` fails rather than checking nothing.

It calls the **singular** `/commits/{sha}/status`, which keeps only the
latest status per context. The `head -1` after each `jq` is defensive and
does nothing on that endpoint. It is there because the plural
`/commits/{sha}/statuses` is one character away and returns full history:
every amelia-boone PR checked had two rows for the context. Fed that, the
script would read `success\npending`, match no branch, and poll to the
deadline on a deploy that succeeded (amelia-boone#50). Keep `head -1` if the
endpoint changes. `tests/test-wait-for-preview.sh` covers the two-row case
and refuses the plural endpoint.

**Production** reads the Netlify API with `NETLIFY_AUTH_TOKEN`. The token is
written to curl as a config on stdin (`curl -K -`) by `printf`, a bash
builtin, so it is never in any process's argv and never in a file on disk.
`-H "Authorization: Bearer $TOKEN"` would put it in argv. A failed request
counts as `request-failed` and the wait continues, so a bad token or a wrong
site name shows up in the timeout message.

API facts it relies on, checked on 2026-10-06 against the OpenAPI spec at
<https://open-api.netlify.com/swagger.json> (`site` and `deploy`
definitions) and against live responses for `ameliabooneracing`:

- `{site_id}` accepts `<name>.netlify.app` in place of the site UUID.
- A deploy has `context` (`production`, `deploy-preview`, ...), `state`,
  `commit_ref` (the full SHA), and `error_message`.
- `GET /sites/{site_id}/deploys` lists newest first (descending
  `created_at`). The script takes the first match, so a retried deploy wins
  over an earlier `error` for the same SHA.
- `site.ssl_url` is the primary custom domain over https
  (`https://ameliabooneracing.com`). `site.url` is the fallback.

### Setup

`.github/workflows/netlify-site-checks.yml` in the site repo. The canonical
copy is `netlify/caller-stub.yml`:

```yaml
name: Netlify Site Checks
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
  statuses: read
jobs:
  netlify-site-checks:
    uses: smartwatermelon/github-workflows/.github/workflows/netlify-site-checks.yml@netlify-site-checks-v1
    with:
      netlify-site: ameliabooneracing
    secrets:
      NETLIFY_AUTH_TOKEN: ${{ secrets.NETLIFY_AUTH_TOKEN }}
```

- With the caller job named `netlify-site-checks`, the status check is
  `netlify-site-checks / site-check` (caller job / inner job).
- `statuses: read` is for preview mode, which reads commit statuses.
- Pass the secret by name, not with `secrets: inherit`, so the workflow gets
  only this one secret. It is handed to the wait step only on `push`.
- The check script is the site repo's own. It runs from the repo root as
  `<script> <base-url>`, after the baseline check, must be executable, and
  must exit nonzero on failure. The workflow verifies it before it starts to
  wait:
  - `check-script` left at its default (`scripts/check-deploy-preview.sh`)
    and the file absent: skipped with a `::notice::`; only the baseline
    check runs. Passing that default path explicitly behaves the same, since
    the workflow cannot tell the two apart.
  - `check-script` set to any other path and the file absent: fails at once
    (exit 2), to catch a typo.
  - The file present but not executable: fails at once (exit 2).

### Inputs

| Input | Type | Default | Description |
| ----- | ---- | ------- | ----------- |
| `netlify-site` | string | (required) | Netlify site name: the `<name>` in `<name>.netlify.app` |
| `check-script` | string | `scripts/check-deploy-preview.sh` | Path in the caller repo, invoked as `<script> <base-url>` after the baseline check. Skipped if absent at the default path; fails if absent at any other path. |
| `timeout-minutes` | number | `20` | Job timeout. The wait alone runs to 10 minutes. |

| Secret | Required | Description |
| ------ | -------- | ----------- |
| `NETLIFY_AUTH_TOKEN` | production only | Netlify personal access token. A `push` run without it fails with a message that says so. |

### Tests

`tests/test-wait-for-preview.sh` and `tests/test-wait-for-production.sh` run
the wait scripts against stub `gh` and `curl` in `tests/stub-netlify/`.
`NETLIFY_POLL_INTERVAL` and `NETLIFY_POLL_DEADLINE` (seconds) shorten the
poll for tests. `tests/test-baseline-check.sh` runs the baseline check
against a stub `curl` in `tests/stub-baseline/`, and covers the check-script
selection, including that its default matches the workflow input's.

### Versioning

| Tag | Meaning |
| ----- | --------- |
| `netlify-site-checks-v1` | Floating major for callers, moved manually and human-authorized, like `standards-check-v1`. |

Prefixed for the same reason as `standards-check-v*`: tags in this repo are
repo-scoped, not per-file.

---

## `auto-tag.yml`

Reusable workflow that tags each push to the default branch with the next
patch version, so an install can say which version it installed
([dev-env#72](https://github.com/smartwatermelon/dev-env/issues/72)).
Callers: dotfiles, claude-config, and scripts.

### How the version is picked

1. If the pushed commit (`github.sha`) already has a `vX.Y.Z` tag, the run
   does nothing and passes. A re-run is a no-op.
2. Otherwise it takes the highest strict `vMAJOR.MINOR.PATCH` tag in the repo
   (`sort -V`, so `v1.0.10` is above `v1.0.9`) and adds 1 to PATCH.
3. The result is that or `v<floor>`, whichever is higher. With no `vX.Y.Z`
   tag at all, the result is `v<floor>`.

Only strict numeric tags count: `standards-check-v1`, `v3`, `v1.2.3-rc1`,
`1.0.0`, and `v01.0.0` are ignored. Examples with the default floor `1.0.0`:
an old `v0.0.2` gives `v1.0.0`; `v1.0.0` and `v1.0.4` give `v1.0.5`.

The tag is lightweight and is pushed as `git push origin refs/tags/vX.Y.Z`,
never `--force`. If the name already exists on the remote, the push fails and
the job goes red; no tag ever moves. The job has a concurrency group per
caller repo (`auto-tag-<owner/repo>`, never cancelled), so two quick merges
run one after the other and take different numbers. GitHub keeps only one
pending run per group: if three merges land while a run is in progress, the
middle one is dropped and its commit stays untagged. The next tag is on a
later commit that contains it.

Any event other than a push to the default branch fails the job.

The version is written to the job summary and returned as the `version`
output (empty when the commit was already tagged).

### Credentials

Both checkouts use `persist-credentials: false`, so no token is written to
`.git/config`. The push step gets `${{ github.token }}` as `GH_TOKEN` and
hands it to git through `auto-tag/git-credential-env.sh`, a credential helper
that reads it from the environment. The token is never in a file on disk or
in any process's argv. The helper and the scripts come from this repo,
checked out at `job.workflow_sha` as in `netlify-site-checks.yml`. No caller
code runs in the job.

A tag pushed with `GITHUB_TOKEN` does not start other workflows, so an
`on: push: tags` workflow in the caller does not run for these tags.

### Setup

`.github/workflows/auto-tag.yml` in the caller repo. The canonical copy is
`auto-tag/caller-stub.yml`:

```yaml
name: Auto Tag
on:
  push:
    branches: [main]
permissions: {}
jobs:
  auto-tag:
    permissions:
      contents: write # push the version tag
    uses: smartwatermelon/github-workflows/.github/workflows/auto-tag.yml@auto-tag-v1
```

`contents: write` is granted on the job, not the workflow, so zizmor's
`excessive-permissions` does not fire on the caller.

### Inputs

| Input | Type | Default | Description |
| ----- | ---- | ------- | ----------- |
| `floor` | string | `"1.0.0"` | Lowest version to tag, `MAJOR.MINOR.PATCH` with no leading `v`. Anything else fails the job. |

### Tests

`tests/test-auto-tag.sh` runs `auto-tag/next-version.sh` against throwaway
git repos, covering every rule above, and runs `auto-tag/push-tag.sh`
against a local bare remote to show that a colliding tag fails without
moving. It never touches this repo's tags.

### Versioning

| Tag | Meaning |
| ----- | --------- |
| `auto-tag-v1` | Floating major for callers, moved manually and human-authorized, like `standards-check-v1`. |
| `auto-tag-vX.Y.Z` | Exact release. |

Prefixed for the same reason as `standards-check-v*`.

---

## `semgrep-scan.yml`

Reusable static-analysis check with Semgrep Community Edition
([dev-env#166](https://github.com/smartwatermelon/dev-env/issues/166)). It
stands in for CodeQL on the private `nightowlstudiollc` repos, which do not
have GitHub Code Security. The pilot caller is nightowlstudiollc/reliquarist.

It is **not** a required check. On a pull request it fails only on findings
that are new in that PR, so existing findings in a repo do not turn every PR
red.

The triggering event and the secret pick the mode:

| Event | `SEMGREP_APP_TOKEN` | Runs |
| ----- | ------------------- | ---- |
| `pull_request` | absent or empty | `semgrep scan --error --config <each ruleset> --baseline-commit <PR base SHA>` |
| `push`, `workflow_dispatch` | absent or empty | `semgrep scan --error --config <each ruleset>` (whole tree) |
| any of the three | set | `semgrep ci` |

Any other event fails with exit 2, `pull_request_target` included.

`--baseline-commit` makes Semgrep report only findings that are not also
present at the PR base (`github.event.pull_request.base.sha`). The caller is
checked out with `fetch-depth: 0` so that commit is in the history. A run
whose base commit is missing fails with exit 2 instead of scanning the wrong
range. A full scan on `push` or `workflow_dispatch` fails on every finding,
old or new; that is why the caller stub leaves `push` commented out.

**Token mode.** With `SEMGREP_APP_TOKEN` set, the workflow runs `semgrep ci`,
which reports to the Semgrep platform. The platform's policies then choose
the rules and the `rulesets` input is ignored. No repo uses a token today;
the secret is there so a repo can move to the platform later without a new
workflow. A PR from Dependabot or a fork gets no secrets, so it runs in scan
mode.

**No code-scanning upload.** The job has only `contents: read`: no
`security-events: write` and no SARIF upload. Code scanning on a private repo
needs the Code Security SKU this workflow exists to avoid. Findings appear in
the job log.

The mode logic is `semgrep/run-semgrep.sh`, checked out from this repo at
`job.workflow_sha`, as in `netlify-site-checks.yml`. Semgrep is installed
with pip into a venv from `semgrep/requirements.txt`, which pins one version;
Dependabot (`pip`, `/semgrep`) bumps it. `SEMGREP_SEND_METRICS=off` and
`--metrics=off` keep Semgrep from sending usage metrics. Registry rulesets
(`p/...`) need no token.

### Setup

`.github/workflows/semgrep-scan.yml` in the caller repo. Keep that file name
and the job name `semgrep-scan`: the daily digest will find callers by them.
The canonical copy is `semgrep/caller-stub.yml`:

```yaml
name: Semgrep Scan
on:
  pull_request:
  workflow_dispatch:
permissions:
  contents: read
jobs:
  semgrep-scan:
    uses: smartwatermelon/github-workflows/.github/workflows/semgrep-scan.yml@semgrep-scan-v1
    secrets:
      SEMGREP_APP_TOKEN: ${{ secrets.SEMGREP_APP_TOKEN }}
```

- The status check is `semgrep-scan / semgrep` (caller job / inner job).
- Pass the secret by name, not with `secrets: inherit`. With no such secret
  in the repo it is empty, and the run uses scan mode.
- To skip paths, add a `.semgrepignore` to the caller repo.

### Inputs

| Input | Type | Default | Description |
| ----- | ---- | ------- | ----------- |
| `rulesets` | string | `p/default p/javascript p/typescript p/python p/ruby` | Semgrep configs, separated by spaces or newlines, each passed as `--config`. Registry names or paths in the caller repo. Ignored in token mode. |
| `timeout-minutes` | number | `20` | Job timeout. |

| Secret | Required | Description |
| ------ | -------- | ----------- |
| `SEMGREP_APP_TOKEN` | no | Semgrep platform token. When set, the run is `semgrep ci` and the platform's policies replace `rulesets`. |

### Tests

`tests/test-semgrep-scan.sh` runs `semgrep/run-semgrep.sh` against a stub
`semgrep` in `tests/stub-semgrep/` and a throwaway git repo. It covers each
mode's arguments, that the token reaches Semgrep only through the
environment, the exit-2 refusals, and that Semgrep's exit code passes
through. It also checks that the `rulesets` default is the same in the
workflow, the caller stub, and this README, and that the stub keeps the
stable job name and `uses:` ref.

### Versioning

| Tag | Meaning |
| ----- | --------- |
| `semgrep-scan-v1` | Floating major for callers, moved manually and human-authorized, like `standards-check-v1`. |

Prefixed for the same reason as `standards-check-v*`.

---

## `claude-assistant` (deprecated)

`claude-assistant.yml` is deprecated. No fleet repo uses it except `kebab-tax`
and `kebab-tax-netlify`; it will be deleted once those callers are gone.
`CLAUDE_CODE_OAUTH_TOKEN` no longer exists, so callers fail at the token
precondition. Do not set it up in a new repo.

---

## New-repo bootstrap script (`smartwatermelon` only)

`new-smartwatermelon-repo.sh` is the creation-time script for a
genuinely *new* `smartwatermelon` repo (the old fleet bulk-install script
is retired). `smartwatermelon` being a User
account means it can't use GitHub's org-only workflow-templates picker
*or* Repository Rulesets to auto-attach anything on repo creation, so this
script is the closest available approximation: one command instead of
"create repo, then remember to install the workflows, then remember
the one repo setting no template can seed."

```bash
./new-smartwatermelon-repo.sh <name> [--private]
```

This does two things:

1. `gh repo create <name> --template smartwatermelon/repo-template` — a
   real [GitHub template repository](https://github.com/smartwatermelon/repo-template)
   containing the standard caller stubs and a `.github/dependabot.yml`. Template
   repos are a general GitHub feature, not gated to Organizations, so this
   part genuinely works the same for a User account as it would for an Org.
2. Sets `can_approve_pull_request_reviews: true` via the Actions API — the
   one setting a template repo cannot seed, and the exact fix from issue
   [#87](https://github.com/smartwatermelon/github-workflows/issues/87).

Plan: `docs/plans/2026-04-30-bulk-install-smartwatermelon-fleet.md`.
