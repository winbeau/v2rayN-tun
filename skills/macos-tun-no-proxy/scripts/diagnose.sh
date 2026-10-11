#!/usr/bin/env bash
# macOS TUN 代理健康检查与分层定位。
#
# 设计原则: 先证明问题不在本地, 再往外查。
#   第 1 层 本地配置  —— 国内能否正常访问
#   第 2 层 网络路径  —— 用 --interface 绕过本地所有代理直连节点
#   第 3 层 节点服务  —— TCP 与 TLS 分开看
#
# Usage: diagnose.sh [--node-ip IP] [--sni DOMAIN] [--proxy-port N]

set -uo pipefail

NODE_IP=""
SNI=""
NODE_PORT=443
PROXY_PORT=10808
TUN_ADDR=172.19.0.1

while [ $# -gt 0 ]; do
  case $1 in
    --node-ip)    NODE_IP=$2; shift 2 ;;
    --node-port)  NODE_PORT=$2; shift 2 ;;
    --sni)        SNI=$2; shift 2 ;;
    --proxy-port) PROXY_PORT=$2; shift 2 ;;
    -h|--help)    sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# 所有探测都绕过代理变量, 避免自我干扰
CURL=(curl --noproxy '*' -s -o /dev/null --max-time 12 -w '%{http_code}')

# ---------------------------------------------------------------- 本地状态
head_ "1. 本地状态"

if ifconfig 2>/dev/null | grep -q "$TUN_ADDR"; then
  ok "TUN 已建立 ($TUN_ADDR)"
  IFACE=$(ifconfig 2>/dev/null | grep -B8 "$TUN_ADDR" | grep -oE '^utun[0-9]+' | head -1)
  MTU=$(ifconfig "$IFACE" 2>/dev/null | grep -oE 'mtu [0-9]+' | awk '{print $2}')
  ok "接口 $IFACE, MTU ${MTU:-未知}"
  [ "${MTU:-0}" -gt 1500 ] 2>/dev/null && warn "MTU > 1500, 建议设为 1500"
else
  bad "TUN 未建立"
  warn "若节点未运行, 守护会主动不建 TUN (这是设计行为, 避免整机断网)"
fi

if lsof -nP -iTCP:"$PROXY_PORT" -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then
  ok "代理端口 $PROXY_PORT 监听中"
else
  bad "代理端口 $PROXY_PORT 未监听 —— 客户端未运行或节点启动失败"
fi

for svc in com.local.v2rayn-tun com.local.v2rayn-dnsguard; do
  st=$(launchctl print "system/$svc" 2>/dev/null | grep -o 'state = [a-z ]*' | head -1)
  if [ -n "$st" ]; then ok "$svc: $st"; else warn "$svc 未加载"; fi
done

head_ "2. 代理变量与系统代理 (目标形态是两者都关)"

if env | grep -qiE '^(http|https|all|no)_proxy='; then
  bad "存在代理环境变量:"
  env | grep -iE '^(http|https|all|no)_proxy=' | sed 's/^/      /'
else
  ok "无代理环境变量"
fi

PROXY_STATE=$(scutil --proxy 2>/dev/null | grep -E 'HTTPEnable|SOCKSEnable|HTTPSEnable' | awk '{print $3}' | tr '\n' ' ')
if echo "$PROXY_STATE" | grep -q '1'; then
  bad "系统代理仍开启 (HTTPEnable/SOCKSEnable/HTTPSEnable = $PROXY_STATE)"
else
  ok "系统代理已关闭"
fi

head_ "3. DNS 健康度 (Bug A: on-link 会绕过 TUN)"

DNS_LIST=$(scutil --dns 2>/dev/null | awk '/nameserver/{print $3}' | sort -u)
echo "  当前解析器: $(echo "$DNS_LIST" | tr '\n' ' ')"

ONLINK=""
for ns in $DNS_LIST; do
  case "$ns" in
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|fe80:*|fd*|fdfe:*)
      ONLINK="$ONLINK $ns" ;;
  esac
done
if [ -n "$ONLINK" ]; then
  bad "存在 on-link / 私有 DNS, 会绕过 TUN 导致污染:$ONLINK"
  warn "dnsguard.sh 应在 30 秒内自动修复; 若未修复查看 /var/log/v2rayn-dnsguard.log"
else
  ok "解析器均为公网地址"
fi

AAAA=$(dig +short AAAA www.google.com 2>/dev/null | head -1)
if [ -z "$AAAA" ]; then ok "无假 IPv6 (AAAA 为空, ipv4_only 生效)"
elif echo "$AAAA" | grep -qE '^(2001::1|::1?)$'; then bad "出现伪造 AAAA: $AAAA"
else warn "AAAA 返回 $AAAA (若非真实地址则可能是污染)"; fi

head_ "4. 出站绑定是否失效 (Bug B)"

IF0=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
IF0_ADDR=$(ifconfig "$IF0" 2>/dev/null | awk '/inet /{print $2; exit}')
echo "  主接口 $IF0 = ${IF0_ADDR:-未知}"

