#!/usr/bin/env bash
# claude-review-audit.sh
#
# Audits Claude Review configuration across all non-archived repos under
# smartwatermelon (User) and nightowlstudiollc (Organization).
#
# READ-ONLY: reports necessary changes but makes none.
#
# Requirements: gh CLI (authenticated), jq, base64, bash 4.0+
# Usage: ./claude-review-audit.sh [--verbose]

set -uo pipefail

# Requires bash 4.0+ for associative arrays (declare -A).
# macOS ships /bin/bash 3.2; run via the shebang (./script.sh) to get bash 5+.
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  printf "Error: bash 4.0+ required (found %s). Run as: ./%s\n" \
    "${BASH_VERSION}" "${0##*/}" >&2
  exit 1
fi

# ── config ─────────────────────────────────────────────────────────────────────
declare -A OWNER_TYPES=(
  ["smartwatermelon"]="User"
  ["nightowlstudiollc"]="Organization"
)
OWNERS=("smartwatermelon" "nightowlstudiollc")
TARGET_SECRET="CLAUDE_CODE_OAUTH_TOKEN"
VERBOSE="${1:-}"
if [[ -n "${VERBOSE}" && "${VERBOSE}" != "--verbose" ]]; then
  printf "Warning: unrecognized argument '%s'. Usage: ./%s [--verbose]\n" \
    "${VERBOSE}" "${0##*/}" >&2
fi

# ── formatting ─────────────────────────────────────────────────────────────────
ok() { printf "  ✅ %s\n" "${*}"; }
fail() { printf "  ❌ %s\n" "${*}"; }
warn() { printf "  ⚠️  %s\n" "${*}"; }
info() { [[ "${VERBOSE}" == "--verbose" ]] && printf "  ℹ  %s\n" "${*}" || true; }

# ── global accumulators ─────────────────────────────────────────────────────────
declare -a REPOS_WITH_ISSUES=()
declare -a ISSUE_LINES=()
TOTAL_REPOS=0
TOTAL_ISSUES=0

# ── helpers ─────────────────────────────────────────────────────────────────────

# Extract a top-level 'name:' field from YAML content (first match only)
yaml_name() {
  echo "${1}" | grep -m1 '^name:' | sed "s/^name:[[:space:]]*//" | tr -d "'\""
}

# Strip YAML comment lines before classification to avoid matching comment-only references
# (e.g., usage examples in the reusable workflow file itself).
strip_comments() {
  echo "${1}" | grep -v '^[[:space:]]*#'
}

# Check if a workflow file's content references the blocking review workflow
uses_blocking_review() {
  local content
  content=$(strip_comments "${1}")
  echo "${content}" | grep -q "claude-blocking-review\.yml"
}

# Check if a workflow file is the Claude assistant (responds to @claude)
is_claude_assistant() {
  local content
  content=$(strip_comments "${1}")
  echo "${content}" | grep -q "anthropics/claude-code-action" \
    && echo "${content}" | grep -qE "issue_comment|pull_request_review|issues:"
}

# Check if a workflow file is a Claude code review (runs on PRs, not assistant-style)
is_claude_code_review() {
  local content
  content=$(strip_comments "${1}")
  echo "${content}" | grep -q "anthropics/claude-code-action" \
    && echo "${content}" | grep -q "pull_request" \
    && ! echo "${content}" | grep -qE "issue_comment|pull_request_review"
}

# Fetch and base64-decode a file from a repo via the GitHub Contents API
fetch_file() {
  local full="${1}" path="${2}"
  gh api "repos/${full}/contents/${path}" --jq '.content' 2>/dev/null \
    | tr -d '\n' | base64 -d 2>/dev/null
}

