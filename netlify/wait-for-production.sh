#!/usr/bin/env bash
# Wait for Netlify's production deploy of one commit; print the site URL.
# Used by netlify-site-checks.yml. See README.md for details.

# Env: NETLIFY_SITE, COMMIT_SHA, NETLIFY_AUTH_TOKEN (required).
# NETLIFY_POLL_INTERVAL / NETLIFY_POLL_DEADLINE: seconds (15 / 600).

# Exit 0 ready, 1 deploy error / timeout / no URL, 2 bad input or no token.

# API fields checked 2026-10-06 against open-api.netlify.com/swagger.json
# and live ameliabooneracing responses. README.md has the list.
set -euo pipefail

: "${NETLIFY_SITE:?NETLIFY_SITE is required}"
: "${COMMIT_SHA:?COMMIT_SHA is required}"
interval="${NETLIFY_POLL_INTERVAL:-15}"
deadline_secs="${NETLIFY_POLL_DEADLINE:-600}"
api="https://api.netlify.com/api/v1"

if [[ -z "${NETLIFY_AUTH_TOKEN:-}" ]]; then
  echo "::error::NETLIFY_AUTH_TOKEN is empty. Production mode needs it: pass" \
    "'secrets: NETLIFY_AUTH_TOKEN: \${{ secrets.NETLIFY_AUTH_TOKEN }}' from the" \
    "caller, and add the secret to the repo (or org)." >&2
  exit 2
fi
if [[ ! "${NETLIFY_SITE}" =~ ^[a-z0-9-]+$ ]]; then
  echo "::error::netlify-site '${NETLIFY_SITE}' is not a Netlify site name ([a-z0-9-]+)" >&2
  exit 2
fi
if [[ ! "${COMMIT_SHA}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::COMMIT_SHA '${COMMIT_SHA}' is not a 40-hex commit SHA" >&2
  exit 2
fi

# The API accepts <name>.netlify.app in place of the site UUID.
site_id="${NETLIFY_SITE}.netlify.app"

# Token goes to curl as a config on stdin via builtin printf: never in argv,
# never on disk. -H "Authorization: ..." would put it in argv.
netlify_get() {
  printf 'header = "Authorization: Bearer %s"\n' "${NETLIFY_AUTH_TOKEN}" |
    curl -K - -fsS --max-time 30 "${api}/$1"
}

deadline=$((SECONDS + deadline_secs))
seen=()

_saw() { # record each state once, in order, for the timeout message
  local s
  for s in "${seen[@]}"; do [[ "${s}" == "$1" ]] && return 0; done
  seen+=("$1")
}

ready=0
while ((SECONDS < deadline)); do
  if deploys="$(netlify_get "sites/${site_id}/deploys?per_page=20")"; then
    # The list is newest first, so a retry after an error wins.
    match="$(jq -c --arg sha "${COMMIT_SHA}" \
      '[.[] | select(.context == "production" and .commit_ref == $sha)] | first // empty' \
      <<<"${deploys}")"
    if [[ -z "${match}" ]]; then
      state="not-yet-present"
    else
      state="$(jq -r '.state // "unknown"' <<<"${match}")"
    fi
  else
    # Not a verdict on the deploy. Keep waiting; the timeout names it.
    state="request-failed"
  fi
  _saw "${state}"

  case "${state}" in
    ready)
      echo "Production deploy of ${COMMIT_SHA} is ready." >&2
      ready=1
      break
      ;;
    error)
      msg="$(jq -r '.error_message // "(no error_message)"' <<<"${match}")"
      echo "::error::Netlify production deploy of ${COMMIT_SHA} failed: ${msg}" >&2
      exit 1
      ;;
    *)
      echo "Waiting for production deploy of ${COMMIT_SHA} (state=${state})..." >&2
      sleep "${interval}"
      ;;
  esac
done

if ((ready == 0)); then
  echo "::error::Timed out after ${deadline_secs}s waiting for the production deploy of" \
    "${COMMIT_SHA} on ${site_id}. States seen: $(IFS=,; echo "${seen[*]}")." >&2
  exit 1
fi

if ! site="$(netlify_get "sites/${site_id}")"; then
  echo "::error::Could not read site ${site_id} from the Netlify API." >&2
  exit 1
fi
# ssl_url is the primary custom domain over https; url is the fallback.
url="$(jq -r '[.ssl_url, .url] | map(select(. != null and . != "")) | first // empty' <<<"${site}")"
if [[ -z "${url}" ]]; then
  echo "::error::Site ${site_id} reported neither ssl_url nor url." >&2
  exit 1
fi
echo "Production URL: ${url}" >&2
printf '%s\n' "${url}"
