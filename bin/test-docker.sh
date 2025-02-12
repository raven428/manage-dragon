#!/usr/bin/env bash
set -euo pipefail
: "${REGI:="ghcr.io/raven428/container-images"}"
: "${IMAGE:="${REGI}/systemd-ubuntu-22_04:000"}"
: "${CONAME:="dkr4ans"}"
: "${CONTENGI:="docker"}"
: "${CONT_NAME:="ans2dkr-${USER}"}"
: "${SSH_AUTH_SOCK:="/dev/null"}"
MY_BIN="$(readlink -f "$0")"
MY_PATH="$(dirname "${MY_BIN}")"
res=0
echo "CONTENGI[${CONTENGI}]/CONAME[${CONAME}]"
/usr/bin/env which sponge >/dev/null || {
  /usr/bin/env sudo su -c 'DEBIAN_FRONTEND=noninteractive apt-get purge -y needrestart'
  /usr/bin/env sudo apt-get update &&
    /usr/bin/env sudo su -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y moreutils'
}
/usr/bin/env which ansible-docker.sh >/dev/null || {
  /usr/bin/env sudo curl -fsSLm 11 -o /usr/local/bin/ansible-docker.sh \
    https://raw.githubusercontent.com/raven428/container-images/refs/heads/master/_shared/install/ansible/ansible-docker.sh
  /usr/bin/env sudo chmod 755 /usr/local/bin/ansible-docker.sh
}
[[ "${SSH_AUTH_SOCK}" == '/dev/null' ]] && export SSH_AUTH_SOCK
# https://www.redhat.com/en/blog/podman-inside-container
ANSIBLE_CONT_ADDONS='--privileged'
ANSIBLE_IMAGE_NAME='ghcr.io/raven428/container-images/ansible-11_1_0:latest'
[[ "${CONTENGI}" == 'docker' ]] && {
  ANSIBLE_IMAGE_NAME="ghcr.io/raven428/container-images/${CONTENGI}-ansible-11_1_0:latest"
  ANSIBLE_CONT_ADDONS='--cap-add=NET_ADMIN --cap-add=SYS_MODULE --cgroupns=host
--privileged -v /sys/fs/cgroup:/sys/fs/cgroup:rw'
  export ANSIBLE_CONT_COMMAND=' '
}
export CONTENGI ANSIBLE_CONT_ADDONS ANSIBLE_IMAGE_NAME
{
  cd "${MY_PATH}/../ansible"
  ANSIBLE_CONT_NAME="${CONT_NAME}" /usr/bin/env ansible-docker.sh true
}
[[ "${CONTENGI}" == 'docker' ]] && {
  count=7
  while ! /usr/bin/env ${CONTENGI} exec "${CONT_NAME}" systemctl status docker; do
    echo "waiting container ready, left [$count] tries"
    count=$((count - 1))
    if [[ $count -le 0 ]]; then
      break
    fi
    sleep 1
  done
}
[[ "${CONTENGI}" == 'podman' ]] && {
  /usr/bin/env ${CONTENGI} exec -t "${CONT_NAME}" mkdir -p /etc/containers
  /usr/bin/env ${CONTENGI} exec -t "${CONT_NAME}" sh -c \
    'cat <<EOF >/etc/containers/storage.conf
[storage]
driver = "vfs"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
EOF'
}
/usr/bin/env ${CONTENGI} exec -t "${CONT_NAME}" ${CONTENGI} pull "${IMAGE}"
/usr/bin/env ${CONTENGI} exec -t "${CONT_NAME}" ${CONTENGI} tag "${IMAGE}" "${CONAME}:l"
/usr/bin/env ${CONTENGI} exec -t "${CONT_NAME}" ${CONTENGI} rm -f "${CONAME}" || true
[[ "${CONTENGI}" == 'podman' ]] && export ANSIBLE_CONT_ADDONS='--cap-add=NET_ADMIN,SYS_MODULE,SYS_ADMIN'
/usr/bin/env ${CONTENGI} exec -t "${CONT_NAME}" \
  ${CONTENGI} run -d ${ANSIBLE_CONT_ADDONS} \
  --hostname="${CONAME}" --name="${CONAME}" "${CONAME}:l"
tmp_log=$(/usr/bin/env mktemp "/tmp/ansidemXXXXX.log")
{
  cd "${MY_PATH}/../ansible"
  ANSIBLE_CONT_NAME="${CONT_NAME}" \
    ansible-docker.sh ansible-playbook site.yaml \
    --diff -i inventory -u root -l "${CONAME}"
  ANSIBLE_LOG_PATH=${tmp_log} \
    ANSIBLE_CONT_NAME="${CONT_NAME}" \
    ansible-docker.sh ansible-playbook site.yaml \
    --diff -i inventory -u root -l "${CONAME}"
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
/usr/bin/env ${CONTENGI} exec -t "${CONT_NAME}" \
  ${CONTENGI} rm -f "${CONAME}"
exit "${res}"
