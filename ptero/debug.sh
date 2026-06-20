#!/usr/bin/env bash

set -euo pipefail

log() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err() { echo "[✗] $*"; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root. Please run with sudo."
    exit 1
fi

echo "=========================================="
echo "   Pterodactyl Wings Debugger"
echo "=========================================="

if systemctl is-active --quiet wings; then
    log "Wings is currently running. Stopping it for log collection..."
    systemctl stop wings
    sleep 2
else
    warn "Wings is not currently active."
fi

log "Extracting the latest 100 lines of Wings logs..."
LOG_FILE="/tmp/wings_debug_$(date +%s).log"
journalctl -u wings -n 100 --no-pager > "$LOG_FILE"

echo ""
echo "--- Last 15 Lines of Log ---"
tail -n 15 "$LOG_FILE"
echo "----------------------------"
echo ""

log "Scanning for known errors..."

ERROR_FOUND=false

if grep -qi "bind: address already in use" "$LOG_FILE"; then
    err "Port Binding Error Detected"
    echo "  Possible Reasons:"
    echo "  - Another service (like an existing web server or old wings instance) is using port 8080 or 2022."
    echo "  - Try running: netstat -tulpn | grep -E '8080|2022' to see what is using the port."
    ERROR_FOUND=true
fi

if grep -qi "Cannot connect to the Docker daemon" "$LOG_FILE" || grep -qi "docker: Cannot connect" "$LOG_FILE"; then
    err "Docker Daemon Error Detected"
    echo "  Possible Reasons:"
    echo "  - Docker is not installed or not running."
    echo "  - Run 'systemctl status docker' to check if Docker is active."
    echo "  - Ensure your user has permissions to access the docker socket."
    ERROR_FOUND=true
fi

if grep -qi "Invalid token" "$LOG_FILE" || grep -qi "Failed to connect to panel" "$LOG_FILE" || grep -qi "connection refused" "$LOG_FILE"; then
    err "Panel Connection Error Detected"
    echo "  Possible Reasons:"
    echo "  - The API token in /etc/pterodactyl/config.yml is invalid."
    echo "  - The Panel URL is incorrect or unreachable from this node."
    echo "  - The Panel has an SSL issue or the node is blocked by a firewall."
    ERROR_FOUND=true
fi

if grep -qi "failed to parse configuration" "$LOG_FILE"; then
    err "Configuration Parse Error Detected"
    echo "  Possible Reasons:"
    echo "  - The /etc/pterodactyl/config.yml file has invalid YAML formatting."
    echo "  - A required field is missing from the configuration."
    ERROR_FOUND=true
fi

if [ "$ERROR_FOUND" = false ]; then
    log "No commonly known errors were immediately detected in the recent logs."
fi

echo ""
log "Uploading complete log for external review..."
if command -v nc >/dev/null 2>&1; then
    PASTE_URL=$(cat "$LOG_FILE" | nc termbin.com 9999)
    echo "=========================================="
    echo "  Log uploaded successfully!"
    echo "  Share this URL for help: $PASTE_URL"
    echo "=========================================="
else
    warn "netcat (nc) is not installed. Could not upload log."
    echo "You can review the log file locally at: $LOG_FILE"
fi

rm -f "$LOG_FILE"
