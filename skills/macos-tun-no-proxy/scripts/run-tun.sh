#!/bin/bash
# v2rayN controls the TUN. Kernel fallback routes survive sing-box restarts.
set -u

BASE=/usr/local/libexec/v2rayn-tun
SINGBOX="$BASE/sing-box"
CONF="$BASE/config.json"
RUN_CONF="$BASE/config.run.json"
GUARD="$BASE/route-guard.py"
EXCL_CONF="$BASE/config.excludes.json"
LOG=/var/log/v2rayn-tun.log
POLL=5
BOUND_STATE=/var/run/v2rayn-tun.bound
GAP_CHECK=/var/run/v2rayn-tun.gap-check
MTU_FLAG="__USER_HOME__/Library/Application Support/v2rayN/tun-mtu"
# TUN 排除清单（用户可编辑）。校园网 10.0.0.0/8 和 WireGuard 段都在这里。
EXCLUDE_FILE="__USER_HOME__/.v2rayn-tun/tun-exclude.txt"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

# v2rayN 进程是否存活 —— 用来区分"代理暂时不可用"和"用户主动退出"
v2rayn_alive() {
    /usr/bin/pgrep -x v2rayN >/dev/null 2>&1
}

# 进程存活但 utun 已被系统撤掉时，也要重建。
sb_alive() {
    [ -n "$SB_PID" ] && kill -0 "$SB_PID" 2>/dev/null &&
        /sbin/ifconfig -a | awk -v addr="$TUN_ADDR" '
            /^[^[:space:]]/ { tun = ($1 ~ /^utun[0-9]+:$/) }
            tun && ($1 == "inet" || $1 == "inet6") && $2 == addr { found = 1 }
            END { exit !found }'
}

