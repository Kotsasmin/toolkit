#!/usr/bin/env bash

# Ensure the script is executed with root or sudo privileges
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run with sudo or as root."
    exit 1
fi

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

echo -e "${YELLOW}ADVANCED SYSTEM & VULNERABILITY AUDIT${NC}"

# 1. PROCESS & HIGH CPU AUDIT
log_check "Scanning Active Processes & CPU Usage"
HIGH_CPU=$(ps aux --sort=-%cpu | grep -v "ps aux" | awk 'NR>1 && $3>70.0 {print $0}')
MALWARE_PROC=$(ps aux | grep -iE 'XXEaDObP|XXcdCoCE|cpu-logind|mone|xmrig|miner|stratum|minerd' | grep -v grep)

if [ -n "$MALWARE_PROC" ]; then
    flag_critical "Known malware processes detected:\n$MALWARE_PROC"
elif [ -n "$HIGH_CPU" ]; then
    flag_warning "High CPU process (>70%) detected:\n$HIGH_CPU"
else
    log_pass "No malware or runaway CPU processes found."
fi

# 2. FILELESS MEMORY & DELETED WORKING DIRECTORIES
log_check "Scanning Memory for Fileless Binaries & Unlinked CWDs"
DELETED_PROCS=$(ls -l /proc/*/exe 2>/dev/null | grep "(deleted)" | grep -vE 'containerd|dockerd|snapd|python|php|node')
DELETED_CWD=$(ls -l /proc/*/cwd 2>/dev/null | grep "(deleted)" | grep -vE 'containerd|dockerd|snapd')

if [ -n "$DELETED_PROCS" ]; then
    flag_critical "Fileless memory binaries detected:\n$DELETED_PROCS"
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
    flag_warning "Kernel pointer restrict is disabled."
fi

# 4. TEMPORARY DIRECTORY AUDIT
log_check "Scanning Temp Directories (/tmp, /var/tmp, /dev/shm)"
HIDDEN_TEMP=$(find /tmp /var/tmp /dev/shm -maxdepth 3 \( -name ".*" -o -type f -perm /111 \) 2>/dev/null | grep -vE '/tmp/\.X11-unix|/tmp/\.ICE-unix|systemd-private')

if [ -n "$HIDDEN_TEMP" ]; then
    flag_warning "Executable or hidden files found in temp directories:\n$HIDDEN_TEMP"
else
    log_pass "Temporary directories are clean."
fi

# 5. SUID PERMISSION AUDIT (OPTIMIZED FAST SEARCH)
log_check "Checking Host SUID Binaries"
SUID_FILES=$(find / -path "/proc" -prune -o -path "/sys" -prune -o -path "/dev" -prune -o -path "/var/lib/docker*" -prune -o -path "/var/lib/containerd*" -prune -o -perm -4000 -type f 2>/dev/null | grep -vE '/usr/bin/sudo|/usr/bin/passwd|/usr/bin/su|/usr/bin/newgrp|/usr/bin/chfn|/usr/bin/chsh|/usr/bin/mount|/usr/bin/gpasswd|/usr/bin/umount|/usr/bin/pkexec|/usr/lib/polkit-1/polkit-agent-helper-1|/usr/lib/cargo/bin/su|/usr/lib/cargo/bin/sudo')

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

# 7. PACKAGE MANAGER UPDATES AUDIT (MULTI-DISTRO DETECT)
log_check "Scanning Package Manager Pending Updates"
if command -v apt-get &> /dev/null; then
    PENDING_UPDATES=$(apt-get -s upgrade 2>/dev/null | grep -iE 'security|ubuntu|debian' | wc -l)
elif command -v checkupdates &> /dev/null; then
    PENDING_UPDATES=$(checkupdates 2>/dev/null | wc -l)
elif command -v dnf &> /dev/null; then
    PENDING_UPDATES=$(dnf check-update --quiet 2>/dev/null | wc -l)
else
    PENDING_UPDATES=0
fi

if [ "$PENDING_UPDATES" -gt 25 ]; then
    flag_warning "System has $PENDING_UPDATES pending package updates."
else
    log_pass "System packages are reasonably up to date."
fi

# 8. NETWORK PROMISCUOUS MODE & LISTENING PORTS
log_check "Auditing Network Interfaces & Open Listening Ports"
PROMISC_IF=$(ip link | grep -i PROMISC)
UNUSUAL_PORTS=$(ss -tulpn | grep LISTEN | grep -vE ':22|:80|:443|:8080|:8000|127.0.0.1|\[::1\]')

if [ -n "$PROMISC_IF" ]; then
    flag_critical "Network interface in PROMISCUOUS mode:\n$PROMISC_IF"
fi

if [ -n "$UNUSUAL_PORTS" ]; then
    flag_warning "Non-standard external open ports:\n$UNUSUAL_PORTS"
else
    log_pass "Network listeners look standard."
fi

# 9. SSH & SYSTEM FIREWALL AUDIT
log_check "Checking SSH Configuration & Firewall Status"
UID_ZERO_USERS=$(cut -d: -f1,3 /etc/passwd | awk -F: '$2==0 {print $1}')
PASS_AUTH=$(grep -iE '^PasswordAuthentication yes' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null)

if [ "$UID_ZERO_USERS" != "root" ]; then
    flag_critical "Extra root accounts with UID 0 found: $UID_ZERO_USERS"
fi

if [ -n "$PASS_AUTH" ]; then
    flag_warning "SSH Password Authentication is ENABLED."
else
    log_pass "SSH Password Authentication is disabled."
fi

FIREWALL_ON=$(systemctl is-active iptables nftables ufw firewalld 2>/dev/null | grep active)
if [ -z "$FIREWALL_ON" ]; then
    flag_warning "No active firewall service detected (iptables, nftables, ufw, or firewalld)."
else
    log_pass "Active firewall service running."
fi

# 10. DOCKER ENVIRONMENT AUDIT
if command -v docker &> /dev/null; then
    log_check "Auditing Running Docker Containers"
    DOCKER_MINERS=$(docker ps -q | xargs -I {} docker exec {} ps aux 2>/dev/null | grep -iE 'XXEaDObP|XXcdCoCE|cpu-logind|mone|xmrig|miner' | grep -v grep)
    
    if [ -n "$DOCKER_MINERS" ]; then
        flag_critical "Malware execution detected inside Docker containers:\n$DOCKER_MINERS"
    else
        log_pass "Docker containers appear clean."
    fi
fi

# FINAL VERDICT
echo ""
echo -e "${YELLOW}FINAL VERDICT${NC}"

if [ $CRITICAL_COUNT -gt 0 ]; then
    echo -e "${RED}[ALERT] Critical threats detected! ($CRITICAL_COUNT Critical, $WARNING_COUNT Warnings)${NC}"
    echo -e "Active malware, rootkits, or malicious persistent hooks found."
elif [ $WARNING_COUNT -gt 0 ]; then
    echo -e "${YELLOW}[SECURE WITH WARNINGS] No active malware found ($WARNING_COUNT minor warning(s)).${NC}"
    echo -e "System is clean, but check minor warnings above."
else
    echo -e "${GREEN}[CLEAN & HARDENED] System is completely clean! (0 Flags)${NC}"
    echo -e "No active threats, vulnerability exposures, or rogue configurations found."
fi
echo ""
