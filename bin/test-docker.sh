#!/usr/bin/env bash
set -euo pipefail
: "${REGI:=ghcr.io/raven428/container-images}"
: "${IMAGE:="${REGI}/systemd-ubuntu-22_04:000"}"
: "${CONAME:="dkr4ans"}"
: "${CONT_NAME:="ans2dkr-${USER}"}"
: "${SSH_AUTH_SOCK:="/nonexistent"}"
MY_BIN="$(readlink -f "$0")"
MY_PATH="$(dirname "${MY_BIN}")"
res=0
/usr/bin/env which sponge >/dev/null || (
  /usr/bin/env sudo apt-get update &&
    /usr/bin/env sudo apt-get install moreutils
)
/usr/bin/env which ansible-docker.sh >/dev/null || (
  /usr/bin/env curl -sL -o /usr/local/bin/ansible-docker.sh \
    https://raw.githubusercontent.com/raven428/container-images/refs/heads/master/sources/ansible-9_9_0/ansible-docker.sh
  /usr/bin/env chmod 755 /usr/local/bin/ansible-docker.sh
)
[[ "${SSH_AUTH_SOCK}" == "/nonexistent" ]] && export SSH_AUTH_SOCK
(
  cd "${MY_PATH}/../ansible"
  ANSIBLE_CONT_NAME="${CONT_NAME}" \
    ANSIBLE_IMAGE_NAME='ghcr.io/raven428/container-images/docker-ansible-6_7_0:000' \
    ANSIBLE_CONT_ADDONS='
    --cgroupns=host --privileged
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw
    --cap-add=NET_ADMIN --cap-add=SYS_MODULE
  ' \
    ANSIBLE_CONT_COMMAND=' ' /usr/bin/env ansible-docker.sh true
)
count=7
while ! /usr/bin/env docker exec "${CONT_NAME}" systemctl status docker; do
  echo "waiting container ready, left [$count] tries"
  count=$((count - 1))
  if [[ $count -le 0 ]]; then
    break
  fi
  sleep 1
done
/usr/bin/env docker exec -t "${CONT_NAME}" docker pull "${IMAGE}"
/usr/bin/env docker exec -t "${CONT_NAME}" docker tag "${IMAGE}" "${CONAME}"
/usr/bin/env docker exec -t "${CONT_NAME}" docker rm -f "${CONAME}"
/usr/bin/env docker exec -t "${CONT_NAME}" \
  docker run -d --privileged --cgroupns=host \
  --cap-add=NET_ADMIN --cap-add=SYS_MODULE --name="${CONAME}" \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  "${CONAME}"
tmp_log=$(/usr/bin/env mktemp "/tmp/ansidemXXXXX.log")
(
  cd "${MY_PATH}/../ansible"
  ANSIBLE_CONT_NAME="${CONT_NAME}" \
    ansible-docker.sh ansible-playbook site.yaml \
    --diff -i inventory -u root -l "${CONAME}"
  ANSIBLE_LOG_PATH=${tmp_log} \
  ANSIBLE_CONT_NAME="${CONT_NAME}" \
    ansible-docker.sh ansible-playbook site.yaml \
    --diff -i inventory -u root -l "${CONAME}"
  /usr/bin/env docker cp "${CONT_NAME}:${tmp_log}" "${tmp_log}"
)
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
