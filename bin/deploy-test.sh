#!/usr/bin/env bash
# cspell:ignore ansidem podman nspawn ABRT
set -euo pipefail
: "${PLATFORM:="podman"}"
: "${ANSIBLE_VER:="11"}"
: "${REGI:="ghcr.io/raven428/container-images"}"
: "${IMAGE:="${REGI}/systemd-${DISTRO:-debian13}:latest"}"
: "${TARGET_NAME:="nsp4ans"}"
MY_BIN="$(/usr/bin/env readlink -f "$0")"
MY_PATH="$(/usr/bin/env dirname "${MY_BIN}")"
res=0
echo "platform [${PLATFORM}] with [${ANSIBLE_VER}] ansible"
# shellcheck disable=1091
source "${MY_PATH}/lib/appimage.sh"
fetch_ansible_appimage "${ANSIBLE_VER}"
case "${PLATFORM}" in
nspawn)
  ensure_packages systemd-container nftables less moreutils
  /usr/bin/env which deploy-nspawn.sh >/dev/null || {
    /usr/bin/env sudo curl -fsSLm 11 -o /usr/local/bin/deploy-nspawn.sh \
      "https://raw.githubusercontent.com/raven428/container-images/refs/heads/master/\
sources/victim-ubuntu-22_04/files/deploy.sh"
    /usr/bin/env sudo chmod 755 /usr/local/bin/deploy-nspawn.sh
  }
  /usr/bin/env sudo nft flush ruleset
  # shellcheck disable=1090
  source "$(/usr/bin/env which deploy-nspawn.sh)"
  /usr/bin/env sudo systemctl restart docker
  ;;
docker | podman)
  CONT_ADDONS='--cap-add=NET_ADMIN'
  if [[ "${PLATFORM}" == 'docker' ]]; then
    TARGET_NAME='dkr4ans'
  else
    TARGET_NAME='pdm4ans'
  fi
  /usr/bin/env "${PLATFORM}" pull "${IMAGE}"
  /usr/bin/env "${PLATFORM}" tag "${IMAGE}" "l.c/${TARGET_NAME}:l"
  # shellcheck disable=2086
  /usr/bin/env "${PLATFORM}" inspect --format '{{.State.Running}}' "${TARGET_NAME}" \
    2>/dev/null | grep -qx true || /usr/bin/env "${PLATFORM}" run -d ${CONT_ADDONS} --rm \
    --hostname="${TARGET_NAME}" --name="${TARGET_NAME}" "l.c/${TARGET_NAME}:l"
  ;;
*)
  echo "wrong [${PLATFORM}] platform, expected: nspawn|docker|podman" >&2
  exit 1
  ;;
esac
tmp_log=$(/usr/bin/env mktemp "/tmp/ansidemXXXXX.log")
_cleanup_done=0
# shellcheck disable=2329
_deploy_cleanup() {
  local _sig="${1:-}"
  # guard against the EXIT trap re-running cleanup after a re-raised signal
  if [[ "${_cleanup_done}" -eq 0 ]]; then
    _cleanup_done=1
    /usr/bin/env rm -vf "${tmp_log}"
  fi
  # re-raise the original signal so the caller sees the real cause
  if [[ -n "${_sig}" ]]; then
    trap - "${_sig}"
    kill -"${_sig}" "$$"
    # fallback if the re-raised signal did not terminate us
    exit $((128 + $(/usr/bin/env kill -l "${_sig}")))
  fi
}
trap '_deploy_cleanup' EXIT
for _sig in INT QUIT ABRT TERM; do
  # shellcheck disable=2064
  trap "_deploy_cleanup ${_sig}" "${_sig}"
done
(
  cd "${MY_PATH}/../ansible"
  "${APPIMAGE_BIN}" ansible-galaxy install -r requirements.yaml
  "${APPIMAGE_BIN}" ansible-playbook site.yaml --diff -i inventory -u root \
    -l "${TARGET_NAME}"
  ANSIBLE_LOG_PATH="${tmp_log}" \
    "${APPIMAGE_BIN}" ansible-playbook site.yaml --diff -i inventory -u root \
    -l "${TARGET_NAME}"
)
# shellcheck disable=2016
changed_count="$(
  /usr/bin/env fgrep 'changed=' "${tmp_log}" |
    /usr/bin/env sed -r 's/.* changed=([0-9]+) .*/\1/i' |
    /usr/bin/env awk '{ s+=$1 } END { print s+0 }'
)" || changed_count=0
if [[ "${changed_count}" -gt 0 ]]; then
  echo "changed=${changed_count}: ansible isn't idempotent"
  res=$((res + 1))
fi
if [[ "${PLATFORM}" == 'docker' || "${PLATFORM}" == 'podman' ]]; then
  /usr/bin/env "${PLATFORM}" rm -f "${TARGET_NAME}"
fi
exit "${res}"
