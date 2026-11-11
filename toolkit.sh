#!/usr/bin/env bash
#
# Toolkit launcher: interactive menu and command line for every script in this repo.
# Created by Kotsasmin - https://kotsasmin.net

set -uo pipefail

# Follow symlinks (e.g. /usr/bin/toolkit or ~/.local/bin/toolkit) back to the real folder.
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
TOOLKIT_ROOT="$(cd -P "$(dirname "$SOURCE")" && pwd)"

if [ ! -f "$TOOLKIT_ROOT/lib/ui.sh" ]; then
    echo "[✗] Missing $TOOLKIT_ROOT/lib/ui.sh, the toolkit install is incomplete." >&2
    exit 1
fi
# shellcheck source=lib/ui.sh
source "$TOOLKIT_ROOT/lib/ui.sh"

MEDIA_DIR="$TOOLKIT_ROOT/media"
OPT_DIR="$TOOLKIT_ROOT/optimization"
SEC_DIR="$TOOLKIT_ROOT/security"
PTERO_DIR="$TOOLKIT_ROOT/ptero"

# Packages write a VERSION file; a git checkout works it out from the history.
toolkit_version() {
    if [ -f "$TOOLKIT_ROOT/VERSION" ]; then
        head -n1 "$TOOLKIT_ROOT/VERSION"
    elif git -C "$TOOLKIT_ROOT" rev-parse --git-dir &>/dev/null; then
        printf "r%s.%s" "$(git -C "$TOOLKIT_ROOT" rev-list --count HEAD)" "$(git -C "$TOOLKIT_ROOT" rev-parse --short=7 HEAD)"
    else
        echo "unknown"
    fi
}
TOOLKIT_VERSION="$(toolkit_version)"

show_banner() {
    ui_banner
    echo -e "${DIM}       Version ${TOOLKIT_VERSION} · ${TOOLKIT_ROOT}${NC}"
    echo ""
}

execute_script() {
    local target="$1"
    local needs_root="${2:-false}"
    local interactive="${3:-false}"
    shift 3 || shift $#

    if [ ! -f "$target" ]; then
        msg_err "Target script not found: $target"
        return 1
    fi

    local exit_code=0
    if [ "$needs_root" = "true" ] && [ "${EUID:-$(id -u)}" -ne 0 ]; then
        msg_warn "This action requires root privileges."
        if command -v sudo &>/dev/null; then
            msg_info "Elevating via sudo..."
            sudo bash "$target" "$@" || exit_code=$?
        else
            msg_err "'sudo' not available. Please run this command as root."
            exit_code=1
        fi
    else
        bash "$target" "$@" || exit_code=$?
    fi

    if [ "$interactive" = "true" ]; then
        ui_pause
    fi

    return $exit_code
}

menu_optimization() {
    local opt_choice
    while true; do
        show_banner
        ui_title "System Optimization"
        ui_option s "Full System Status" "hardware info & every tweak, changes nothing"
        ui_option 1 "Full Supertune" "Network, VM & CPU low-latency tuning" root
        ui_option 2 "TCP & BBR Tune" "Network buffer & congestion tuning" root
        ui_option 3 "Install SCX Schedulers & Loader" "sched_ext" root
        ui_option 4 "Run SCX P2DQ Scheduler" "low-latency gaming/server scheduler" root
        ui_option 5 "Setup 2MB Hugepages" "JVM/Minecraft optimization" root
        ui_option 6 "Install Psycachy Kernel" "Debian/Ubuntu only" root
        ui_option 7 "Undo Supertune" "revert tuning to system defaults" root
        ui_option 8 "ZRAM & Memory Optimizer" "ZSTD compressed swap & MGLRU" root
        ui_option 9 "AMD Gaming & Low-Latency" "Ryzen & Radeon desktop clock/C-state locks" root
        ui_back 0 "Back to Main Menu"
        echo ""
        ui_read_choice "Select an option [0-9, s]: " opt_choice || return 0

        case $opt_choice in
            s|S) execute_script "$OPT_DIR/status.sh" false true ;;
            1) execute_script "$OPT_DIR/supertune.sh" true true ;;
            2) execute_script "$OPT_DIR/tcptune.sh" true true ;;
            3) execute_script "$OPT_DIR/installscx.sh" true true ;;
            4) execute_script "$OPT_DIR/run_p2dq.sh" true true ;;
            5) execute_script "$OPT_DIR/setup-hugepages.sh" true true ;;
            6) execute_script "$OPT_DIR/install_psycachy.sh" true true ;;
            7) execute_script "$OPT_DIR/undosupertune.sh" true true ;;
            8) execute_script "$OPT_DIR/ramtune.sh" true true ;;
            9) execute_script "$OPT_DIR/amd_gaming_tune.sh" true true ;;
            0|q|Q) break ;;
            *) ui_invalid "$opt_choice" ;;
        esac
    done
}

