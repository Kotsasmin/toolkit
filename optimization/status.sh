#!/usr/bin/env bash

SCRIPT_DIR="$(cd -P "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
UI_LIB="$SCRIPT_DIR/../lib/ui.sh"
if [ -f "$UI_LIB" ]; then
    # shellcheck source=../lib/ui.sh
    source "$UI_LIB"
else
    BOLD='' DIM='' CYAN='' GREEN='' YELLOW='' RED='' MAGENTA='' BLUE='' NC=''
    ui_banner() { echo "System Status"; }
fi

DO_PING=1
DO_BLOAT=0
for arg in "$@"; do
    case $arg in
    --no-ping) DO_PING=0 ;;
    --bufferbloat) DO_BLOAT=1 ;;
    -h | --help)
        echo "Usage: status.sh [--no-ping] [--bufferbloat]"
        echo "  --no-ping       skip the latency checks"
        echo "  --bufferbloat   also run a ~10s bufferbloat test (downloads ~100MB)"
        exit 0
        ;;
    esac
done

N_SCRIPT=0 N_GOOD=0 N_FIX=0
LABEL_W=30

###############################################################################
# Output helpers
###############################################################################

section() {
    echo ""
    echo -e "${MAGENTA}${BOLD}━━ $1 ${NC}${DIM}$(printf '━%.0s' $(seq 1 $((52 - ${#1}))))${NC}"
}

# row STATE LABEL VALUE [DETAIL]   STATE: script | good | fix | info
row() {
    local state=$1 label=$2 value=${3:-} detail=${4:-} mark="  " dcol=$DIM
    case $state in
    script)
        mark="${GREEN}✓${NC} "
        N_SCRIPT=$((N_SCRIPT + 1))
        [[ -z $detail ]] && detail="set by toolkit"
        dcol=$GREEN
        ;;
    good)
        mark="${CYAN}✓${NC} "
        N_GOOD=$((N_GOOD + 1))
        [[ -z $detail ]] && detail="already good"
        dcol=$CYAN
        ;;
    fix)
        mark="${RED}✗${NC} "
        N_FIX=$((N_FIX + 1))
        dcol=$RED
        ;;
    esac
    if ((${#label} > LABEL_W)); then
        printf "  %b%s\n  %-$((LABEL_W + 2))s %b%s%b %b%s%b\n" "$mark" "$label" "" "$BOLD" "$value" "$NC" "$dcol" "$detail" "$NC"
    else
        printf "  %b%-${LABEL_W}s %b%s%b %b%s%b\n" "$mark" "$label" "$BOLD" "$value" "$NC" "$dcol" "$detail" "$NC"
    fi
}

info() { row info "$1" "${2:-}" "${3:-}"; }
sub() { echo -e "  ${BOLD}$*${NC}"; }

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN { split("B KB MB GB TB PB", u); i = 1; while (b >= 1024 && i < 6) { b /= 1024; i++ } printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'
}
human_kb() { human_bytes $((${1:-0} * 1024)); }

readf() { cat "$1" 2>/dev/null; }

# Friendly names for the tweaks supertune checks
declare -A NAMES=(
    [vm.swappiness]="Swappiness"
    [vm.page-cluster]="Swap read-ahead (page-cluster)"
    [vm.vfs_cache_pressure]="File cache pressure"
    [vm.watermark_boost_factor]="Watermark boost"
    [vm.watermark_scale_factor]="Watermark scale"
    [vm.dirty_bytes]="Dirty write limit"
    [vm.dirty_background_bytes]="Background write start"
    [vm.min_free_kbytes]="Free memory reserve"
    [vm.max_map_count]="Max memory maps (games)"
    [net.ipv4.tcp_congestion_control]="TCP congestion control"
    [net.core.default_qdisc]="Default queue discipline"
    [net.core.rmem_max]="Max socket receive buffer"
    [net.core.wmem_max]="Max socket send buffer"
    [net.ipv4.tcp_rmem]="TCP receive buffer"
    [net.ipv4.tcp_wmem]="TCP send buffer"
    [net.ipv4.tcp_fastopen]="TCP Fast Open"
    [net.ipv4.tcp_mtu_probing]="MTU probing"
    [net.ipv4.tcp_slow_start_after_idle]="Slow start after idle"
    [net.ipv4.tcp_tw_reuse]="TIME_WAIT reuse"
    [net.ipv4.tcp_fin_timeout]="FIN timeout"
    [net.ipv4.tcp_keepalive_time]="Keepalive time"
    [net.ipv4.tcp_keepalive_intvl]="Keepalive interval"
    [net.ipv4.tcp_keepalive_probes]="Keepalive probes"
    [net.ipv4.tcp_syncookies]="SYN cookies"
    [net.ipv4.tcp_no_metrics_save]="Don't cache old TCP metrics"
    [net.core.netdev_max_backlog]="NIC input backlog"
    [net.core.somaxconn]="Listen queue size"
    [net.ipv4.tcp_max_syn_backlog]="SYN backlog"
    [net.ipv4.tcp_max_tw_buckets]="TIME_WAIT bucket limit"
    [net.core.netdev_budget]="NIC poll budget"
    [net.core.netdev_budget_usecs]="NIC poll budget (µs)"
    [net.ipv4.tcp_notsent_lowat]="Unsent data low-water mark"
    [net.ipv4.udp_rmem_min]="UDP min receive buffer"
    [net.ipv4.udp_wmem_min]="UDP min send buffer"
    [net.core.rmem_default]="Default receive buffer"
    [net.core.wmem_default]="Default send buffer"
    [net.netfilter.nf_conntrack_max]="Conntrack table size"
    [net.netfilter.nf_conntrack_tcp_timeout_established]="Conntrack idle timeout"
    [net.netfilter.nf_conntrack_tcp_timeout_time_wait]="Conntrack TIME_WAIT timeout"
    [net.core.rps_sock_flow_entries]="RPS flow table"
    [fs.nr_open]="Max open files per process"
    [fs.file-max]="Max open files (system)"
    [fs.inotify.max_user_watches]="File watchers (inotify)"
    [fs.inotify.max_user_instances]="Inotify instances"
    [kernel.pid_max]="Max process IDs"
    [kernel.sched_autogroup_enabled]="Scheduler autogroup"
    [kernel.nmi_watchdog]="NMI watchdog"
    [kernel.split_lock_mitigate]="Split-lock slowdown"
    [kernel.panic]="Reboot after kernel panic (s)"
)

###############################################################################
# Collect: supertune report, latency pings (in the background while we read the rest)
###############################################################################

REPORT_LINES=()
PROFILE="" PROFILE_REASON="" MACHINE="" APPLIED=""
if [[ -f $SCRIPT_DIR/supertune.sh ]]; then
    while IFS= read -r line; do
        case $line in
        P\|*) IFS='|' read -r _ PROFILE PROFILE_REASON MACHINE <<<"$line" ;;
        A\|*) APPLIED=${line#A|} ;;
        R\|*) REPORT_LINES+=("$line") ;;
        esac
    done < <(bash "$SCRIPT_DIR/supertune.sh" --report 2>/dev/null)
