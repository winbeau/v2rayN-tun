#!/usr/bin/env bash
# Deploy a Hysteria2 node with a publicly-trusted Let's Encrypt certificate,
# and emit a v2rayN-importable hysteria2:// share link.
#
# Why a real certificate is mandatory:
#   Hysteria2 runs over QUIC/UDP, so it CANNOT sit behind Cloudflare's proxy
#   (which only forwards TCP). It must be reachable directly, which means the
#   client must validate the certificate chain itself. A Cloudflare Origin
#   certificate is only trusted by Cloudflare, so a direct client cannot verify
#   it and has to fall back to `insecure`, which modern Xray REFUSES to load:
#       "cannot connect via Xray-core versions 26.2.6 or higher.
#        Insecure configuration detected: AllowInsecure is enabled but no
#        certificate is provided."
#   That is a dead end, not a tuning problem.
#
# Prerequisites (this script checks them):
#   1. <domain> resolves directly to this host (NOT Cloudflare-proxied)
#   2. TCP 80 is free and reachable from the public internet (HTTP-01 challenge)
#
# Usage:
#   sudo bash setup_hy2.sh --domain hy.example.com [options]
#
# Options:
#   --domain DOMAIN     certificate domain, also the client SNI (required)
#   --port N            UDP listen port (default 443)
#   --salamander PASS   enable salamander obfuscation with this password
#   --bandwidth UP/DOWN server-side bandwidth hints (default 200mbps/1gbps)
#   --remark TEXT       node name shown in the client
#   --skip-cert         reuse an existing certificate, skip issuance

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

DOMAIN=""
PORT=443
SALAMANDER=""
BANDWIDTH_UP="200 mbps"
BANDWIDTH_DOWN="1 gbps"
REMARK=""
SKIP_CERT=0

while [ $# -gt 0 ]; do
  case $1 in
    --domain)     DOMAIN=$2; shift 2 ;;
    --port)       PORT=$2; shift 2 ;;
    --salamander) SALAMANDER=$2; shift 2 ;;
    --bandwidth)  BANDWIDTH_UP=${2%%/*}; BANDWIDTH_DOWN=${2##*/}; shift 2 ;;
    --remark)     REMARK=$2; shift 2 ;;
    --skip-cert)  SKIP_CERT=1; shift ;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[ -n "$DOMAIN" ] || { echo "error: --domain is required" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "error: must run as root" >&2; exit 1; }
[ -n "$REMARK" ] || REMARK="hy2-$DOMAIN"

HY_DIR=/etc/hysteria
HY_BIN=/usr/local/bin/hysteria
HOOK=/etc/letsencrypt/renewal-hooks/deploy/hysteria-reload.sh
CERT_SRC="/etc/letsencrypt/live/$DOMAIN"

log() { printf '==> %s\n' "$*"; }

# ---------------------------------------------------------------- 1. 前提检查
log "检查前提条件"

case $(uname -m) in
  x86_64)         HY_ARCH=amd64 ;;
  aarch64|arm64)  HY_ARCH=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

MACHINE_IPS=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | tr '\n' ' ')
RESOLVED=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')
log "  $DOMAIN -> ${RESOLVED:-未解析}"
log "  本机 IPv4: ${MACHINE_IPS:-无}"

if [ -n "$RESOLVED" ] && ! echo " $MACHINE_IPS " | grep -qw "$RESOLVED"; then
  cat >&2 <<EOF
warning: $DOMAIN 未解析到本机。
  若域名走 Cloudflare 橙色云代理, HTTP-01 验证会失败 —— 请改为灰色云,
  或改用 DNS-01 验证方式。脚本继续执行, 但签发很可能失败。
EOF
fi

if ss -tln 2>/dev/null | grep -q ":80 "; then
  echo "error: TCP 80 已被占用, --standalone 模式无法工作:" >&2
  ss -tlnp | grep ':80 ' >&2
  exit 1
fi
log "  TCP 80 空闲"

if ss -uln 2>/dev/null | grep -q ":$PORT "; then
  echo "error: UDP $PORT 已被占用" >&2
  exit 1
fi
log "  UDP $PORT 空闲"

# ---------------------------------------------------------------- 2. 证书
if [ "$SKIP_CERT" -eq 0 ]; then
  command -v certbot >/dev/null 2>&1 || {
    log "安装 certbot"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq certbot
  }
  log "签发 Let's Encrypt 证书 (HTTP-01 standalone)"
  certbot certonly --standalone -d "$DOMAIN" \
    --non-interactive --agree-tos --register-unsafely-without-email \
    --preferred-challenges http --keep-until-expiring
fi

[ -f "$CERT_SRC/fullchain.pem" ] || { echo "error: 未找到 $CERT_SRC/fullchain.pem" >&2; exit 1; }

openssl x509 -in "$CERT_SRC/fullchain.pem" -noout -issuer -dates | sed 's/^/    /'

if openssl x509 -in "$CERT_SRC/fullchain.pem" -noout -issuer | grep -qi cloudflare; then
  cat >&2 <<'EOF'
error: 这是一张 Cloudflare Origin 证书, 公开客户端不信任。
       直连场景必须使用公开 CA 签发的证书, 否则客户端只能 insecure,
       而新版 Xray 会拒绝加载 insecure 节点。
EOF
  exit 1
