#!/usr/bin/env bash

set -euo pipefail

log() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err() { echo "[✗] $*"; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root. Please run with sudo."
    exit 1
fi

echo "ZRAM & Memory Low-Latency Optimization"

log "Checking ZRAM kernel module..."
modprobe zram num_devices=1 2>/dev/null || modprobe zram 2>/dev/null || true

if [[ ! -b /dev/zram0 ]]; then
    err "Kernel does not support ZRAM or /dev/zram0 could not be created."
    exit 1
fi

log "Deactivating existing ZRAM swap if active..."
swapoff /dev/zram0 2>/dev/null || true
echo 1 > /sys/block/zram0/reset 2>/dev/null || true

log "Selecting best compression algorithm..."
ALGO="lzo-rle"
if grep -q "zstd" /sys/block/zram0/comp_algorithm 2>/dev/null; then
    ALGO="zstd"
elif grep -q "lz4" /sys/block/zram0/comp_algorithm 2>/dev/null; then
    ALGO="lz4"
fi
echo "$ALGO" > /sys/block/zram0/comp_algorithm
log "Compression algorithm set to: $ALGO"

TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
ZRAM_SIZE_BYTES=$((TOTAL_MEM_KB * 1024))
ZRAM_SIZE_GB=$((TOTAL_MEM_KB / 1024 / 1024))
echo "$ZRAM_SIZE_BYTES" > /sys/block/zram0/disksize
log "ZRAM virtual device sized to 100% of RAM (~${ZRAM_SIZE_GB} GB)"

log "Formatting and enabling ZRAM swap..."
mkswap -U clear -L zram0 /dev/zram0 >/dev/null
swapon -p 32767 /dev/zram0

log "Tuning virtual memory subsystem for compressed RAM..."
mkdir -p /etc/sysctl.d
cat >/etc/sysctl.d/99-ramtune.conf <<'EOF'
vm.swappiness = 150
vm.page-cluster = 0
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOF

sysctl -w vm.swappiness=150 >/dev/null 2>&1 || true
sysctl -w vm.page-cluster=0 >/dev/null 2>&1 || true
sysctl -w vm.watermark_boost_factor=0 >/dev/null 2>&1 || true
sysctl -w vm.watermark_scale_factor=125 >/dev/null 2>&1 || true
sysctl -w vm.vfs_cache_pressure=50 >/dev/null 2>&1 || true
sysctl -w vm.dirty_ratio=10 >/dev/null 2>&1 || true
sysctl -w vm.dirty_background_ratio=5 >/dev/null 2>&1 || true

if [[ -f /sys/kernel/mm/lru_gen/enabled ]]; then
    log "Enabling Multi-Gen LRU (MGLRU) for smart page aging..."
    echo y > /sys/kernel/mm/lru_gen/enabled 2>/dev/null || echo 7 > /sys/kernel/mm/lru_gen/enabled 2>/dev/null || true
    mkdir -p /etc/tmpfiles.d
    echo "w /sys/kernel/mm/lru_gen/enabled - - - - y" > /etc/tmpfiles.d/99-mglru.conf
fi

log "Setting up persistence service..."
mkdir -p /usr/local/bin
cat >/usr/local/bin/ramtune-init.sh <<EOF
#!/usr/bin/env bash
modprobe zram num_devices=1 2>/dev/null || modprobe zram 2>/dev/null || true
[[ -b /dev/zram0 ]] || exit 0
swapoff /dev/zram0 2>/dev/null || true
echo 1 > /sys/block/zram0/reset 2>/dev/null || true
grep -q "$ALGO" /sys/block/zram0/comp_algorithm 2>/dev/null && echo "$ALGO" > /sys/block/zram0/comp_algorithm
echo "$ZRAM_SIZE_BYTES" > /sys/block/zram0/disksize
mkswap -U clear -L zram0 /dev/zram0 >/dev/null 2>&1
swapon -p 32767 /dev/zram0 2>/dev/null || true
[[ -f /sys/kernel/mm/lru_gen/enabled ]] && echo y > /sys/kernel/mm/lru_gen/enabled 2>/dev/null || true
EOF
chmod +x /usr/local/bin/ramtune-init.sh

cat >/usr/local/bin/ramtune-stop.sh <<'EOF'
#!/usr/bin/env bash
swapoff /dev/zram0 2>/dev/null || true
echo 1 > /sys/block/zram0/reset 2>/dev/null || true
EOF
chmod +x /usr/local/bin/ramtune-stop.sh

cat >/etc/systemd/system/ramtune.service <<'EOF'
[Unit]
Description=ZRAM & RAM Low-Latency Optimizer
DefaultDependencies=no
After=local-fs.target
Before=swap.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/ramtune-init.sh
ExecStop=/usr/local/bin/ramtune-stop.sh

[Install]
WantedBy=swap.target
EOF

systemctl daemon-reload
systemctl enable ramtune.service 2>/dev/null || true

echo ""
log "RAM & ZRAM Optimization Complete!"
if command -v zramctl &>/dev/null; then
    zramctl
else
    swapon --show
fi
