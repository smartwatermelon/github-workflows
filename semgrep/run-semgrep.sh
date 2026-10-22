#!/usr/bin/env bash
# Run Semgrep for semgrep-scan.yml, from the root of the caller checkout.

# Env: EVENT_NAME, BASE_SHA (PR only), RULESETS, SEMGREP_APP_TOKEN,
# SEMGREP_BIN. Exit: Semgrep's code (1 = findings), or 2 if misconfigured.

# With a token: `semgrep ci` (platform rules, not RULESETS). Else
# `semgrep scan --error`, plus --baseline-commit on pull_request.
set -euo pipefail

semgrep_bin="${SEMGREP_BIN:-semgrep}"
: "${EVENT_NAME:?EVENT_NAME is required}"

if ! command -v "${semgrep_bin}" >/dev/null 2>&1; then
  echo "::error::semgrep not found at '${semgrep_bin}'" >&2
  exit 2
fi

case "${EVENT_NAME}" in
  pull_request | push | workflow_dispatch) ;;
  *)
    echo "::error::semgrep-scan runs on pull_request, push, or workflow_dispatch, not '${EVENT_NAME}'" >&2
    exit 2
    ;;
esac

if [[ -n "${SEMGREP_APP_TOKEN:-}" ]]; then
  echo "::notice::SEMGREP_APP_TOKEN is set: running semgrep ci; platform policies replace the rulesets input." >&2
  exec "${semgrep_bin}" ci
fi

read -r -d '' -a rulesets <<<"${RULESETS:-}" || true
if [[ "${#rulesets[@]}" -eq 0 ]]; then
  echo "::error::RULESETS is empty; give at least one Semgrep config" >&2
  exit 2
fi
args=(scan --error --metrics=off)
for r in "${rulesets[@]}"; do
  # A registry name (p/default, r/...) or a path in the caller repo.
  if [[ ! "${r}" =~ ^[A-Za-z0-9_.][A-Za-z0-9_./:@-]*$ ]]; then
    echo "::error::ruleset '${r}' is not a valid Semgrep config name" >&2
    exit 2
  fi
  args+=(--config "${r}")
done

if [[ "${EVENT_NAME}" == "pull_request" ]]; then
  if [[ ! "${BASE_SHA:-}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "::error::pull_request run without a valid BASE_SHA ('${BASE_SHA:-}')" >&2
    exit 2
  fi
  if ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
    echo "::error::base commit ${BASE_SHA} is not in this checkout; check out with fetch-depth: 0" >&2
    exit 2
  fi
  echo "Diff-aware scan: only findings new since ${BASE_SHA} fail." >&2
  args+=(--baseline-commit "${BASE_SHA}")
else
  echo "Full scan (${EVENT_NAME})." >&2
fi

exec "${semgrep_bin}" "${args[@]}"
