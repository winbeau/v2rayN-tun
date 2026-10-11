#!/bin/bash
#
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

# __USER_HOME__ 由 install.sh 在安装时替换为实际用户主目录
FLAG="__USER_HOME__/Library/Application Support/v2rayN/tun-disabled"
MTU_FLAG="__USER_HOME__/Library/Application Support/v2rayN/tun-mtu"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

proxy_up() {
    /usr/bin/nc -z -w 2 127.0.0.1 "$PROXY_PORT" >/dev/null 2>&1
}

# 依据用户开关生成实际使用的配置; 校验不过就回退
prepare_conf() {
    local mtu
    mtu=$(/usr/bin/head -c 16 "$MTU_FLAG" 2>/dev/null | /usr/bin/tr -dc '0-9')
    case "$mtu" in ''|*[!0-9]*) mtu="" ;; esac

    if [ -n "$mtu" ] && [ "$mtu" -ge 576 ] && [ "$mtu" -le 9000 ]; then
        /usr/bin/sed "s/\"mtu\": [0-9]*/\"mtu\": $mtu/" "$CONF" > "$RUN_CONF" 2>/dev/null
        if "$SINGBOX" check -c "$RUN_CONF" >/dev/null 2>&1; then
            echo "mtu=$mtu"
            return
        fi
        log "自定义 MTU $mtu 生成的配置校验失败, 回退默认配置"
    fi

    /bin/cp "$CONF" "$RUN_CONF"
    echo "mtu=default"
}

SB_PID=""
FLAG_LOGGED=""
LAST_MTU=""

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
        if [ -z "$SB_PID" ] || ! kill -0 "$SB_PID" 2>/dev/null; then
            start_tun
            sleep 3
            if ! kill -0 "$SB_PID" 2>/dev/null; then
                log "sing-box 立即退出, 请检查上方错误输出"
                SB_PID=""
                sleep 10
            fi
        fi
    else
        if [ -n "$SB_PID" ]; then
            log "代理端口 $PROXY_PORT 已下线, 撤掉 TUN 以免断网"
            stop_tun
        fi
    fi
    sleep "$POLL"
done