if grep -q "can't assign requested address" /var/log/v2rayn-tun.log 2>/dev/null; then
  LAST=$(grep "can't assign requested address" /var/log/v2rayn-tun.log | tail -1 | awk '{print $1, $2, $3}')
  warn "历史日志中出现过该错误 (最后一次: $LAST)"
  warn "若重启 TUN 后不再出现即为已修复; 持续出现说明绑定仍失效"
else
  ok "无绑定失效记录"
fi

# ---------------------------------------------------------------- 连通性
head_ "5. 分层连通性"

CN=$( "${CURL[@]}" https://www.baidu.com )
[ "$CN" = "200" ] && ok "国内 HTTP $CN (第 1 层: 本地配置健康)" \
                  || bad "国内 HTTP $CN —— 本地配置或链路有问题, 先解决这个"

FOREIGN=$( "${CURL[@]}" https://www.google.com/generate_204 )
[ "$FOREIGN" = "204" ] && ok "国外 HTTP $FOREIGN (经 TUN)" \
                       || bad "国外 HTTP $FOREIGN"

VIA_PROXY=$(curl --noproxy '*' -s -o /dev/null --max-time 12 -x "socks5h://127.0.0.1:$PROXY_PORT" \
            -w '%{http_code}' https://www.google.com/generate_204 2>/dev/null)
[ "$VIA_PROXY" = "204" ] && ok "经代理端口 HTTP $VIA_PROXY" \
                         || bad "经代理端口 HTTP $VIA_PROXY"

if [ -n "$IF0" ]; then
  # --interface 设置 IP_BOUND_IF, 绕过路由表, 完全跳过 TUN
  BYPASS=$(curl --noproxy '*' -s -o /dev/null --max-time 10 --interface "$IF0" \
           -w '%{http_code}' https://www.baidu.com 2>/dev/null)
  [ "$BYPASS" = "200" ] && ok "绕过 TUN 直连国内 HTTP $BYPASS (第 2 层基线有效)" \
                        || warn "绕过 TUN 直连国内 HTTP $BYPASS (--interface 可能未生效)"
fi

if [ -n "$NODE_IP" ]; then
  head_ "6. 节点可达性 (第 3 层: TCP 与 TLS 分开看)"
  RESOLVE_ARG=()
  [ -n "$SNI" ] && RESOLVE_ARG=(--resolve "$SNI:$NODE_PORT:$NODE_IP")
  TARGET=${SNI:-$NODE_IP}
  OUT=$(curl -vsk -o /dev/null --interface "${IF0:-en0}" --max-time 10 \
        "${RESOLVE_ARG[@]}" -w 'connect=%{time_connect} tls=%{time_appconnect}' \
        "https://$TARGET:$NODE_PORT/" 2>&1)
  CONNECT=$(echo "$OUT" | grep -o 'connect=[0-9.]*' | cut -d= -f2)
  TLS=$(echo "$OUT" | grep -o 'tls=[0-9.]*' | cut -d= -f2)
  if [ "${TLS:-0.000000}" != "0.000000" ] && [ -n "$TLS" ]; then
    ok "TCP ${CONNECT}s / TLS ${TLS}s —— 节点握手正常"
  elif echo "$OUT" | grep -q "Connected to"; then
    bad "TCP 通但 TLS 零响应 —— 节点被封或服务端进程挂死"
  else
    bad "TCP 都不通 —— 网络封锁或服务器宕机"
  fi
  echo "  (以上均经 --interface 绕过本机 TUN, 与本地配置无关)"
fi

# ---------------------------------------------------------------- 日志摘要
head_ "7. 最近日志"
for f in /var/log/v2rayn-tun.log /var/log/v2rayn-dnsguard.log; do
  if [ -r "$f" ]; then
    echo "  --- $f ---"
    tail -4 "$f" 2>/dev/null | sed 's/^/    /'
  else
    warn "$f 不可读 (需 root, 或用 sudo)"
  fi
done

cat <<'EOF'

────────────────────────────────────────
判读指引
  国内不通            → 先解决本地, 不要往外查
  国内通 国外不通     → 第 2/3 层: 跑 --node-ip 定位到节点
  两个 bug 中招       → dnsguard.sh 应自动修复; 未修复看它的日志
  都通但应用异常      → 该应用可能绕过了 TUN, 用 netstat 源端口比对确认

第 3 层的局限 (实测踩到)
  「TCP/TLS 握手正常」**不能**证明节点可用。流量超限被服务商限速时,
  握手照样在 0.6s 内完成, 但实际传输慢到不可用。
  要区分「握手失败」和「握手成功但带宽被掐」, 必须实测吞吐:

    curl --noproxy '*' -o /dev/null -r 0-2000000 --max-time 20 \
         -w '%{speed_download}\n' https://codeload.github.com/2dust/v2rayN/tar.gz/refs/heads/master

  明显低于链路正常水平 (几 MB/s) 且服务端出网正常 → 多半是被限速了。
EOF
