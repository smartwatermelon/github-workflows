#!/usr/bin/env bash
# Validation for auto-tag/next-version.sh and auto-tag/git-credential-env.sh
# on throwaway git repos. Never touches this repo's tags.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../auto-tag/next-version.sh"
helper="${here}/../auto-tag/git-credential-env.sh"
# Isolate from the developer's global git config (hooks, signing, identity).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
pass=0; fail=0
_ok() { echo "  ok   $1"; pass=$((pass + 1)); }
_bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

# _repo NAME: a fixture repo with two commits; sets d, old (first), head.
_repo() {
  d="${tmp}/$1"
  git init -q "${d}"
  git -C "${d}" commit -q --allow-empty -m "one $1"
  old="$(git -C "${d}" rev-parse HEAD)"
  git -C "${d}" commit -q --allow-empty -m "two $1"
  head="$(git -C "${d}" rev-parse HEAD)"
}

# _expect DESC WANT [FLOOR]: run in d against head; WANT is the full line.
_expect() {
  local desc="$1" want="$2" floor="${3:-1.0.0}" got
  if ! got="$(cd "${d}" && TARGET_SHA="${head}" FLOOR="${floor}" "${script}" 2>/dev/null)"; then
    _bad "${desc}: exit status nonzero"
    return 0
  fi
  if [[ "${got}" == "${want}" ]]; then _ok "${desc}"; else _bad "${desc}: got '${got}', want '${want}'"; fi
}

_repo none
_expect "no tags -> floor" "version=v1.0.0"
_expect "no tags -> custom floor" "version=v2.3.0" "2.3.0"

_repo old
git -C "${d}" tag v0.0.2 "${old}"
_expect "v0.0.2 below floor 1.0.0 -> v1.0.0" "version=v1.0.0"

_repo bump
git -C "${d}" tag v1.0.0 "${old}"
git -C "${d}" tag v1.0.4 "${old}"
_expect "v1.0.0 + v1.0.4 -> v1.0.5" "version=v1.0.5"

_repo annotated
git -C "${d}" tag -a -m rel v1.2.3 "${old}"
_expect "annotated v1.2.3 counts -> v1.2.4" "version=v1.2.4"

_repo noise
git -C "${d}" tag v1.0.1 "${old}"
for t in v3 standards-check-v1 standards-check-v9.9.9 v1.2.3-rc1 1.5.0 v01.0.0 v2.0; do
  git -C "${d}" tag "${t}" "${old}"
done
_expect "non-semver tags ignored -> v1.0.2" "version=v1.0.2"

_repo onlynoise
for t in v3 standards-check-v1 v9.9.9-rc1; do git -C "${d}" tag "${t}" "${old}"; done
_expect "only non-semver tags -> floor" "version=v1.0.0"

_repo digits
git -C "${d}" tag v1.0.9 "${old}"
git -C "${d}" tag v1.0.10 "${old}"
_expect "v1.0.9 + v1.0.10 sorts numerically -> v1.0.11" "version=v1.0.11"

_repo nine
git -C "${d}" tag v1.0.9 "${old}"
_expect "v1.0.9 -> v1.0.10" "version=v1.0.10"

_repo above
git -C "${d}" tag v2.4.6 "${old}"
_expect "highest above floor wins -> v2.4.7" "version=v2.4.7"

_repo tagged
git -C "${d}" tag v1.0.0 "${old}"
git -C "${d}" tag v1.0.1 "${head}"
_expect "already-tagged commit -> no-op" "version="

_repo taggedann
git -C "${d}" tag -a -m rel v1.0.7 "${head}"
_expect "already-tagged (annotated) commit -> no-op" "version="

_repo nonsemverhead
git -C "${d}" tag v1.0.0 "${old}"
git -C "${d}" tag standards-check-v1 "${head}"
_expect "non-semver tag on commit is not a no-op -> v1.0.1" "version=v1.0.1"

# Bad input exits 2.
_repo bad
for f in v1.0.0 1.0 1.0.0.0 01.0.0 abc ""; do
  rc=0
  (cd "${d}" && TARGET_SHA="${head}" FLOOR="${f}" "${script}" >/dev/null 2>&1) || rc=$?
  if [[ "${rc}" -eq 2 ]]; then _ok "floor '${f}' rejected"; else _bad "floor '${f}': exit ${rc}, want 2"; fi
done
rc=0
(cd "${d}" && TARGET_SHA=0123456789abcdef0123456789abcdef01234567 FLOOR=1.0.0 "${script}" >/dev/null 2>&1) || rc=$?
if [[ "${rc}" -eq 2 ]]; then _ok "unknown TARGET_SHA rejected"; else _bad "unknown TARGET_SHA: exit ${rc}, want 2"; fi

# push-tag.sh against a local bare remote: a new tag lands; a collision fails
# and leaves the remote tag where it was.
pusher="${here}/../auto-tag/push-tag.sh"
remote="${tmp}/remote.git"
git init -q --bare "${remote}"
_repo pusha
git -C "${d}" remote add origin "${remote}"
git -C "${d}" push -q origin HEAD:refs/heads/main
first_head="${head}"
# _remote_tag: where v1.0.0 points on the remote, or empty.
_remote_tag() { git -C "${remote}" rev-parse -q --verify refs/tags/v1.0.0 || true; }
rc=0
(cd "${d}" && VERSION=v1.0.0 TARGET_SHA="${head}" "${pusher}" >/dev/null 2>&1) || rc=$?
at="$(_remote_tag)"
if [[ "${rc}" -eq 0 && "${at}" == "${head}" ]]; then
  _ok "push-tag pushes a new tag to the pushed commit"
else
  _bad "push-tag did not push v1.0.0 to ${head}"
fi
# A second clone that never fetched v1.0.0 picks the same name for another commit.
_repo pushb
git -C "${d}" remote add origin "${remote}"
rc=0
(cd "${d}" && VERSION=v1.0.0 TARGET_SHA="${head}" "${pusher}" >/dev/null 2>&1) || rc=$?
at="$(_remote_tag)"
if [[ "${head}" != "${first_head}" && "${rc}" -ne 0 && "${at}" == "${first_head}" ]]; then
  _ok "colliding push fails and does not move the remote tag"
else
  _bad "colliding push: exit ${rc}, or the remote tag moved"
fi
rc=0
(cd "${d}" && VERSION="" TARGET_SHA="${head}" "${pusher}" >/dev/null 2>&1) || rc=$?
if [[ "${rc}" -eq 2 ]]; then _ok "push-tag without VERSION rejected"; else _bad "push-tag without VERSION: exit ${rc}"; fi

# Credential helper: answers get only, from env.
out="$(GH_TOKEN=tok123 "${helper}" get)"
if [[ "${out}" == $'username=x-access-token\npassword=tok123' ]]; then _ok "helper get prints token"; else _bad "helper get: '${out}'"; fi
out="$(GH_TOKEN=tok123 "${helper}" store </dev/null)"
if [[ -z "${out}" ]]; then _ok "helper store prints nothing"; else _bad "helper store printed '${out}'"; fi
rc=0
env -u GH_TOKEN "${helper}" get >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -ne 0 ]]; then _ok "helper without GH_TOKEN fails"; else _bad "helper without GH_TOKEN exited 0"; fi

echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
