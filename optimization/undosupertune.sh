#!/usr/bin/env bash

set -euo pipefail

log() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err() { echo "[✗] $*"; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root. Please run with sudo."
    exit 1
fi

echo "Reverting Low-Latency Optimizations (supertune.sh)..."

log "Removing kernel module configurations..."
rm -f /etc/modules-load.d/99-supertune.conf

log "Removing sysctl configurations..."
rm -f /etc/sysctl.d/99-supertune.conf

log "Removing CPU governor udev rules..."
rm -f /etc/udev/rules.d/99-cpu-governor.rules

log "Re-enabling IRQBalance..."
systemctl enable --now irqbalance 2>/dev/null || true

log "Removing ulimits..."
rm -f /etc/security/limits.d/99-performance.conf

log "Removing TCP route tuning scripts and hooks..."
rm -f /usr/local/bin/supertune-routes.sh
rm -f /etc/NetworkManager/dispatcher.d/99-supertune-routes
rm -f /etc/network/if-up.d/99-supertune-routes
rm -f /etc/cron.d/99-supertune-routes

log "Optimizations removed!"
warn "Please REBOOT your system to fully revert CPU states, active sysctl network buffers, and BBR settings to Linux defaults."
