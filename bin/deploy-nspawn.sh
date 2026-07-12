#!/usr/bin/env bash
# cspell:ignore keygen DNSSEC edns networkd journalctl networkctl
set -euo pipefail
: "${REGI:="ghcr.io/raven428/container-images"}"
: "${NSPAWN:="${REGI}/victim-ubuntu-22_04:latest"}"
: "${NSP_NAME:="nsp4ans"}"
: "${DEST_DIR:="/tmp/${NSP_NAME}"}"
/usr/bin/env which machinectl >/dev/null || (
  export DEBIAN_FRONTEND=noninteractive
  /usr/bin/env sudo apt-get update
  /usr/bin/env sudo apt-get -y install --no-install-recommends systemd-container less \
    moreutils nftables
  # /usr/bin/env sudo nft flush ruleset
)
/usr/bin/env sudo machinectl -s SIGKILL kill "${NSP_NAME}" || true
/usr/bin/env podman rm -f "${NSP_NAME}" || true
/usr/bin/env podman run -d --name "${NSP_NAME}" --entrypoint sleep "${NSPAWN}" infinity
/usr/bin/env podman exec -e DEBIAN_FRONTEND=noninteractive "${NSP_NAME}" \
  apt-get update
/usr/bin/env podman exec -e DEBIAN_FRONTEND=noninteractive "${NSP_NAME}" \
  apt-get -y install --no-install-recommends systemd-resolved
/usr/bin/env sudo rm -rf "${DEST_DIR}"
/usr/bin/env mkdir -vp "${DEST_DIR}"
/usr/bin/env podman export "${NSP_NAME}" |
  /usr/bin/env sudo tar -x -C "${DEST_DIR}"
/usr/bin/env podman rm -f "${NSP_NAME}"
/usr/bin/env mkdir -vp /etc/systemd/network
/usr/bin/env sudo mkdir -vp "${DEST_DIR}/root/.ssh"
if [[ -e ~/.ssh/authorized_keys ]]; then
  /usr/bin/env sudo cp -v ~/.ssh/authorized_keys "${DEST_DIR}/root/.ssh"
else
  key_name='ssh-key'
  /usr/bin/env ssh-agent -s >/tmp/ssh-agent-nspawn.env
  # shellcheck disable=1091
  source /tmp/ssh-agent-nspawn.env
  /usr/bin/env ssh-keygen -t ed25519 -f "${key_name}" -C "${key_name}" -N '' <<<'y'
  /usr/bin/env ssh-add "${key_name}"
  /usr/bin/env sudo cp -v "${key_name}.pub" "${DEST_DIR}/root/.ssh/authorized_keys"
fi
/usr/bin/env ssh-keygen -f ~/.ssh/known_hosts -R '192.168.99.2' || true
/usr/bin/env ssh-keygen -f ~/.ansible/ssh/known_hosts -R '192.168.99.2' || true
/usr/bin/env cat <<EOF | /usr/bin/env sudo tee \
  /etc/systemd/network/80-container-ve-"${NSP_NAME}".network >/dev/null
# veth for [${NSP_NAME}]
[Match]
Name=ve-${NSP_NAME}
Driver=veth

[Network]
EmitLLDP=customer-bridge
Address=192.168.99.1/28
LinkLocalAddressing=no
IPMasquerade=both
DHCPServer=yes
IPv6SendRA=no
LLDP=no
EOF
/usr/bin/env cat <<EOF | /usr/bin/env sudo tee \
  "${DEST_DIR}/etc/systemd/network/80-container-host0.network" >/dev/null
# main
[Match]
Name=host0

[Network]
IPv6AcceptRA=no
MulticastDNS=yes
LinkLocalAddressing=no
Address=192.168.99.2/28
Gateway=192.168.99.1
EOF
/usr/bin/env cat <<EOF | /usr/bin/env sudo tee \
  "${DEST_DIR}/etc/systemd/resolved.conf" >/dev/null
# resolved.conf(5)
[Resolve]
DNS=1.1.1.1   8.8.8.8   9.9.9.9
FallbackDNS=1.0.0.1   8.8.4.4   149.112.112.112
Domains=
Cache=yes
DNSSEC=allow-downgrade
DNSOverTLS=opportunistic
MulticastDNS=yes
DNSStubListener=yes
EOF
/usr/bin/env cat <<EOF | /usr/bin/env sudo tee \
  "${DEST_DIR}/etc/resolv.conf" >/dev/null
nameserver 127.0.0.53
options edns0 trust-ad
search local
EOF
/usr/bin/env sudo systemctl --root="${DEST_DIR}" enable \
  ssh.service systemd-networkd.service systemd-resolved.service
/usr/bin/env sudo systemctl reload systemd-networkd
count=7
while ! /usr/bin/env curl -sm 1 https://connectivitycheck.gstatic.com/generate_204; do
  echo "waiting network ready, left [$count] tries"
  count=$((count - 1))
  if [[ $count -le 0 ]]; then
    echo 'container failed'
    exit 1
  fi
  sleep 1
done
if [[ $count -le 0 ]]; then
  echo '… failed, exiting'
  exit 1
fi
/usr/bin/env sudo systemd-run --unit="nspawn-${NSP_NAME}" --collect \
  --property=StandardOutput=journal --property=StandardError=journal systemd-nspawn -b \
  --link-journal=no --private-network --network-veth --machine="${NSP_NAME}" \
  --directory="${DEST_DIR}"
