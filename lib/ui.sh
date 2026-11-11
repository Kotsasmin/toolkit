# Shared look and helpers for the toolkit scripts.
# Source this file, don't run it:  source "<toolkit root>/lib/ui.sh"

WEBSITE_URL="https://kotsasmin.net"

# Colours are turned off when NO_COLOR is set (https://no-color.org).
if [ -z "${NO_COLOR:-}" ]; then
    BOLD='\033[1m'
    DIM='\033[2m'
    CYAN='\033[0;36m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    MAGENTA='\033[0;35m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    BOLD='' DIM='' CYAN='' GREEN='' YELLOW='' RED='' MAGENTA='' BLUE='' NC=''
fi

# ui_banner [subtitle]: clears the screen and draws the toolkit logo.
ui_banner() {
    clear 2>/dev/null || printf '\n'
    echo -e "${CYAN}${BOLD}"
    echo "  ████████╗ ██████╗  ██████╗ ██╗     ██╗  ██╗██╗████████╗"
    echo "  ╚══██╔══╝██╔═══██╗██╔═══██╗██║     ██║ ██╔╝██║╚══██╔══╝"
    echo "     ██║   ██║   ██║██║   ██║██║     █████╔╝ ██║   ██║   "
    echo "     ██║   ██║   ██║██║   ██║██║     ██╔═██╗ ██║   ██║   "
    echo "     ██║   ╚██████╔╝╚██████╔╝███████╗██║  ██╗██║   ██║   "
    echo "     ╚═╝    ╚═════╝  ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝   ╚═╝   "
    echo -e "${NC}${DIM}       ${1:-System Optimization, Security & Media Toolkit}${NC}"
    echo -e "       Created by ${BOLD}Kotsasmin${NC} ${DIM}- ${WEBSITE_URL}${NC}"
    echo ""
}

# ui_title "Text" [colour]
ui_title() {
    echo -e "${2:-$YELLOW}${BOLD}$1${NC}"
}

# ui_option key "Label" ["description"] [root]
ui_option() {
    local tag=""
    [ "${4:-}" = "root" ] && tag=" ${RED}[root]${NC}"
    if [ -n "${3:-}" ]; then
        echo -e "  ${GREEN}$1)${NC} $2 ${DIM}($3)${NC}${tag}"
    else
        echo -e "  ${GREEN}$1)${NC} $2${tag}"
    fi
}

# ui_back key "Label": the leave/back entry at the bottom of a menu.
ui_back() {
    echo -e "  ${BLUE}$1)${NC} $2"
}

# ui_read_choice "Prompt" VAR: reads a menu choice with spaces and a stray \r removed.
ui_read_choice() {
    local _input=""
    read -rp "$1" _input || return 1
    _input="${_input//[[:space:]]/}"
    printf -v "$2" '%s' "$_input"
}

msg_info() { echo -e "${CYAN}[+] $*${NC}"; }
msg_ok()   { echo -e "${GREEN}[✓] $*${NC}"; }
msg_warn() { echo -e "${YELLOW}[!] $*${NC}"; }
msg_err()  { echo -e "${RED}[✗] $*${NC}" >&2; }

ui_invalid() {
    msg_err "Invalid option '$1'"
    sleep 1
}

ui_pause() {
    echo ""
    read -rp "${1:-Press [Enter] to return to menu...}" _ || true
}

# ui_confirm "Question": yes/no question, default no.
ui_confirm() {
    local answer=""
    read -rp "$1 [y/N]: " answer || return 1
    [[ "$answer" =~ ^[Yy] ]]
}

# open_target URL_OR_PATH: opens a link or folder in the desktop's default app.
# On a server or over SSH there is no desktop, so it prints the target instead.
open_target() {
    local target="$1" opener=""
    for cmd in xdg-open gio open; do
        if command -v "$cmd" &>/dev/null; then
            opener="$cmd"
            break
        fi
    done

    if [ -n "$opener" ] && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ] || [ "$(uname -s)" = "Darwin" ]; }; then
        msg_info "Opening $target"
        if [ "$opener" = "gio" ]; then
            gio open "$target" &>/dev/null &
        else
            "$opener" "$target" &>/dev/null &
        fi
        disown 2>/dev/null || true
    else
        msg_warn "No desktop to open it here. Location: ${BOLD}$target${NC}"
    fi
}
