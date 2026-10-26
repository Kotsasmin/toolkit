#!/usr/bin/env bash
#
# supertune - adaptive low-latency tuning for desktops, laptops, servers, VMs and containers.
#
# It detects what kind of machine it runs on and only applies tuning that helps there.
# Original values are saved before anything changes, so --undo puts them back.
# Settings you already made in your own /etc/sysctl.d files are never overridden.

VERSION="2.0.0"

log() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err() { echo "[✗] $*"; }

usage() {
    cat <<'EOF'
Usage: supertune.sh [options]

  (no options)        apply everything that fits this machine
  --dry-run, -n       show what would change without changing anything (no root needed)
  --status, -s        show the detected profile and the current tuning state
  --undo, -r          restore the saved original values and remove supertune's files
  --profile NAME      force a profile: desktop, laptop, server, vm, hypervisor, container
  --only LIST         run only these modules (comma separated)
  --skip LIST         run every module except these

Modules: memory disk cpu irq network limits system
EOF
}

CONF_DIR=/etc/supertune
STATE_DIR=/var/lib/supertune
STATE_FILE=$STATE_DIR/original.state
NET_HOOK=$CONF_DIR/net-hook
ZRAM_HELPER=$CONF_DIR/zram-setup
ALL_MODULES="memory disk cpu irq network limits system"
PROFILES="desktop laptop server vm hypervisor container"

# Files written by older supertune/tcptune versions. They are removed on every run because
# some of them hurt: a 1520-packet initcwnd, realtime priority for every user, bfq on VM disks.
LEGACY_FILES=(
    /etc/sysctl.d/99-supertune.conf
    /etc/sysctl.d/99-tcptune.conf
    /etc/modules-load.d/99-supertune.conf
    /etc/modules-load.d/99-tcptune.conf
    /etc/udev/rules.d/60-supertune-ioschedulers.rules
    /etc/udev/rules.d/99-cpu-governor.rules
    /etc/security/limits.d/99-performance.conf
    /etc/tmpfiles.d/99-supertune-mglru.conf
    /etc/tmpfiles.d/99-supertune-thp.conf
    /usr/local/bin/supertune-routes.sh
    /usr/local/bin/tcptune-routes.sh
    /etc/NetworkManager/dispatcher.d/99-supertune-routes
    /etc/NetworkManager/dispatcher.d/99-tcptune-routes
    /etc/network/if-up.d/99-supertune-routes
    /etc/network/if-up.d/99-tcptune-routes
    /etc/cron.d/99-supertune-routes
    /etc/cron.d/99-tcptune-routes
)
RAMTUNE_FILES=(
    /etc/sysctl.d/99-ramtune.conf
    /etc/tmpfiles.d/99-mglru.conf
    /usr/local/bin/ramtune-init.sh
    /usr/local/bin/ramtune-stop.sh
)

MODE=apply
DRY_RUN=0
FORCED_PROFILE=""
ONLY=""
SKIP=""

CHANGES=0
SKIPPED=()
PROBLEMS=()
NOTES=()
CHANGED=0
WROTE=0
SYSCTL_BUF=""
declare -A ADMIN_SYSCTL

section() {
    echo
    log "$*"
}
did() {
    CHANGES=$((CHANGES + 1))
    if ((DRY_RUN)); then echo "    would: $*"; else echo "    $*"; fi
}
info() { echo "    - $*"; }
skip() { SKIPPED+=("$*"); }
problem() {
    PROBLEMS+=("$*")
    warn "$*"
}
note() { NOTES+=("$*"); }

###############################################################################
# Low-level helpers
###############################################################################

has_systemd() { [[ -d /run/systemd/system ]]; }
unit_exists() { has_systemd && [[ -n $(systemctl list-unit-files --no-legend "$1" 2>/dev/null) ]]; }
units_reload() { ((DRY_RUN)) || systemctl daemon-reload >/dev/null 2>&1; }

