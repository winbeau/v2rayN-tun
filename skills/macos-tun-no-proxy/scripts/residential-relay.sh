#!/bin/bash
# 住宅入口在本地网络不可达时的应急通道：经跳板机做 TCP 转发。
#
# 为什么不改出口：住宅节点的 TLS/Reality 是端到端的，跳板机只做 TCP 中继，
# 所以 Claude 看到的仍然是住宅 IP（实测 48.47.154.42）。变慢，但不换身份。
#
# 什么时候用：切到某个网络后 `nc -z 72.249.203.81 12442` 不通，
# 但同一目标从跳板机（如 huawei1）是通的 —— 说明是本地网络的封锁/路由问题。
#
# 用法:
#   ./scripts/residential-relay.sh on       # 建转发 + 装 launchd（开机自启）
#   ./scripts/residential-relay.sh off      # 拆掉
#   ./scripts/residential-relay.sh status   # 看每个端口是否在听
#   ./scripts/residential-relay.sh run      # 前台跑（launchd 调这个）
#
# 转发端口固定 19442-19445，和 v2rayN 里那 4 条住宅线路的 Address 一一对应。
set -u

SUB="http://127.0.0.1:18080/sub"
TARGETS="$HOME/.v2rayn-tun/relay-targets.txt"
JUMP="${JUMP_HOST:-huawei1}"
BASE_PORT=19442
LABEL=com.local.residential-relay
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
DOMAIN="gui/$(id -u)"

die() { echo "  ✗ $*" >&2; exit 1; }

# 订阅里的 4 条住宅线路 -> "本地端口 远端IP:端口"
collect_targets() {
    local links
    links=$(curl -s --max-time 10 "$SUB")
    # 订阅服务本身要出网，网断了就退回它上次落盘的缓存
    [ -n "$links" ] || links=$(cat "$HOME/.v2rayn-tun/subcache/sub.txt" 2>/dev/null)
    [ -n "$links" ] || die "订阅服务和缓存都没有住宅线路（$SUB）"
    echo "$links" | grep -oE '@[0-9.]+:[0-9]+' | sed 's/^@//' | sort -u |
    awk -v base="$BASE_PORT" '{ printf "%d %s\n", base + NR - 1, $0 }'
}

write_plist() {
    mkdir -p "$(dirname "$PLIST")"
    cat >"$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SELF</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>15</integer>
    <key>StandardErrorPath</key><string>/tmp/residential-relay.log</string>
    <key>StandardOutPath</key><string>/tmp/residential-relay.log</string>
</dict>
</plist>
PLISTEOF
    plutil -lint "$PLIST" >/dev/null || die "plist 校验失败"
}

DB="$HOME/Library/Application Support/v2rayN/guiConfigs/guiNDB.db"

# 把 v2rayN 里那 4 条住宅线路的 Address 改到本地转发 / 改回真实入口。
# 必须让 v2rayN 先退出，否则它退出时会用内存里的值覆盖回去。
repoint() {
    local want="$1"   # point|restore
    [ -s "$TARGETS" ] || die "缺少 $TARGETS（先跑 on）"
    osascript -e 'quit app "v2rayN"' >/dev/null 2>&1
    for _ in $(seq 1 20); do pgrep -x v2rayN >/dev/null || break; sleep 0.5; done
    pgrep -x v2rayN >/dev/null && die "v2rayN 没退掉，先手动退出再跑"
    /usr/bin/python3 - "$DB" "$TARGETS" "$want" <<'PYEOF'
import sqlite3, sys
db, targets, want = sys.argv[1], sys.argv[2], sys.argv[3]
rows = []
for line in open(targets):
    port, dest = line.split()
    ip, rport = dest.rsplit(":", 1)
    rows.append((int(port), ip, int(rport)))
con = sqlite3.connect(db)
n = 0
for lport, ip, rport in rows:
    if want == "point":
        n += con.execute("update ProfileItem set Address='127.0.0.1', Port=? "
                         "where Address=? and Port=?", (lport, ip, rport)).rowcount
    else:
        n += con.execute("update ProfileItem set Address=?, Port=? "
                         "where Address='127.0.0.1' and Port=?", (ip, rport, lport)).rowcount
con.commit()
print(f"  {'已指向本地转发' if want == 'point' else '已还原真实入口'}：{n} 条线路")
PYEOF
    open -a v2rayN
}

case "${1:-status}" in
point|restore)
    repoint "$1"
    ;;
on)
    collect_targets >"$TARGETS" || exit 1
    [ "$(wc -l <"$TARGETS" | tr -d ' ')" -gt 0 ] || die "订阅里没解析出住宅入口"
    echo "转发目标（本地端口 -> 远端）:"
    sed 's/^/    /' "$TARGETS"
    write_plist
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
    launchctl bootstrap "$DOMAIN" "$PLIST" || die "launchd 装载失败"
    sleep 3
    "$SELF" status
    ;;
off)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null && echo "  ✓ 已卸载 launchd 任务" || echo "  · 本来就没在跑"
    rm -f "$PLIST"
    pkill -f -- "-L $BASE_PORT:" 2>/dev/null
    ;;
run)
    [ -s "$TARGETS" ] || die "缺少 $TARGETS（先跑 on）"
    args=()
    while read -r port dest; do
        args+=(-L "$port:$dest")
    done <"$TARGETS"
    exec ssh -N \
        -o BatchMode=yes \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3 \
        -o ConnectTimeout=10 \
        "${args[@]}" "$JUMP"
    ;;
status)
    rc=0
    if [ -f "$TARGETS" ]; then
        while read -r port dest; do
            if nc -z -G 2 127.0.0.1 "$port" >/dev/null 2>&1; then
                printf "  ✓ %-6s -> %s\n" "$port" "$dest"
            else
                printf "  ✗ %-6s -> %s (没在听)\n" "$port" "$dest"
                rc=1
            fi
        done <"$TARGETS"
    else
        echo "  · 未启用（$TARGETS 不存在）"
        rc=1
    fi
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || { echo "  · launchd 任务未装载"; rc=1; }
    exit $rc
    ;;
*)
    echo "用法: $0 on|off|status|run" >&2
    exit 2
    ;;
esac
