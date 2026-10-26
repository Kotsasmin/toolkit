#!/usr/bin/env bash

set -uo pipefail

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
# Only local filesystems where SUID works. Network shares, FUSE and nosuid mounts are skipped,
# because SUID can't be used there and an unreachable share would hang the scan forever.
SUID_FS='^(ext[234]|xfs|btrfs|f2fs|zfs|bcachefs|jfs|reiserfs|tmpfs)$'
SUID_SKIP='^/(proc|sys|run/user|\.snapshots|var/lib/(docker|containerd|pterodactyl/volumes))(/|$)'
LOW_PRIO=(nice -n 19)
command -v ionice &>/dev/null && LOW_PRIO+=(ionice -c3)

if command -v findmnt &>/dev/null; then
    SUID_MOUNTS=$(findmnt -rn -o TARGET,FSTYPE,OPTIONS 2>/dev/null | awk -v fs="$SUID_FS" '$2 ~ fs && $3 !~ /(^|,)nosuid(,|$)/ {print $1}' | sort -u)
else
    SUID_MOUNTS=/
fi

SUID_ALL=""
while IFS= read -r mnt; do
    [[ -n $mnt ]] || continue
    mnt=$(printf '%b' "$mnt")
    [[ $mnt =~ $SUID_SKIP ]] && continue
    found=$(timeout 300 "${LOW_PRIO[@]}" find "$mnt" -xdev \( -path /var/lib/docker -o -path /var/lib/containerd -o -path /var/lib/pterodactyl/volumes -o -path /.snapshots \) -prune -o -perm -4000 -type f -print 2>/dev/null)
    [[ $? -eq 124 ]] && warn "SUID scan of $mnt took over 5 minutes and was stopped - results for it are partial."
    [[ -n $found ]] && SUID_ALL+="$found"$'\n'
done <<<"$SUID_MOUNTS"

# Files that belong to an installed package are expected; anything else is worth a look
pkg_owned() {
    if command -v pacman &>/dev/null; then
        pacman -Qoq "$1" &>/dev/null
    elif command -v dpkg &>/dev/null; then
        dpkg -S "$1" &>/dev/null || dpkg -S "${1#/usr}" &>/dev/null
    elif command -v rpm &>/dev/null; then
        rpm -qf "$1" &>/dev/null
    else
        [[ $1 =~ ^/usr/(bin/(sudo|passwd|su|newgrp|chfn|chsh|mount|umount|gpasswd|fusermount3?|ntfs-3g|pkexec)|lib/(snapd|dbus|openssh/ssh-keysign|polkit)) ]]
    fi
}

SUID_FILES=""
SUID_KNOWN=0
while IFS= read -r f; do
    [[ -n $f ]] || continue
    if pkg_owned "$f"; then
        SUID_KNOWN=$((SUID_KNOWN + 1))
    else
        SUID_FILES+="    $f"$'\n'
    fi
done < <(printf '%s' "$SUID_ALL" | sort -u)

if [ -n "$SUID_FILES" ]; then
    warn "SUID root files that don't belong to any installed package:"
    printf '%s' "$SUID_FILES"
else
    log "SUID permissions look normal on host ($SUID_KNOWN SUID files, all from installed packages)."
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
    # NoLocking: don't wait behind a running apt/unattended-upgrades
    UPDATES=$(timeout 120 apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null)
    RC=$?
    TOTAL=$(grep -c '^Inst ' <<<"$UPDATES")
    SECURITY=$(grep '^Inst ' <<<"$UPDATES" | grep -ci 'security')
    if [ "$RC" -eq 124 ]; then
        warn "Update check timed out."
    elif [ "$SECURITY" -gt 0 ]; then
        warn "System has $SECURITY pending security updates ($TOTAL updates in total)."
    elif [ "$TOTAL" -gt 0 ]; then
        log "$TOTAL updates pending, none marked as security updates."
    else
        log "System packages are up to date."
    fi
elif command -v checkupdates &> /dev/null; then
    UPDATES=$(timeout 120 checkupdates 2>/dev/null)
    if [ $? -eq 124 ]; then
        warn "Update check timed out."
    elif [ -n "$UPDATES" ]; then
        warn "System has $(wc -l <<<"$UPDATES") pending package updates (Arch doesn't mark security updates - update regularly)."
    else
        log "System packages are up to date."
    fi
elif command -v dnf &> /dev/null; then
    SECURITY=$(timeout 120 dnf -q updateinfo list --security 2>/dev/null | grep -c .)
    if [ "$SECURITY" -gt 0 ]; then
        warn "System has $SECURITY pending security updates."
    else
        log "No pending security updates."
    fi
else
    log "No supported package manager found, skipping package updates check."
fi

log "System audit complete."