fi

# report_rows MODULE...: prints every tweak supertune checked in these modules
report_rows() {
    local line mod state label value detail m
    for line in "${REPORT_LINES[@]}"; do
        IFS='|' read -r _ mod state label value detail <<<"$line"
        for m in "$@"; do
            [[ $mod == "$m" ]] || continue
            [[ -n ${NAMES[$label]:-} ]] && label="${NAMES[$label]}"
            label="${label^}"
            if [[ $state == info ]]; then
                if [[ -n $value ]]; then
                    row info "$label" "$value" "$detail"
                else
                    echo -e "    ${DIM}· $label${NC}"
                fi
            else
                row "$state" "$label" "$value" "$detail"
            fi
        done
    done
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

GATEWAY=$(ip -4 route show default 2>/dev/null | awk '/default/{for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit }}')
if ((DO_PING)) && command -v ping &>/dev/null; then
    [[ -n $GATEWAY ]] && ping -n -q -c 10 -i 0.2 -W 1 "$GATEWAY" >"$TMP/ping_gw" 2>&1 &
    ping -n -q -c 10 -i 0.2 -W 1 1.1.1.1 >"$TMP/ping_net" 2>&1 &
fi

# CPU usage: two /proc/stat samples half a second apart
read -r _ u1 n1 s1 i1 w1 x1 y1 z1 _ </proc/stat
sleep 0.5
read -r _ u2 n2 s2 i2 w2 x2 y2 z2 _ </proc/stat
CPU_BUSY=$(((u2 + n2 + s2 + x2 + y2 + z2) - (u1 + n1 + s1 + x1 + y1 + z1)))
CPU_ALL=$((CPU_BUSY + (i2 + w2) - (i1 + w1)))
CPU_USAGE=$((CPU_ALL > 0 ? CPU_BUSY * 100 / CPU_ALL : 0))

###############################################################################
# Sections
###############################################################################

sec_system() {
    section "System"
    local os host kernel up init de pkgs
    os=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-$NAME}")
    host="$(readf /sys/class/dmi/id/sys_vendor) $(readf /sys/class/dmi/id/product_name)"
    [[ $host == " " ]] && host=$(readf /sys/firmware/devicetree/base/model | tr -d '\0')
    kernel=$(uname -r)
    up=$(awk '{d = int($1 / 86400); h = int($1 % 86400 / 3600); m = int($1 % 3600 / 60); printf "%s%dh %dm", (d ? d "d " : ""), h, m}' /proc/uptime)
    init=$(ps -p 1 -o comm= 2>/dev/null)
    de="${XDG_CURRENT_DESKTOP:-none}${XDG_SESSION_TYPE:+ ($XDG_SESSION_TYPE)}"
    if command -v pacman &>/dev/null; then
        pkgs="$(pacman -Qq 2>/dev/null | wc -l) (pacman)"
    elif command -v dpkg-query &>/dev/null; then
        pkgs="$(dpkg-query -f '.\n' -W 2>/dev/null | wc -l) (dpkg)"
    elif command -v rpm &>/dev/null; then
        pkgs="$(rpm -qa 2>/dev/null | wc -l) (rpm)"
    fi
    command -v flatpak &>/dev/null && pkgs+=", $(flatpak list 2>/dev/null | wc -l) (flatpak)"

    info "OS" "$os"
    info "Host" "${host:-unknown}"
    info "Kernel" "$kernel" "$(uname -v | grep -oE 'PREEMPT[_A-Z]*' | head -1)"
    info "Uptime" "$up"
    info "Init" "${init:-unknown}"
    info "Desktop" "$de"
    [[ -n $pkgs ]] && info "Packages" "$pkgs"
    info "Shell" "$(basename "${SHELL:-unknown}")"
    if [[ -n $PROFILE ]]; then
        info "Machine type" "$PROFILE" "$PROFILE_REASON"
        if [[ $APPLIED == yes ]]; then
            row script "Supertune" "applied"
        else
            row info "Supertune" "not applied" "run Full Supertune to tune this machine"
        fi
    fi

    # sched_ext schedulers (installed by the toolkit's SCX option, or by the distro)
    local scx_state scx_ops
    scx_state=$(readf /sys/kernel/sched_ext/state)
    if [[ -n $scx_state ]]; then
        scx_ops=$(readf /sys/kernel/sched_ext/root/ops)
        if [[ $scx_state == enabled ]]; then
            info "sched_ext scheduler" "${scx_ops:-enabled}" "running"
        else
            info "sched_ext scheduler" "not running" "kernel supports it, see the SCX options"
        fi
    fi
    [[ -r /proc/sys/kernel/sched_bore ]] && info "BORE scheduler" "$([[ $(readf /proc/sys/kernel/sched_bore) == 1 ]] && echo on || echo off)"

    sub "Kernel & limits tweaks"
    report_rows system limits cleanup
    info "Open files (this shell)" "soft $(ulimit -Sn), hard $(ulimit -Hn)"
}

