#!/usr/bin/env bash

set -euo pipefail

# --- Utilities ---
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

# --- Optimizations ---
echo "Applying Low-Latency and Network Optimizations..."

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

if grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    modprobe sch_fq 2>/dev/null || true
    modprobe tcp_bbr 2>/dev/null || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
fi

sysctl -w vm.swappiness=10 >/dev/null
sysctl -w vm.vfs_cache_pressure=50 >/dev/null
sysctl -w vm.dirty_ratio=10 >/dev/null
sysctl -w vm.dirty_background_ratio=5 >/dev/null
sysctl -w vm.max_map_count=2147483642 >/dev/null

for gov_path in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -f "$gov_path" ]] && echo performance >"$gov_path" 2>/dev/null || true
done
[[ -f /sys/devices/system/cpu/cpufreq/boost ]] && echo 1 >/sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true

systemctl stop irqbalance 2>/dev/null || true
systemctl disable irqbalance 2>/dev/null || true

ulimit -n 1048576 2>/dev/null || true
ulimit -l unlimited 2>/dev/null || true

# TCP Tune CWND
CWND=1520
ip route show | while read -r route; do
    echo "$route" | grep -q "initcwnd" && continue
    ip route replace $route initcwnd $CWND initrwnd $CWND 2>/dev/null || true
done
ip route show | while read -r route; do
    echo "$route" | grep -q "quickack" && continue
    ip route replace $route quickack 1 2>/dev/null || true
done

log "Optimizations Applied Successfully."

# --- Dependency Installation ---
echo "Installing base dependencies (htop, curl, jq, netcat)..."
if [[ "$DETECTED_OS" == "debian" ]]; then
    apt-get update
    apt-get install -y htop curl jq netcat-traditional
elif [[ "$DETECTED_OS" == "arch" ]]; then
    pacman -Sy --noconfirm htop curl jq gnu-netcat
elif [[ "$DETECTED_OS" == "rhel" ]]; then
    dnf install -y htop curl jq nc
else
    warn "Unsupported OS. Please install htop, curl, jq, and netcat manually."
fi
log "Dependencies installed."

# --- Installer Prompt ---
echo ""
echo "=========================================================================="
echo "    System optimized and ready for Pterodactyl Wings installation!    "
echo "=========================================================================="
echo ""
echo "To proceed with the Pterodactyl installation, please copy and paste"
echo "the following command into your prompt (make sure you run 'sudo su' first):"
echo ""
echo "    bash <(curl -s https://pterodactyl-installer.se)"
echo ""
echo "=========================================================================="
