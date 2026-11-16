#!/usr/bin/env bash
# Tests standards-check.yml's linter install step: each RUNNER_ARCH gets its own builds and SHA pins.
# All commands are stubs.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wf="${here}/../.github/workflows/standards-check.yml"
pass=0; fail=0
tmp_dirs=()
trap 'rm -rf "${tmp_dirs[@]}"' EXIT
_ok() { echo "  ok   $1"; pass=$((pass + 1)); }
_bad() { echo "  FAIL $1"; fail=$((fail + 1)); }
_check() { # _check DESC CMD...: pass when CMD succeeds
  local desc="$1"; shift
  if "$@"; then _ok "${desc}"; else _bad "${desc}"; fi
}
_check_not() { # _check_not DESC CMD...: pass when CMD fails
  local desc="$1"; shift
  if "$@"; then _bad "${desc}"; else _ok "${desc}"; fi
}

install_sh="$(yq '.jobs.run-standards-check.steps[] | select(.name == "Install pinned linters") | .run' "${wf}")"
[[ -n "${install_sh}" && "${install_sh}" != "null" ]] || { echo "could not extract the install step"; exit 1; }

# The workflow-level env block, read once.
declare -A pin
for k in SHELLCHECK_VERSION SHELLCHECK_SHA256 SHELLCHECK_SHA256_ARM64 \
  ACTIONLINT_VERSION ACTIONLINT_SHA256 ACTIONLINT_SHA256_ARM64 \
  ZIZMOR_VERSION ZIZMOR_SHA256 ZIZMOR_SHA256_ARM64 \
  YQ_VERSION YQ_SHA256 YQ_SHA256_ARM64 \
  YAMLLINT_VERSION MARKDOWNLINT_CLI2_VERSION; do
  pin[${k}]="$(yq ".env.${k}" "${wf}")"
done

_fixture() {
  STUB_DIR="$(mktemp -d)"
  tmp_dirs+=("${STUB_DIR}")
  mkdir -p "${STUB_DIR}/bin" "${STUB_DIR}/home"
  : >"${STUB_DIR}/calls.log"
  local cmd
  for cmd in curl tar install mkdir find pipx npm; do
    cat >"${STUB_DIR}/bin/${cmd}" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >>"${STUB_DIR}/calls.log"
STUB
  done
  # sha256sum -c - reads "<sha>  <file>" on stdin: record that line.
  cat >"${STUB_DIR}/bin/sha256sum" <<'STUB'
#!/usr/bin/env bash
line="$(cat)"
printf 'sha256sum %s\n' "${line}" >>"${STUB_DIR}/calls.log"
STUB
  chmod +x "${STUB_DIR}/bin/"*
}

_run() { # _run ARCH [SKIP_COOLDOWN_YQ]: run the install block with RUNNER_ARCH=ARCH; sets rc
  rc=0
  env -i PATH="${STUB_DIR}/bin:/usr/bin:/bin" HOME="${STUB_DIR}/home" STUB_DIR="${STUB_DIR}" \
    GITHUB_PATH="${STUB_DIR}/github_path" RUNNER_ARCH="$1" \
    SKIP_SHELLCHECK=false SKIP_ACTIONLINT=false SKIP_ZIZMOR=false \
    SKIP_YAMLLINT=false SKIP_MARKDOWNLINT=false SKIP_COOLDOWN_YQ="${2:-false}" \
    SHELLCHECK_VERSION="${pin[SHELLCHECK_VERSION]}" \
    SHELLCHECK_SHA256="${pin[SHELLCHECK_SHA256]}" SHELLCHECK_SHA256_ARM64="${pin[SHELLCHECK_SHA256_ARM64]}" \
    ACTIONLINT_VERSION="${pin[ACTIONLINT_VERSION]}" \
    ACTIONLINT_SHA256="${pin[ACTIONLINT_SHA256]}" ACTIONLINT_SHA256_ARM64="${pin[ACTIONLINT_SHA256_ARM64]}" \
    ZIZMOR_VERSION="${pin[ZIZMOR_VERSION]}" \
    ZIZMOR_SHA256="${pin[ZIZMOR_SHA256]}" ZIZMOR_SHA256_ARM64="${pin[ZIZMOR_SHA256_ARM64]}" \
    YQ_VERSION="${pin[YQ_VERSION]}" YQ_SHA256="${pin[YQ_SHA256]}" YQ_SHA256_ARM64="${pin[YQ_SHA256_ARM64]}" \
    YAMLLINT_VERSION="${pin[YAMLLINT_VERSION]}" MARKDOWNLINT_CLI2_VERSION="${pin[MARKDOWNLINT_CLI2_VERSION]}" \
    bash -c "${install_sh}" >"${STUB_DIR}/out" 2>&1 || rc=$?
}
_has() { grep -qF -- "$1" "${STUB_DIR}/calls.log"; }
_said() { grep -qF -- "$1" "${STUB_DIR}/out"; }

# Every SHA pin is 64 hex characters, and the two architectures differ.
_distinct() {
  local x="$1" a="$2"
  [[ "${x}" =~ ^[0-9a-f]{64}$ && "${a}" =~ ^[0-9a-f]{64}$ && "${x}" != "${a}" ]]
}
for t in SHELLCHECK ACTIONLINT ZIZMOR YQ; do
  _check "${t}: distinct X64 and ARM64 pins" _distinct "${pin[${t}_SHA256]}" "${pin[${t}_SHA256_ARM64]}"
done

echo "-- X64"
_fixture
_run X64
_check "exits 0 (got ${rc})" test "${rc}" -eq 0
_check "shellcheck x86_64 build" _has "linux.x86_64.tar.xz"
_check "actionlint amd64 build" _has "_linux_amd64.tar.gz"
_check "zizmor x86_64 build" _has "zizmor-x86_64-unknown-linux-gnu"
_check "yq amd64 build" _has "/yq_linux_amd64"
for t in SHELLCHECK ACTIONLINT ZIZMOR YQ; do
  _check "${t} checked against the X64 pin" _has "sha256sum ${pin[${t}_SHA256]}"
done
_check_not "no arm64 URL" _has "aarch64"

echo "-- ARM64"
_fixture
_run ARM64
_check "exits 0 (got ${rc})" test "${rc}" -eq 0
_check "shellcheck aarch64 build" _has "linux.aarch64.tar.xz"
_check "actionlint arm64 build" _has "_linux_arm64.tar.gz"
_check "zizmor aarch64 build" _has "zizmor-aarch64-unknown-linux-gnu"
_check "yq arm64 build" _has "/yq_linux_arm64"
for t in SHELLCHECK ACTIONLINT ZIZMOR YQ; do
  _check "${t} checked against the ARM64 pin" _has "sha256sum ${pin[${t}_SHA256_ARM64]}"
done
_check_not "no x86_64 URL" _has "x86_64"
_check "yamllint via pipx" _has "pipx install yamllint=="
_check "markdownlint-cli2 via npm" _has "npm install -g markdownlint-cli2@"

echo "-- cooldown check off"
_fixture
_run ARM64 true
_check "exits 0 (got ${rc})" test "${rc}" -eq 0
_check_not "no yq download" _has "yq_linux_"

echo "-- unknown architecture"
_fixture
_run ARM
_check "exits 2 (got ${rc})" test "${rc}" -eq 2
_check "names the architecture" _said "unsupported runner architecture 'ARM'"
_check_not "no download" _has "curl "

echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