sec_cpu() {
    section "CPU"
    local model cores threads sockets mhz_cur mhz_max driver epp temp load mc vuln off smt f
    model=$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)
    [[ -z $model ]] && model=$(lscpu 2>/dev/null | awk -F': +' '/^Model name/{print $2; exit}')
    threads=$(grep -c '^processor' /proc/cpuinfo)
    cores=$(awk -F': ' '/^core id/{c[$2]} /^physical id/{p[$2]} END{n = length(c) * (length(p) ? length(p) : 1); print n}' /proc/cpuinfo)
    sockets=$(awk -F': ' '/^physical id/{p[$2]} END{print length(p)}' /proc/cpuinfo)
    info "Model" "${model:-unknown}"
    info "Cores / threads" "${cores:-?} / $threads${sockets:+$( ((sockets > 1)) && echo ", $sockets sockets")}"
    smt=$(readf /sys/devices/system/cpu/smt/control)
    [[ -n $smt ]] && info "SMT / Hyper-threading" "$smt"

    mhz_cur=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null | awk '{s += $1; n++} END{if (n) printf "%.0f", s / n / 1000}')
    mhz_max=$(awk '{printf "%.0f", $1 / 1000}' /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
    [[ -n $mhz_cur ]] && info "Clock (avg / max)" "$mhz_cur MHz / ${mhz_max:-?} MHz"
    driver=$(readf /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)
    [[ -n $driver ]] && info "Frequency driver" "$driver"
    epp=$(readf /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference)
    [[ -n $epp ]] && info "Energy preference (EPP)" "$epp" "AMD Gaming tune sets this to performance"
    info "Usage" "${CPU_USAGE}%" "load $(cut -d' ' -f1-3 /proc/loadavg)"

    for f in /sys/class/hwmon/hwmon*; do
        case $(readf "$f/name") in
        k10temp | coretemp | zenpower | cpu_thermal | soc_thermal)
            temp=$(awk '{printf "%.1f °C", $1 / 1000}' "$f/temp1_input" 2>/dev/null)
            break
            ;;
        esac
    done
    [[ -z $temp ]] && temp=$(awk '{printf "%.1f °C", $1 / 1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    [[ -n $temp ]] && info "Temperature" "$temp"

    mc=$(awk -F': ' '/^microcode/{print $2; exit}' /proc/cpuinfo)
    [[ -n $mc ]] && info "Microcode" "$mc"
    vuln=0 off=0
    for f in /sys/devices/system/cpu/vulnerabilities/*; do
        [[ -r $f ]] || continue
        case $(readf "$f") in
        Vulnerable*) vuln=$((vuln + 1)) ;;
        "Not affected") ;;
        *) off=$((off + 1)) ;;
        esac
    done
    info "Security mitigations" "$off active, $vuln vulnerable" "$(grep -oE 'mitigations=[a-z,]+' /proc/cmdline)"
    grep -qE '\b(svm|vmx)\b' /proc/cpuinfo && info "Virtualization (VT-x/AMD-V)" "supported"

    local states disabled=0 total=0
    for f in /sys/devices/system/cpu/cpu0/cpuidle/state*/disable; do
        [[ -r $f ]] || continue
        total=$((total + 1))
        [[ $(readf "$f") == 1 ]] && disabled=$((disabled + 1))
    done
    if ((total)); then
        states=$(cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name 2>/dev/null | tr '\n' ' ')
        info "Idle states (C-states)" "$((total - disabled))/$total enabled" "$states"
    fi

    sub "CPU tweaks"
    report_rows cpu irq
}

