#!/usr/bin/env bash
# check-dependabot-cooldown.sh <repo-dir> <floor-days>
# Exit 1 if a Dependabot entry has no cooldown or any days under the floor.
set -euo pipefail

repo="${1:?usage: check-dependabot-cooldown.sh <repo-dir> <floor-days>}"
floor="${2:?usage: check-dependabot-cooldown.sh <repo-dir> <floor-days>}"
[[ "${floor}" =~ ^[0-9]+$ ]] || { echo "::error::floor must be a whole number of days, got '${floor}'"; exit 2; }

cfg=""
for f in "${repo}/.github/dependabot.yml" "${repo}/.github/dependabot.yaml"; do
  if [[ -f "${f}" ]]; then cfg="${f}"; break; fi
done
if [[ -z "${cfg}" ]]; then
  echo "::notice::no .github/dependabot.yml"
  exit 0
fi
where="${cfg#"${repo}"/}"

# Never skip silently: without yq a missing cooldown would pass unnoticed.
if ! command -v yq >/dev/null; then
  echo "::error::${where} is present but yq is not installed; the cooldown cannot be checked"
  exit 2
fi

# One line per updates entry: index, ecosystem, directory, then each
# cooldown key=value, or NONE when the entry has no cooldown block.
if ! rows="$(yq -r '
    .updates // [] | to_entries | .[] |
    [ (.key | tostring),
      (.value["package-ecosystem"] // "?"),
      (.value.directory // (.value.directories // ["?"] | join(","))),
      ( if .value.cooldown == null then "NONE"
        else (.value.cooldown | to_entries
              | map(select(.key | test("days$")) | .key + "=" + (.value | tostring))
              | join(" "))
        end ) ] | join("\t")' "${cfg}" 2>&1)"; then
  echo "::error::${where}: could not parse: ${rows}"
  exit 2
fi
if [[ -z "${rows}" ]]; then
  echo "::error::${where}: no updates entries"
  exit 1
fi

errors=0
while IFS=$'\t' read -r idx eco dir days; do
  label="${where} updates[${idx}] (${eco} ${dir})"
  if [[ "${days}" == NONE ]]; then
    echo "::error::${label}: no cooldown; set cooldown.default-days to at least ${floor}"
    errors=$((errors + 1))
    continue
  fi
  if [[ " ${days} " != *" default-days="* ]]; then
    echo "::error::${label}: cooldown has no default-days; set it to at least ${floor}"
    errors=$((errors + 1))
  fi
  for kv in ${days}; do
    key="${kv%%=*}" val="${kv#*=}"
    if [[ ! "${val}" =~ ^[0-9]+$ ]]; then
      echo "::error::${label}: cooldown.${key} is '${val}', not a whole number"
      errors=$((errors + 1))
    elif ((val < floor)); then
      echo "::error::${label}: cooldown.${key} is ${val}, below the ${floor}-day floor"
      errors=$((errors + 1))
    fi
  done
done <<<"${rows}"

if ((errors > 0)); then exit 1; fi
echo "dependabot cooldown: every entry is at least ${floor} days (${where})"
