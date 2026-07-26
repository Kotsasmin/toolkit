#!/usr/bin/env bash

set -euo pipefail

log() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err() { echo "[✗] $*"; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root. Please run with sudo."
    exit 1
fi

echo "Applying Full Low-Latency Optimizations"

log "Tuning network stack..."
mkdir -p /etc/modules-load.d
cat >/etc/modules-load.d/99-supertune.conf <<EOF
sch_fq
tcp_bbr
EOF
modprobe sch_fq 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true

mkdir -p /etc/sysctl.d
cat >/etc/sysctl.d/99-supertune.conf <<EOF
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 65536
net.core.somaxconn = 65535
net.core.optmem_max = 2097152
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.core.default_qdisc = fq
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_adv_win_scale = 2
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_congestion_control = bbr
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.max_map_count = 2147483642
EOF
sysctl --system >/dev/null 2>&1 || true

log "Tuning VM and memory..."
# Applied via /etc/sysctl.d/99-supertune.conf above

log "Tuning CPU Governors..."
mkdir -p /etc/udev/rules.d
cat >/etc/udev/rules.d/99-cpu-governor.rules <<EOF
SUBSYSTEM=="cpu", ACTION=="add", TEST=="cpufreq/scaling_governor", ATTR{cpufreq/scaling_governor}="performance"
EOF
for gov_path in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -f "$gov_path" ]] && echo performance >"$gov_path" 2>/dev/null || true
done
[[ -f /sys/devices/system/cpu/cpufreq/boost ]] && echo 1 >/sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true

log "Disabling Power Management & IRQBalance..."
systemctl stop irqbalance 2>/dev/null || true
systemctl disable irqbalance 2>/dev/null || true

log "Setting Ulimits..."
ulimit -n 1048576 2>/dev/null || true
ulimit -l unlimited 2>/dev/null || true
mkdir -p /etc/security/limits.d
cat >/etc/security/limits.d/99-performance.conf <<EOF
*    soft    nofile    1048576
*    hard    nofile    1048576
*    soft    memlock   unlimited
*    hard    memlock   unlimited
*    soft    nproc     unlimited
*    hard    nproc     unlimited
EOF

log "Applying TCP Tuning..."
mkdir -p /usr/local/bin
cat >/usr/local/bin/supertune-routes.sh <<'EOF'
#!/usr/bin/env bash
CWND=1520
ip route show | while read -r route; do
    echo "$route" | grep -q "initcwnd" && continue
    ip route replace $route initcwnd $CWND initrwnd $CWND 2>/dev/null || true
done
ip route show | while read -r route; do
    echo "$route" | grep -q "quickack" && continue
    ip route replace $route quickack 1 2>/dev/null || true
done
EOF
chmod +x /usr/local/bin/supertune-routes.sh

if [[ -f /etc/systemd/system/supertune.service ]]; then
    systemctl disable --now supertune.service 2>/dev/null || true
    rm -f /etc/systemd/system/supertune.service
    systemctl daemon-reload 2>/dev/null || true
fi
if [[ -d /etc/NetworkManager/dispatcher.d ]]; then
    ln -sf /usr/local/bin/supertune-routes.sh /etc/NetworkManager/dispatcher.d/99-supertune-routes
fi
if [[ -d /etc/network/if-up.d ]]; then
    ln -sf /usr/local/bin/supertune-routes.sh /etc/network/if-up.d/99-supertune-routes
fi
mkdir -p /etc/cron.d
cat >/etc/cron.d/99-supertune-routes <<EOF
@reboot root /usr/local/bin/supertune-routes.sh >/dev/null 2>&1
EOF
/usr/local/bin/supertune-routes.sh 2>/dev/null || true

log "Optimizations Applied!"