sec_memory() {
    section "Memory"
    local total avail used swap_t swap_f dev orig compr psi hp hpsize ksm
    total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    used=$((total - avail))
    info "RAM" "$(human_kb $used) / $(human_kb "$total")" "$((used * 100 / total))% used, $(human_kb "$avail") available"
    swap_t=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
    swap_f=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
    if ((swap_t > 0)); then
        info "Swap" "$(human_kb $((swap_t - swap_f))) / $(human_kb "$swap_t") used"
        while read -r dev type size usedk prio; do
            info "  $dev" "$type, $(human_kb "$size")" "priority $prio, $(human_kb "$usedk") used"
        done < <(awk 'NR > 1 {print $1, $2, $3, $4, $5}' /proc/swaps)
    else
        info "Swap" "none"
    fi
    if [[ -r /sys/block/zram0/mm_stat ]]; then
        read -r orig compr _ </sys/block/zram0/mm_stat
        ((compr > 0)) && info "zram compression" "$(human_bytes "$orig") -> $(human_bytes "$compr")" "ratio $(awk -v a="$orig" -v b="$compr" 'BEGIN{printf "%.1fx", a / b}')"
    fi
    hp=$(readf /proc/sys/vm/nr_hugepages)
    hpsize=$(awk '/^Hugepagesize:/{print $2}' /proc/meminfo)
    if ((${hp:-0} > 0)); then
        if [[ -f /etc/sysctl.d/99-hugepages.conf ]]; then
            row script "Static hugepages" "$hp x $(human_kb "$hpsize")" "set by toolkit (hugepages option)"
        else
            info "Static hugepages" "$hp x $(human_kb "$hpsize")"
        fi
    else
        info "Static hugepages" "none" "the hugepages option reserves them for Minecraft/JVM"
    fi
    ksm=$(readf /sys/kernel/mm/ksm/run)
    [[ -n $ksm ]] && info "KSM (page merging)" "$([[ $ksm == 1 ]] && echo on || echo off)"
    psi=$(awk '/^some/{split($2, a, "="); print a[2]}' /proc/pressure/memory 2>/dev/null)
    [[ -n $psi ]] && info "Memory pressure (10s)" "${psi}%" "time tasks waited for memory"

    sub "Memory tweaks"
    report_rows memory
}

