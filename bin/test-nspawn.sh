#!/usr/bin/env bash
set -euo pipefail


: "${NSP_NAME:="nsp4ans"}"
: "${CONTENGI:="docker"}"
: "${CONT_NAME:="ans2nsp-${USER}"}"
MY_BIN="$(readlink -f "$0")"
MY_PATH="$(dirname "${MY_BIN}")"
res=0
echo "CONTENGI[${CONTENGI}]"
/usr/bin/env sudo su -c 'DEBIAN_FRONTEND=noninteractive apt-get purge -y needrestart'
/usr/bin/env which sponge >/dev/null || {
  /usr/bin/env sudo apt-get update &&
    /usr/bin/env sudo su -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y moreutils'
}
/usr/bin/env which deploy-nspawn.sh >/dev/null || {
  /usr/bin/env sudo curl -sL -o /usr/local/bin/deploy-nspawn.sh \
    https://raw.githubusercontent.com/raven428/container-images/refs/heads/master/sources/victim-ubuntu-22_04/files/deploy.sh
  /usr/bin/env sudo chmod 755 /usr/local/bin/deploy-nspawn.sh
}
/usr/bin/env which ansible-docker.sh >/dev/null || {
  /usr/bin/env sudo curl -fsSLm 11 -o /usr/local/bin/ansible-docker.sh \
    https://raw.githubusercontent.com/raven428/container-images/refs/heads/master/_shared/install/ansible/ansible-docker.sh
  /usr/bin/env sudo chmod 755 /usr/local/bin/ansible-docker.sh
}
# flush firewall for nspawn deploy:
/usr/bin/env sudo nft flush ruleset
# shellcheck disable=1090
source "$(which deploy-nspawn.sh)"
# recover docker and podman rules:
/usr/bin/env sudo systemctl restart docker
/usr/bin/env sudo systemctl restart podman
tmp_log=$(/usr/bin/env mktemp "/tmp/ansidemXXXXX.log")
ANSIBLE_IMAGE_NAME='ghcr.io/raven428/container-images/ansible-11:latest'
[[ "${CONTENGI}" == 'podman' ]] && export ANSIBLE_CONT_ADDONS='--userns=keep-id'
export CONTENGI ANSIBLE_IMAGE_NAME ANSIBLE_CONT_ADDONS
{
  cd "${MY_PATH}/../ansible"
  ANSIBLE_CONT_NAME="${CONT_NAME}" /usr/bin/env ansible-docker.sh true
  /usr/bin/env machinectl -la
  ANSIBLE_CONT_NAME="${CONT_NAME}" \
    /usr/bin/env ansible-docker.sh ansible-playbook site.yaml \
    --diff -i inventory -u root -l "${NSP_NAME}"
  ANSIBLE_LOG_PATH=${tmp_log} \
    ANSIBLE_CONT_NAME="${CONT_NAME}" \
    /usr/bin/env ansible-docker.sh ansible-playbook site.yaml \
    --diff -i inventory -u root -l "${NSP_NAME}"
  /usr/bin/env ${CONTENGI} cp "${CONT_NAME}:${tmp_log}" "${tmp_log}"
}
# shellcheck disable=2016
changed_count="$(
  /usr/bin/env fgrep 'changed=' "${tmp_log}" |
    /usr/bin/env sed -r 's/.* changed=([0-9]+) .*/\1/i' |
    /usr/bin/env awk '{ s+=$1 } END { print s }'
)"
if [[ ${changed_count} -gt 0 ]]; then
  echo "changed=${changed_count}: ansible isn't idempotent"
  res=$((res + 1))
fi
/usr/bin/env rm -fv "${tmp_log}"
exit "${res}"