menu_security() {
    local sec_choice
    while true; do
        show_banner
        ui_title "Security & Auditing" "$MAGENTA"
        ui_option 1 "Run Full Security Audit" "Comprehensive audit of all vectors" root
        ui_option 2 "Audit Malware & Cryptominers" "Memory, temp dirs & Docker" root
        ui_option 3 "Audit Network Listeners" "Open ports, promiscuous interfaces" root
        ui_option 4 "Audit System & SUID" "Rootkits, cron jobs & permissions" root
        ui_option 5 "Audit NPM / Node Vulnerabilities" "Host & container package scan"
        ui_back 0 "Back to Main Menu"
        echo ""
        ui_read_choice "Select an option [0-5]: " sec_choice || return 0

        case $sec_choice in
            1) execute_script "$SEC_DIR/audit_all.sh" true true ;;
            2) execute_script "$SEC_DIR/audit_malware.sh" true true ;;
            3) execute_script "$SEC_DIR/audit_network.sh" true true ;;
            4) execute_script "$SEC_DIR/audit_system.sh" true true ;;
            5) execute_script "$SEC_DIR/npm_vulnerability_audit.sh" false true ;;
            0|q|Q) break ;;
            *) ui_invalid "$sec_choice" ;;
        esac
    done
}

menu_ptero() {
    local ptero_choice
    while true; do
        show_banner
        ui_title "Pterodactyl Tools (legacy)" "$CYAN"
        echo -e "  ${DIM}Calagopus support is coming soon.${NC}"
        echo ""
        ui_option 1 "Prep System & Install Wings" "Base deps & sysctl tune" root
        ui_option 2 "Wings Diagnostic & Debugger" "Inspect logs & error detection" root
        ui_back 0 "Back to Main Menu"
        echo ""
        ui_read_choice "Select an option [0-2]: " ptero_choice || return 0

        case $ptero_choice in
            1) execute_script "$PTERO_DIR/install.sh" true true ;;
            2) execute_script "$PTERO_DIR/debug.sh" true true ;;
            0|q|Q) break ;;
            *) ui_invalid "$ptero_choice" ;;
        esac
    done
}

main_menu() {
    local main_choice
    while true; do
        show_banner
        ui_title "Select a Category:" ""
        ui_option 1 "Media Downloader" "YouTube videos & playlists with yt-dlp"
        ui_option 2 "System Optimization" "Status, Supertune, TCP, SCX, Hugepages"
        ui_option 3 "Security & Auditing" "Malware, Network, SUID, NPM audits"
        ui_option 4 "Pterodactyl Tools ${YELLOW}[legacy]${NC}" "Wings prep & debugger · Calagopus coming soon"
        ui_option 5 "Visit kotsasmin.net" "Open the creator's website"
        echo -e "  ${RED}0)${NC} Exit"
        echo ""
        ui_read_choice "Select an option [0-5]: " main_choice || { echo ""; exit 0; }

        case $main_choice in
            1) execute_script "$MEDIA_DIR/media.sh" false false --from-toolkit ;;
            2) menu_optimization ;;
            3) menu_security ;;
            4) menu_ptero ;;
            5) open_target "$WEBSITE_URL"; ui_pause ;;
            0|q|Q|exit)
                echo -e "\n${CYAN}Goodbye!${NC}"
                exit 0
                ;;
            *) ui_invalid "$main_choice" ;;
        esac
    done
}

