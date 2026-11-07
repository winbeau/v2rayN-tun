#!/bin/bash
# v2rayN TUN 守护 (root): 建/撤 TUN、kill-switch、地址变化重建
# v2rayN TUN 守护包装脚本 (root)
#
# 架构:  sing-box TUN (root) --> socks --> 127.0.0.1:10808 --> xray (v2rayN) --> 节点
#
# 为什么需要这个包装脚本:
#   TUN 一旦启用就会接管默认路由。如果 v2rayN 没在运行(10808 无人监听),
#   所有流量都会被丢进一个死掉的代理里, 导致整机断网。
#   所以这里持续探测 10808: 代理就绪才拉起 TUN, 代理下线立刻撤掉 TUN。
#
# 路由环路如何避免:
#   xray / sing-box 自身去连节点的流量不能再次被 TUN 吞掉,
#   这在 config.json 的 route.rules 里用 process_path 规则强制走 direct 解决。
#
# ============ 两个用户可写的开关 (都无需 sudo, 最多 5 秒生效) ============
#   1) 临时关闭 TUN:   touch "$FLAG"      恢复: rm "$FLAG"
#   2) 临时改 MTU:     echo 1500 > "$MTU_FLAG"   恢复默认: rm "$MTU_FLAG"
#      取值 576-9000。生成后会用 sing-box check 校验, 失败自动回退默认配置。
#      两个文件都只影响你自己的 TUN, 不构成提权面。
#

set -u

BASE=/usr/local/libexec/v2rayn-tun
SINGBOX="$BASE/sing-box"
CONF="$BASE/config.json"
RUN_CONF="$BASE/config.run.json"
PROXY_PORT=10808
LOG=/var/log/v2rayn-tun.log
POLL=5
# kill-switch 开关文件。存在时强制保持 TUN (即使 v2rayN 已退出也不撤)。
# 平时不需要它 —— 默认行为就是: v2rayN 在就保 TUN, v2rayN 走了才撤。
KS_FLAG="__USER_HOME__/Library/Application Support/v2rayN/killswitch-always"

# __USER_HOME__ 由 install.sh 在安装时替换为实际用户主目录
FLAG="__USER_HOME__/Library/Application Support/v2rayN/tun-disabled"
MTU_FLAG="__USER_HOME__/Library/Application Support/v2rayN/tun-mtu"
# TUN 排除清单（用户可编辑）。校园网 10.0.0.0/8 和 WireGuard 段都在这里。
EXCLUDE_FILE="__USER_HOME__/.v2rayn-tun/tun-exclude.txt"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

# 用户主动创建的"始终开启 kill-switch"开关
KILLSWITCH_FLAG="$KS_FLAG"

# v2rayN 进程是否存活 —— 用来区分"代理暂时不可用"和"用户主动退出"
v2rayn_alive() {
    /usr/bin/pgrep -x v2rayN >/dev/null 2>&1
}

# sing-box 是否真的还活着。
# ⚠️ 不能只看 $SB_PID 非空 —— 进程可能已经崩了而变量还留着。
#    在 kill-switch 分支里这个区别是致命的: 以为"TUN 保持中", 实际接口早没了,
#    路由已经回到直连, 代理又不可用 —— 正好是最危险的组合。
sb_alive() {
    [ -n "$SB_PID" ] && kill -0 "$SB_PID" 2>/dev/null
}

proxy_up() {
    /usr/bin/nc -z -w 2 127.0.0.1 "$PROXY_PORT" >/dev/null 2>&1
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
            if not (r.get("outbound") == "direct" and set(r.get("ip_cidr") or []) == target)]
pos = next((i for i, r in enumerate(rules) if r.get("action") == "hijack-dns"), len(rules))
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
FLAG_LOGGED=""
LAST_MTU=""
# 代理掉线的时刻 (epoch 秒)。空 = 代理正常。用于宽限期倒计时。
DOWN_SINCE=""

start_tun() {
    local info
    info=$(prepare_conf)
    /usr/sbin/chown root:wheel "$RUN_CONF" 2>/dev/null
    /bin/chmod 644 "$RUN_CONF" 2>/dev/null
    LAST_MTU="$info"

    "$SINGBOX" run -c "$RUN_CONF" >>"$LOG" 2>&1 &
    SB_PID=$!
    log "TUN 已启动 sing-box pid=$SB_PID ($info)"
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

log "=== v2rayn-tun 守护启动 (探测端口 $PROXY_PORT) ==="

while true; do
    # ---- 开关 1: 停用 TUN ----
    if [ -e "$FLAG" ]; then
        if [ "$FLAG_LOGGED" != "disabled" ]; then
            log "检测到开关文件, TUN 保持关闭: $FLAG"
            FLAG_LOGGED="disabled"
        fi
        [ -n "$SB_PID" ] && { log "开关文件已存在, 撤掉 TUN"; stop_tun; }
        sleep "$POLL"
        continue
    fi
    if [ "$FLAG_LOGGED" = "disabled" ]; then
        log "开关文件已移除, TUN 恢复启用"
        FLAG_LOGGED=""
    fi

    # ---- 自动模式: 代理就绪才建 TUN ----
    if proxy_up; then
        if ! sb_alive; then
            start_tun
            sleep 3
            if ! sb_alive; then
                log "sing-box 立即退出, 请检查上方错误输出"
                SB_PID=""
                sleep 10
            fi
        fi
        DOWN_SINCE=""
    else
        # 代理端口下线。分两种情况, 区别很关键:
        #
        #   A. v2rayN 进程还在 —— 只是代理暂时不可用(节点故障/正在重连/DNS 抖动)。
        #      → 【保持 TUN】, 不撤。
        #        国外流量走 proxy 出口 -> 10808 已死 -> 连接失败,
        #        但它【绝不会】绕出去用真实 IP 直连。
        #        国内流量走 direct 出口(sing-box 的 auto_detect_interface 让它绑
        #        物理网卡, 不经过 TUN), 所以国内照常可用 —— 不会被卡死。
        #        节点恢复后自动接上, 不存在死锁(xray 走 direct 出口能连到节点)。
        #
        #   B. v2rayN 进程已退出 —— 用户主动退出。
        #      → 【撤掉 TUN】, 恢复直连, 系统不留任何痕迹。
        #
        # 这样"任何意外都不漏真实 IP"和"退出即干净"两个需求同时满足。
        if [ -e "$KILLSWITCH_FLAG" ] || v2rayn_alive; then
            if sb_alive; then
                NOW=$(/bin/date +%s)
                if [ -z "$DOWN_SINCE" ]; then
                    DOWN_SINCE=$NOW
                    log "代理端口 $PROXY_PORT 已下线, 但 v2rayN 仍在运行 -> 保持 TUN (kill-switch: 国外连接会失败而非泄漏真实 IP)"
                fi
            else
                # sing-box 崩了 —— 这时 TUN 接口其实已经没了, 路由回到直连,
                # 而代理又不可用, 正好是最危险的组合。
                # 必须立刻把它拉起来, 否则 kill-switch 形同虚设。
                log "⚠ 代理不可用且 sing-box 已死 -> 重建 TUN 以维持 kill-switch"
                SB_PID=""
                start_tun
                sleep 3
                if ! sb_alive; then
                    log "❌ 重建 sing-box 失败, kill-switch 暂时失效"
                    SB_PID=""
                    sleep 10
                fi
            fi
        else
            if sb_alive; then
                log "v2rayN 已退出, 撤掉 TUN (干净退出)"
                stop_tun
            fi
            SB_PID=""
            DOWN_SINCE=""
        fi
    fi
    sleep "$POLL"
done
