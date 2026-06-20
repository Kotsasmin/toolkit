#!/usr/bin/env bash

set -euo pipefail

log() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err() { echo "[✗] $*"; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root. Please run with sudo."
    exit 1
fi

echo "Applying TCP Tuning Only"
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

log "TCP Tuning Applied!"
