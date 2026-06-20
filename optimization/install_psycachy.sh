#!/usr/bin/env bash

set -euo pipefail

log() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err() { echo "[✗] $*"; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root. Please run with sudo."
    exit 1
fi

DETECTED_OS="unknown"
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    case $ID in
    ubuntu | debian | pop | linuxmint) DETECTED_OS="debian" ;;
    arch | cachyos | manjaro | endeavouros) DETECTED_OS="arch" ;;
    fedora | rhel | centos | rocky | almalinux) DETECTED_OS="rhel" ;;
    *) DETECTED_OS=$ID ;;
    esac
fi

echo "Installing Psycachy Kernel"

if [[ "$DETECTED_OS" != "debian" ]]; then
    err "Psycachy kernel installation is only supported on Debian/Ubuntu systems."
    exit 1
fi
PSYCACHY_TAG="6.17.13"
PSYCACHY_VERSION="6.17.13-3"
GITHUB_BASE="https://github.com/psygreg/linux-psycachy/releases/download/${PSYCACHY_TAG}"
WORK_DIR="/tmp/psycachy-install"

PRIMARY_NIC=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(enp|eno|eth)' | head -1 || true)
SECONDARY_NIC=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(enp|eno|eth)' | tail -1 || true)
if [[ -n "$PRIMARY_NIC" && -n "$SECONDARY_NIC" && "$PRIMARY_NIC" != "$SECONDARY_NIC" ]]; then
    WAIT_ONLINE_ARGS="--interface=${PRIMARY_NIC} --interface=${SECONDARY_NIC} --timeout=10"
else
    WAIT_ONLINE_ARGS="--any --timeout=10"
fi
mkdir -p /etc/systemd/system/systemd-networkd-wait-online.service.d/
cat >/etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online ${WAIT_ONLINE_ARGS}
EOF
systemctl daemon-reload
log "Downloading packages..."
mkdir -p "$WORK_DIR" && cd "$WORK_DIR"
IMAGE_DEB="linux-image-psycachy_${PSYCACHY_VERSION}_amd64.deb"
HEADERS_DEB="linux-headers-psycachy_${PSYCACHY_VERSION}_amd64.deb"
[[ ! -f "$IMAGE_DEB" ]] && curl -fSL -o "$IMAGE_DEB" "${GITHUB_BASE}/${IMAGE_DEB}"
[[ ! -f "$HEADERS_DEB" ]] && curl -fSL -o "$HEADERS_DEB" "${GITHUB_BASE}/${HEADERS_DEB}"
log "Installing kernel..."
dpkg -i "$IMAGE_DEB" "$HEADERS_DEB"
log "Configuring GRUB..."
cp /etc/default/grub /etc/default/grub.bak.$(date +%s)
OVH_BASE='nomodeset iommu=pt console=tty0 console=ttyS0,115200n8'
TUNING_PARAMS='processor.max_cstate=1 amd_pstate.status=active mitigations=off'
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"${OVH_BASE} ${TUNING_PARAMS}\"|" /etc/default/grub
sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT=0|' /etc/default/grub
update-grub
log "Installed! You must reboot to use the new kernel."
