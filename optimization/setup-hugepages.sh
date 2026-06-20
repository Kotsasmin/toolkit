#!/usr/bin/env bash

set -euo pipefail

log() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err() { echo "[✗] $*"; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root. Please run with sudo."
    exit 1
fi

echo "Setup 2MB Huge Pages"
read -p "Enter target Heap size in GB [default: 35]: " HEAP_GB
[[ -z "$HEAP_GB" ]] && HEAP_GB=35

PAGES=$(((HEAP_GB * 1024 / 2) + 512))
echo "Heap size:       ${HEAP_GB}G"
echo "Pages to alloc:  ${PAGES} (x 2MB = $((PAGES * 2))MB)"
TOTAL_MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
REQUIRED_MB=$((PAGES * 2 + 4096))
if [[ $TOTAL_MEM_MB -lt $REQUIRED_MB ]]; then
    err "Not enough memory. Need $((REQUIRED_MB / 1024))G, have $((TOTAL_MEM_MB / 1024))G"
    exit 1
fi
echo "--- Configuring memory lock limits ---"
LIMITS_FILE="/etc/security/limits.d/99-hugepages.conf"
cat >"$LIMITS_FILE" <<EOF
*    soft    memlock    unlimited
*    hard    memlock    unlimited
root soft    memlock    unlimited
root hard    memlock    unlimited
EOF
echo "--- Configuring sysctl ---"
SYSCTL_FILE="/etc/sysctl.d/99-hugepages.conf"
cat >"$SYSCTL_FILE" <<EOF
vm.nr_hugepages = ${PAGES}
vm.max_map_count = 2097152
vm.overcommit_memory = 1
vm.swappiness = 1
vm.zone_reclaim_mode = 0
EOF
echo "--- Allocating huge pages ---"
sync
echo 3 >/proc/sys/vm/drop_caches || true
sleep 1
sysctl --system >/dev/null 2>&1
echo "$PAGES" >/proc/sys/vm/nr_hugepages || true
sleep 2
ALLOCATED=$(cat /proc/sys/vm/nr_hugepages)
if [[ $ALLOCATED -ge $PAGES ]]; then
    log "All ${PAGES} pages allocated successfully!"
else
    warn "Only ${ALLOCATED}/${PAGES} pages allocated."
fi
if mount | grep -q hugetlbfs; then
    log "hugetlbfs already mounted"
else
    mkdir -p /dev/hugepages
    mount -t hugetlbfs nodev /dev/hugepages
    if ! grep -q "hugetlbfs" /etc/fstab; then
        echo "hugetlbfs /dev/hugepages hugetlbfs defaults 0 0" >>/etc/fstab
    fi
    log "Mounted hugetlbfs at /dev/hugepages"
fi