kernel_ge() {
    local v=${KVER%%-*} major minor
    major=${v%%.*}
    minor=${v#*.}
    minor=${minor%%.*}
    ((major > $1 || (major == $1 && minor >= $2)))
}

module_ready() {
    [[ -d /sys/module/${1//-/_} ]] || grep -q "/$1.ko" "/lib/modules/$KVER/modules.builtin" 2>/dev/null
}
load_module() {
    module_ready "$1" && return 0
    if ((DRY_RUN)); then
        modprobe -nq "$1" 2>/dev/null
        return
    fi
    modprobe -q "$1" 2>/dev/null
}

# Remembers the value a knob had before supertune first touched it (later runs keep the first one).
state_save() {
    ((DRY_RUN)) && return 0
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    grep -qF -- "$1|$2|" "$STATE_FILE" 2>/dev/null && return 0
    printf '%s|%s|%s\n' "$1" "$2" "$3" >>"$STATE_FILE"
}

# Current value of a sysfs file; for "a [b] c" style files, the selected entry.
read_sel() {
    local v
    v=$(cat "$1" 2>/dev/null) || return 1
    if [[ $v == *\[*\]* ]]; then
        v=${v#*\[}
        v=${v%%\]*}
    fi
    printf '%s' "$v"
}

# set_sysfs PATH VALUE [LABEL] - without a label the change is silent. Sets CHANGED=1 on a change.
set_sysfs() {
    local path=$1 val=$2 label=${3:-} cur
    CHANGED=0
    [[ -e $path ]] || return 2
    cur=$(read_sel "$path") || return 2
    [[ $cur == "$val" ]] && return 0
    if ((DRY_RUN)); then
        CHANGED=1
        [[ -n $label ]] && did "$label: $cur -> $val"
        return 0
    fi
    state_save sysfs "$path" "$cur"
    if echo "$val" >"$path" 2>/dev/null; then
        CHANGED=1
        [[ -n $label ]] && did "$label: $cur -> $val"
        return 0
    fi
    [[ -n $label ]] && skip "$label: the kernel refused '$val'"
    return 1
}

# Reads every sysctl key that the admin (or another tool) set in /etc or /run, so we never fight it.
load_admin_sysctls() {
    local f line key
    for f in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf; do
        [[ -f $f ]] || continue
        case ${f##*/} in 99-supertune*.conf | 99-tcptune.conf | 99-ramtune.conf) continue ;; esac
        while IFS= read -r line; do
            line=${line%%#*}
            [[ $line == *=* ]] || continue
            key=${line%%=*}
            key=${key//[[:space:]]/}
            key=${key#-}
            key=${key//\//.}
            [[ -n $key ]] && ADMIN_SYSCTL[$key]=$f
        done <"$f"
    done
}

# set_sysctl KEY VALUE [raise|lower]
#   raise/lower only move a number in that direction, so bigger distro defaults are never lowered.
#   The value is written live and collected for the module's /etc/sysctl.d file.
set_sysctl() {
    local key=$1 val=$2 mode=${3:-} path cur want
    path=/proc/sys/${key//.//}
    if [[ -n ${ADMIN_SYSCTL[$key]:-} ]]; then
        skip "$key: kept your setting from ${ADMIN_SYSCTL[$key]}"
        return 1
    fi
    if [[ ! -e $path ]]; then
        skip "$key: not available on this kernel"
        return 1
    fi
    cur=$(tr -s ' \t' ' ' <"$path" 2>/dev/null)
    cur=${cur% }
    want=$(tr -s ' \t' ' ' <<<"$val")
    if [[ -n $mode && $cur =~ ^[0-9]+$ ]]; then
        [[ $mode == raise ]] && ((cur > want)) && return 0
        [[ $mode == lower ]] && ((cur < want)) && return 0
    fi
    if [[ $cur != "$want" ]]; then
        if ((DRY_RUN)); then
            did "$key: $cur -> $want"
        else
            state_save sysctl "$key" "$cur"
            if ! echo "$want" >"$path" 2>/dev/null; then
                skip "$key: not writable here"
                return 1
            fi
            did "$key: $cur -> $want"
        fi
    fi
    SYSCTL_BUF+="$key = $want"$'\n'
}

flush_sysctl() {
    local file=/etc/sysctl.d/99-supertune-$1.conf
    if [[ -n $SYSCTL_BUF ]]; then
        write_file "$file" "# Managed by supertune ($1). Remove with: supertune.sh --undo
${SYSCTL_BUF%$'\n'}"
    else
        remove_file "$file"
    fi
    SYSCTL_BUF=""
}

write_file() {
    local path=$1 content=$2 mode=${3:-644}
    WROTE=0
    if [[ -f $path && ! -L $path ]] && [[ "$(cat "$path" 2>/dev/null)" == "$content" ]]; then
        return 0
    fi
    if ((DRY_RUN)); then
        did "write $path"
        return 0
    fi
    mkdir -p "${path%/*}" 2>/dev/null
    [[ -L $path ]] && rm -f "$path"
    if printf '%s\n' "$content" >"$path" 2>/dev/null; then
        chmod "$mode" "$path" 2>/dev/null
        WROTE=1
        did "wrote $path"
        return 0
    fi
    problem "could not write $path (read-only filesystem?)"
    return 1
}

remove_file() {
    [[ -e $1 || -L $1 ]] || return 0
    if ((DRY_RUN)); then
        did "remove $1"
        return 0
    fi
    rm -f "$1" && did "removed $1"
}

# svc_set UNIT on|off - enable+start or disable+stop, remembering the previous state.
svc_set() {
    local unit=$1 want=$2 en act
    if ((DRY_RUN)) && ! unit_exists "$unit"; then
        [[ $want == on ]] && did "enable and start $unit"
        return 0
    fi
    en=$(systemctl is-enabled "$unit" 2>/dev/null)
    act=$(systemctl is-active "$unit" 2>/dev/null)
    case $en in
    enabled | disabled) ;;
    *)
        skip "$unit: is $en, left alone"
        return 1
        ;;
    esac
    if [[ $want == on ]]; then
        [[ $en == enabled && $act == active ]] && return 0
        if ((DRY_RUN)); then
            did "enable and start $unit"
            return 0
        fi
        state_save svc "$unit" "$en $act"
        if systemctl enable --now "$unit" >/dev/null 2>&1; then
            did "enabled and started $unit"
        else
            problem "could not start $unit"
            return 1
        fi
    else
        [[ $en == disabled && $act != active ]] && return 0
        if ((DRY_RUN)); then
            did "disable and stop $unit"
            return 0
        fi
        state_save svc "$unit" "$en $act"
        systemctl disable --now "$unit" >/dev/null 2>&1 && did "disabled and stopped $unit"
    fi
}

###############################################################################
# Detection
###############################################################################

is_laptop() {
    local ps
    case $(cat /sys/class/dmi/id/chassis_type 2>/dev/null) in
    8 | 9 | 10 | 11 | 14 | 30 | 31 | 32) return 0 ;;
    esac
    for ps in /sys/class/power_supply/*; do
        [[ $(cat "$ps/type" 2>/dev/null) == Battery ]] || continue
        # Mouse/keyboard/controller batteries report scope=Device
        [[ $(cat "$ps/scope" 2>/dev/null) == Device ]] && continue
        return 0
    done
    return 1
}

has_gui() {
    local s
    [[ -e /etc/systemd/system/display-manager.service ]] && return 0
    if command -v loginctl >/dev/null 2>&1; then
        for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
            case $(loginctl show-session "$s" -p Type --value 2>/dev/null) in
            x11 | wayland | mir) return 0 ;;
            esac
        done
    fi
    pgrep -x 'Xorg|Xwayland|gnome-shell|kwin_wayland|kwin_x11|sway|Hyprland|plasmashell|weston|labwc|niri|cosmic-comp|xfce4-session|cinnamon|mate-session|lxqt-session|gamescope' >/dev/null 2>&1
}

detect() {
    RAM_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    RAM_GB=$(((RAM_KB + 524288) / 1048576))
    CPUS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)
    NUMA_NODES=$(find /sys/devices/system/node -maxdepth 1 -name 'node[0-9]*' 2>/dev/null | wc -l)
    ((NUMA_NODES > 0)) || NUMA_NODES=1
    KVER=$(uname -r)
    case $(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo) in
    AuthenticAMD) CPU_VENDOR=AMD ;;
    GenuineIntel) CPU_VENDOR=Intel ;;
    *) CPU_VENDOR=$(uname -m) ;;
    esac

    CONTAINER=""
    VIRT=none
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        CONTAINER=$(systemd-detect-virt -c 2>/dev/null) || CONTAINER=""
        [[ $CONTAINER == none ]] && CONTAINER=""
        VIRT=$(systemd-detect-virt -v 2>/dev/null) || VIRT=none
    else
        if [[ -f /.dockerenv || -f /run/.containerenv ]] || grep -qa 'container=' /proc/1/environ 2>/dev/null; then
            CONTAINER=container
        elif [[ -d /proc/vz && ! -d /proc/bc ]]; then
            CONTAINER=openvz
        fi
        if grep -qw hypervisor /proc/cpuinfo 2>/dev/null; then
            VIRT=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)
            [[ -n $VIRT ]] || VIRT=vm
        fi
    fi
    [[ -n $CONTAINER ]] && VIRT=none

    IS_PROXMOX=0
    [[ -d /etc/pve ]] || command -v pveversion >/dev/null 2>&1 && IS_PROXMOX=1
    HAS_DOCKER=0
    command -v docker >/dev/null 2>&1 || unit_exists docker.service && HAS_DOCKER=1
    HAS_WINGS=0
    [[ -d /etc/pterodactyl ]] || unit_exists wings.service && HAS_WINGS=1
    HAS_ZFS=0
    [[ -d /sys/module/zfs ]] && HAS_ZFS=1

    if [[ -n $CONTAINER ]]; then
        PROFILE=container PROFILE_REASON="running inside a $CONTAINER container"
    elif ((IS_PROXMOX)); then
        PROFILE=hypervisor PROFILE_REASON="Proxmox VE host"
    elif [[ $VIRT != none ]]; then
        PROFILE=vm PROFILE_REASON="virtual machine ($VIRT)"
    elif is_laptop; then
        PROFILE=laptop PROFILE_REASON="battery or laptop chassis detected"
    elif has_gui; then
        PROFILE=desktop PROFILE_REASON="bare metal with a graphical session"
    else
        PROFILE=server PROFILE_REASON="bare metal without a graphical session"
    fi
    if [[ -n $FORCED_PROFILE ]]; then
        PROFILE=$FORCED_PROFILE PROFILE_REASON="set with --profile"
    fi

    BAREMETAL=0
    [[ $VIRT == none && -z $CONTAINER ]] && BAREMETAL=1
    SERVERISH=0
    DESKTOPISH=0
    case $PROFILE in
    desktop | laptop) DESKTOPISH=1 ;;
    *) SERVERISH=1 ;;
    esac

    load_admin_sysctls
}

describe() {
    local where
    if [[ -n $CONTAINER ]]; then
        where="container ($CONTAINER)"
    elif [[ $VIRT != none ]]; then
        where="VM ($VIRT)"
    else
        where="bare metal"
    fi
    printf '%s, %s, %s CPUs, %s GB RAM' "$where" "$CPU_VENDOR" "$CPUS" "$RAM_GB"
    ((NUMA_NODES > 1)) && printf ', %s NUMA nodes' "$NUMA_NODES"
    ((HAS_ZFS)) && printf ', ZFS'
    ((HAS_WINGS)) && printf ', Pterodactyl Wings'
    ((HAS_DOCKER && !HAS_WINGS)) && printf ', Docker'
    echo
}

###############################################################################
# Legacy cleanup
###############################################################################

# Some legacy paths have generic names, so only remove them if they hold what old versions wrote.
legacy_owned() {
    case $1 in
    */99-cpu-governor.rules) grep -q 'ATTR{cpufreq/scaling_governor}="performance"' "$1" 2>/dev/null && (($(wc -l <"$1") <= 1)) ;;
    */99-performance.conf) grep -qE '^\*[[:space:]]+hard[[:space:]]+rtprio[[:space:]]+99' "$1" 2>/dev/null ;;
    */99-mglru.conf) [[ $(cat "$1" 2>/dev/null) == "w /sys/kernel/mm/lru_gen/enabled - - - - y" ]] ;;
    *) return 0 ;;
    esac
}

LEGACY_ROUTES=0
cleanup_legacy() {
    local f u
    for f in "${LEGACY_FILES[@]}"; do
        [[ -e $f || -L $f ]] || continue
        legacy_owned "$f" || continue
        [[ $f == *routes* ]] && LEGACY_ROUTES=1
        remove_file "$f"
    done
    for u in supertune.service tcptune.service; do
        [[ -f /etc/systemd/system/$u ]] || continue
        if ((DRY_RUN)); then
            did "remove old $u"
        else
            systemctl disable --now "$u" >/dev/null 2>&1
            rm -f "/etc/systemd/system/$u"
            did "removed old $u"
        fi
    done
}

# ramtune's zram service is replaced by supertune's. It is disabled without stopping it, so
# the zram swap that is in use right now stays up.
cleanup_ramtune() {
    local f
    for f in "${RAMTUNE_FILES[@]}"; do
        [[ -e $f ]] && legacy_owned "$f" && remove_file "$f"
    done
    [[ -f /etc/systemd/system/ramtune.service ]] || return 0
    if ((DRY_RUN)); then
        did "remove old ramtune.service"
        return 0
    fi
    systemctl disable ramtune.service >/dev/null 2>&1
    rm -f /etc/systemd/system/ramtune.service
    units_reload
    did "removed old ramtune.service"
}

###############################################################################
# Memory: zram, swappiness, writeback, MGLRU, transparent hugepages
###############################################################################

zram_swap_active() { grep -q '^/dev/zram' /proc/swaps 2>/dev/null; }

# zram-generator, zram-tools, zram-config and friends: if any of them is set up, it owns zram.
zram_foreign() {
    local f u
    for f in /etc/systemd/zram-generator.conf /usr/lib/systemd/zram-generator.conf \
        /usr/local/lib/systemd/zram-generator.conf /run/systemd/zram-generator.conf \
        /etc/systemd/zram-generator.conf.d/*.conf /usr/lib/systemd/zram-generator.conf.d/*.conf; do
        [[ -s $f ]] && return 0
    done
    for u in zramswap.service zram-config.service zram-swap.service systemd-swap.service zram-init.service; do
        [[ $(systemctl is-enabled "$u" 2>/dev/null) == enabled ]] && return 0
    done
    return 1
}

gen_zram_helper() {
    cat <<EOF
#!/usr/bin/env bash
# Generated by supertune - sets up compressed RAM swap (zram) at boot.
# If zram can't be set up, swappiness falls back to a value that is safe for disk swap.
ALGO=$1
SIZE=$2
FALLBACK_SWAPPINESS=$3
dev=/sys/block/zram0
fallback() {
    sysctl -qw vm.swappiness=\$FALLBACK_SWAPPINESS vm.page-cluster=3 >/dev/null 2>&1
    exit 0
}
grep -q '^/dev/zram0 ' /proc/swaps && exit 0
modprobe zram 2>/dev/null
[[ -d \$dev ]] || fallback
[[ \$(cat \$dev/disksize) == 0 ]] || fallback
grep -qw -- "\$ALGO" \$dev/comp_algorithm && echo "\$ALGO" >\$dev/comp_algorithm
echo "\$SIZE" >\$dev/disksize || fallback
mkswap -L zram0 /dev/zram0 >/dev/null 2>&1 || fallback
swapon -p 100 /dev/zram0 || fallback
EOF
}

ZRAM_OK=0
setup_zram() {
    local dev=/sys/block/zram0 algo=zstd a size max cur_algo cur_size used avail swp=$1
    ZRAM_OK=0
    if zram_foreign; then
        if zram_swap_active; then
            ZRAM_OK=1
            info "zram is managed by your system (zram-generator or similar) - kept as is"
        else
            skip "zram: another zram tool is configured but not active - left alone"
        fi
        return
    fi
    if ! has_systemd; then
        skip "zram: needs systemd to come back after a reboot - not set up"
        return
    fi
    if ! load_module zram; then
        skip "zram: this kernel has no zram support"
        return
    fi
    if [[ -d $dev ]] && ! zram_swap_active && [[ $(cat $dev/disksize 2>/dev/null) != 0 ]]; then
        skip "zram: /dev/zram0 is already used for something else - left alone"
        return
    fi
    if [[ -e $dev/comp_algorithm ]]; then
        algo=lzo-rle
        for a in zstd lz4 lzo-rle lzo; do
            if grep -qw -- "$a" $dev/comp_algorithm; then
                algo=$a
                break
            fi
        done
    fi
    size=$((RAM_KB * 1024))
    max=$((64 * 1024 * 1024 * 1024))
    ((size > max)) && size=$max

    if zram_swap_active; then
        cur_algo=$(read_sel $dev/comp_algorithm)
        cur_size=$(cat $dev/disksize 2>/dev/null)
        if [[ $cur_algo == "$algo" ]] && ((cur_size >= size * 9 / 10 && cur_size <= size * 11 / 10)); then
            info "zram already set up ($algo, $((cur_size / 1073741824)) GB) - kept"
        else
            used=$(awk '{print $1}' $dev/mm_stat 2>/dev/null)
            avail=$(awk '/^MemAvailable:/{print $2 * 1024}' /proc/meminfo)
            if ((${used:-0} < avail / 2)); then
                if ((DRY_RUN)); then
                    did "rebuild zram: $cur_algo -> $algo, $((size / 1073741824)) GB"
                elif swapoff /dev/zram0 2>/dev/null && echo 1 >$dev/reset 2>/dev/null; then
                    did "zram swap emptied for rebuild"
                else
                    problem "zram: could not empty the current zram swap - new settings apply after reboot"
                fi
            else
                note "zram holds too much data to rebuild safely right now. The new zram settings apply after the next reboot."
            fi
        fi
    fi

    write_file "$ZRAM_HELPER" "$(gen_zram_helper "$algo" "$size" "$swp")" 755
    write_file /etc/systemd/system/supertune-zram.service "[Unit]
Description=supertune compressed RAM swap (zram)
DefaultDependencies=no
After=systemd-modules-load.service systemd-sysctl.service
Before=swap.target
ConditionVirtualization=!container

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$ZRAM_HELPER

[Install]
WantedBy=swap.target"
    units_reload
    svc_set supertune-zram.service on
    if ((DRY_RUN)); then
        ZRAM_OK=1
        zram_swap_active || did "zram swap: $algo, $((size / 1073741824)) GB"
        return
    fi
    if ! zram_swap_active; then
        "$ZRAM_HELPER"
        if zram_swap_active; then
            state_save zram created 1
            did "zram swap: $algo, $((size / 1073741824)) GB"
        fi
    fi
    if zram_swap_active; then ZRAM_OK=1; else problem "zram could not be started"; fi
}

mod_memory() {
    section "Memory"
    if [[ $PROFILE == container ]]; then
        info "memory is managed by the container host - skipped"
        return
    fi
    cleanup_ramtune

    local swp_disk=10 swp_zram dbytes dbg cur lru=/sys/kernel/mm/lru_gen thp=/sys/kernel/mm/transparent_hugepage tmpf=""
    if ((DESKTOPISH)); then swp_zram=150; else swp_zram=100; fi
    kernel_ge 5 8 || swp_zram=100

    # Hypervisors keep VM memory out of compressed swap
    if [[ $PROFILE == hypervisor ]]; then
        info "hypervisor: zram not set up, VM memory stays out of swap"
    else
        setup_zram "$swp_disk"
    fi

    if ((ZRAM_OK)) && [[ $PROFILE != hypervisor ]]; then
        set_sysctl vm.swappiness "$swp_zram"
        set_sysctl vm.page-cluster 0
    else
        set_sysctl vm.swappiness "$swp_disk"
        set_sysctl vm.page-cluster 3
    fi
    set_sysctl vm.vfs_cache_pressure 50
    set_sysctl vm.watermark_boost_factor 0
    set_sysctl vm.watermark_scale_factor 125

    # Fixed writeback sizes instead of % of RAM, so big-RAM machines don't stall on huge flushes
    if ((RAM_KB < 8 * 1048576)); then
        dbytes=134217728 dbg=33554432
    elif ((RAM_KB < 32 * 1048576)); then
        dbytes=268435456 dbg=67108864
    else
        dbytes=1073741824 dbg=268435456
    fi
    if [[ -z ${ADMIN_SYSCTL[vm.dirty_ratio]:-}${ADMIN_SYSCTL[vm.dirty_background_ratio]:-}${ADMIN_SYSCTL[vm.dirty_bytes]:-}${ADMIN_SYSCTL[vm.dirty_background_bytes]:-} ]]; then
        # Undo restores the ratios; writing a ratio resets the byte value
        cur=$(cat /proc/sys/vm/dirty_ratio)
        ((cur > 0)) && state_save sysctl vm.dirty_ratio "$cur"
        cur=$(cat /proc/sys/vm/dirty_background_ratio)
        ((cur > 0)) && state_save sysctl vm.dirty_background_ratio "$cur"
        set_sysctl vm.dirty_bytes "$dbytes"
        set_sysctl vm.dirty_background_bytes "$dbg"
    fi

    # Bigger free-memory reserve on servers absorbs network bursts without allocation stalls
    if ((SERVERISH && RAM_KB >= 8 * 1048576)); then
        cur=$((RAM_KB / 200))
        ((cur > 1048576)) && cur=1048576
        set_sysctl vm.min_free_kbytes "$cur" raise
    fi

    if [[ -e $lru/enabled ]]; then
        cur=$(cat $lru/enabled 2>/dev/null)
        if [[ $cur == 0x0000 ]]; then
            if ((DRY_RUN)); then
                did "Multi-Gen LRU: off -> on"
            else
                state_save sysfs $lru/enabled "$cur"
                echo y >$lru/enabled 2>/dev/null && did "Multi-Gen LRU: off -> on"
            fi
        fi
        tmpf+="w $lru/enabled - - - - y"$'\n'
        if ((DESKTOPISH)) && [[ -e $lru/min_ttl_ms ]]; then
            set_sysfs $lru/min_ttl_ms 1000 "MGLRU thrashing protection (min_ttl_ms)"
            tmpf+="w $lru/min_ttl_ms - - - - 1000"$'\n'
        fi
    else
        skip "Multi-Gen LRU: needs kernel 6.1+"
    fi

    if [[ -e $thp/enabled ]]; then
        if [[ $(read_sel $thp/enabled) == never ]]; then
            info "transparent hugepages are turned off on this system - kept off"
        else
            set_sysfs $thp/enabled madvise "transparent hugepages"
            tmpf+="w $thp/enabled - - - - madvise"$'\n'
            if grep -q 'defer+madvise' $thp/defrag 2>/dev/null; then
                set_sysfs $thp/defrag defer+madvise "hugepage defrag"
                tmpf+="w $thp/defrag - - - - defer+madvise"$'\n'
            fi
        fi
    fi

    if [[ -n $tmpf ]]; then
        write_file /etc/tmpfiles.d/99-supertune-memory.conf "# Managed by supertune (memory)
${tmpf%$'\n'}"
        has_systemd || note "MGLRU and hugepage settings are not kept after reboot without systemd-tmpfiles."
    fi
    flush_sysctl memory
}

###############################################################################
# Disks: I/O schedulers per disk type
###############################################################################

disk_kind() {
    local n=$1 d=/sys/block/$1
    if ((HAS_ZFS)) && lsblk -nro FSTYPE "/dev/$n" 2>/dev/null | grep -q zfs_member; then
        echo zfs
    elif [[ $n == nvme* ]]; then
        echo nvme
    elif [[ $VIRT != none || $n == vd* || $n == xvd* ]]; then
        echo virtual
    elif [[ $(cat "$d/queue/rotational" 2>/dev/null) == 0 ]]; then
        echo ssd
    else
        echo hdd
    fi
}

real_disks() {
    local dev
    for dev in /sys/block/*; do
        case ${dev##*/} in
        loop* | ram* | zram* | dm-* | md* | sr* | fd* | nbd* | rbd* | drbd* | bcache* | zd* | nullb*) continue ;;
        esac
        [[ -f $dev/queue/scheduler ]] && echo "${dev##*/}"
    done
}

# Your own udev rules in /etc that set the same knob win over supertune
admin_udev() {
    grep -lsE "$1" /etc/udev/rules.d/*.rules 2>/dev/null | grep -v supertune | head -n1
}

mod_disk() {
    section "Disks"
    if [[ $PROFILE == container ]]; then
        info "disks are managed by the container host - skipped"
        return
    fi
    local own
    own=$(admin_udev 'queue/scheduler')
    if [[ -n $own ]]; then
        info "I/O schedulers are set by your own rule in $own - left alone"
        remove_file /etc/udev/rules.d/60-supertune-disk.rules
        return
    fi
    local hdd=mq-deadline name kind want avail used_bfq=0 rules
    # bfq keeps desktops responsive on spinning disks; servers and ZFS want mq-deadline throughput
    ((DESKTOPISH && !HAS_ZFS)) && hdd=bfq

    for name in $(real_disks); do
        kind=$(disk_kind "$name")
        # Zoned (host-managed SMR) disks need the scheduler the kernel picked
        if [[ $(cat "/sys/block/$name/queue/zoned" 2>/dev/null) == host-* ]]; then
            info "$name: zoned disk - scheduler left as is"
            continue
        fi
        case $kind in
        zfs)
            info "$name: part of a ZFS pool - left to ZFS"
            continue
            ;;
        nvme | virtual) want=none ;;
        ssd) want=mq-deadline ;;
        hdd) want=$hdd ;;
        esac
        avail=$(cat "/sys/block/$name/queue/scheduler")
        if [[ " ${avail//[\[\]]/} " != *" $want "* ]]; then
            load_module "${want/none/}" >/dev/null 2>&1
            ((DRY_RUN)) || avail=$(cat "/sys/block/$name/queue/scheduler")
        fi
        if [[ " ${avail//[\[\]]/} " != *" $want "* ]] && ! ((DRY_RUN)); then
            if [[ $want == bfq && " ${avail//[\[\]]/} " == *" mq-deadline "* ]]; then
                want=mq-deadline
            else
                skip "$name: scheduler $want not available"
                continue
            fi
        fi
        [[ $want == bfq ]] && used_bfq=1
        set_sysfs "/sys/block/$name/queue/scheduler" "$want" "$name ($kind) I/O scheduler"
        [[ $kind == hdd ]] && set_sysfs "/sys/block/$name/queue/read_ahead_kb" 1024 "$name read-ahead (KB)"
        set_sysfs "/sys/block/$name/queue/add_random" 0
    done

    rules='# Managed by supertune (disk)
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ATTR{queue/zoned}!="host-managed", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"'
    if [[ $VIRT != none ]]; then
        rules+='
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ATTR{queue/zoned}!="host-managed", KERNEL=="vd[a-z]*|xvd[a-z]*|sd[a-z]*", ATTR{queue/scheduler}="none"'
    else
        rules+="
ACTION==\"add|change\", SUBSYSTEM==\"block\", ENV{DEVTYPE}==\"disk\", ATTR{queue/zoned}!=\"host-managed\", KERNEL==\"sd[a-z]*|mmcblk[0-9]*\", ATTR{queue/rotational}==\"0\", ATTR{queue/scheduler}=\"mq-deadline\"
ACTION==\"add|change\", SUBSYSTEM==\"block\", ENV{DEVTYPE}==\"disk\", ATTR{queue/zoned}!=\"host-managed\", KERNEL==\"sd[a-z]*\", ATTR{queue/rotational}==\"1\", ATTR{queue/scheduler}=\"$hdd\", ATTR{queue/read_ahead_kb}=\"1024\""
    fi
    write_file /etc/udev/rules.d/60-supertune-disk.rules "$rules"
    if [[ $hdd == bfq ]] && { ((used_bfq)) || ! module_ready bfq; }; then
        write_file /etc/modules-load.d/99-supertune-disk.conf "bfq"
    else
        remove_file /etc/modules-load.d/99-supertune-disk.conf
    fi
    ((DRY_RUN)) || udevadm control --reload >/dev/null 2>&1
}

###############################################################################
# CPU: governor and boost
###############################################################################

mod_cpu() {
    section "CPU"
    local cpu0=/sys/devices/system/cpu/cpu0/cpufreq gov n=0 cur
    if [[ $PROFILE == container ]]; then
        info "CPU is managed by the container host - skipped"
        return
    fi
    if [[ ! -e $cpu0/scaling_governor ]]; then
        info "no CPU frequency control here (normal for VMs) - skipped"
        return
    fi
    if [[ $PROFILE == laptop ]]; then
        info "laptop: CPU power management left to the system for battery life and thermals"
        return
    fi

    if has_systemd && systemctl is-active -q power-profiles-daemon 2>/dev/null && command -v powerprofilesctl >/dev/null 2>&1; then
        cur=$(powerprofilesctl get 2>/dev/null)
        if [[ -n $cur && $cur != performance ]] && powerprofilesctl list 2>/dev/null | grep -q 'performance:'; then
            if ((DRY_RUN)); then
                did "power profile: $cur -> performance"
            else
                state_save ppd profile "$cur"
                powerprofilesctl set performance 2>/dev/null && did "power profile: $cur -> performance"
            fi
        fi
    fi
    if has_systemd && [[ $(systemctl is-enabled tlp.service 2>/dev/null) == enabled ]]; then
        note "TLP is enabled. It may switch the CPU back to power saving on this $PROFILE."
    fi
    if has_systemd && systemctl is-active -q tuned 2>/dev/null; then
        note "tuned is running and may override some of these settings. 'tuned-adm profile latency-performance' matches supertune."
    fi

    cur=$(admin_udev 'scaling_governor')
    if [[ -n $cur ]]; then
        info "CPU governor is set by your own rule in $cur - left alone"
    elif grep -qw performance "$cpu0/scaling_available_governors" 2>/dev/null; then
        cur=$(cat "$cpu0/scaling_governor")
        for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            set_sysfs "$gov" performance && ((CHANGED)) && n=$((n + 1))
        done
        ((n)) && did "CPU governor: $cur -> performance ($n cores)"
        write_file /etc/udev/rules.d/99-supertune-cpu.rules '# Managed by supertune (cpu)
SUBSYSTEM=="cpu", ACTION=="add", TEST=="cpufreq/scaling_governor", ATTR{cpufreq/scaling_governor}="performance"'
        ((DRY_RUN)) || udevadm control --reload >/dev/null 2>&1
    else
        skip "CPU governor: 'performance' not offered by this driver"
    fi
    set_sysfs /sys/devices/system/cpu/cpufreq/boost 1 "CPU boost"
    set_sysfs /sys/devices/system/cpu/intel_pstate/no_turbo 0 "Intel turbo"
}

###############################################################################
# IRQ balancing
###############################################################################

mod_irq() {
    section "Interrupts"
    if [[ $PROFILE == container ]]; then
        info "interrupts are handled by the container host - skipped"
        return
    fi
    if ((CPUS < 2)); then
        info "single CPU - nothing to balance"
        return
    fi
    if unit_exists irqbalance.service; then
        svc_set irqbalance.service on
    elif ((SERVERISH)); then
        info "irqbalance not installed - network load is spread with RPS instead (network section)"
    else
        info "irqbalance not installed - the kernel's own interrupt placement is kept"
    fi
}

###############################################################################
# Network: congestion control, buffers, conntrack, routes, NICs
###############################################################################

# These three functions are copied into the network hook that runs whenever the network changes.
# They read CWND, RWND, QUICKACK, NIC_RINGS, RPS and TUNE_DRY.
tune_routes() {
    local fam line base want ok
    for fam in -4 -6; do
        while read -r line; do
            case $line in
            *nexthop* | *\\* | unreachable* | blackhole* | prohibit* | throw* | fe80:* | ff00:* | multicast*) continue ;;
            esac
            [[ $line == *" dev "* ]] || continue
            [[ $fam == -6 && $line == *" expires "* ]] && continue
            ok=1
            for want in "initcwnd:$CWND" "initrwnd:$RWND" "quickack:$QUICKACK"; do
                if [[ -n ${want#*:} ]]; then
                    [[ " $line " == *" ${want%%:*} ${want#*:} "* ]] || ok=0
                else
                    [[ " $line " == *" ${want%%:*} "* ]] && ok=0
                fi
            done
            ((ok)) && continue
            base=$(sed -E 's/ (initcwnd|initrwnd|quickack) [0-9]+//g; s/ (linkdown|dead|offload|trap|rt_offload|rt_trap|rt_offload_failed)( |$)/\2/g; s/ +$//' <<<"$line")
            want=$base
            [[ -n $CWND ]] && want+=" initcwnd $CWND"
            [[ -n $RWND ]] && want+=" initrwnd $RWND"
            [[ -n $QUICKACK ]] && want+=" quickack $QUICKACK"
            if [[ -n ${TUNE_DRY:-} ]]; then
                echo "    would: ip $fam route replace $want"
            else
                # shellcheck disable=SC2086
                ip "$fam" route replace $want 2>/dev/null
            fi
        done < <(ip "$fam" -o route show 2>/dev/null)
    done
}

rps_mask() {
    local n=$1 out="" g
    (((n % 32) > 0)) && out=$(printf '%x' $(((1 << (n % 32)) - 1)))
    for ((g = 0; g < n / 32; g++)); do out+="${out:+,}ffffffff"; done
    echo "$out"
}

tune_nics() {
    local p n rxm txm rxc txc q nq ncpu mask
    ncpu=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    for p in /sys/class/net/*; do
        n=${p##*/}
        [[ $n == lo || ! -e $p/device || -e $p/wireless || -e $p/phy80211 ]] && continue
        if [[ $NIC_RINGS == 1 ]] && command -v ethtool >/dev/null 2>&1; then
            read -r rxm txm rxc txc < <(ethtool -g "$n" 2>/dev/null | awk '/^Pre-set/{s=1} /^Current/{s=2} s==1&&/^RX:/{rm=$2} s==1&&/^TX:/{tm=$2} s==2&&/^RX:/{rc=$2} s==2&&/^TX:/{tc=$2} END{print rm+0, tm+0, rc+0, tc+0}')
            ((rxm > 4096)) && rxm=4096
            ((txm > 4096)) && txm=4096
            if ((rxc > 0 && rxm > rxc)); then
                if [[ -n ${TUNE_DRY:-} ]]; then echo "    would: $n RX ring $rxc -> $rxm"; else ethtool -G "$n" rx "$rxm" >/dev/null 2>&1; fi
            fi
            if ((txc > 0 && txm > txc)); then
                if [[ -n ${TUNE_DRY:-} ]]; then echo "    would: $n TX ring $txc -> $txm"; else ethtool -G "$n" tx "$txm" >/dev/null 2>&1; fi
            fi
        fi
        if [[ $RPS == 1 ]]; then
            nq=$(find "$p/queues" -maxdepth 1 -name 'rx-*' 2>/dev/null | wc -l)
            ((nq > 0 && nq < ncpu)) || continue
            mask=$(rps_mask "$ncpu")
            for q in "$p"/queues/rx-*; do
                [[ -e $q/rps_cpus ]] || continue
                # Leave masks that someone already set
                [[ -z $(tr -d '0,\n' <"$q/rps_cpus") ]] || continue
                if [[ -n ${TUNE_DRY:-} ]]; then
                    echo "    would: spread $n ${q##*/} over $ncpu CPUs (RPS)"
                else
                    echo "$mask" >"$q/rps_cpus" 2>/dev/null
                    echo $((32768 / nq)) >"$q/rps_flow_cnt" 2>/dev/null
                fi
            done
        fi
    done
}

