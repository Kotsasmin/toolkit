#!/usr/bin/env bash

set -euo pipefail

log() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err() { echo "[✗] $*"; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root. Please run with sudo."
    exit 1
fi

echo "Applying TCP Tuning Only"

mkdir -p /etc/modules-load.d
cat >/etc/modules-load.d/99-tcptune.conf <<EOF
sch_fq
tcp_bbr
EOF
modprobe sch_fq 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true

mkdir -p /etc/sysctl.d
cat >/etc/sysctl.d/99-tcptune.conf <<EOF
net.core.default_qdisc = fq
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 8192
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 4000
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_adv_win_scale = 2
net.ipv4.tcp_rmem = 4096 2097152 16777216
net.ipv4.tcp_wmem = 4096 2097152 16777216
EOF
sysctl --system >/dev/null 2>&1 || true

mkdir -p /usr/local/bin
cat >/usr/local/bin/tcptune-routes.sh <<'EOF'
#!/usr/bin/env bash
CWND=1520
ip route show | while read -r route; do
    echo "$route" | grep -q "initcwnd" && continue
    ip route replace $route initcwnd $CWND initrwnd $CWND 2>/dev/null || true
done
ip route show | while read -r route; do
    echo "$route" | grep -q "quickack" && continue
    ip route replace $route quickack 1 2>/dev/null || true
done
EOF
chmod +x /usr/local/bin/tcptune-routes.sh

if [[ -f /etc/systemd/system/tcptune.service ]]; then
    systemctl disable --now tcptune.service 2>/dev/null || true
    rm -f /etc/systemd/system/tcptune.service
    systemctl daemon-reload 2>/dev/null || true
fi
if [[ -d /etc/NetworkManager/dispatcher.d ]]; then
    ln -sf /usr/local/bin/tcptune-routes.sh /etc/NetworkManager/dispatcher.d/99-tcptune-routes
fi
if [[ -d /etc/network/if-up.d ]]; then
    ln -sf /usr/local/bin/tcptune-routes.sh /etc/network/if-up.d/99-tcptune-routes
fi
mkdir -p /etc/cron.d
cat >/etc/cron.d/99-tcptune-routes <<EOF
@reboot root /usr/local/bin/tcptune-routes.sh >/dev/null 2>&1
EOF
/usr/local/bin/tcptune-routes.sh 2>/dev/null || true

log "TCP Tuning Applied!"
