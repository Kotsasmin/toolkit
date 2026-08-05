#!/usr/bin/env bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SUSPICION_SCORE=0
CRITICAL_COUNT=0
WARNING_COUNT=0

log_check() {
    echo -e "\n${BLUE}[+] $1...${NC}"
}

flag_critical() {
    echo -e "${RED}[CRITICAL] $1${NC}"
    ((SUSPICION_SCORE+=5))
    ((CRITICAL_COUNT++))
}

flag_warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
    ((SUSPICION_SCORE+=1))
    ((WARNING_COUNT++))
}

log_pass() {
    echo -e "${GREEN}[OK] $1${NC}"
}

echo -e "${YELLOW}----------------------------------------------------${NC}"
echo -e "${YELLOW}       ADVANCED SYSTEM & VULNERABILITY AUDIT        ${NC}"
echo -e "${YELLOW}----------------------------------------------------${NC}"

# 1. PROCESS AUDIT & AUTOMATED MINER TERMINATION
log_check "Scanning & Terminating All Cryptominers (Host & Memory)"

# Detect PIDs executing from /tmp, /var/tmp, /dev/shm, or deleted paths
SUSPECT_PIDS=$(ls -l /proc/*/exe 2>/dev/null | grep -E '/tmp/|/var/tmp/|/dev/shm/|\(deleted\)' | awk '{print $9}' | cut -d'/' -f3 | grep -E '^[0-9]+$')

# Detect high CPU processes (>60%)
HIGH_CPU_PIDS=$(ps aux --sort=-%cpu | awk 'NR>1 && $3>60.0 {print $2}')

# Combine all matched PIDs and exclude the script's own PID
ALL_TARGET_PIDS=$(echo -e "${SUSPECT_PIDS}\n${HIGH_CPU_PIDS}" | sort -u | grep -v "^$$")

if [ -n "$ALL_TARGET_PIDS" ]; then
    flag_critical "Suspicious high-CPU or fileless processes detected! Auto-terminating PIDs:"
    for pid in $ALL_TARGET_PIDS; do
        PROC_NAME=$(ps -p "$pid" -o comm= 2>/dev/null)
        if [ -n "$PROC_NAME" ] && [ "$PROC_NAME" != "dockerd" ] && [ "$PROC_NAME" != "containerd" ]; then
            echo -e "${RED}[KILLING PID $pid] -> $PROC_NAME${NC}"
            kill -9 "$pid" 2>/dev/null
        fi
    done
else
    log_pass "No running fileless or runaway CPU processes found on host."
fi

# 2. FILELESS MEMORY & DELETED WORKING DIRECTORIES
log_check "Scanning Memory for Fileless Binaries & Unlinked CWDs"
DELETED_PROCS=$(ls -l /proc/*/exe 2>/dev/null | grep "(deleted)" | grep -vE 'containerd|dockerd|snapd|python|php|node')
DELETED_CWD=$(ls -l /proc/*/cwd 2>/dev/null | grep "(deleted)" | grep -vE 'containerd|dockerd|snapd')

if [ -n "$DELETED_PROCS" ]; then
    flag_critical "Fileless memory binaries detected (running process deleted from disk):\n$DELETED_PROCS"
elif [ -n "$DELETED_CWD" ]; then
    flag_warning "Processes running with deleted working directories:\n$DELETED_CWD"
else
    log_pass "No suspicious fileless memory binaries detected."
fi

# 3. ROOTKIT INJECTION & PRELOAD AUDIT
log_check "Checking Preload Rootkits & Kernel Protections"
PRELOAD_FILE="/etc/ld.so.preload"
KPTR=$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null)

if [ -s "$PRELOAD_FILE" ]; then
    flag_critical "LD_PRELOAD rootkit vector found in $PRELOAD_FILE:\n$(cat $PRELOAD_FILE)"
else
    log_pass "No LD_PRELOAD rootkits detected."
fi

if [ "$KPTR" -eq 0 ]; then
    flag_warning "Kernel pointer restrict (kptr_restrict) is disabled (makes local kernel exploits easier)."
fi

# 4. TEMPORARY DIRECTORY AUDIT
log_check "Scanning Temp Directories (/tmp, /var/tmp, /dev/shm)"
HIDDEN_TEMP=$(find /tmp /var/tmp /dev/shm -maxdepth 3 \( -name ".*" -o -type f -perm /111 \) 2>/dev/null | grep -vE '/tmp/\.X11-unix|/tmp/\.ICE-unix|/tmp/\.font-unix|/tmp/\.XIM-unix|snap-private-tmp|systemd-private')

if [ -n "$HIDDEN_TEMP" ]; then
    flag_warning "Executable or hidden files found in temp directories:\n$HIDDEN_TEMP"
else
    log_pass "Temporary directories are clean."
fi

# 5. SUID PERMISSION AUDIT (EXCLUDES DOCKER OVERLAYFS)
log_check "Checking Host SUID Binaries (Privilege Escalation Vector)"
SUID_FILES=$(find / -path "/var/lib/docker" -prune -o -path "/var/lib/containerd" -prune -o -perm -4000 -type f 2>/dev/null | grep -vE '/usr/bin/sudo|/usr/bin/passwd|/usr/bin/su|/usr/bin/newgrp|/usr/lib/snapd|/usr/lib/dbus|/usr/bin/chfn|/usr/bin/chsh|/usr/bin/mount|/usr/bin/gpasswd|/usr/bin/umount|/usr/bin/fusermount3|/usr/bin/ntfs-3g|/usr/lib/openssh/ssh-keysign')

if [ -n "$SUID_FILES" ]; then
    flag_warning "Non-standard host SUID root files found:\n$SUID_FILES"
else
    log_pass "SUID permissions look normal on host."
fi

# 6. CRON, AUTOSTART, & SHELL PROFILE HOOKS
log_check "Auditing Cron Jobs & Autostart Persistence"
CRON_MATCHES=""
for user in $(cut -f1 -d: /etc/passwd); do
    USER_CRON=$(crontab -u "$user" -l 2>/dev/null | grep -v '^#')
    if [ -n "$USER_CRON" ]; then
        CRON_MATCHES="${CRON_MATCHES}\nUser $user: $USER_CRON"
    fi
done

MAL_PROFILE_HOOKS=$(grep -iE '(curl|wget).*(http|tcp|bash|sh)' /etc/profile /etc/profile.d/*.sh /etc/bash.bashrc ~/.bashrc 2>/dev/null | grep -vE 'cloud-init|debuginfod|gawk')

if [ -n "$CRON_MATCHES" ]; then
    flag_warning "User cron jobs active:\n$CRON_MATCHES"
fi

if [ -n "$MAL_PROFILE_HOOKS" ]; then
    flag_critical "Malicious auto-download commands in shell profiles:\n$MAL_PROFILE_HOOKS"
else
    log_pass "Shell profile hooks are clean."
fi

# 7. VULNERABLE & OUTDATED PACKAGES AUDIT
log_check "Scanning for Pending Security Updates & Outdated Packages"
PENDING_SEC_UPDATES=$(apt-get -s upgrade 2>/dev/null | grep -iE 'security|ubuntu' | wc -l)

if [ "$PENDING_SEC_UPDATES" -gt 15 ]; then
    flag_warning "System has $PENDING_SEC_UPDATES pending software updates."
else
    log_pass "System packages are up to date."
fi

# 8. NETWORK PROMISCUOUS MODE & LISTENING PORTS
log_check "Auditing Network Interfaces & Open Listening Ports"
PROMISC_IF=$(ip link | grep -i PROMISC)
UNUSUAL_PORTS=$(ss -tulpn | grep LISTEN | grep -vE ':22|:80|:443|:8080|:8000|:6001|:6002|:53|:51820|:38129|:39861|127.0.0.1|\[::1\]')

if [ -n "$PROMISC_IF" ]; then
    flag_critical "Network interface in PROMISCUOUS mode (potential packet sniffer active):\n$PROMISC_IF"
fi

if [ -n "$UNUSUAL_PORTS" ]; then
    flag_warning "Non-standard external open ports:\n$UNUSUAL_PORTS"
else
    log_pass "Network listeners look standard."
fi

# 9. SSH AUDIT & FIREWALL AUDIT
log_check "Checking SSH Configuration & UFW Firewall Status"
UID_ZERO_USERS=$(cut -d: -f1,3 /etc/passwd | awk -F: '$2==0 {print $1}')
PASS_AUTH=$(grep -iE '^PasswordAuthentication yes' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null)
UFW_ACTIVE=$(ufw status 2>/dev/null | grep "Status: active")

if [ "$UID_ZERO_USERS" != "root" ]; then
    flag_critical "Extra root accounts with UID 0 found: $UID_ZERO_USERS"
fi

if [ -n "$PASS_AUTH" ]; then
    flag_warning "SSH Password Authentication is ENABLED."
else
    log_pass "SSH Password Authentication is disabled."
fi

if [ -z "$UFW_ACTIVE" ]; then
    flag_warning "UFW Firewall is currently DISABLED."
else
    log_pass "UFW Firewall is active."
fi

# 10. DOCKER ENVIRONMENT AUDIT & CONTAINER PURGE
if command -v docker &> /dev/null; then
    log_check "Auditing & Cleaning Running Docker Containers"
    
    INFECTED_CONTAINERS=""
    for id in $(docker ps -q); do
        if docker exec "$id" ps aux 2>/dev/null | grep -iE 'SqGY|xmrig|miner|/tmp/' | grep -v grep > /dev/null; then
            INFECTED_CONTAINERS="${INFECTED_CONTAINERS} $id"
        fi
    done

    if [ -n "$INFECTED_CONTAINERS" ]; then
        flag_critical "Malware execution detected inside Docker containers! Auto-stopping containers:"
        for container_id in $INFECTED_CONTAINERS; do
            C_NAME=$(docker inspect --format='{{.Name}}' "$container_id" 2>/dev/null | tr -d '/')
            echo -e "${RED}[STOPPING INFECTED CONTAINER] $C_NAME ($container_id)${NC}"
            docker stop "$container_id" >/dev/null
            docker rm -f "$container_id" >/dev/null
        done
    else
        log_pass "Docker containers appear clean."
    fi
fi

# FINAL VERDICT
echo -e "\n----------------------------------------------------"
echo -e "                  FINAL VERDICT                     "
echo -e "----------------------------------------------------"

if [ $CRITICAL_COUNT -gt 0 ]; then
    echo -e "${RED}[ALERT] Critical threats detected! ($CRITICAL_COUNT Critical, $WARNING_COUNT Warnings)${NC}"
    echo -e "Active malware or unlinked process execution detected. Automatic remediation actions were taken."
elif [ $WARNING_COUNT -gt 0 ]; then
    echo -e "${YELLOW}[SECURE WITH WARNINGS] No active malware found ($WARNING_COUNT minor warning(s)).${NC}"
    echo -e "System is clean, but check minor warnings above (e.g., UFW status, SSH settings)."
else
    echo -e "${GREEN}[CLEAN & HARDENED] System is completely clean! (0 Flags)${NC}"
    echo -e "No active threats, vulnerability exposures, or rogue configurations found."
fi

echo -e "----------------------------------------------------"
