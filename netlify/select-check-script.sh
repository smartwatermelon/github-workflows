#!/usr/bin/env bash
# Decide whether netlify-site-checks.yml runs the caller's check script.
# Prints run=true or run=false on stdout, for GITHUB_OUTPUT.

# Env: CHECK_SCRIPT (path in the caller repo), SITE_DIR (caller checkout).
# Exit 0 = decided, 2 = a script that cannot run.

# Missing at the default path: skip; the baseline check still runs.
# Missing at any other path: a typo, so fail.
set -euo pipefail

: "${CHECK_SCRIPT:?CHECK_SCRIPT is required}"
: "${SITE_DIR:?SITE_DIR is required}"
# Must match the check-script input default in netlify-site-checks.yml.
default_script="scripts/check-deploy-preview.sh"
path="${SITE_DIR}/${CHECK_SCRIPT}"

if [[ ! -f "${path}" ]]; then
  if [[ "${CHECK_SCRIPT}" == "${default_script}" ]]; then
    echo "::notice::No ${default_script} in the caller repo; only the baseline check runs." >&2
    echo "run=false"
    exit 0
  fi
  echo "::error::check-script '${CHECK_SCRIPT}' does not exist in the caller repo" >&2
  exit 2
fi
if [[ ! -x "${path}" ]]; then
  echo "::error::check-script '${CHECK_SCRIPT}' is not executable (git update-index --chmod=+x)" >&2
  exit 2
fi
echo "run=true"
