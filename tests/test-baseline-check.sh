#!/usr/bin/env bash
# Hermetic tests for netlify/baseline-check.sh (stub curl in
# tests/stub-baseline/) and netlify/select-check-script.sh.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../netlify/baseline-check.sh"
select="${here}/../netlify/select-check-script.sh"
workflow="${here}/../.github/workflows/netlify-site-checks.yml"
# An exported curl function or BASH_ENV would shadow the PATH stub.
unset -f curl 2>/dev/null || true
unset BASH_ENV
pass=0; fail=0
tmp_dirs=()
trap 'rm -rf "${tmp_dirs[@]}"' EXIT
_ok() { echo "  ok   $1"; pass=$((pass + 1)); }
_bad() { echo "  FAIL $1"; fail=$((fail + 1)); }
_tmp() { local d; d="$(mktemp -d)"; tmp_dirs+=("${d}"); printf '%s' "${d}"; }

# A page over the 1024-byte floor, with a title.
pad="$(printf '%*s' 1100 '' | tr ' ' 'x')"
good="<!doctype html><html><head><title>Example</title></head><body>${pad}</body></html>"

# _fixture STATUS BODY
_fixture() {
  STUB_DIR="$(_tmp)"; export STUB_DIR
  : >"${STUB_DIR}/calls.log"
  printf '%s' "$1" >"${STUB_DIR}/status"
  printf '%s' "$2" >"${STUB_DIR}/body"
}
run() {
  rc=0
  out="$(PATH="${here}/stub-baseline:${PATH}" bash "${script}" "$@" 2>"${STUB_DIR}/err")" || rc=$?
  err="$(cat "${STUB_DIR}/err")"
}

echo "baseline-check.sh"

# 1. pass: 200, big enough, has a title; requests <base>/ and follows redirects
_fixture 200 "${good}"
run "https://example.com/"
call="$(cat "${STUB_DIR}/calls.log")"
if [[ "${rc}" -eq 0 && -z "${err}" ]] && grep -q '^ok: .* returned 200' <<<"${out}" \
  && grep -q '^ok: / contains a <title>' <<<"${out}"; then
  _ok "sane page passes"
else
  _bad "pass case: rc=${rc} out='${out}' err='${err}'"
fi
if [[ "${call}" == *"--location"* && "${call}" == *"--max-time"* && "${call}" == *"--retry"* \
  && "${call}" == *" https://example.com/" ]]; then
  _ok "requests <base>/ with redirects, timeout, retries"
else
  _bad "curl argv: ${call}"
fi

# 2. non-200
_fixture 404 "${good}"
run "https://example.com"
if [[ "${rc}" -eq 1 ]] && grep -q '^FAIL: https://example.com/ returned 404' <<<"${err}"; then
  _ok "non-200 fails"
else
  _bad "non-200 case: rc=${rc} out='${out}' err='${err}'"
fi

# 3. connection failure reads as status 000, not a crash
_fixture 200 "${good}"
: >"${STUB_DIR}/down"
run "https://example.com"
if [[ "${rc}" -eq 1 ]] && grep -q 'returned 000' <<<"${err}"; then
  _ok "connection failure fails as 000"
else
  _bad "down case: rc=${rc} err='${err}'"
fi

# 4. short body
_fixture 200 "<html><head><title>Tiny</title></head></html>"
run "https://example.com"
if [[ "${rc}" -eq 1 ]] && grep -q '^FAIL: / body is [0-9]* bytes, below the 1024-byte floor' <<<"${err}"; then
  _ok "short body fails"
else
  _bad "short-body case: rc=${rc} err='${err}'"
fi

# 5. missing title
_fixture 200 "<html><head></head><body>${pad}</body></html>"
run "https://example.com"
if [[ "${rc}" -eq 1 ]] && grep -q '^FAIL: / has no <title>' <<<"${err}"; then
  _ok "missing title fails"
else
  _bad "no-title case: rc=${rc} err='${err}'"
fi

# 6. usage errors: no args, empty arg, two args; no request made
for args in "" "EMPTY" "a b"; do
  _fixture 200 "${good}"
  case "${args}" in
    "") run ;;
    EMPTY) run "" ;;
    *) run a b ;;
  esac
  if [[ "${rc}" -eq 2 && ! -s "${STUB_DIR}/calls.log" ]] && grep -q '^usage:' <<<"${err}"; then
    _ok "usage error (${args:-no args}) exits 2"
  else
    _bad "usage case '${args}': rc=${rc} err='${err}'"
  fi
done

echo "select-check-script.sh"

# sel CHECK_SCRIPT: runs the selector against SITE
sel() {
  rc=0
  out="$(CHECK_SCRIPT="$1" SITE_DIR="${SITE}" bash "${select}" 2>"${SITE}.err")" || rc=$?
  err="$(cat "${SITE}.err")"
}
SITE="$(_tmp)/site"
mkdir -p "${SITE}/scripts"

# 7. default path missing: skip with a notice
sel scripts/check-deploy-preview.sh
if [[ "${rc}" -eq 0 && "${out}" == "run=false" ]] && grep -q '^::notice::.*only the baseline check runs' <<<"${err}"; then
  _ok "missing default script is skipped with a notice"
else
  _bad "default-missing case: rc=${rc} out='${out}' err='${err}'"
fi

# 8. non-default path missing: exit 2
sel scripts/chek.sh
if [[ "${rc}" -eq 2 && -z "${out}" ]] && grep -q "^::error::check-script 'scripts/chek.sh' does not exist" <<<"${err}"; then
  _ok "missing non-default script fails with exit 2"
else
  _bad "typo case: rc=${rc} out='${out}' err='${err}'"
fi

# 9. exists but not executable: exit 2, for the default path too
printf '#!/bin/sh\nexit 0\n' >"${SITE}/scripts/check-deploy-preview.sh"
chmod -x "${SITE}/scripts/check-deploy-preview.sh"
sel scripts/check-deploy-preview.sh
if [[ "${rc}" -eq 2 && -z "${out}" ]] && grep -q 'is not executable' <<<"${err}"; then
  _ok "non-executable script fails with exit 2"
else
  _bad "non-exec case: rc=${rc} out='${out}' err='${err}'"
fi

# 10. exists and executable: run, default and custom paths
chmod +x "${SITE}/scripts/check-deploy-preview.sh"
cp "${SITE}/scripts/check-deploy-preview.sh" "${SITE}/scripts/custom.sh"
for p in scripts/check-deploy-preview.sh scripts/custom.sh; do
  sel "${p}"
  if [[ "${rc}" -eq 0 && "${out}" == "run=true" && -z "${err}" ]]; then
    _ok "executable ${p} runs"
  else
    _bad "run case ${p}: rc=${rc} out='${out}' err='${err}'"
  fi
done

# 11. the selector's default matches the workflow's check-script default
wf_default="$(grep -A8 '^      check-script:' "${workflow}" | sed -n 's/^ *default: *//p')"
sel_default="$(sed -n 's/^default_script="\(.*\)"$/\1/p' "${select}")"
if [[ -n "${wf_default}" && "${wf_default}" == "${sel_default}" ]]; then
  _ok "selector default matches the workflow input default (${wf_default})"
else
  _bad "default drift: workflow='${wf_default}' selector='${sel_default}'"
fi

echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
