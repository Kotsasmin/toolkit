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
sysctl -w net.core.rmem_default=1048576 >/dev/null
sysctl -w net.core.wmem_default=1048576 >/dev/null
sysctl -w net.core.rmem_max=67108864 >/dev/null
sysctl -w net.core.wmem_max=67108864 >/dev/null
sysctl -w net.core.netdev_max_backlog=65536 >/dev/null
sysctl -w net.core.somaxconn=65535 >/dev/null
sysctl -w net.core.optmem_max=2097152 >/dev/null
sysctl -w net.core.netdev_budget=600 >/dev/null
sysctl -w net.core.netdev_budget_usecs=8000 >/dev/null
sysctl -w net.ipv4.tcp_rmem="4096 1048576 67108864" >/dev/null
sysctl -w net.ipv4.tcp_wmem="4096 1048576 67108864" >/dev/null
sysctl -w net.ipv4.udp_rmem_min=8192 >/dev/null
sysctl -w net.ipv4.udp_wmem_min=8192 >/dev/null
sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null
sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null
sysctl -w net.ipv4.tcp_fin_timeout=10 >/dev/null
sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null
sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null
sysctl -w net.ipv4.tcp_timestamps=1 >/dev/null
sysctl -w net.ipv4.tcp_sack=1 >/dev/null
sysctl -w net.ipv4.tcp_window_scaling=1 >/dev/null
sysctl -w net.ipv4.tcp_no_metrics_save=1 >/dev/null
sysctl -w net.ipv4.tcp_ecn=1 >/dev/null
sysctl -w net.ipv4.tcp_adv_win_scale=2 >/dev/null
sysctl -w net.ipv4.tcp_max_syn_backlog=65536 >/dev/null
sysctl -w net.ipv4.tcp_max_tw_buckets=2000000 >/dev/null
sysctl -w net.ipv4.tcp_syncookies=1 >/dev/null
sysctl -w net.ipv4.tcp_keepalive_time=60 >/dev/null
sysctl -w net.ipv4.tcp_keepalive_intvl=10 >/dev/null
sysctl -w net.ipv4.tcp_keepalive_probes=6 >/dev/null
if grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    modprobe sch_fq 2>/dev/null || true
    modprobe tcp_bbr 2>/dev/null || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
fi
log "Tuning VM and memory..."
sysctl -w vm.swappiness=10 >/dev/null
sysctl -w vm.vfs_cache_pressure=50 >/dev/null
sysctl -w vm.dirty_ratio=10 >/dev/null
sysctl -w vm.dirty_background_ratio=5 >/dev/null
sysctl -w vm.max_map_count=2147483642 >/dev/null
log "Tuning CPU Governors..."
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
cat >/etc/security/limits.d/99-performance.conf <<EOF
*    soft    nofile    1048576
*    hard    nofile    1048576
*    soft    memlock   unlimited
*    hard    memlock   unlimited
*    soft    nproc     unlimited
*    hard    nproc     unlimited
EOF

log "Applying TCP Tuning..."
CWND=1520
modprobe tcp_bbr 2>/dev/null || true
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true
sysctl -w net.core.default_qdisc=fq 2>/dev/null || true
sysctl -w net.ipv4.tcp_slow_start_after_idle=0 2>/dev/null || true
sysctl -w net.ipv4.tcp_adv_win_scale=2 2>/dev/null || true
sysctl -w net.core.netdev_max_backlog=8192 2>/dev/null || true
sysctl -w net.core.netdev_budget=600 2>/dev/null || true
sysctl -w net.core.netdev_budget_usecs=4000 2>/dev/null || true
sysctl -w net.core.rmem_max=16777216 2>/dev/null || true
sysctl -w net.core.wmem_max=16777216 2>/dev/null || true
sysctl -w net.ipv4.tcp_rmem="4096 2097152 16777216" 2>/dev/null || true
sysctl -w net.ipv4.tcp_wmem="4096 2097152 16777216" 2>/dev/null || true

ip route show | while read -r route; do
    echo "$route" | grep -q "initcwnd" && continue
    ip route replace $route initcwnd $CWND initrwnd $CWND 2>/dev/null || true
done
ip route show | while read -r route; do
    echo "$route" | grep -q "quickack" && continue
    ip route replace $route quickack 1 2>/dev/null || true
done

log "Optimizations Applied!"
