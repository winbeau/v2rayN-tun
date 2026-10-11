#!/bin/bash
#
# v2rayN 网络守护 —— 处理两类"网络变化后没切换干净"的问题
#
# ============ 问题 1: DNS 回落到 on-link 地址 ============
#   sing-box TUN 只接管"跟随默认路由"的流量。与本机同网段(on-link)的 DNS
#   (如路由器的 10.236.42.55 或 RA 下发的 IPv6 地址) 走链路直连、不进 TUN,
#   绕过 sing-box 的 DNS 劫持, 返回被污染的结果。
#
# ============ 问题 2: sing-box 出站绑定了已失效的旧地址 ============
#   sing-box 在启动时检测网络接口并确定出站绑定。网络切换(换 WiFi/热点)后,
#   旧地址消失, 但 sing-box 仍用它发包, 日志报:
#       write udp 10.236.42.160:...: can't assign requested address
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
# 记录被我们改掉之前的原始 DNS。放在持久位置(不是 /var/run), 因为系统 DNS 设置
# 本身是持久化的 —— 重启后代理若没起来, 也要能把 DNS 还回去。
ORIG_DNS=$BASE/origdns
PROXY_PORT=10808

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

[ -e "$BASE/DISABLED" ] && exit 0

svc_for_if() {
    /usr/sbin/networksetup -listnetworkserviceorder 2>/dev/null | awk -v dev="Device: $1" '
        /^\([0-9]+\)/ { s=$0; sub(/^\([0-9]+\) /, "", s) }
        $0 ~ dev     { print s; exit }'
}

# 读取某网络服务当前手动设置的 DNS; "自动"时 networksetup 会输出一句英文提示
get_dns() {
    local out
    out=$(/usr/sbin/networksetup -getdnsservers "$1" 2>/dev/null | tr '\n' ' ')
    case "$out" in
        *"aren't any"*|*"not set"*|"") echo "Empty" ;;
        *) echo "${out% }" ;;
    esac
}

flush_dns() {
    /usr/bin/dscacheutil -flushcache   2>/dev/null || true
    /usr/bin/killall -HUP mDNSResponder 2>/dev/null || true
}

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

# ================= 问题 3: TUN 不在时, 把 DNS 还回原样 =================
# 当初改 DNS 是为了让查询跟随默认路由进 TUN —— on-link 的 DNS 会绕过劫持。
# TUN 不在了这个改动就失去意义, 留着会让系统残留一处非用户设置的配置。
# 触发时机: 退出 v2rayN 后 run-tun.sh 撤掉 TUN 时会主动 kickstart 本守护。
if ! /usr/sbin/lsof -nP -iTCP:"$PROXY_PORT" -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then
    SVC3=$(svc_for_if "$PRIMARY_IF")
    if [ -n "$SVC3" ]; then
        CUR3=$(get_dns "$SVC3")
        # 只在我们设的值还在时才还原, 避免覆盖用户后来手动改的 DNS
        if [ "$CUR3" = "$DESIRED_DNS" ]; then
            if [ -f "$ORIG_DNS" ]; then
                ORIG=$(/bin/cat "$ORIG_DNS")
                /usr/sbin/networksetup -setdnsservers "$SVC3" $ORIG
                log "代理端口 $PROXY_PORT 已下线 -> 还原 DNS「$SVC3」为原值: $ORIG"
            else
                # 没有原值记录(例如本逻辑上线前 DNS 就被改过) -> 还原为"自动",
                # 即由 DHCP/RA 下发, 这是系统未被干预时的默认状态
                ORIG="Empty"
                /usr/sbin/networksetup -setdnsservers "$SVC3" Empty
                log "代理端口 $PROXY_PORT 已下线 -> DNS「$SVC3」还原为自动 (无原值记录)"
            fi
            flush_dns
            sleep 1
        elif [ -f "$ORIG_DNS" ]; then
            log "代理已下线, 但当前 DNS「$CUR3」不是我们设的值, 不动它"
        fi
        /bin/rm -f "$ORIG_DNS"
    fi
    exit 0
fi

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

SVC=$(svc_for_if "$PRIMARY_IF")
[ -z "$SVC" ] && { log "接口 $PRIMARY_IF: $REASON, 但找不到对应网络服务, 跳过"; exit 0; }

# 改之前先把原值记下来, 供「代理下线时还原」使用。
# 只在首次记录 —— 否则第二次运行会把我们自己设的值当成"原值"存进去。
if [ ! -f "$ORIG_DNS" ]; then
    ORIG=$(get_dns "$SVC")
    /bin/echo "$ORIG" > "$ORIG_DNS"
    log "记录原始 DNS「$SVC」= $ORIG"
fi

log "接口 $PRIMARY_IF / 服务「$SVC」: $REASON -> 改回公网 DNS"

/usr/sbin/networksetup -setdnsservers "$SVC" $DESIRED_DNS
flush_dns
sleep 1

NEW=$(get_dns "$SVC")
log "修复完成: $NEW"