gen_net_hook() {
    printf '#!/usr/bin/env bash\n# Generated by supertune - reapplies route and NIC tuning when the network changes.\n'
    printf 'CWND=%q RWND=%q QUICKACK=%q NIC_RINGS=%q RPS=%q\n' "$CWND" "$RWND" "$QUICKACK" "$NIC_RINGS" "$RPS"
    declare -f tune_routes rps_mask tune_nics
    printf 'tune_routes\ntune_nics\nexit 0\n'
}

# Saves NIC ring sizes and RPS state so --undo can put them back.
snapshot_nics() {
    local p n rxc txc
    for p in /sys/class/net/*; do
        n=${p##*/}
        [[ $n == lo || ! -e $p/device || -e $p/wireless || -e $p/phy80211 ]] && continue
        if [[ $NIC_RINGS == 1 ]] && command -v ethtool >/dev/null 2>&1; then
            read -r rxc txc < <(ethtool -g "$n" 2>/dev/null | awk '/^Current/{s=1} s&&/^RX:/{rc=$2} s&&/^TX:/{tc=$2} END{print rc+0, tc+0}')
            ((rxc > 0)) && state_save ring "$n" "$rxc $txc"
        fi
        [[ $RPS == 1 ]] && [[ -z $(cat "$p"/queues/rx-*/rps_cpus 2>/dev/null | tr -d '0,\n') ]] && state_save rps "$n" 1
    done
}