sec_disks() {
    section "Disks"
    local d n model size rot kind ra temp f
    for d in /sys/block/*; do
        n=${d##*/}
        case $n in loop* | ram* | zram* | dm-* | md* | sr* | fd* | nbd* | zd*) continue ;; esac
        [[ -f $d/queue/scheduler ]] || continue
        model=$(readf "$d/device/model" | xargs)
        size=$(($(readf "$d/size") * 512))
        rot=$(readf "$d/queue/rotational")
        if [[ $n == nvme* ]]; then kind=NVMe; elif [[ $rot == 0 ]]; then kind=SSD; else kind=HDD; fi
        ra=$(readf "$d/queue/read_ahead_kb")
        temp=""
        for f in "$d"/device/hwmon*/temp1_input "$d"/device/device/hwmon/hwmon*/temp1_input; do
            [[ -r $f ]] && temp=$(awk '{printf ", %.0f °C", $1 / 1000}' "$f") && break
        done
        info "$n" "${model:-unknown} ($kind)" "$(human_bytes $size), read-ahead ${ra} KB${temp}"
    done
    sub "Filesystems"
    while read -r src fstype sz usedb pct target; do
        info "$target" "$fstype, $pct used" "$(human_bytes $((usedb * 1024))) / $(human_bytes $((sz * 1024))) on $src"
    done < <(df -kP -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs -x fuse.portal 2>/dev/null | awk 'NR > 1 && !seen[$1]++ {print $1, "-", $2, $3, $5, $6}' | while read -r src _ sz u p t; do
        echo "$src $(findmnt -no FSTYPE "$t" 2>/dev/null | head -1) $sz $u $p $t"
    done)
    local opts
    opts=$(findmnt -no OPTIONS / 2>/dev/null)
    if [[ -n $opts ]]; then
        if [[ $opts == *noatime* ]]; then info "Root access times" "noatime"; else info "Root access times" "$(grep -oE 'relatime|strictatime' <<<"$opts" || echo atime)" "noatime saves a few writes, set it in /etc/fstab if you like"; fi
    fi
    local psi
    psi=$(awk '/^some/{split($2, a, "="); print a[2]}' /proc/pressure/io 2>/dev/null)
    [[ -n $psi ]] && info "I/O pressure (10s)" "${psi}%" "time tasks waited for disks"

    sub "Disk tweaks"
    report_rows disk
}

sec_gpu() {
    local card found=0 vendor name drv lvl prof vram vused temp power busy
    for card in /sys/class/drm/card[0-9]; do
        [[ -e $card/device/vendor ]] || continue
        ((found)) || section "GPU"
        found=1
        vendor=$(readf "$card/device/vendor")
        drv=$(basename "$(readlink -f "$card/device/driver" 2>/dev/null)")
        name=""
        if command -v lspci &>/dev/null; then
            name=$(lspci -s "$(basename "$(readlink -f "$card/device")")" 2>/dev/null | sed -E 's/^[^:]+:[^:]+: //')
        fi
        info "${card##*/}" "${name:-vendor $vendor}" "driver ${drv:-none}"
        vram=$(readf "$card/device/mem_info_vram_total")
        vused=$(readf "$card/device/mem_info_vram_used")
        [[ -n $vram ]] && info "  VRAM" "$(human_bytes "$vused") / $(human_bytes "$vram")"
        busy=$(readf "$card/device/gpu_busy_percent")
        [[ -n $busy ]] && info "  Usage" "$busy%"
        for f in "$card"/device/hwmon/hwmon*; do
            temp=$(awk '{printf "%.0f °C", $1 / 1000}' "$f/temp1_input" 2>/dev/null)
            power=$(awk '{printf "%.0f W", $1 / 1000000}' "$f/power1_average" 2>/dev/null || awk '{printf "%.0f W", $1 / 1000000}' "$f/power1_input" 2>/dev/null)
            [[ -n $temp ]] && info "  Temperature / power" "$temp${power:+ / $power}"
            break
        done
        lvl=$(readf "$card/device/power_dpm_force_performance_level")
        [[ -n $lvl ]] && info "  Power level" "$lvl" "AMD Gaming tune sets 'high'"
        prof=$(grep -E '\*' "$card/device/pp_power_profile_mode" 2>/dev/null | awk '{print $2}' | tr -d '*:' | head -1)
        [[ -n $prof ]] && info "  Power profile" "$prof"
    done
    if command -v nvidia-smi &>/dev/null; then
        ((found)) || section "GPU"
        nvidia-smi --query-gpu=name,driver_version,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null |
            while IFS=', ' read -r name drv busy vused vram temp power; do
                info "NVIDIA" "$name" "driver $drv"
                info "  Usage / VRAM" "$busy% / $vused of $vram MiB"
                info "  Temperature / power" "$temp °C / $power W"
            done
    fi
}

