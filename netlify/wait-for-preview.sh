#!/usr/bin/env bash
# Wait for the Netlify deploy preview of one commit; print its URL on stdout.
# Used by netlify-site-checks.yml. See README.md for details.

# Env: GITHUB_REPOSITORY, COMMIT_SHA, NETLIFY_SITE, GH_TOKEN (required).
# NETLIFY_POLL_INTERVAL / NETLIFY_POLL_DEADLINE: seconds (15 / 600).

# Exit 0 ready, 1 failed / no target_url / timeout, 2 bad input.
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${COMMIT_SHA:?COMMIT_SHA is required}"
: "${NETLIFY_SITE:?NETLIFY_SITE is required}"
interval="${NETLIFY_POLL_INTERVAL:-15}"
deadline_secs="${NETLIFY_POLL_DEADLINE:-600}"

# The site name goes into a --jq string (no --arg there), so allow only
# Netlify's name charset.
if [[ ! "${NETLIFY_SITE}" =~ ^[a-z0-9-]+$ ]]; then
  echo "::error::netlify-site '${NETLIFY_SITE}' is not a Netlify site name ([a-z0-9-]+)" >&2
  exit 2
fi
if [[ ! "${COMMIT_SHA}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::COMMIT_SHA '${COMMIT_SHA}' is not a 40-hex commit SHA" >&2
  exit 2
fi

# The exact context Netlify posts, keyed by SITE name (not repo name).
status_context="netlify/${NETLIFY_SITE}/deploy-preview"

deadline=$((SECONDS + deadline_secs))

while ((SECONDS < deadline)); do
  status_json="$(gh api \
    "repos/${GITHUB_REPOSITORY}/commits/${COMMIT_SHA}/status" \
    --jq ".statuses[] | select(.context == \"${status_context}\")" ||
    true)"

  # Defensive, not load-bearing on singular /status. Plural /statuses returns
  # history, so keep head -1. amelia-boone#50; tested.
  state="$(printf '%s' "${status_json}" | jq -r '.state // empty' | head -1)"
  target="$(printf '%s' "${status_json}" | jq -r '.target_url // empty' | head -1)"

  case "${state}" in
    success)
      if [[ -z "${target}" ]]; then
        echo "::error::Deploy preview succeeded but reported no target_url." >&2
        exit 1
      fi
      echo "Deploy preview ready: ${target}" >&2
      printf '%s\n' "${target}"
      exit 0
      ;;
    failure | error)
      echo "::error::Netlify deploy preview failed (state=${state})." >&2
      exit 1
      ;;
    *)
      echo "Waiting for deploy preview (state=${state:-none})..." >&2
      sleep "${interval}"
      ;;
  esac
done

echo "::error::Timed out after ${deadline_secs}s waiting for the deploy preview (context ${status_context})." >&2
exit 1
