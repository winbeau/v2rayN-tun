#!/usr/bin/env bash
# Install the built Xray REALITY node as a hardened systemd service. Requires root.
#
# Usage: sudo bash install_service.sh --workdir ./xray-build [--no-bbr] [--no-firewall]

set -euo pipefail

WORKDIR=""
DO_BBR=1
DO_FIREWALL=1

while [ $# -gt 0 ]; do
  case $1 in
    --workdir)     WORKDIR=$2; shift 2 ;;
    --no-bbr)      DO_BBR=0; shift ;;
    --no-firewall) DO_FIREWALL=0; shift ;;
    -h|--help)     sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "error: must run as root" >&2; exit 1; }
[ -n "$WORKDIR" ] || { echo "error: --workdir is required" >&2; exit 1; }
WORKDIR=$(cd "$WORKDIR" && pwd)

for f in xray config.json params.env geoip.dat geosite.dat; do
  [ -e "$WORKDIR/$f" ] || { echo "error: missing $WORKDIR/$f (run setup_reality.sh first)" >&2; exit 1; }
done

# shellcheck disable=SC1091
. "$WORKDIR/params.env"

echo "==> installing binary and geo data"
install -m 755 "$WORKDIR/xray" /usr/local/bin/xray
install -d /usr/local/share/xray /usr/local/etc/xray /var/log/xray
install -m 644 "$WORKDIR/geoip.dat" "$WORKDIR/geosite.dat" /usr/local/share/xray/

if [ -f /usr/local/etc/xray/config.json ]; then
  BACKUP="/usr/local/etc/xray/config.json.bak.$(date +%Y%m%d%H%M%S)"
  cp -a /usr/local/etc/xray/config.json "$BACKUP"
  echo "    existing config backed up to $BACKUP"
fi
install -m 600 "$WORKDIR/config.json" /usr/local/etc/xray/config.json
install -m 600 "$WORKDIR/params.env" /usr/local/etc/xray/params.env

echo "==> creating service user"
id -u xray >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -M xray
chown -R xray:xray /var/log/xray /usr/local/etc/xray

echo "==> writing systemd unit"
cat > /etc/systemd/system/xray.service <<'UNIT'
[Unit]
Description=Xray Service
Documentation=https://xtls.github.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=xray
Group=xray
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray

[Install]
WantedBy=multi-user.target
UNIT

if [ "$DO_BBR" -eq 1 ]; then
  echo "==> enabling BBR and TCP tuning"
  modprobe tcp_bbr 2>/dev/null || true
  cat > /etc/sysctl.d/99-xray-tune.conf <<'SYSCTL'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
SYSCTL
  sysctl --system >/dev/null 2>&1 || true
fi

if [ "$DO_FIREWALL" -eq 1 ] && command -v ufw >/dev/null 2>&1; then
  if ufw status 2>/dev/null | grep -q "Status: active"; then
    echo "==> allowing ${PORT}/tcp through ufw"
    ufw allow "${PORT}/tcp" || true
  fi
fi

echo "==> starting service"
systemctl daemon-reload
systemctl enable --now xray
sleep 2
systemctl --no-pager --full status xray | head -15

echo
echo "==> result"
echo -n "    congestion control: "; sysctl -n net.ipv4.tcp_congestion_control
if ss -tlnp | grep -q ":${PORT}\b"; then
  ss -tlnp | grep ":${PORT}\b"
else
  echo "    WARNING: port ${PORT} is not listening" >&2
fi

cat <<EOF

The host firewall is only one layer. If clients still cannot connect, check the
VPS provider's security group and any cloud network ACL for inbound ${PORT}/tcp.
EOF