ping_summary() {
    # "rtt min/avg/max/mdev = 1.1/2.2/3.3/0.4 ms" and the loss line
    local f=$1 loss rtt
    [[ -s $f ]] || return 1
    loss=$(grep -oE '[0-9.]+% packet loss' "$f" | cut -d% -f1)
    rtt=$(awk -F'[ =/]+' '/^(rtt|round-trip)/{printf "%.1f ± %.1f ms", $7, $9}' "$f")
    echo "${rtt:-no reply}|${loss:-100}"
}

sec_network() {
    section "Network"
    local p n state speed duplex mtu drv kind addr q wifi
    for p in /sys/class/net/*; do
        n=${p##*/}
        [[ $n == lo ]] && continue
        [[ -e $p/device ]] || [[ $n == wg* || $n == tun* || $n == tailscale* ]] || continue
        state=$(readf "$p/operstate")
        mtu=$(readf "$p/mtu")
        drv=$(basename "$(readlink -f "$p/device/driver" 2>/dev/null)")
        if [[ -e $p/wireless || -e $p/phy80211 ]]; then kind="Wi-Fi"; elif [[ -e $p/device ]]; then kind="Ethernet"; else kind="VPN/tunnel"; fi
        speed=$(readf "$p/speed")
        duplex=$(readf "$p/duplex")
        addr=$(ip -o -4 addr show dev "$n" 2>/dev/null | awk '{print $4}' | head -1)
        q=$(tc qdisc show dev "$n" root 2>/dev/null | awk 'NR == 1 {print $2}')
        local detail="$state"
        [[ -n $speed && $speed != -1 && $state == up ]] && detail+=", ${speed} Mbit/s ${duplex}"
        info "$n" "$kind${drv:+ ($drv)}" "$detail"
        [[ -n $addr ]] && info "  IPv4" "$addr"
        info "  MTU" "$mtu" "$( ((mtu > 1500)) && echo "jumbo frames" || echo "standard (jumbo frames are not changed by the toolkit)")"
        [[ -n $q ]] && info "  Queue discipline" "$q"
        if [[ $kind == Wi-Fi ]] && command -v iw &>/dev/null; then
            wifi=$(iw dev "$n" link 2>/dev/null | awk -F': ' '/SSID/{s = $2} /signal/{g = $2} /tx bitrate/{split($2, b, " "); r = b[1] " " b[2]} END{if (s) print s "|" g "|" r}')
            if [[ -n $wifi ]]; then
                IFS='|' read -r ssid signal rate <<<"$wifi"
                info "  Wi-Fi" "$ssid" "signal $signal, link $rate"
            fi
        fi
    done
    [[ -n $GATEWAY ]] && info "Default gateway" "$GATEWAY"
    local dns
    if command -v resolvectl &>/dev/null; then
        dns=$(resolvectl dns 2>/dev/null | awk -F': ' 'NF > 1 && $2 != "" {print $2}' | tr '\n' ' ' | xargs)
    fi
    [[ -z $dns ]] && dns=$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')
    info "DNS servers" "${dns:-unknown}"
    info "Congestion controls" "$(readf /proc/sys/net/ipv4/tcp_available_congestion_control)" "available"
    info "ECN" "$(case $(readf /proc/sys/net/ipv4/tcp_ecn) in 0) echo off ;; 1) echo on ;; 2) echo "only when asked" ;; esac)"
    info "IPv6" "$([[ $(readf /proc/sys/net/ipv6/conf/all/disable_ipv6) == 1 ]] && echo disabled || echo enabled)"

    # Latency (pings started at the beginning)
    if ((DO_PING)); then
        wait
        sub "Latency"
        local res rtt loss
        if res=$(ping_summary "$TMP/ping_gw"); then
            IFS='|' read -r rtt loss <<<"$res"
            info "Router ($GATEWAY)" "$rtt" "${loss}% loss"
        fi
        if res=$(ping_summary "$TMP/ping_net"); then
            IFS='|' read -r rtt loss <<<"$res"
            info "Internet (1.1.1.1)" "$rtt" "${loss}% loss"
        fi
        ((DO_BLOAT)) && bufferbloat_test
    fi

    # Counters since boot
    sub "Traffic since boot"
    local out_segs retrans in_err rcvbuf
    read -r out_segs retrans < <(awk '/^Tcp:/{if (!h) {for (i = 1; i <= NF; i++) k[i] = $i; h = 1} else {for (i = 1; i <= NF; i++) v[k[i]] = $i}} END{print v["OutSegs"], v["RetransSegs"]}' /proc/net/snmp)
    ((out_segs > 0)) && info "TCP retransmissions" "$(awk -v r="$retrans" -v o="$out_segs" 'BEGIN{printf "%.2f%%", r * 100 / o}')" "$retrans of $out_segs segments (under 1% is healthy)"
    read -r in_err rcvbuf < <(awk '/^Udp:/{if (!h) {for (i = 1; i <= NF; i++) k[i] = $i; h = 1} else {for (i = 1; i <= NF; i++) v[k[i]] = $i}} END{print v["InErrors"] + 0, v["RcvbufErrors"] + 0}' /proc/net/snmp)
    info "UDP receive errors" "$in_err" "$rcvbuf dropped because a buffer was full"
    local estab
    estab=$(ss -Htn state established 2>/dev/null | wc -l)
    info "Open TCP connections" "$estab established"
    if [[ -r /proc/sys/net/netfilter/nf_conntrack_count ]]; then
        local c m
        c=$(readf /proc/sys/net/netfilter/nf_conntrack_count)
        m=$(readf /proc/sys/net/netfilter/nf_conntrack_max)
        info "Conntrack table" "$c / $m" "$((c * 100 / (m > 0 ? m : 1)))% full"
    fi

    tcp_connections

    sub "Network tweaks"
    report_rows network
}