refresh_qdiscs() {
    local p n q
    command -v tc >/dev/null 2>&1 || return 0
    [[ $(cat /proc/sys/net/core/default_qdisc 2>/dev/null) == fq ]] || return 0
    for p in /sys/class/net/*; do
        n=${p##*/}
        [[ $n == lo || ! -e $p/device || -e $p/wireless || -e $p/phy80211 ]] && continue
        q=$(tc qdisc show dev "$n" 2>/dev/null)
        # Only replace the kernel's stock qdiscs, never a custom shaping setup
        [[ $q == *"qdisc fq_codel"* || $q == *"qdisc pfifo_fast"* ]] || continue
        grep -qE 'qdisc (cake|htb|hfsc|tbf|netem|prio|drr|qfq|ets|cbq|taprio|mqprio|sfq|red|choke|pie|fq_pie|ingress|clsact)' <<<"$q" && continue
        if ((DRY_RUN)); then
            did "$n: switch queueing to fq"
        elif tc qdisc replace dev "$n" root pfifo_fast 2>/dev/null && tc qdisc del dev "$n" root 2>/dev/null; then
            did "$n: queueing switched to fq"
        fi
    done
}

install_net_hooks() {
    local wrapper="#!/bin/sh
# Managed by supertune
exec $NET_HOOK \"\$@\""
    write_file "$NET_HOOK" "$(gen_net_hook)" 755
    if has_systemd; then
        write_file /etc/systemd/system/supertune-net.service "[Unit]
Description=supertune network route and NIC tuning
After=network.target

[Service]
Type=oneshot
ExecStart=$NET_HOOK"
        write_file /etc/systemd/system/supertune-net.timer "[Unit]
Description=Reapply supertune network tuning

[Timer]
OnBootSec=20s
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target"
        units_reload
        svc_set supertune-net.timer on
    elif [[ -d /etc/cron.d ]]; then
        write_file /etc/cron.d/supertune "@reboot root $NET_HOOK >/dev/null 2>&1"
    fi
    [[ -d /etc/NetworkManager/dispatcher.d ]] && write_file /etc/NetworkManager/dispatcher.d/90-supertune "$wrapper" 755
    [[ -d /etc/network/if-up.d ]] && write_file /etc/network/if-up.d/supertune "$wrapper" 755
    [[ -d /etc/networkd-dispatcher/routable.d ]] && write_file /etc/networkd-dispatcher/routable.d/50-supertune "$wrapper" 755
}

