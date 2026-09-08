#!/usr/bin/env bash
# run-standards.sh — the deterministic standards check.
#
#   run-standards.sh [--repo DIR] [--config-dir DIR] [--skip a,b,c] [--node-floor N]
#
# Runs shellcheck, yamllint, actionlint, zizmor, markdownlint, and the
# Node-floor check over the tracked files of DIR (default: cwd). Exit 0 only
# when every enabled linter is clean. A linter with nothing to lint passes
# with a notice — absence of files is not a failure.
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
while (($# > 0)); do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --config-dir) config_dir="$2"; shift 2 ;;
    --skip) skip="$2"; shift 2 ;;
    --node-floor) node_floor="$2"; shift 2 ;;
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
_header() { echo; echo "== $1"; }
_fail() { echo "::error::$1 found problems"; failures=$((failures + 1)); }
_tracked() { git -C "${repo}" ls-files -z --cached --others --exclude-standard; }

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