# The busiest TCP connections with the same numbers a Minecraft F3 network overlay shows:
# RTT, MSS, congestion control, pacing, CWND, buffers, retransmits.
tcp_connections() {
    command -v ss &>/dev/null || return
    local lines
    lines=$(ss -Htinm state established 2>/dev/null | awk '
        /^[0-9]/ || /^\[/ { if (peer != "") print out; split($0, f, " "); local = f[3]; peer = f[4]; out = peer " " local; next }
        { out = out " " $0 }
        END { if (peer != "") print out }' |
        grep -vE '^(127\.|\[::1\]|\[::ffff:127\.)' |
        awk '{ b = 0; if (match($0, /bytes_acked:[0-9]+/)) b += substr($0, RSTART + 12, RLENGTH - 12); if (match($0, /bytes_received:[0-9]+/)) b += substr($0, RSTART + 15, RLENGTH - 15); print b "\t" $0 }' |
        sort -rn | head -n 5 | cut -f2-)
    [[ -n $lines ]] || return
    sub "Busiest TCP connections"
    local l peer cc rtt mss advmss cwnd pacing retr lost unacked sb rb sent recv
    while IFS= read -r l; do
        peer=${l%% *}
        cc=$(grep -oE ' (cubic|bbr[0-9]?|reno|vegas|westwood|htcp|dctcp|bic|illinois|hybla|lp|veno|yeah|scalable|highspeed|nv|cdg) ' <<<" $l " | head -1 | xargs)
        rtt=$(grep -oE 'rtt:[0-9.]+/[0-9.]+' <<<"$l" | head -1 | awk -F'[:/]' '{printf "%.1f ± %.1f ms", $2, $3}')
        mss=$(grep -oE '(^| )mss:[0-9]+' <<<"$l" | head -1 | cut -d: -f2)
        advmss=$(grep -oE 'advmss:[0-9]+' <<<"$l" | cut -d: -f2)
        cwnd=$(grep -oE 'cwnd:[0-9]+' <<<"$l" | cut -d: -f2)
        pacing=$(grep -oE 'pacing_rate [0-9.]+[KMG]?bps' <<<"$l" | cut -d' ' -f2 | awk '{
            v = $1 + 0; if ($1 ~ /Kbps/) v *= 1e3; else if ($1 ~ /Mbps/) v *= 1e6; else if ($1 ~ /Gbps/) v *= 1e9
            printf "%.1f MB/s", v / 8 / 1e6 }')
        retr=$(grep -oE 'retrans:[0-9]+/[0-9]+' <<<"$l" | cut -d/ -f2)
        lost=$(grep -oE 'lost:[0-9]+' <<<"$l" | cut -d: -f2)
        unacked=$(grep -oE 'unacked:[0-9]+' <<<"$l" | cut -d: -f2)
        sb=$(grep -oE 'tb[0-9]+' <<<"$l" | head -1 | tr -d tb)
        rb=$(grep -oE 'rb[0-9]+' <<<"$l" | head -1 | tr -d rb)
        sent=$(grep -oE 'bytes_acked:[0-9]+' <<<"$l" | cut -d: -f2)
        recv=$(grep -oE 'bytes_received:[0-9]+' <<<"$l" | cut -d: -f2)
        echo -e "  ${CYAN}${peer}${NC} ${DIM}↑$(human_bytes "${sent:-0}") ↓$(human_bytes "${recv:-0}")${NC}"
        printf "      %-8s %s\n" "RTT" "${rtt:-?}"
        printf "      %-8s %s\n" "MSS" "${mss:-?}${advmss:+ (adv $advmss)}"
        printf "      %-8s %s\n" "CC" "${cc:-?}${pacing:+, pace $pacing}"
        [[ -n $cwnd && -n $mss ]] && printf "      %-8s %s\n" "CWND" "$cwnd packets ($(human_bytes $((cwnd * mss))))"
        printf "      %-8s %s\n" "Buffers" "send $(human_bytes "${sb:-0}"), receive $(human_bytes "${rb:-0}")"
        printf "      %-8s %s\n" "Retx" "${retr:-0} retransmitted, ${lost:-0} lost, ${unacked:-0} unacked"
    done <<<"$lines"
}

# Measures how much latency rises while the connection is busy downloading.
bufferbloat_test() {
    command -v curl &>/dev/null || {
        info "Bufferbloat" "skipped" "needs curl"
        return
    }
    local idle loaded diff grade
    idle=$(ping -n -q -c 5 -i 0.2 -W 1 1.1.1.1 2>/dev/null | awk -F'[ =/]+' '/^(rtt|round-trip)/{print $7}')
    [[ -n $idle ]] || return
    echo -e "    ${DIM}· measuring bufferbloat for ~10s...${NC}"
    (for _ in 1 2 3 4; do curl -s -o /dev/null --max-time 10 "https://speed.cloudflare.com/__down?bytes=25000000" & done; wait) &
    local dl=$!
    sleep 1
    loaded=$(ping -n -q -c 20 -i 0.3 -W 1 1.1.1.1 2>/dev/null | awk -F'[ =/]+' '/^(rtt|round-trip)/{print $7}')
    kill "$dl" 2>/dev/null
    pkill -P "$dl" curl 2>/dev/null
    wait "$dl" 2>/dev/null
    [[ -n $loaded ]] || return
    diff=$(awk -v a="$loaded" -v b="$idle" 'BEGIN{d = a - b; printf "%.0f", (d < 0 ? 0 : d)}')
    if ((diff < 5)); then grade=A+; elif ((diff < 30)); then grade=A; elif ((diff < 60)); then grade=B; elif ((diff < 200)); then grade=C; elif ((diff < 400)); then grade=D; else grade=F; fi
    info "Bufferbloat (download)" "grade $grade" "+${diff} ms under load (idle ${idle} ms, loaded ${loaded} ms); usually fixed on the router (SQM/cake)"
}

sec_power() {
    local b found=0 cap status full design prof
    for b in /sys/class/power_supply/*; do
        [[ $(readf "$b/type") == Battery && $(readf "$b/scope") != Device ]] || continue
        ((found)) || section "Power"
        found=1
        cap=$(readf "$b/capacity")
        status=$(readf "$b/status")
        full=$(readf "$b/energy_full")
        design=$(readf "$b/energy_full_design")
        [[ -z $full ]] && full=$(readf "$b/charge_full") design=$(readf "$b/charge_full_design")
        info "Battery ${b##*/}" "${cap}% ($status)" "$( ((${design:-0} > 0)) && echo "health $((full * 100 / design))%")"
    done
    if command -v powerprofilesctl &>/dev/null; then
        prof=$(powerprofilesctl get 2>/dev/null)
        if [[ -n $prof ]]; then
            ((found)) || section "Power"
            found=1
            info "Power profile" "$prof"
        fi
    fi
}

summary() {
    echo ""
    echo -e "${DIM}$(printf '━%.0s' $(seq 1 56))${NC}"
    echo -e "  ${GREEN}✓ $N_SCRIPT set by toolkit${NC}   ${CYAN}✓ $N_GOOD already good${NC}   ${RED}✗ $N_FIX can be improved${NC}"
    if ((N_FIX > 0)); then
        echo -e "  ${BOLD}Fix the ✗ items with:${NC} toolkit optimize supertune ${DIM}(or Optimization → Full Supertune)${NC}"
        echo -e "  ${DIM}See exactly what would change first: toolkit optimize supertune --dry-run${NC}"
    else
        echo -e "  ${GREEN}${BOLD}Everything the toolkit can tune is already tuned.${NC}"
    fi
}

if declare -f ui_banner >/dev/null; then ui_banner "System Status"; fi
echo -e "  ${GREEN}✓${NC} set by toolkit   ${CYAN}✓${NC} already good   ${RED}✗${NC} toolkit can improve it   ${DIM}no mark = info only${NC}"
sec_system
sec_cpu
sec_memory
sec_disks
sec_gpu
sec_network
sec_power
summary