# ── per-repo check ──────────────────────────────────────────────────────────────
check_repo() {
  local owner="${1}" repo="${2}"
  local full="${owner}/${repo}"
  local -a issues=()

  printf "\n── %s\n" "${full}"
  TOTAL_REPOS=$((TOTAL_REPOS + 1))

  # ── metadata ──────────────────────────────────────────────────────────────
  local meta
  meta=$(gh api "repos/${full}" --jq '{default_branch,visibility,has_issues}' 2>/dev/null) || {
    fail "Cannot access repo — skipping"
    REPOS_WITH_ISSUES+=("${full}")
    ISSUE_LINES+=("${full}: repo access error")
    TOTAL_ISSUES=$((TOTAL_ISSUES + 1))
    return
  }

  local default_branch visibility
  default_branch=$(echo "${meta}" | jq -r .default_branch)
  visibility=$(echo "${meta}" | jq -r .visibility)
  info "branch=${default_branch}  visibility=${visibility}"

  # ── 1. Workflow files ──────────────────────────────────────────────────────
  local wf_list
  wf_list=$(gh api "repos/${full}/contents/.github/workflows" \
    --jq '.[].name' 2>/dev/null || echo "")

  local has_blocking_caller=false
  local has_claude_assistant=false
  local has_claude_code_review=false
  local caller_workflow_name=""
  local caller_job_name=""

  if [[ -z "${wf_list}" ]]; then
    fail "No .github/workflows directory found"
    issues+=("Add .github/workflows with Claude workflow(s)")
  else
    while IFS= read -r wf; do
      [[ -z "${wf}" ]] && continue

      local raw
      raw=$(fetch_file "${full}" ".github/workflows/${wf}")
      [[ -z "${raw}" ]] && {
        warn "Could not fetch ${wf} — skipped"
        continue
      }

      if uses_blocking_review "${raw}"; then
        has_blocking_caller=true
        # Best-effort: extract workflow name and calling job name for status-check hint
        caller_workflow_name=$(yaml_name "${raw}")
        # Find the job key whose 'uses:' line references claude-blocking-review.yml
        local in_job=false current_job=""
        while IFS= read -r line; do
          if echo "${line}" | grep -qE '^  [a-zA-Z0-9_-]+:'; then
            current_job=$(echo "${line}" | sed 's/:[[:space:]]*//' | tr -d ' ')
            in_job=true
          fi
          if ${in_job} && echo "${line}" | grep -q "claude-blocking-review\.yml"; then
            caller_job_name="${current_job}"
            break
          fi
        done <<<"${raw}"
        local job_suffix=""
        [[ -n "${caller_job_name}" ]] && job_suffix=" (job: ${caller_job_name})"
        ok "Blocking review caller: ${wf}${job_suffix}"

        # Check that the caller passes the OAuth token secret to the reusable workflow
        if echo "${raw}" | grep -q "claude_oauth_token"; then
          ok "Caller passes claude_oauth_token secret to blocking review"
        else
          fail "Caller does not appear to pass claude_oauth_token to blocking review"
          issues+=("In ${wf}, add: secrets: claude_oauth_token: \${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}")
        fi
      fi

      if is_claude_assistant "${raw}"; then
        has_claude_assistant=true
        ok "Claude assistant workflow: ${wf}"
      fi

      if is_claude_code_review "${raw}"; then
        has_claude_code_review=true
        ok "Claude code review workflow: ${wf}"
      fi
    done <<<"${wf_list}"

    if [[ "${has_blocking_caller}" == false && "${has_claude_assistant}" == false && "${has_claude_code_review}" == false ]]; then
      local wf_count
      wf_count=$(printf "%s\n" "${wf_list}" | grep -c '.' || echo 0)
      fail "No Claude workflows found (${wf_count} workflow files scanned)"
      issues+=("Add workflow calling claude-blocking-review.yml and/or claude-assistant (claude.yml)")
    fi
  fi

  # ── 2. Secret: CLAUDE_CODE_OAUTH_TOKEN ────────────────────────────────────
  local secret_found=false

  # Repo-level secrets (also includes org secrets selected for this repo in some API versions)
  local secrets_json
  secrets_json=$(gh api "repos/${full}/actions/secrets" 2>/dev/null || echo "")

  if [[ -z "${secrets_json}" ]]; then
    warn "Could not read repo secrets (token scope may be insufficient)"
    issues+=("Verify ${TARGET_SECRET} secret exists — could not check")
  elif echo "${secrets_json}" | jq -e --arg s "${TARGET_SECRET}" \
    '[.secrets[].name] | any(. == $s)' >/dev/null 2>&1; then
    secret_found=true
    ok "${TARGET_SECRET} found in repo secrets"
  fi

  # Org-level secrets (only applicable for Organization owners)
  if [[ "${secret_found}" == false && "${OWNER_TYPES[${owner}]}" == "Organization" ]]; then
    # First check the secret's visibility: 'all'/'private' means every repo in the org has access;
    # 'selected' means only explicitly listed repos do. The /repositories endpoint only returns
    # a populated list when visibility=selected, so we must check visibility first.
    local org_secret_visibility
    org_secret_visibility=$(gh api "orgs/${owner}/actions/secrets/${TARGET_SECRET}" \
      --jq '.visibility' 2>/dev/null || echo "")
    if [[ "${org_secret_visibility}" == "all" || "${org_secret_visibility}" == "private" ]]; then
      secret_found=true
      ok "${TARGET_SECRET} available via org-level secret (visibility=${org_secret_visibility})"
    elif [[ "${org_secret_visibility}" == "selected" ]]; then
      local org_secret_repos
      org_secret_repos=$(gh api "orgs/${owner}/actions/secrets/${TARGET_SECRET}/repositories" \
        --jq "[.repositories[].name] | any(. == \"${repo}\")" 2>/dev/null || echo "false")
      if [[ "${org_secret_repos}" == "true" ]]; then
        secret_found=true
        ok "${TARGET_SECRET} available via org-level secret (selected for this repo)"
      fi
    fi
  fi

  if [[ "${secret_found}" == false && -n "${secrets_json}" ]]; then
    fail "${TARGET_SECRET} not found at repo or org level"
    if [[ "${OWNER_TYPES[${owner}]}" == "Organization" ]]; then
      issues+=("Add ${TARGET_SECRET} at repo level, or configure org-level secret to include this repo")
    else
      issues+=("Add ${TARGET_SECRET} secret to this repo")
    fi
  fi

  # ── 3. Branch protection & required status checks ──────────────────────────
  # Only meaningful when a blocking review caller is configured
  if [[ "${has_blocking_caller}" == true ]]; then
    local protection
    protection=$(gh api "repos/${full}/branches/${default_branch}/protection" 2>/dev/null || echo "")

    if [[ -z "${protection}" ]]; then
      fail "No branch protection on '${default_branch}'"
      issues+=("Enable branch protection on '${default_branch}' with Claude review as required status check")
    else
      # Collect required status checks from both the legacy 'contexts' and newer 'checks' arrays
      local req_checks req_checks_apps all_checks
      req_checks=$(echo "${protection}" | jq -r '.required_status_checks.contexts[]? // empty' 2>/dev/null || echo "")
      req_checks_apps=$(echo "${protection}" | jq -r '.required_status_checks.checks[]?.context? // empty' 2>/dev/null || echo "")
      all_checks=$(printf "%s\n%s" "${req_checks}" "${req_checks_apps}" | sort -u | grep -v '^$' || echo "")

      if echo "${all_checks}" | grep -qi "claude"; then
        ok "Claude review is a required status check on '${default_branch}'"
        echo "${all_checks}" | grep -i "claude" | while IFS= read -r chk; do
          printf "     check name: %s\n" "${chk}"
        done
      else
        fail "Claude review is NOT in required status checks on '${default_branch}'"
        # Compute expected check name to guide the user
        local expected_check=""
        if [[ -n "${caller_workflow_name}" && -n "${caller_job_name}" ]]; then
          expected_check="${caller_workflow_name} / ${caller_job_name}"
        elif [[ -n "${caller_job_name}" ]]; then
          expected_check="<workflow-name> / ${caller_job_name}"
        fi
        local hint=""
        [[ -n "${expected_check}" ]] && hint=" (expected: \"${expected_check}\")"
        issues+=("Add Claude review to required status checks on '${default_branch}'${hint}")

        if [[ -n "${all_checks}" ]]; then
          info "Current required checks:"
          echo "${all_checks}" | while IFS= read -r chk; do info "  - ${chk}"; done
        else
          info "No required status checks configured at all"
        fi
      fi

      # Enforce admins (admins can bypass required checks if false)
      local enforce_admins
      enforce_admins=$(echo "${protection}" | jq -r '.enforce_admins.enabled // false')
      if [[ "${enforce_admins}" == "false" ]]; then
        warn "enforce_admins=false: admins can merge without passing required checks"
      fi

      # Strict status checks (branch must be up-to-date before merging)
      local strict
      strict=$(echo "${protection}" | jq -r '.required_status_checks.strict // false')
      if [[ "${strict}" == "false" ]]; then
        warn "strict=false: branch doesn't need to be up-to-date before merging"
      fi
    fi
  fi

  # ── 4. GitHub Actions enabled? ────────────────────────────────────────────
  local actions_allowed
  actions_allowed=$(gh api "repos/${full}/actions/permissions" --jq '.enabled' 2>/dev/null || echo "unknown")
  if [[ "${actions_allowed}" == "false" ]]; then
    fail "GitHub Actions are DISABLED for this repo"
    issues+=("Enable GitHub Actions in repo settings")
  elif [[ "${actions_allowed}" == "true" ]]; then
    info "GitHub Actions: enabled"
  fi

  # ── summary for this repo ──────────────────────────────────────────────────
  if [[ "${#issues[@]}" -gt 0 ]]; then
    TOTAL_ISSUES=$((TOTAL_ISSUES + ${#issues[@]}))
    REPOS_WITH_ISSUES+=("${full}")
    printf "\n  CHANGES NEEDED (%d):\n" "${#issues[@]}"
    for iss in "${issues[@]}"; do
      printf "    → %s\n" "${iss}"
      ISSUE_LINES+=("${full}: ${iss}")
    done
  else
    ok "Configuration looks complete"
  fi
}

# ── main ────────────────────────────────────────────────────────────────────────
current_date=$(date)
token_status=$(gh auth status 2>&1 | grep 'Logged in' | head -1 | xargs || echo 'see gh auth status')
printf "\n══════════════════════════════════════════════════════════\n"
printf "  Claude Review Configuration Audit\n"
printf "  %s\n" "${current_date}"
printf "  Token: %s\n" "${token_status}"
printf "══════════════════════════════════════════════════════════\n"
printf "\nChecking the following owners:\n"
for owner in "${OWNERS[@]}"; do
  printf "  • %s (%s)\n" "${owner}" "${OWNER_TYPES[${owner}]}"
done
printf "\nWhat this script checks per repo:\n"
printf "  1. Claude workflow files (.github/workflows/*.yml)\n"
printf "  2. Caller passes claude_oauth_token secret to reusable workflow\n"
printf "  3. Secret: CLAUDE_CODE_OAUTH_TOKEN (repo + org level)\n"
printf "  4. Branch protection & required status checks (for blocking review)\n"
printf "  5. GitHub Actions enabled\n"
printf "\nNOTE: This script is read-only — it reports issues but makes no changes.\n"

for owner in "${OWNERS[@]}"; do
  printf "\n\n══════════════════════════════\n"
  printf "  %s (%s)\n" "${owner}" "${OWNER_TYPES[${owner}]}"
  printf "══════════════════════════════\n"

  repos=$(gh repo list "${owner}" --no-archived --json name --limit 300 \
    --jq '.[].name' 2>/dev/null || echo "")

  if [[ -z "${repos}" ]]; then
    warn "No repos found for ${owner} (no access or empty)"
    continue
  fi

  repo_count=$(printf "%s\n" "${repos}" | grep -c '.' || echo 0)
  if [[ "${repo_count}" -ge 300 ]]; then
    warn "Hit the 300-repo limit for ${owner} — increase --limit if more repos exist"
  fi
  printf "  Scanning %d non-archived repos…\n" "${repo_count}"

  while IFS= read -r repo; do
    [[ -z "${repo}" ]] && continue
    check_repo "${owner}" "${repo}"
  done <<<"${repos}"
done

# ── final summary ────────────────────────────────────────────────────────────
printf "\n\n══════════════════════════════════════════════════════════\n"
printf "  FINAL SUMMARY\n"
printf "══════════════════════════════════════════════════════════\n"
printf "  Repos scanned    : %d\n" "${TOTAL_REPOS}"
printf "  Repos with issues: %d\n" "${#REPOS_WITH_ISSUES[@]}"
printf "  Total issues     : %d\n" "${TOTAL_ISSUES}"

if [[ "${#REPOS_WITH_ISSUES[@]}" -eq 0 ]]; then
  printf "\n  ✅ All repos appear correctly configured — no changes needed.\n"
else
  printf "\n  ❌ Repos requiring attention:\n"
  for r in "${REPOS_WITH_ISSUES[@]}"; do
    printf "    → %s\n" "${r}"
  done

  printf "\n  All issues by repo:\n"
  for line in "${ISSUE_LINES[@]}"; do
    printf "    • %s\n" "${line}"
  done
fi

printf "\n══════════════════════════════════════════════════════════\n"
printf "  Run with --verbose for additional informational details.\n"
printf "══════════════════════════════════════════════════════════\n\n"
