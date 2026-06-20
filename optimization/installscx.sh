#!/usr/bin/env bash

set -euo pipefail

log() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err() { echo "[✗] $*"; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root. Please run with sudo."
    exit 1
fi

DETECTED_OS="unknown"
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    case $ID in
    ubuntu | debian | pop | linuxmint) DETECTED_OS="debian" ;;
    arch | cachyos | manjaro | endeavouros) DETECTED_OS="arch" ;;
    fedora | rhel | centos | rocky | almalinux) DETECTED_OS="rhel" ;;
    *) DETECTED_OS=$ID ;;
    esac
fi

build_scx_from_source() {
    echo ">>> Installing/Updating Rust..."
    if ! command -v rustup &>/dev/null; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    else
        rustup update
    fi
    rustup default stable
    echo ">>> Building SCX Schedulers from source..."
    rm -rf /tmp/scx-build && mkdir -p /tmp/scx-build && cd /tmp/scx-build
    git clone https://github.com/sched-ext/scx.git
    cd scx
    cargo build --release
    find target/release -maxdepth 1 -type f -name "scx_*" -executable -exec cp {} /usr/bin/ \;
    echo ">>> Building SCX Loader from source..."
    cd /tmp/scx-build
    git clone https://github.com/sched-ext/scx-loader.git
    cd scx-loader
    cargo build --release
    echo ">>> Installing SCX Loader Files..."
    install -Dm755 target/release/scx_loader /usr/bin/scx_loader
    install -Dm755 target/release/scxctl /usr/bin/scxctl
    install -Dm644 services/scx_loader.service /usr/lib/systemd/system/scx_loader.service
    install -Dm644 services/org.scx.Loader.service /usr/share/dbus-1/system-services/org.scx.Loader.service
    install -Dm644 configs/org.scx.Loader.conf /usr/share/dbus-1/system.d/org.scx.Loader.conf
    install -Dm644 configs/org.scx.Loader.policy /usr/share/polkit-1/actions/org.scx.Loader.policy
    mkdir -p /usr/share/scx_loader/
    install -Dm644 configs/scx_loader.toml /usr/share/scx_loader/config.toml
}

echo "Installing SCX Schedulers & Loader"
echo ">>> Stopping existing services..."
systemctl stop scx_loader 2>/dev/null || true
systemctl stop scx.service 2>/dev/null || true
echo ">>> Installing Dependencies for $DETECTED_OS..."
if [[ "$DETECTED_OS" == "debian" ]]; then
    apt-get update
    apt-get install -y build-essential cmake pkg-config libelf-dev \
        libseccomp-dev libbpf-dev clang llvm pahole git curl \
        protobuf-compiler libssl-dev screen
    build_scx_from_source
elif [[ "$DETECTED_OS" == "arch" ]]; then
    if pacman -Si scx-scheds &>/dev/null; then
        echo ">>> Found scx-scheds in repositories (CachyOS). Installing directly..."
        pacman -Sy --noconfirm scx-scheds scx-loader screen
    else
        echo ">>> Standard Arch detected. Installing build tools and building from source..."
        pacman -Sy --noconfirm base-devel cmake pkgconf libelf libseccomp libbpf clang llvm pahole git curl protobuf openssl screen
        build_scx_from_source
    fi
elif [[ "$DETECTED_OS" == "rhel" ]]; then
    dnf install -y @development-tools cmake pkgconf elfutils-libelf-devel libseccomp-devel libbpf-devel clang llvm pahole git curl protobuf-compiler openssl-devel screen
    build_scx_from_source
else
    warn "Unsupported OS. Please install dependencies manually."
    exit 1
fi
echo ">>> Reloading System Services..."
systemctl daemon-reload
systemctl reload dbus
systemctl enable --now scx_loader
echo ">>> Verifying and Switching..."
sleep 2
if systemctl is-active --quiet scx_loader; then
    echo "SUCCESS: scx_loader is running!"
else
    echo "WARNING: scx_loader failed to start. Dumping logs:"
    journalctl -u scx_loader -n 20 --no-pager
    exit 1
fi
echo ">>> Switching scheduler to p2dq..."
/usr/bin/scxctl start -s p2dq --mode server || true
/usr/bin/scxctl switch -s p2dq --mode server || true
echo "DONE! Current status:"
/usr/bin/scxctl get || true
cd /
