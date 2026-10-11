#!/bin/bash
#
# v2rayN 网络守护 —— 处理两类"网络变化后没切换干净"的问题
#
# ============ 问题 1: DNS 回落到 on-link 地址 ============
#   sing-box TUN 只接管"跟随默认路由"的流量。与本机同网段(on-link)的 DNS
#   (如路由器的 10.20.30.55 或 RA 下发的 IPv6 地址) 走链路直连、不进 TUN,
#   绕过 sing-box 的 DNS 劫持, 返回被污染的结果。
#
# ============ 问题 2: sing-box 出站绑定了已失效的旧地址 ============
#   sing-box 在启动时检测网络接口并确定出站绑定。网络切换(换 WiFi/热点)后,
#   旧地址消失, 但 sing-box 仍用它发包, 日志报:
#       write udp 10.20.30.160:...: can't assign requested address
#   结果是所有直连出站失败 —— 表现为微信卡住、程序报传输错误。
#   本脚本检测到本机地址变化就重启 TUN, 让 sing-box 重新绑定。
#
# 触发方式: launchd 每 30 秒一次 + 监听网络配置变化即时触发
# 临时停用: sudo touch /usr/local/libexec/v2rayn-dnsguard/DISABLED
#

set -u

DESIRED_DNS="223.5.5.5 119.29.29.29"
BASE=/usr/local/libexec/v2rayn-dnsguard
LOG=/var/log/v2rayn-dnsguard.log
ADDR_STATE=/var/run/v2rayn-netguard.addr
RESTART_STAMP=/var/run/v2rayn-netguard.restart

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

[ -e "$BASE/DISABLED" ] && exit 0

is_onlink() {
    case "$1" in
        10.*|127.*|169.254.*|192.168.*)          return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*)   return 0 ;;
        ::1)                                     return 0 ;;
        fe80:*|FE80:*|f[cd]*:*|F[CD]*:*)         return 0 ;;
    esac
    return 1
}

PRIMARY_IF=$(/sbin/route -n get default 2>/dev/null | awk '/interface:/{print $2}')
[ -z "$PRIMARY_IF" ] && exit 0

# ================= 问题 2: 本机地址变化 -> 重启 TUN =================
CUR_ADDR=$(/sbin/ifconfig "$PRIMARY_IF" 2>/dev/null | awk '/inet /{print $2; exit}')
LAST_ADDR=$(/bin/cat "$ADDR_STATE" 2>/dev/null || true)

if [ -n "$CUR_ADDR" ] && [ "$CUR_ADDR" != "$LAST_ADDR" ]; then
    if [ -n "$LAST_ADDR" ]; then
        # 防抖: 60 秒内只重启一次, 避免网络抖动导致反复重建 TUN
        NOW=$(/bin/date +%s)
        LAST_RESTART=$(/bin/cat "$RESTART_STAMP" 2>/dev/null || echo 0)
        if [ $((NOW - LAST_RESTART)) -ge 60 ]; then
            log "网络地址变化 $LAST_ADDR -> $CUR_ADDR, 重启 TUN 让 sing-box 重新绑定出站"
            /bin/launchctl kickstart -k system/com.local.v2rayn-tun 2>/dev/null || true
            /bin/echo "$NOW" > "$RESTART_STAMP"
            sleep 8
        else
            log "网络地址变化 $LAST_ADDR -> $CUR_ADDR (距上次重启不足 60 秒, 跳过重启)"
        fi
    fi
    /bin/echo "$CUR_ADDR" > "$ADDR_STATE"
fi

# ================= 问题 1: DNS 回落到 on-link =================
DNS_IN_USE=$(/usr/sbin/scutil --dns 2>/dev/null | awk -v ifn="$PRIMARY_IF" '
    /^resolver #[0-9]+/ { rel = 1; next }
    /^  if_index/       { rel = (index($0, "(" ifn ")") > 0) }
    /^  nameserver/     { if (rel) print $3 }
')

BAD=""
for ip in $DNS_IN_USE; do
    if is_onlink "$ip"; then BAD="$ip"; break; fi
done

if [ -z "$DNS_IN_USE" ]; then
    REASON="主解析器当前没有任何 DNS, 解析会完全失效"
elif [ -n "$BAD" ]; then
    REASON="检测到 on-link DNS [$BAD], 会绕过 TUN 被污染"
else
    exit 0
fi

SVC=$(/usr/sbin/networksetup -listnetworkserviceorder 2>/dev/null | awk -v dev="Device: $PRIMARY_IF" '
    /^\([0-9]+\)/ { s=$0; sub(/^\([0-9]+\) /, "", s) }
    $0 ~ dev     { print s; exit }')
[ -z "$SVC" ] && { log "接口 $PRIMARY_IF: $REASON, 但找不到对应网络服务, 跳过"; exit 0; }

log "接口 $PRIMARY_IF / 服务「$SVC」: $REASON -> 改回公网 DNS"

/usr/sbin/networksetup -setdnsservers "$SVC" $DESIRED_DNS
/usr/bin/dscacheutil -flushcache        2>/dev/null || true
/usr/bin/killall -HUP mDNSResponder     2>/dev/null || true
sleep 1

NEW=$(/usr/sbin/networksetup -getdnsservers "$SVC" 2>/dev/null | tr '\n' ' ')
log "修复完成: $NEW"