# tcp_rmem/tcp_wmem: only raise the max, keep the kernel's min and default
tcp_buf() {
    local key=$1 def=$2 max=$3 cur
    cur=$(awk '{print $3}' "/proc/sys/${key//.//}" 2>/dev/null)
    [[ -n $cur ]] && ((cur > max)) && return 0
    set_sysctl "$key" "4096 $def $max"
}

mod_network() {
    section "Network"
    local max mods="" ct hash cur

    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null ||
        { load_module tcp_bbr && { ((DRY_RUN)) || grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; }; }; then
        set_sysctl net.ipv4.tcp_congestion_control bbr && mods+="tcp_bbr"$'\n'
    else
        skip "BBR congestion control: not available in this kernel"
    fi
    if load_module sch_fq; then
        set_sysctl net.core.default_qdisc fq && mods+="sch_fq"$'\n'
    fi

    if ((RAM_KB < 2 * 1048576)); then
        max=16777216
    elif ((RAM_KB < 8 * 1048576 || DESKTOPISH)); then
        max=33554432
    else
        max=67108864
    fi
    set_sysctl net.core.rmem_max "$max" raise
    set_sysctl net.core.wmem_max "$max" raise
    tcp_buf net.ipv4.tcp_rmem 131072 "$max"
    tcp_buf net.ipv4.tcp_wmem 16384 "$max"

    set_sysctl net.ipv4.tcp_fastopen 3
    set_sysctl net.ipv4.tcp_mtu_probing 1
    set_sysctl net.ipv4.tcp_slow_start_after_idle 0
    set_sysctl net.ipv4.tcp_tw_reuse 1
    set_sysctl net.ipv4.tcp_fin_timeout 15
    set_sysctl net.ipv4.tcp_keepalive_time 60
    set_sysctl net.ipv4.tcp_keepalive_intvl 10
    set_sysctl net.ipv4.tcp_keepalive_probes 6
    set_sysctl net.ipv4.tcp_syncookies 1
    set_sysctl net.ipv4.tcp_no_metrics_save 1

    if ((SERVERISH)); then
        set_sysctl net.core.netdev_max_backlog 65536 raise
        set_sysctl net.core.somaxconn 65535 raise
        set_sysctl net.ipv4.tcp_max_syn_backlog 65536 raise
        set_sysctl net.ipv4.tcp_max_tw_buckets 2000000 raise
        set_sysctl net.core.netdev_budget 600 raise
        set_sysctl net.core.netdev_budget_usecs 4000 raise
        set_sysctl net.ipv4.tcp_notsent_lowat 131072
        set_sysctl net.ipv4.udp_rmem_min 8192 raise
        set_sysctl net.ipv4.udp_wmem_min 8192 raise
        # Bigger default socket buffers help UDP game servers
        if ((RAM_KB >= 4 * 1048576)); then
            set_sysctl net.core.rmem_default 1048576 raise
            set_sysctl net.core.wmem_default 1048576 raise
        fi
    else
        set_sysctl net.core.netdev_max_backlog 16384 raise
        set_sysctl net.core.somaxconn 8192 raise
        set_sysctl net.ipv4.tcp_notsent_lowat 16384
    fi

    # Docker/Wings NAT every connection through conntrack; a full table drops packets
    if ((SERVERISH)) && [[ $PROFILE != container ]] && { [[ -d /sys/module/nf_conntrack ]] || ((HAS_DOCKER || HAS_WINGS)); }; then
        if load_module nf_conntrack; then
            ct=$((RAM_GB * 65536))
            ((ct < 262144)) && ct=262144
            ((ct > 2097152)) && ct=2097152
            hash=$((ct / 4))
            set_sysctl net.netfilter.nf_conntrack_max "$ct" raise
            set_sysctl net.netfilter.nf_conntrack_tcp_timeout_established 86400 lower
            set_sysctl net.netfilter.nf_conntrack_tcp_timeout_time_wait 30 lower
            cur=$(cat /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null)
            if [[ -n $cur ]] && ((cur < hash)); then
                set_sysfs /sys/module/nf_conntrack/parameters/hashsize "$hash" "conntrack hash table"
                write_file /etc/modprobe.d/99-supertune.conf "# Managed by supertune (network)
options nf_conntrack hashsize=$hash"
            fi
            mods+="nf_conntrack"$'\n'
        fi
    fi

    # Route options: a modest initcwnd on servers, faster ACKs and a bigger receive window everywhere
    if ((SERVERISH)); then CWND=32; else CWND=""; fi
    RWND=64
    QUICKACK=1
    NIC_RINGS=0
    RPS=0
    if [[ $PROFILE == server || $PROFILE == hypervisor ]]; then NIC_RINGS=1; fi
    if ((SERVERISH && CPUS >= 4)) && [[ $PROFILE != container ]]; then RPS=1; fi
    ((RPS)) && set_sysctl net.core.rps_sock_flow_entries 32768 raise

    if command -v ip >/dev/null 2>&1; then
        install_net_hooks
        if ((DRY_RUN)); then
            TUNE_DRY=1 tune_routes
            [[ $PROFILE != container ]] && TUNE_DRY=1 tune_nics
        else
            snapshot_nics
            tune_routes
            [[ $PROFILE != container ]] && tune_nics
            did "route and NIC tuning applied (initcwnd ${CWND:-default}, initrwnd $RWND, quickack)"
        fi
    else
        skip "route tuning: 'ip' command not found"
    fi
    [[ $PROFILE != container ]] && refresh_qdiscs

    if [[ -n $mods ]]; then
        write_file /etc/modules-load.d/99-supertune-network.conf "${mods%$'\n'}"
    else
        remove_file /etc/modules-load.d/99-supertune-network.conf
    fi
    flush_sysctl network
}

