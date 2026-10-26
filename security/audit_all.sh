#!/usr/bin/env bash
# Runs every audit in this folder. Options (like --kill for the malware audit) are passed on.

set -uo pipefail

log() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err() { echo "[✗] $*"; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root. Please run with sudo."
    exit 1
fi

DIR=$(dirname "$(readlink -f "$0")")

echo "ADVANCED SYSTEM & VULNERABILITY AUDIT"

for script in audit_malware.sh npm_vulnerability_audit.sh audit_system.sh audit_network.sh; do
    echo ""
    if [[ -f $DIR/$script ]]; then
        bash "$DIR/$script" "$@"
    else
        err "$script is missing next to audit_all.sh - skipped."
    fi
done

echo ""
echo "AUDIT COMPLETE"
