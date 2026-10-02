#!/usr/bin/env bash
###############################################################################
# AMD Gaming & Ultra Low-Latency Hardware Tuning Script
# Target: AMD Ryzen CPU + AMD Radeon GPU Desktop Systems
# WARNING: Designed strictly for desktop PCs with proper cooling.
#          DO NOT USE ON LAPTOPS ON BATTERY (causes extreme heat and battery drain).
###############################################################################
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root. Please run with sudo."
    exit 1
fi

FORCE=0
REVERT=0
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=1 ;;
        --revert|-r) REVERT=1 ;;
    esac
done

###############################################################################
# Revert Logic
###############################################################################
if [[ $REVERT -eq 1 ]]; then
    echo "Reverting AMD Gaming Hardware Optimizations..."
    for card in /sys/class/drm/card[0-9]*/device; do
        [[ -f "$card/vendor" ]] || continue
        if [[ "$(cat "$card/vendor" 2>/dev/null)" == "0x1002" ]]; then
            [[ -w "$card/power_dpm_force_performance_level" ]] && echo "auto" > "$card/power_dpm_force_performance_level" 2>/dev/null || true
            log "Reset AMD GPU ($card) DPM level to auto."
        fi
    done

    for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        [[ -w "$epp" ]] && echo "balance_performance" > "$epp" 2>/dev/null || true
    done
    log "Reset AMD CPU EPP to balance_performance."

    for state in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do
        [[ -w "$state" ]] && echo 0 > "$state" 2>/dev/null || true
    done
    log "Re-enabled all CPU idle C-states."

    rm -f /etc/udev/rules.d/99-amd-gaming.rules
    udevadm control --reload-rules 2>/dev/null || true
    log "Reverted AMD Gaming hardware tweaks."
    exit 0
fi

echo -e "${CYAN}AMD Gaming & Ultra Low-Latency Tuning${NC}"

###############################################################################
# Safety & Hardware Detection
###############################################################################
IS_LAPTOP=0
if compgen -G "/sys/class/power_supply/BAT*" > /dev/null; then
    IS_LAPTOP=1
fi
if [[ -f /sys/class/dmi/id/chassis_type ]]; then
    CHASSIS=$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || echo 0)
    case "$CHASSIS" in
        8|9|10|11|14|31|32) IS_LAPTOP=1 ;;
    esac
fi

if [[ $IS_LAPTOP -eq 1 && $FORCE -eq 0 ]]; then
    warn "LAPTOP DETECTED: This script disables power savings and locks clocks."
    warn "Running this on battery will rapidly drain power and generate high heat."
    echo -n "Are you sure you want to proceed on this laptop? [y/N]: "
    read -r resp
    if [[ ! "$resp" =~ ^[yY](es)?$ ]]; then
        err "Aborted by user."
        exit 1
    fi
fi

IS_AMD_CPU=0
if grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
    IS_AMD_CPU=1
    log "Detected AMD CPU."
else
    warn "Non-AMD CPU detected. AMD-specific CPU P-State tweaks will be skipped."
fi

AMD_GPUS=()
for card in /sys/class/drm/card[0-9]*/device; do
    [[ -f "$card/vendor" ]] || continue
    if [[ "$(cat "$card/vendor" 2>/dev/null)" == "0x1002" ]]; then
        AMD_GPUS+=("$card")
    fi
done