###############################################################################
# Limits: open files for logins and for systemd services
###############################################################################

mod_limits() {
    section "Limits"
    local soft=1024 pam nr
    set_sysctl fs.nr_open 1048576 raise
    flush_sysctl limits
    nr=$(cat /proc/sys/fs/nr_open 2>/dev/null)
    if ((${nr:-0} < 1048576)); then
        skip "open-file limits: fs.nr_open is below 1048576, raising limits could block logins"
        return
    fi
    # Servers get a high soft limit; desktops only raise the hard limit (apps like Proton raise their own soft limit)
    ((SERVERISH)) && soft=1048576
    pam="# Managed by supertune (limits)
*       hard    nofile    1048576
root    hard    nofile    1048576"
    if ((SERVERISH)); then
        pam+="
*       soft    nofile    1048576
root    soft    nofile    1048576"
    fi
    write_file /etc/security/limits.d/99-supertune.conf "$pam"
    if has_systemd; then
        write_file /etc/systemd/system.conf.d/99-supertune.conf "# Managed by supertune (limits)
[Manager]
DefaultLimitNOFILE=$soft:1048576"
        write_file /etc/systemd/user.conf.d/99-supertune.conf "# Managed by supertune (limits)
[Manager]
DefaultLimitNOFILE=$soft:1048576"
        note "New open-file limits reach running services after a reboot, and logins after logging in again."
    fi
}