show_help() {
    echo -e "${BOLD}Toolkit CLI${NC} ${DIM}${TOOLKIT_VERSION}${NC} - Fast execution for system tools"
    echo -e "Created by ${BOLD}Kotsasmin${NC} - ${WEBSITE_URL}"
    echo ""
    echo -e "${BOLD}Usage:${NC}"
    echo "  toolkit                     Launch interactive TUI menu"
    echo "  toolkit media [-o DIR]      Launch media downloader (saves to ~/media by default)"
    echo "  toolkit optimize <action>   Run optimization script"
    echo "  toolkit security <action>   Run security audit script"
    echo "  toolkit ptero <action>      Run Pterodactyl tool (legacy, Calagopus coming soon)"
    echo "  toolkit website             Open kotsasmin.net"
    echo "  toolkit version             Show the installed version"
    echo "  toolkit help                Show this help screen"
    echo ""
    echo -e "${BOLD}Optimization actions:${NC}"
    echo "  status       - Full system status: hardware info and every tweak (--bufferbloat for a lag test)"
    echo "  supertune    - Full low-latency system tuning (Network, VM, CPU, ZRAM)"
    echo "  tcptune      - TCP & BBR network buffer tuning only"
    echo "  ramtune      - Setup ZRAM with ZSTD compression & MGLRU memory tuning"
    echo "  amd          - AMD Ryzen & Radeon gaming / low-latency tuning"
    echo "  scx          - Install SCX schedulers & loader"
    echo "  p2dq         - Run SCX P2DQ scheduler in screen session"
    echo "  hugepages    - Pre-allocate 2MB huge pages"
    echo "  psycachy     - Install custom Psycachy kernel (Debian/Ubuntu)"
    echo "  undo         - Revert supertune optimizations"
    echo ""
    echo -e "${BOLD}Security actions:${NC}"
    echo "  all          - Run full comprehensive system audit"
    echo "  malware      - Audit malware, cryptominers & memory"
    echo "  network      - Audit network listeners & promiscuous interfaces"
    echo "  system       - Audit SUID binaries, cron & shell persistence"
    echo "  npm          - Audit Node & NPM vulnerabilities"
    echo ""
    echo -e "${BOLD}Pterodactyl actions (legacy, Calagopus coming soon):${NC}"
    echo "  install      - Apply base optimizations and prep for Wings install"
    echo "  debug        - Run Wings debugger, inspect logs & common issues"
    echo ""
}

if [ $# -eq 0 ]; then
    main_menu
fi

COMMAND="$1"
shift

case "$COMMAND" in
    menu)
        main_menu
        ;;
    media)
        execute_script "$MEDIA_DIR/media.sh" false false "$@"
        ;;
    optimize|opt)
        ACTION="${1:-}"
        shift || true
        case "$ACTION" in
            status) execute_script "$OPT_DIR/status.sh" false false "$@" ;;
            supertune) execute_script "$OPT_DIR/supertune.sh" true false "$@" ;;
            tcptune) execute_script "$OPT_DIR/tcptune.sh" true false "$@" ;;
            ramtune|zram) execute_script "$OPT_DIR/ramtune.sh" true false "$@" ;;
            scx) execute_script "$OPT_DIR/installscx.sh" true false "$@" ;;
            p2dq) execute_script "$OPT_DIR/run_p2dq.sh" true false "$@" ;;
            hugepages) execute_script "$OPT_DIR/setup-hugepages.sh" true false "$@" ;;
            psycachy) execute_script "$OPT_DIR/install_psycachy.sh" true false "$@" ;;
            undo) execute_script "$OPT_DIR/undosupertune.sh" true false "$@" ;;
            amd|amdtune) execute_script "$OPT_DIR/amd_gaming_tune.sh" true false "$@" ;;
            *)
                msg_err "Unknown optimization action: '$ACTION'"
                echo "Available actions: status, supertune, tcptune, ramtune, amd, scx, p2dq, hugepages, psycachy, undo"
                exit 1
                ;;
        esac
        ;;
    security|sec)
        ACTION="${1:-}"
        shift || true
        case "$ACTION" in
            all) execute_script "$SEC_DIR/audit_all.sh" true false "$@" ;;
            malware) execute_script "$SEC_DIR/audit_malware.sh" true false "$@" ;;
            network) execute_script "$SEC_DIR/audit_network.sh" true false "$@" ;;
            system) execute_script "$SEC_DIR/audit_system.sh" true false "$@" ;;
            npm) execute_script "$SEC_DIR/npm_vulnerability_audit.sh" false false "$@" ;;
            *)
                msg_err "Unknown security action: '$ACTION'"
                echo "Available actions: all, malware, network, system, npm"
                exit 1
                ;;
        esac
        ;;
    ptero)
        ACTION="${1:-}"
        shift || true
        case "$ACTION" in
            install) execute_script "$PTERO_DIR/install.sh" true false "$@" ;;
            debug) execute_script "$PTERO_DIR/debug.sh" true false "$@" ;;
            *)
                msg_err "Unknown pterodactyl action: '$ACTION'"
                echo "Available actions: install, debug"
                exit 1
                ;;
        esac
        ;;
    website|web|site)
        open_target "$WEBSITE_URL"
        ;;
    version|--version|-v)
        echo "toolkit $TOOLKIT_VERSION"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        msg_err "Unknown command: '$COMMAND'"
        echo "Run 'toolkit help' for usage instructions."
        exit 1
        ;;
esac
