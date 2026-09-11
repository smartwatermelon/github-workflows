#!/usr/bin/env bash
# run-standards.sh — the deterministic standards check.
#
#   run-standards.sh [--repo DIR] [--config-dir DIR] [--skip a,b,c] [--node-floor N]
#                    [--changed-since REF]
#
# Runs shellcheck, yamllint, actionlint, zizmor, markdownlint, and the
# Node-floor check over the tracked files of DIR (default: cwd). Exit 0 only
# when every enabled linter is clean. A linter with nothing to lint passes
# with a notice — absence of files is not a failure.
#
# --changed-since REF narrows the file-based linters to files this branch
# actually changed, plus new untracked files. Without it the linters see every
# tracked file, which is the right behaviour for a deliberate hygiene sweep but
# the wrong one for a feature PR: pre-existing debt in a file the author never
# opened fails their unrelated change. Measured across the fleet, that was the
# single largest source of standards-check failures.
#
# Scope: the flag narrows the four linters that enumerate through _tracked
# (shellcheck, yamllint, zizmor, markdownlint). actionlint and the Node-floor
# check find their own inputs and stay whole-repo — both are cheap, and
# neither has ever produced a failure on this fleet.
#
# Config precedence, per linter: a config at the repo root wins; otherwise
# the canonical file under --config-dir (github-workflows/standards/) is
# used. zizmor's canonical config is ../zizmor.yml relative to --config-dir.
#
# Same script runs in CI (standards-check.yml) and locally.
set -euo pipefail

repo="$(pwd)"
config_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skip=""
node_floor="22"
changed_since=""
while (($# > 0)); do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --config-dir) config_dir="$2"; shift 2 ;;
    --skip) skip="$2"; shift 2 ;;
    --node-floor) node_floor="$2"; shift 2 ;;
    --changed-since) changed_since="$2"; shift 2 ;;
    *) echo "::error::unknown argument: $1"; exit 2 ;;
  esac
done
repo="$(cd "${repo}" && pwd)"
config_dir="$(cd "${config_dir}" && pwd)"

# Fail loudly on a directory git cannot read. Every file-based linter
# enumerates through `_tracked || true`, so without this guard a non-repo (or
# a repo git refuses, e.g. dubious ownership) yields an empty file list and
# each linter reports a clean pass over nothing.
if ! git -C "${repo}" rev-parse --git-dir >/dev/null 2>&1; then
  echo "::error::--repo ${repo} is not a git repository"
  exit 2
fi

failures=0
_skipped() { [[ ",${skip}," == *",$1,"* ]]; }
# Say which mode is in effect. A run that lints 3 files and one that lints 300
# both print "all enabled linters clean", so without this line the scope of a
# green check is not recoverable from its log.
if [[ -n "${changed_since}" ]]; then
  echo "scope: files changed since ${changed_since} (+ new untracked files)"
else
  echo "scope: all tracked files (whole-repo hygiene mode)"
fi
_header() { echo; echo "== $1"; }
_fail() { echo "::error::$1 found problems"; failures=$((failures + 1)); }

# Fail loudly on a --changed-since ref git cannot resolve. Left to fall
# through, an unresolvable ref yields an empty changed set, every file-based
# linter reports a clean pass over nothing, and the check goes green having
# linted zero files — the same false-OK shape the non-repo guard above exists
# to prevent.
if [[ -n "${changed_since}" ]] &&
  ! git -C "${repo}" rev-parse --verify --quiet "${changed_since}^{commit}" >/dev/null; then
  echo "::error::--changed-since ${changed_since} is not a resolvable commit in ${repo}"
  exit 2
fi

# The file set every file-based linter enumerates.
#
# Default: all tracked and untracked-but-not-ignored files.
#
# With --changed-since REF: the files this branch changed, plus new untracked
# files. Both halves matter — the diff covers edits to existing files, and
# ls-files --others covers a file added but not yet committed, which has no
# diff entry against REF at all.
#
# The changed set is intersected with the default set rather than used
# directly, so .gitignore handling, deleted files (ACMR excludes D), and the
# "is this file even ours" question all keep exactly one answer.
_tracked_all() { git -C "${repo}" ls-files -z --cached --others --exclude-standard; }
_tracked() {
  if [[ -z "${changed_since}" ]]; then
    _tracked_all
    return
  fi
  local -A changed=()
  local f
  while IFS= read -r -d '' f; do changed["${f}"]=1; done < <(
    git -C "${repo}" diff --name-only -z --diff-filter=ACMR "${changed_since}" || true
  )
  while IFS= read -r -d '' f; do changed["${f}"]=1; done < <(
    git -C "${repo}" ls-files -z --others --exclude-standard || true
  )
  while IFS= read -r -d '' f; do
    [[ -n "${changed[${f}]:-}" ]] && printf '%s\0' "${f}"
  done < <(_tracked_all || true)
}