###############################################################################
# System: kernel limits, gaming knobs, crash recovery, journald, SSH, TRIM
###############################################################################

has_flash() {
    local name
    for name in $(real_disks); do
        [[ $(cat "/sys/block/$name/queue/rotational" 2>/dev/null) == 0 || $VIRT != none ]] && return 0
    done
    return 1
}

mod_system() {
    section "System"
    local u pid
    set_sysctl fs.file-max 2097152 raise
    set_sysctl fs.inotify.max_user_watches 1048576 raise
    set_sysctl fs.inotify.max_user_instances 8192 raise
    [[ $(getconf LONG_BIT 2>/dev/null) == 64 ]] && set_sysctl kernel.pid_max 4194304 raise
    # Some games and Steam need a very high memory map count
    set_sysctl vm.max_map_count 2147483642 raise

    if ((DESKTOPISH && BAREMETAL)); then
        set_sysctl kernel.sched_autogroup_enabled 1
        set_sysctl kernel.nmi_watchdog 0
        # Split-lock slowdowns hurt some games (kernel 6.2+)
        [[ -e /proc/sys/kernel/split_lock_mitigate ]] && set_sysctl kernel.split_lock_mitigate 0
    fi
    # Remote machines reboot after a kernel panic instead of hanging until someone power-cycles them
    if ((SERVERISH)) && [[ $PROFILE != container && $(cat /proc/sys/kernel/panic 2>/dev/null) == 0 ]]; then
        set_sysctl kernel.panic 10
    fi
    flush_sysctl system

    if ! has_systemd || [[ $PROFILE == container ]]; then
        return
    fi
    if unit_exists fstrim.timer && has_flash; then
        svc_set fstrim.timer on
    fi
    if ((SERVERISH)); then
        if ! grep -rqsE '^[[:space:]]*SystemMaxUse=' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/ --exclude=99-supertune.conf; then
            write_file /etc/systemd/journald.conf.d/99-supertune.conf "# Managed by supertune (system)
[Journal]
SystemMaxUse=1G"
            ((WROTE)) && systemctl restart systemd-journald >/dev/null 2>&1
        fi
        # Keep SSH alive when memory runs out, so the machine stays reachable
        for u in ssh sshd; do
            [[ $(systemctl show -p LoadState --value "$u.service" 2>/dev/null) == loaded ]] || continue
            # Drop-ins must go under the real unit name, not an alias
            u=$(systemctl show -p Id --value "$u.service" 2>/dev/null)
            u=${u%.service}
            write_file "/etc/systemd/system/$u.service.d/99-supertune.conf" "# Managed by supertune (system)
[Service]
OOMScoreAdjust=-900"
            units_reload
            pid=$(systemctl show -p MainPID --value "$u.service" 2>/dev/null)
            ((DRY_RUN == 0 && ${pid:-0} > 0)) && echo -900 >"/proc/$pid/oom_score_adj" 2>/dev/null
            break
        done
    fi

    if [[ $PROFILE == desktop && $CPU_VENDOR == AMD ]] && grep -qs 0x1002 /sys/class/drm/card*/device/vendor; then
        note "Ryzen + Radeon desktop: amd_gaming_tune.sh adds GPU clock and C-state tuning (opt-in, more heat and power)."
    fi
}

###############################################################################
# Undo
###############################################################################

do_undo() {
    section "Restoring original settings"
    local kind key val en act f
    if [[ -f $STATE_FILE ]]; then
        while IFS='|' read -r kind key val; do
            case $kind in
            sysctl)
                # Writing the ratios already resets the byte values
                [[ $key == vm.dirty_* && $val == 0 ]] && continue
                if ((DRY_RUN)); then did "$key -> $val"; else echo "$val" >"/proc/sys/${key//.//}" 2>/dev/null && did "$key -> $val"; fi
                ;;
            sysfs)
                if ((DRY_RUN)); then did "$key -> $val"; else echo "$val" >"$key" 2>/dev/null && did "$key -> $val"; fi
                ;;
            svc)
                read -r en act <<<"$val"
                [[ $key == supertune-* ]] && continue
                if ((DRY_RUN)); then
                    did "$key -> $en, $act"
                    continue
                fi
                [[ $en == enabled ]] && systemctl enable "$key" >/dev/null 2>&1
                [[ $en == disabled ]] && systemctl disable "$key" >/dev/null 2>&1
                [[ $act == active ]] && systemctl start "$key" >/dev/null 2>&1
                [[ $act != active ]] && systemctl stop "$key" >/dev/null 2>&1
                did "$key -> $en, $act"
                ;;
            ppd)
                if ((DRY_RUN)); then did "power profile -> $val"; else powerprofilesctl set "$val" 2>/dev/null && did "power profile -> $val"; fi
                ;;
            ring)
                if ((DRY_RUN)); then
                    did "$key rings -> $val"
                else
                    ethtool -G "$key" rx "${val% *}" tx "${val#* }" >/dev/null 2>&1 && did "$key rings -> $val"
                fi
                ;;
            rps)
                for f in /sys/class/net/"$key"/queues/rx-*; do
                    ((DRY_RUN)) && break
                    echo 0 >"$f/rps_cpus" 2>/dev/null
                    echo 0 >"$f/rps_flow_cnt" 2>/dev/null
                done
                did "$key RPS -> off"
                ;;
            esac
        done <"$STATE_FILE"
    else
        info "no saved state found - only removing files"
    fi

    # zram swap that supertune created is only emptied if RAM can take the data back
    if [[ -f /etc/systemd/system/supertune-zram.service ]] || grep -q '^zram|' "$STATE_FILE" 2>/dev/null; then
        if ((!DRY_RUN)); then
            systemctl disable supertune-zram.service >/dev/null 2>&1
            if zram_swap_active && ! zram_foreign; then
                local used avail
                used=$(awk '{print $1}' /sys/block/zram0/mm_stat 2>/dev/null)
                avail=$(awk '/^MemAvailable:/{print $2 * 1024}' /proc/meminfo)
                if ((${used:-0} < avail / 2)) && swapoff /dev/zram0 2>/dev/null; then
                    echo 1 >/sys/block/zram0/reset 2>/dev/null
                    did "zram swap removed"
                else
                    note "zram swap is still in use and will be gone after a reboot."
                fi
            fi
        else
            did "remove supertune zram swap"
        fi
    fi

    section "Removing supertune files"
    if ((DRY_RUN)); then
        did "remove route options (initcwnd/initrwnd/quickack)"
    else
        CWND="" RWND="" QUICKACK="" tune_routes
        has_systemd && systemctl disable --now supertune-net.timer >/dev/null 2>&1
    fi
    for f in /etc/sysctl.d/99-supertune-*.conf /etc/modules-load.d/99-supertune-*.conf /etc/tmpfiles.d/99-supertune-*.conf \
        /etc/modprobe.d/99-supertune.conf /etc/udev/rules.d/60-supertune-disk.rules /etc/udev/rules.d/99-supertune-cpu.rules \
        /etc/security/limits.d/99-supertune.conf /etc/systemd/system.conf.d/99-supertune.conf /etc/systemd/user.conf.d/99-supertune.conf \
        /etc/systemd/journald.conf.d/99-supertune.conf /etc/systemd/system/ssh.service.d/99-supertune.conf \
        /etc/systemd/system/sshd.service.d/99-supertune.conf /etc/systemd/system/supertune-zram.service \
        /etc/systemd/system/supertune-net.service /etc/systemd/system/supertune-net.timer \
        /etc/NetworkManager/dispatcher.d/90-supertune /etc/network/if-up.d/supertune \
        /etc/networkd-dispatcher/routable.d/50-supertune /etc/cron.d/supertune "$NET_HOOK" "$ZRAM_HELPER"; do
        remove_file "$f"
    done
    cleanup_legacy
    cleanup_ramtune
    if ((!DRY_RUN)); then
        rm -rf "$STATE_DIR"
        rmdir "$CONF_DIR" 2>/dev/null
        units_reload
        udevadm control --reload >/dev/null 2>&1
        sysctl --system >/dev/null 2>&1
        # swappiness above 100 only makes sense with zram
        if ! zram_swap_active && (($(cat /proc/sys/vm/swappiness) > 100)); then
            echo 60 >/proc/sys/vm/swappiness
        fi
    fi
    note "Reboot to bring every remaining live value back to the distro defaults."
}