if [[ ${#AMD_GPUS[@]} -gt 0 ]]; then
    log "Detected ${#AMD_GPUS[@]} AMD GPU(s)."
else
    warn "No AMD Radeon GPU detected. GPU-specific DPM clock locks will be skipped."
fi

###############################################################################
# 1. AMD GPU Clocks & Performance Level
###############################################################################
if [[ ${#AMD_GPUS[@]} -gt 0 ]]; then
    log "Tuning AMD GPU DPM & performance profiles..."
    for gpu in "${AMD_GPUS[@]}"; do
        # Force high performance DPM clock level
        if [[ -w "$gpu/power_dpm_force_performance_level" ]]; then
            echo "high" > "$gpu/power_dpm_force_performance_level" 2>/dev/null || true
            log "  → Set power_dpm_force_performance_level to high on $(basename "$(dirname "$gpu")")"
        fi

        # Select 3D fullscreen / VR / compute power profile mode if supported
        if [[ -w "$gpu/pp_power_profile_mode" ]]; then
            # Check available profiles in pp_power_profile_mode
            if grep -q "3D_FULL_SCREEN" "$gpu/pp_power_profile_mode" 2>/dev/null; then
                # Find profile ID for 3D_FULL_SCREEN
                PROFILE_ID=$(grep "3D_FULL_SCREEN" "$gpu/pp_power_profile_mode" | awk '{print $1}' | tr -d ':' | head -n1)
                if [[ -n "$PROFILE_ID" ]]; then
                    echo "$PROFILE_ID" > "$gpu/pp_power_profile_mode" 2>/dev/null || true
                    log "  → Activated 3D_FULL_SCREEN power profile mode ($PROFILE_ID)"
                fi
            elif grep -q "COMPUTE" "$gpu/pp_power_profile_mode" 2>/dev/null; then
                PROFILE_ID=$(grep "COMPUTE" "$gpu/pp_power_profile_mode" | awk '{print $1}' | tr -d ':' | head -n1)
                if [[ -n "$PROFILE_ID" ]]; then
                    echo "$PROFILE_ID" > "$gpu/pp_power_profile_mode" 2>/dev/null || true
                    log "  → Activated COMPUTE power profile mode ($PROFILE_ID)"
                fi
            fi
        fi
    done
fi

###############################################################################
# 2. AMD CPU & P-State Performance
###############################################################################
if [[ $IS_AMD_CPU -eq 1 ]]; then
    log "Tuning AMD CPU P-State & Boost..."

    # Enable CPU boost
    if [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
        echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
        log "  → AMD Core Performance Boost enabled."
    fi

    # Energy Performance Preference (EPP)
    EPP_COUNT=0
    for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        if [[ -w "$epp" ]]; then
            echo "performance" > "$epp" 2>/dev/null || true
            ((EPP_COUNT++))
        fi
    done
    [[ $EPP_COUNT -gt 0 ]] && log "  → Set Energy Performance Preference to 'performance' on $EPP_COUNT CPU cores."

    # Minimum frequency scaling pinning
    for min_f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_min_freq; do
        cpu_dir=$(dirname "$min_f")
        if [[ -f "$cpu_dir/cpuinfo_max_freq" && -w "$min_f" ]]; then
            MAX_F=$(cat "$cpu_dir/cpuinfo_max_freq")
            echo "$MAX_F" > "$min_f" 2>/dev/null || true
        fi
    done
    log "  → Scaled minimum CPU frequency to maximum capability."
fi

###############################################################################
# 3. CPU Idle & Deep C-State Latency Limiting
###############################################################################
log "Optimizing CPU sleep latency..."
# Disable C-states > state1 (C2/C3+) to prevent micro-stutters during frame rendering
DISABLED_STATES=0
for state in /sys/devices/system/cpu/cpu*/cpuidle/state[2-9]/disable; do
    if [[ -w "$state" ]]; then
        echo 1 > "$state" 2>/dev/null || true
        ((DISABLED_STATES++))
    fi
done
if [[ $DISABLED_STATES -gt 0 ]]; then
    log "  → Disabled deep C-states (C2+) on idle cores to eliminate wake-up latency."
fi

###############################################################################
# 4. Kernel / BORE Scheduler Tunables (CachyOS / Zen / BORE Kernels)
###############################################################################
if [[ -f /proc/sys/kernel/sched_bore ]]; then
    echo 1 > /proc/sys/kernel/sched_bore 2>/dev/null || true
    log "Configured BORE scheduler (sched_bore = 1)."
fi
if [[ -f /proc/sys/kernel/sched_burst_fork_atavistic ]]; then
    echo 1 > /proc/sys/kernel/sched_burst_fork_atavistic 2>/dev/null || true
    log "Configured sched_burst_fork_atavistic = 1."
fi

log "AMD Gaming & Low-Latency Hardware Tuning complete!"
warn "To revert these hardware clock locks and C-state settings, run: sudo $0 --revert"
