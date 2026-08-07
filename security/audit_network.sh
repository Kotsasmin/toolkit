#!/usr/bin/env bash

set -euo pipefail

log() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err() { echo "[✗] $*"; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root. Please run with sudo."
    exit 1
fi

echo "Network & Access Audit"

log "Auditing Network Interfaces & Open Listening Ports..."
PROMISC_IF=$(ip link | grep -i PROMISC || true)
UNUSUAL_PORTS=$(ss -tulpn | grep LISTEN | grep -vE ':22|:80|:443|:8080|:8000|:6001|:6002|:53|:51820|:38129|:39861|127.0.0.1|\[::1\]' || true)

if [ -n "$PROMISC_IF" ]; then
    err "Network interface in PROMISCUOUS mode (potential packet sniffer active):"
    echo "$PROMISC_IF"
fi

if [ -n "$UNUSUAL_PORTS" ]; then
    warn "Non-standard external open ports:"
    echo "$UNUSUAL_PORTS"
else
    log "Network listeners look standard."
fi

log "Checking SSH Configuration & UFW Firewall Status..."
UID_ZERO_USERS=$(cut -d: -f1,3 /etc/passwd | awk -F: '$2==0 {print $1}' || true)
PASS_AUTH=$(grep -iE '^PasswordAuthentication yes' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true)

if command -v ufw &> /dev/null; then
    UFW_ACTIVE=$(ufw status 2>/dev/null | grep "Status: active" || true)
else
    UFW_ACTIVE=""
fi

if [ "$UID_ZERO_USERS" != "root" ]; then
    err "Extra root accounts with UID 0 found: $UID_ZERO_USERS"
fi

if [ -n "$PASS_AUTH" ]; then
    warn "SSH Password Authentication is ENABLED."
else
    log "SSH Password Authentication is disabled."
fi

if command -v ufw &> /dev/null; then
    if [ -z "$UFW_ACTIVE" ]; then
        warn "UFW Firewall is currently DISABLED."
    else
        log "UFW Firewall is active."
    fi
else
    log "ufw not installed on this system."
fi

log "Network audit complete."