###############################################################################
# Status
###############################################################################

show_status() {
    local f legacy=0 name
    echo "supertune $VERSION"
    printf '  %-20s %s\n' "Machine" "$(describe)"
    printf '  %-20s %s (%s)\n' "Profile" "$PROFILE" "$PROFILE_REASON"
    if [[ -f $STATE_FILE || -d $CONF_DIR ]] || compgen -G "/etc/sysctl.d/99-supertune-*.conf" >/dev/null; then
        printf '  %-20s %s\n' "Applied" "yes"
    else
        printf '  %-20s %s\n' "Applied" "no"
    fi
    for f in "${LEGACY_FILES[@]}" "${RAMTUNE_FILES[@]}" /etc/systemd/system/ramtune.service; do
        [[ -e $f ]] && legacy_owned "$f" && legacy=1
    done
    ((legacy)) && printf '  %-20s %s\n' "Old versions" "files from old supertune/tcptune/ramtune found - running supertune cleans them up"
    if zram_swap_active; then
        printf '  %-20s %s\n' "zram swap" "$(awk '/^\/dev\/zram/{printf "%s %d GB  ", $1, $3 / 1048576}' /proc/swaps)$(read_sel /sys/block/zram0/comp_algorithm)"
    else
        printf '  %-20s %s\n' "zram swap" "off"
    fi
    printf '  %-20s %s\n' "swappiness" "$(cat /proc/sys/vm/swappiness)"
    printf '  %-20s %s / %s\n' "TCP / qdisc" "$(cat /proc/sys/net/ipv4/tcp_congestion_control)" "$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
    printf '  %-20s %s\n' "CPU governor" "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
    if unit_exists irqbalance.service; then
        printf '  %-20s %s\n' "irqbalance" "$(systemctl is-active irqbalance 2>/dev/null)"
    else
        printf '  %-20s %s\n' "irqbalance" "not installed"
    fi
    printf '  %-20s %s\n' "Hugepages (THP)" "$(read_sel /sys/kernel/mm/transparent_hugepage/enabled || echo n/a)"
    printf '  %-20s %s\n' "Multi-Gen LRU" "$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || echo n/a)"
    for name in $(real_disks); do
        printf '  %-20s %s\n' "Disk $name" "$(disk_kind "$name"), $(read_sel "/sys/block/$name/queue/scheduler")"
    done
    if has_systemd; then
        printf '  %-20s %s:%s\n' "Service open files" "$(systemctl show -p DefaultLimitNOFILESoft --value 2>/dev/null)" "$(systemctl show -p DefaultLimitNOFILE --value 2>/dev/null)"
    fi
    printf '  %-20s %s\n' "Routes" "$(ip -o route show default 2>/dev/null | head -n1)"
}

###############################################################################
# Main
###############################################################################

summary() {
    local s
    echo
    if ((DRY_RUN)); then
        log "Dry run finished: $CHANGES change(s) would be made."
    else
        log "Done: $CHANGES change(s) made."
    fi
    if ((${#SKIPPED[@]})); then
        echo "  Skipped:"
        for s in "${SKIPPED[@]}"; do echo "    - $s"; done
    fi
    if ((${#PROBLEMS[@]})); then
        echo "  Problems:"
        for s in "${PROBLEMS[@]}"; do echo "    - $s"; done
    fi
    if ((${#NOTES[@]})); then
        echo "  Notes:"
        for s in "${NOTES[@]}"; do echo "    - $s"; done
    fi
}

main() {
    local m modules="" ran_network=0
    while (($#)); do
        case $1 in
        --dry-run | -n) DRY_RUN=1 ;;
        --status | -s) MODE=status ;;
        --undo | --revert | -r) MODE=undo ;;
        --profile | -p)
            FORCED_PROFILE=${2:-}
            shift
            ;;
        --profile=*) FORCED_PROFILE=${1#*=} ;;
        --only)
            ONLY=${2:-}
            shift
            ;;
        --only=*) ONLY=${1#*=} ;;
        --skip)
            SKIP=${2:-}
            shift
            ;;
        --skip=*) SKIP=${1#*=} ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) warn "Ignoring unknown option: $1" ;;
        esac
        shift
    done

    if [[ -n $FORCED_PROFILE && " $PROFILES " != *" $FORCED_PROFILE "* ]]; then
        err "Unknown profile '$FORCED_PROFILE'. Choose one of: $PROFILES"
        exit 1
    fi
    for m in ${ONLY//,/ } ${SKIP//,/ }; do
        if [[ " $ALL_MODULES " != *" $m "* ]]; then
            err "Unknown module '$m'. Modules: $ALL_MODULES"
            exit 1
        fi
    done

    detect
    if [[ $MODE == status ]]; then
        show_status
        exit 0
    fi
    if ((EUID != 0 && !DRY_RUN)); then
        err "This script must be run as root. Please run with sudo."
        err "(--dry-run and --status work without root and change nothing.)"
        exit 1
    fi
    if ((!DRY_RUN)) && command -v flock >/dev/null 2>&1; then
        exec 9>/run/supertune.lock
        if ! flock -n 9; then
            err "Another supertune run is in progress."
            exit 1
        fi
    fi

    echo "Supertune $VERSION"
    log "Machine: $(describe)"
    log "Profile: $PROFILE ($PROFILE_REASON)"
    ((DRY_RUN)) && warn "Dry run: nothing will be changed."

    if [[ $MODE == undo ]]; then
        do_undo
        summary
        exit 0
    fi

    for m in $ALL_MODULES; do
        [[ -n $ONLY && ",$ONLY," != *",$m,"* ]] && continue
        [[ ",$SKIP," == *",$m,"* ]] && continue
        modules+="$m "
    done

    section "Cleaning up files from older versions"
    m=$CHANGES
    cleanup_legacy
    ((CHANGES == m)) && info "nothing to clean up"

    for m in $modules; do
        "mod_$m"
        [[ $m == network ]] && ran_network=1
    done

    # Old versions left a 1520-packet initcwnd on the routes; clear it even if the network module didn't run
    if ((LEGACY_ROUTES && !ran_network && !DRY_RUN)); then
        CWND="" RWND="" QUICKACK="" tune_routes
    fi
    summary
}

[[ ${BASH_SOURCE[0]} == "$0" ]] && main "$@"