# Shell lint pass over *.sh, *.bash, and files whose shebang is a
# bourne-family shell. (Do not start this comment with the linter's name
# followed by a colon: that parses as a shellcheck directive, SC1073.)
if _skipped shellcheck; then echo "== shellcheck: skipped by input"; else
  _header shellcheck
  files=()
  while IFS= read -r -d '' f; do
    case "${f}" in
      *.sh|*.bash) files+=("${f}") ;;
      *)
        if [[ -f "${repo}/${f}" ]] &&
          head -c 64 "${repo}/${f}" 2>/dev/null | head -1 | grep -qE '^#!.*\b(ba)?sh\b'; then
          files+=("${f}")
        fi
        ;;
    esac
  done < <(_tracked || true)
  if ((${#files[@]} == 0)); then echo "::notice::no shell files"; else
    (cd "${repo}" && shellcheck -S info "${files[@]}") || _fail shellcheck
  fi
fi

# yamllint: *.yml, *.yaml
if _skipped yamllint; then echo "== yamllint: skipped by input"; else
  _header yamllint
  files=()
  while IFS= read -r -d '' f; do
    case "${f}" in
      *.yml|*.yaml) files+=("${f}") ;;
      *) ;;
    esac
  done < <(_tracked || true)
  if ((${#files[@]} == 0)); then echo "::notice::no YAML files"; else
    cfg=""
    for c in .yamllint .yamllint.yml .yamllint.yaml; do
      if [[ -f "${repo}/${c}" ]]; then cfg="${repo}/${c}"; break; fi
    done
    [[ -n "${cfg}" ]] || cfg="${config_dir}/yamllint.yml"
    (cd "${repo}" && yamllint -c "${cfg}" -f parsable "${files[@]}") || _fail yamllint
  fi
fi

# actionlint: .github/workflows only; it finds them itself.
if _skipped actionlint; then echo "== actionlint: skipped by input"; else
  _header actionlint
  if compgen -G "${repo}/.github/workflows/*.y*ml" >/dev/null; then
    (cd "${repo}" && actionlint -shellcheck= -pyflakes=) || _fail actionlint
  else echo "::notice::no workflows"; fi
fi

# zizmor: .github/workflows/*.yml|*.yaml only (a tracked example workflow
# living elsewhere, e.g. docs/examples/.github/workflows/, is out of scope).
# Config: repo-root zizmor.yml, else the canonical policy one level above
# config-dir.
if _skipped zizmor; then echo "== zizmor: skipped by input"; else
  _header zizmor
  files=()
  while IFS= read -r -d '' f; do
    case "${f}" in
      .github/workflows/*.yml|.github/workflows/*.yaml) files+=("${f}") ;;
      *) ;;
    esac
  done < <(_tracked || true)
  if ((${#files[@]} == 0)); then echo "::notice::no workflows"; else
    cfg="${repo}/zizmor.yml"; [[ -f "${cfg}" ]] || cfg="${config_dir}/../zizmor.yml"
    (cd "${repo}" && zizmor --config "${cfg}" --min-severity low --no-online-audits "${files[@]}") || _fail zizmor
  fi
fi

# markdownlint: *.md via markdownlint-cli2; repo config wins, else canonical.
if _skipped markdownlint; then echo "== markdownlint: skipped by input"; else
  _header markdownlint
  files=()
  while IFS= read -r -d '' f; do
    case "${f}" in
      *.md) files+=("${f}") ;;
      *) ;;
    esac
  done < <(_tracked || true)
  if ((${#files[@]} == 0)); then echo "::notice::no Markdown files"; else
    cfg=""
    for c in .markdownlint-cli2.jsonc .markdownlint-cli2.yaml .markdownlint-cli2.cjs .markdownlint.jsonc .markdownlint.json .markdownlint.yaml .markdownlint.yml .markdownlintrc; do
      if [[ -f "${repo}/${c}" ]]; then cfg="${repo}/${c}"; break; fi
    done
    [[ -n "${cfg}" ]] || cfg="${config_dir}/markdownlint.json"
    (cd "${repo}" && markdownlint-cli2 --config "${cfg}" "${files[@]}") || _fail markdownlint
  fi
fi

# node-floor
if _skipped node-floor; then echo "== node-floor: skipped by input"; else
  _header node-floor
  bash "${config_dir}/check-node-floor.sh" "${repo}" "${node_floor}" || _fail node-floor
fi

echo
if ((failures > 0)); then
  echo "::error::standards-check: ${failures} linter(s) failed"
  exit 1
fi
echo "standards-check: all enabled linters clean"