fi

# ---------------------------------------------------------------- 3. 续期钩子
# /etc/letsencrypt 下是 root-only, 而 hysteria 以 hysteria 用户运行读不到,
# 必须复制一份并重设属主。没有这个钩子, 90 天后证书到期服务会静默失效。
log "安装续期钩子 (证书更新后同步并重启)"
mkdir -p "$(dirname "$HOOK")"
cat > "$HOOK" <<HOOKEOF
#!/bin/bash
# 由 setup_hy2.sh 生成: Let's Encrypt 续期后同步证书给 hysteria 并重启
set -e
install -o hysteria -g hysteria -m 644 $CERT_SRC/fullchain.pem $HY_DIR/tls.crt
install -o hysteria -g hysteria -m 600 $CERT_SRC/privkey.pem  $HY_DIR/tls.key
systemctl restart hysteria-server
logger -t hysteria-cert "证书已更新并重启 hysteria-server"
HOOKEOF
chmod 755 "$HOOK"
"$HOOK"
log "  钩子已安装并已执行一次"

# ---------------------------------------------------------------- 4. 安装二进制
log "安装 hysteria"
mkdir -p "$HY_DIR"
if [ ! -x "$HY_BIN" ] || [ "${HYSTERIA_FORCE_UPGRADE:-0}" = 1 ]; then
  curl -fsSL --max-time 180 -o /tmp/hysteria.new \
    "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-$HY_ARCH"
  chmod +x /tmp/hysteria.new
  systemctl stop hysteria-server 2>/dev/null || true
  cp "$HY_BIN" "$HY_BIN.bak.$(date +%s)" 2>/dev/null || true
  mv /tmp/hysteria.new "$HY_BIN"
fi
"$HY_BIN" version 2>/dev/null | grep -i '^version' | sed 's/^/    /' || true

# 独立系统用户, 不以 root 运行
id hysteria >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin hysteria

# ---------------------------------------------------------------- 5. 写配置
log "写 $HY_DIR/config.yaml"
OBFS_BLOCK=""
[ -n "$SALAMANDER" ] && OBFS_BLOCK="obfs:
  type: salamander
  salamander:
    password: $SALAMANDER
"
AUTH_PASS=$(openssl rand -hex 16)
cat > "$HY_DIR/config.yaml" <<EOF
listen: :$PORT
tls:
  cert: $HY_DIR/tls.crt
  key: $HY_DIR/tls.key
${OBFS_BLOCK}auth:
  type: password
  password: $AUTH_PASS
bandwidth:
  up: $BANDWIDTH_UP
  down: $BANDWIDTH_DOWN
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
EOF
chmod 640 "$HY_DIR/config.yaml"
chown -R hysteria:hysteria "$HY_DIR"

# ---------------------------------------------------------------- 6. systemd
log "安装 systemd unit"
cat > /etc/systemd/system/hysteria-server.service <<'EOF'
[Unit]
Description=Hysteria Server Service (config.yaml)
After=network.target

[Service]
Type=simple
User=hysteria
Group=hysteria
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
WorkingDirectory=/etc/hysteria
Restart=on-failure
RestartSec=3
LimitNOFILE=1000000
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now hysteria-server
sleep 2

# ---------------------------------------------------------------- 7. 自检
log "自检"
systemctl is-active hysteria-server | sed 's/^/    service: /'
ss -ulnp 2>/dev/null | grep -q ":$PORT " && log "  UDP $PORT 已监听" || {
  echo "error: hysteria 未监听 UDP $PORT" >&2
  journalctl -u hysteria-server -n 20 --no-pager >&2
  exit 1
}
journalctl -u hysteria-server -n 5 --no-pager | tail -5 | sed 's/^/    /'

# ---------------------------------------------------------------- 8. 链接
SERVER_IP=$(curl -fsS -4 --max-time 15 https://api.ipify.org || true)
[ -n "$SERVER_IP" ] || SERVER_IP=$(echo "$MACHINE_IPS" | awk '{print $1}')

LINK=$(bash "$SCRIPT_DIR/make_hy2_link.sh" \
  "$SERVER_IP" "$PORT" "$AUTH_PASS" "$DOMAIN" "$SALAMANDER" "$REMARK")

OUTDIR=${OUTDIR:-./hy2-build}
mkdir -p "$OUTDIR"; umask 077
printf '%s\n' "$LINK" > "$OUTDIR/share-link.txt"
cat > "$OUTDIR/params.env" <<EOF
SERVER_IP=$SERVER_IP
PORT=$PORT
DOMAIN=$DOMAIN
AUTH=$AUTH_PASS
SALAMANDER=$SALAMANDER
REMARK=$REMARK
EOF

cat <<EOF

==> Hysteria2 部署完成
    server   $SERVER_IP:$PORT (UDP)
    domain   $DOMAIN  (SNI, 真证书)
    obfs     ${SALAMANDER:+salamander}${SALAMANDER:-none}
    链接     $OUTDIR/share-link.txt
    参数     $OUTDIR/params.env

    $LINK

注意:
  - Hysteria2 走 UDP。部分网络会限制 UDP, 届时需回落到 TCP 系节点。
  - 本机自检无法证明公网 UDP 可达, 需从客户端实测。
  - 分享链接含凭证, 不要公开分发。
EOF
