#!/usr/bin/env bash

set -euo pipefail

log() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err() { echo "[✗] $*"; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root. Please run with sudo."
    exit 1
fi

echo "ADVANCED SYSTEM & VULNERABILITY AUDIT"
echo ""

log "Scanning & Terminating Cryptominers (Host & Memory)..."
SUSPECT_PIDS=$(ls -l /proc/*/exe 2>/dev/null | grep -E '/tmp/|/var/tmp/|/dev/shm/|\(deleted\)' | awk '{print $9}' | cut -d'/' -f3 | grep -E '^[0-9]+$' || true)
HIGH_CPU_PIDS=$(ps aux --sort=-%cpu | awk 'NR>1 && $3>60.0 {print $2}' || true)
ALL_TARGET_PIDS=$(echo -e "${SUSPECT_PIDS}\n${HIGH_CPU_PIDS}" | sort -u | grep -v "^$$" || true)

if [ -n "$ALL_TARGET_PIDS" ]; then
    warn "Suspicious high-CPU or fileless processes detected! Auto-terminating PIDs:"
    for pid in $ALL_TARGET_PIDS; do
        PROC_NAME=$(ps -p "$pid" -o comm= 2>/dev/null || true)
        if [ -n "$PROC_NAME" ] && [ "$PROC_NAME" != "dockerd" ] && [ "$PROC_NAME" != "containerd" ]; then
            err "[KILLING PID $pid] -> $PROC_NAME"
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
else
    log "No running fileless or runaway CPU processes found on host."
fi

log "Scanning Memory for Fileless Binaries & Unlinked CWDs..."
DELETED_PROCS=$(ls -l /proc/*/exe 2>/dev/null | grep "(deleted)" | grep -vE 'containerd|dockerd|snapd|python|php|node' || true)
DELETED_CWD=$(ls -l /proc/*/cwd 2>/dev/null | grep "(deleted)" | grep -vE 'containerd|dockerd|snapd' || true)

if [ -n "$DELETED_PROCS" ]; then
    err "Fileless memory binaries detected (running process deleted from disk):"
    echo "$DELETED_PROCS"
elif [ -n "$DELETED_CWD" ]; then
    warn "Processes running with deleted working directories:"
    echo "$DELETED_CWD"
else
    log "No suspicious fileless memory binaries detected."
fi

log "Scanning Temp Directories (/tmp, /var/tmp, /dev/shm)..."
HIDDEN_TEMP=$(find /tmp /var/tmp /dev/shm -maxdepth 3 \( -name ".*" -o -type f -perm /111 \) 2>/dev/null | grep -vE '/tmp/\.X11-unix|/tmp/\.ICE-unix|/tmp/\.font-unix|/tmp/\.XIM-unix|snap-private-tmp|systemd-private' || true)

if [ -n "$HIDDEN_TEMP" ]; then
    warn "Executable or hidden files found in temp directories:"
    echo "$HIDDEN_TEMP"
else
    log "Temporary directories are clean."
fi

if command -v docker &> /dev/null; then
    log "Auditing & Cleaning Running Docker Containers..."
    
    INFECTED_CONTAINERS=""
    for id in $(docker ps -q); do
        if docker exec "$id" ps aux 2>/dev/null | grep -iE 'SqGY|xmrig|miner|/tmp/' | grep -v grep > /dev/null; then
            INFECTED_CONTAINERS="${INFECTED_CONTAINERS} $id"
        fi
    done

    if [ -n "$INFECTED_CONTAINERS" ]; then
        err "Malware execution detected inside Docker containers! Auto-stopping containers:"
        for container_id in $INFECTED_CONTAINERS; do
            C_NAME=$(docker inspect --format='{{.Name}}' "$container_id" 2>/dev/null | tr -d '/')
            err "[STOPPING INFECTED CONTAINER] $C_NAME ($container_id)"
            docker stop "$container_id" >/dev/null
            docker rm -f "$container_id" >/dev/null
        done
    else
        log "Docker containers appear clean."
    fi
fi

echo ""
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

echo ""
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

echo ""
echo "AUDIT COMPLETE"
