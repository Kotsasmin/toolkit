#!/usr/bin/env bash

set -euo pipefail

log() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err() { echo "[✗] $*"; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root. Please run with sudo."
    exit 1
fi

echo "System & Vulnerability Audit"

log "Checking Preload Rootkits & Kernel Protections..."
PRELOAD_FILE="/etc/ld.so.preload"
KPTR=$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null || echo "unknown")

if [ -s "$PRELOAD_FILE" ]; then
    err "LD_PRELOAD rootkit vector found in $PRELOAD_FILE:"
    cat $PRELOAD_FILE || true
else
    log "No LD_PRELOAD rootkits detected."
fi

if [ "$KPTR" = "0" ]; then
    warn "Kernel pointer restrict (kptr_restrict) is disabled (makes local kernel exploits easier)."
fi

log "Checking Host SUID Binaries (Privilege Escalation Vector)..."
SUID_FILES=$(find / -path "/var/lib/docker" -prune -o -path "/var/lib/containerd" -prune -o -perm -4000 -type f 2>/dev/null | grep -vE '/usr/bin/sudo|/usr/bin/passwd|/usr/bin/su|/usr/bin/newgrp|/usr/lib/snapd|/usr/lib/dbus|/usr/bin/chfn|/usr/bin/chsh|/usr/bin/mount|/usr/bin/gpasswd|/usr/bin/umount|/usr/bin/fusermount3|/usr/bin/ntfs-3g|/usr/lib/openssh/ssh-keysign' || true)

if [ -n "$SUID_FILES" ]; then
    warn "Non-standard host SUID root files found:"
    echo "$SUID_FILES"
else
    log "SUID permissions look normal on host."
fi

log "Auditing Cron Jobs & Autostart Persistence..."
CRON_MATCHES=""
for user in $(cut -f1 -d: /etc/passwd); do
    USER_CRON=$(crontab -u "$user" -l 2>/dev/null | grep -v '^#' || true)
    if [ -n "$USER_CRON" ]; then
        CRON_MATCHES="${CRON_MATCHES}\nUser $user: $USER_CRON"
    fi
done

MAL_PROFILE_HOOKS=$(grep -iE '(curl|wget).*(http|tcp|bash|sh)' /etc/profile /etc/profile.d/*.sh /etc/bash.bashrc ~/.bashrc 2>/dev/null | grep -vE 'cloud-init|debuginfod|gawk' || true)

if [ -n "$CRON_MATCHES" ]; then
    warn "User cron jobs active:"
    echo -e "$CRON_MATCHES"
fi

if [ -n "$MAL_PROFILE_HOOKS" ]; then
    err "Malicious auto-download commands in shell profiles:"
    echo "$MAL_PROFILE_HOOKS"
else
    log "Shell profile hooks are clean."
fi

log "Scanning for Pending Security Updates & Outdated Packages..."
if command -v apt-get &> /dev/null; then
    PENDING_SEC_UPDATES=$(apt-get -s upgrade 2>/dev/null | grep -iE 'security|ubuntu' | wc -l || true)
    if [ "$PENDING_SEC_UPDATES" -gt 15 ]; then
        warn "System has $PENDING_SEC_UPDATES pending software updates."
    else
        log "System packages are up to date."
    fi
else
    log "Non-apt system, skipping package updates check."
fi

log "System audit complete."