# 依据用户开关生成实际使用的配置; 校验不过就回退
# 把 $EXCLUDE_FILE 里的网段合并进 route_exclude_address，并保证
# 「目标=排除网段 -> direct」的规则存在。
#
# ⚠️ 必须每次启动都做，不能只在装的时候写一次：
#    fix-loop.sh / per-app-routing.py 会重写 route_exclude_address，
#    只留节点 IP。如果不在这里兜底，排除清单会被冲掉，
#    校园网和 WireGuard 就又被 TUN 吃走了。
apply_excludes() {
    [ -f "$RUN_CONF" ] || return 0
    /usr/bin/python3 - "$RUN_CONF" "$EXCLUDE_FILE" <<'PYEOF' 2>/dev/null || true
import json, os, sys, collections

conf, excl_file = sys.argv[1], sys.argv[2]
d = json.load(open(conf, encoding="utf-8"), object_pairs_hook=collections.OrderedDict)

tun = next((i for i in d.get("inbounds", []) if i.get("type") == "tun"), None)
if tun is None:
    raise SystemExit(0)

# 现有排除（来自 config.json 的节点 IP）
excl = list(tun.get("route_exclude_address") or [])

# 加上用户清单
if os.path.exists(excl_file):
    for line in open(excl_file, encoding="utf-8"):
        line = line.split("#")[0].strip()
        if line and line not in excl:
            excl.append(line)

tun["route_exclude_address"] = excl

# 规则层双保险：目标在排除网段内 -> direct
# 注意: 不要往规则里塞自定义字段（比如 _tun_excl）—— sing-box 会拒绝未知键，
#       check 失败后守护会回退到未合并的配置，规则就白加了。实测踩过。
rules = d.setdefault("route", {}).setdefault("rules", [])
target = set(excl)
rules[:] = [r for r in rules
            if not (r.get("outbound") == "direct" and "ip_cidr" in r
                    and set(r["ip_cidr"]) == target)]
pos = next((i for i, r in enumerate(rules) if r.get("action") == "hijack-dns"), len(rules))
if excl:
    rules.insert(pos, collections.OrderedDict([
        ("outbound", "direct"),
        ("ip_cidr", excl),
    ]))

json.dump(d, open(conf, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PYEOF
}

prepare_conf() {
    local mtu
    mtu=$(/usr/bin/head -c 16 "$MTU_FLAG" 2>/dev/null | /usr/bin/tr -dc '0-9')
    case "$mtu" in ''|*[!0-9]*) mtu="" ;; esac

    if [ -n "$mtu" ] && [ "$mtu" -ge 576 ] && [ "$mtu" -le 9000 ]; then
        /usr/bin/sed "s/\"mtu\": [0-9]*/\"mtu\": $mtu/" "$CONF" > "$RUN_CONF" 2>/dev/null
        apply_excludes
        if "$SINGBOX" check -c "$RUN_CONF" >/dev/null 2>&1; then
            echo "mtu=$mtu excl=$(excl_count)"
            return
        fi
        log "自定义 MTU $mtu 生成的配置校验失败, 回退默认配置"
    fi

    /bin/cp "$CONF" "$RUN_CONF"
    apply_excludes
    if ! "$SINGBOX" check -c "$RUN_CONF" >/dev/null 2>&1; then
        log "合并排除清单后校验失败, 回退到未合并的配置"
        /bin/cp "$CONF" "$RUN_CONF"
        echo "mtu=default excl=FAILED"
        return
    fi
    echo "mtu=default excl=$(excl_count)"
}

excl_count() {
    /usr/bin/python3 - "$RUN_CONF" 2>/dev/null <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
t = next((i for i in d.get("inbounds", []) if i.get("type") == "tun"), None)
print(len((t or {}).get("route_exclude_address") or []))
PYEOF
}

SB_PID=""
TUN_ADDR=""
GUARD_OFF=0

start_tun() {
    local info iface addr
    [ -n "$SB_PID" ] && stop_tun
    info=$(prepare_conf)
    /usr/sbin/chown root:wheel "$RUN_CONF" 2>/dev/null
    /bin/chmod 644 "$RUN_CONF" 2>/dev/null
    /bin/cp "$RUN_CONF" "$EXCL_CONF" &&
        /usr/bin/python3 "$GUARD" prepare "$RUN_CONF" &&
        "$SINGBOX" check -c "$RUN_CONF" &&
        /usr/bin/python3 "$GUARD" sync "$EXCL_CONF" || return 1

    TUN_ADDR=$(/usr/bin/python3 -c 'import json,sys; print(next(i for i in json.load(open(sys.argv[1]))["inbounds"] if i["type"] == "tun")["address"][0].split("/")[0])' "$RUN_CONF") || return 1
    # 在实际重建窗口查内核决定，不向测试地址发包。
    if /sbin/route -n get 1.1.1.1 2>/dev/null | grep -q 'flags:.*BLACKHOLE' &&
        /sbin/route -n get -inet6 2606:4700:4700::1111 2>/dev/null | grep -q 'flags:.*BLACKHOLE'; then
        echo blocked > "$GAP_CHECK"
    else
        echo other-route > "$GAP_CHECK"
        log "重建窗口测试地址未全部命中黑洞，请检查其他 VPN 的更具体路由"
    fi
    iface=$(/sbin/route -n get default 2>/dev/null | awk '/interface:/{print $2}')
    addr=$(/sbin/ifconfig "$iface" 2>/dev/null | awk '/inet /{print $2; exit}')
    "$SINGBOX" run -c "$RUN_CONF" >>"$LOG" 2>&1 &
    SB_PID=$!
    for _ in {1..20}; do
        if sb_alive; then
            # 记启动前的快照，启动期间再次切网也会被 dnsguard 察觉。
            echo "${iface:-offline} ${addr:--}" > "$BOUND_STATE.new" && /bin/mv -f "$BOUND_STATE.new" "$BOUND_STATE"
            log "TUN 已就绪 sing-box pid=$SB_PID ($info)"
            return 0
        fi
        kill -0 "$SB_PID" 2>/dev/null || break
        sleep 0.5
    done
    log "sing-box 或 TUN 接口未就绪，稍后重试"
    stop_tun
    return 1
}

stop_tun() {
    if [ -n "$SB_PID" ] && kill -0 "$SB_PID" 2>/dev/null; then
        kill "$SB_PID" 2>/dev/null
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$SB_PID" 2>/dev/null || break
            sleep 0.5
        done
        kill -9 "$SB_PID" 2>/dev/null
        log "TUN 已停止 sing-box pid=$SB_PID"
    fi
    SB_PID=""
    /bin/rm -f "$BOUND_STATE"
    # 立刻触发网络守护, 让它在代理下线时把 DNS 还原成原样。
    # 否则要等它下一次 30 秒轮询, 期间系统会残留一处非用户设置的 DNS。
    /bin/launchctl kickstart -k system/com.local.v2rayn-dnsguard 2>/dev/null || true
}

cleanup() {
    log "收到退出信号, 撤掉 TUN"
    stop_tun
    exit 0
}
trap cleanup TERM INT

log "=== v2rayn-tun 守护启动 ==="

while true; do
    if v2rayn_alive; then
        GUARD_OFF=0
        if sb_alive; then
            # DHCP 或默认网关变化时，刷新节点和内网的旁路。
            /usr/bin/python3 "$GUARD" sync "$EXCL_CONF" || log "断流路由同步失败，稍后重试"
        elif /usr/bin/python3 "$GUARD" arm; then
            start_tun || sleep 2
        fi
    elif [ "$GUARD_OFF" = 0 ]; then
        [ -n "$SB_PID" ] && stop_tun
        if /usr/bin/python3 "$GUARD" off; then
            GUARD_OFF=1
        fi
    fi
    sleep "$POLL"
done
