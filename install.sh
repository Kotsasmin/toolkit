#!/usr/bin/env bash
#
# Installs the `toolkit` command for the current user by linking it into ~/.local/bin.
# The toolkit keeps running from this folder, so `git pull` here updates it.
# Arch users can install the AUR package (kotsasmin-toolkit-git) instead.
#
# Usage: ./install.sh              install
#        ./install.sh --uninstall  remove the command again

set -euo pipefail

ROOT="$(cd -P "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
LINK="$BIN_DIR/toolkit"

if [ "${1:-}" = "--uninstall" ]; then
    if [ -L "$LINK" ] && [ "$(readlink -f "$LINK")" = "$ROOT/toolkit.sh" ]; then
        rm "$LINK"
        echo "[✓] Removed $LINK"
    else
        echo "[!] $LINK is not a toolkit link from this folder, nothing removed."
    fi
    exit 0
fi

if [ -e "$LINK" ] && [ "$(readlink -f "$LINK")" != "$ROOT/toolkit.sh" ]; then
    echo "[✗] $LINK already exists and points somewhere else. Remove it first." >&2
    exit 1
fi

if command -v toolkit &>/dev/null && [ "$(readlink -f "$(command -v toolkit)")" != "$ROOT/toolkit.sh" ]; then
    echo "[!] Another toolkit is already installed at $(command -v toolkit) (the AUR package?)."
    echo "    Whichever comes first in your PATH will run."
fi

mkdir -p "$BIN_DIR"
chmod +x "$ROOT/toolkit.sh" "$ROOT"/{media,optimization,ptero,security}/*.sh
ln -sfn "$ROOT/toolkit.sh" "$LINK"
echo "[✓] Installed: $LINK -> $ROOT/toolkit.sh"

case ":$PATH:" in
    *":$BIN_DIR:"*) echo "    Run it with: toolkit" ;;
    *)
        echo "[!] $BIN_DIR is not in your PATH. Add this to your shell config, then open a new terminal:"
        echo "    export PATH=\"$BIN_DIR:\$PATH\""
        ;;
esac
