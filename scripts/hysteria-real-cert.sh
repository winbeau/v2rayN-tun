#!/bin/bash
# 为 Hysteria2 申请并安装 Let's Encrypt 真证书
# 为 Hysteria2 申请并安装 Let's Encrypt 真证书
#
# 背景: Hysteria2 走 QUIC/UDP, 无法像 WS+TLS 那样躲在 Cloudflare 后面,
#       必须直连。而 Cloudflare Origin 证书只有 Cloudflare 自己信任,
#       直连客户端只能靠 AllowInsecure 跳过校验 —— 新版 Xray 会拒绝加载。
#       所以必须给 Hysteria2 换一张公开受信任的证书。
#
# 前提:
#   1. 域名直接解析到本机 (非 Cloudflare 橙色云)
#   2. 80 端口空闲且从公网可达 (Let's Encrypt 的验证服务器需要访问)
#
# 用法: ./hysteria-real-cert.sh <域名> [证书路径...]
#   例: ./hysteria-real-cert.sh hy.example.net
#
set -e

DOMAIN="${1:?用法: $0 <域名>}"
HY_DIR=/etc/hysteria
HOOK=/etc/letsencrypt/renewal-hooks/deploy/hysteria-reload.sh

echo "=== 0. 前提检查 ==="
RESOLVED=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}')
LOCAL_IPS=$(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | tr '\n' ' ')
echo "  $DOMAIN 解析到: $RESOLVED"
echo "  本机 IP:       $LOCAL_IPS"
if ! echo "$LOCAL_IPS" | grep -qw "$RESOLVED"; then
    echo "  ⚠ 域名未指向本机 —— 若走 Cloudflare 代理, HTTP-01 会失败"
    echo "     (Cloudflare 代理的域名请改用 DNS-01 验证)"
fi
if ss -tln | grep -q ':80 '; then
    echo "  ✗ 80 端口被占用, standalone 模式无法工作"; ss -tlnp | grep ':80 '
    exit 1
fi
echo "  ✓ 80 端口空闲"

echo
echo "=== 1. 安装 certbot ==="
if ! command -v certbot >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq certbot
fi
echo "  $(certbot --version 2>&1)"

echo
echo "=== 2. 申请证书 ==="
certbot certonly --standalone -d "$DOMAIN" \
    --non-interactive --agree-tos --register-unsafely-without-email \
    --preferred-challenges http --keep-until-expiring

echo
echo "=== 3. 安装续期钩子 (同步证书给 hysteria 并重启) ==="
# /etc/letsencrypt/live 是 root-only, 而 hysteria 以 hysteria 用户运行 -> 必须复制
mkdir -p "$(dirname "$HOOK")"
cat > "$HOOK" <<HOOKEOF
#!/bin/bash
# Let's Encrypt 续期后同步证书给 hysteria 并重启
set -e
install -o hysteria -g hysteria -m 644 /etc/letsencrypt/live/$DOMAIN/fullchain.pem $HY_DIR/tls.crt
install -o hysteria -g hysteria -m 600 /etc/letsencrypt/live/$DOMAIN/privkey.pem  $HY_DIR/tls.key
systemctl restart hysteria-server
logger -t hysteria-cert "证书已更新并重启 hysteria-server"
HOOKEOF
chmod 755 "$HOOK"
"$HOOK"
echo "  ✓ 钩子已安装并已执行一次"

echo
echo "=== 4. 更新 hysteria 配置 ==="
CFG="$HY_DIR/config.yaml"
[ -f "$CFG.bak.orig" ] || cp "$CFG" "$CFG.bak.orig"
sed -i "s|cert: .*origin.*|cert: $HY_DIR/tls.crt|" "$CFG"
sed -i "s|key: .*origin.*|key:  $HY_DIR/tls.key|" "$CFG"
sed -n '/^tls:/,/^[a-z]/p' "$CFG" | head -4 | sed 's/^/  /'

echo
echo "=== 5. 重启并验证 ==="
systemctl restart hysteria-server
sleep 2
echo "  服务: $(systemctl is-active hysteria-server)"
openssl x509 -in "$HY_DIR/tls.crt" -noout -subject -issuer -dates | sed 's/^/  /'

echo
echo "=== 6. 续期演练 (务必通过, 否则 90 天后会静默失效) ==="
certbot renew --dry-run 2>&1 | grep -iE "congratul|success|fail|error" | tail -3 | sed 's/^/  /'

echo
echo "✅ 完成。客户端请关闭该节点的 AllowInsecure:"
echo "   sqlite3 ~/Library/Application\\ Support/v2rayN/guiConfigs/guiNDB.db \\"
echo "     \"update ProfileItem set AllowInsecure=NULL where Remarks='<节点名>';\""
echo "   (改之前先从托盘菜单退出 v2rayN, 否则会被覆盖)"
