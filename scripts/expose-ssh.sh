#!/bin/bash
# 把本机的 SSH 通过反向隧道挂到跳板机，随时可断。
#
#   expose-ssh.sh on       开隧道
#   expose-ssh.sh off      断隧道 + 跳板机封端口
#   expose-ssh.sh status   看状态
#
# 结构:
#   外部 ── ssh -p 30022 <user>@<jump> ──▶ 跳板机:30022
#                                          │ 反向隧道
#                                          └──▶ 本机 127.0.0.1:22
#
# 安全设计（重要）:
#   · 本机 sshd 只允许从 127.0.0.1 连 —— 局域网里也进不来
#   · 唯一的入口就是这条隧道
#   · off 之后跳板机的端口也会一起关掉，不留后门
set -uo pipefail

# 默认 huawei1 (1.92.76.152)，走【单跳】：端口绑 0.0.0.0，外部直接连。
#
# 为什么之前是两跳：huawei1 的 /etc/ssh/sshd_config.d/90-router.conf 里
# GatewayPorts 和 PermitListen 都写在 `Match User router` 下，只对 router
# 用户生效；winbeau 建的 -R 一律落回 127.0.0.1，外部进不来。
# 2026-11-14 加了 95-winbeau-tunnel.conf（Match User winbeau，
# GatewayPorts clientspecified + PermitListen *:30022）之后就通了。
#
# huawei2 (124.71.228.242) 没有那段配置，只能绑 127.0.0.1，
# 用它会退回两跳（需要 -J）。要单跳请留在 huawei1。
# 按 cann-tools/expose-public 的约定：中继用户固定是 router，
# 端口从 22001-22007 这个池子里取（router 的 PermitListen 只放行这些）。
# 已占用: 22003、22007(pi4)。本机用 22001。
JUMP_HOST="${EXPOSE_JUMP:-huawei1}"
RELAY_USER="${EXPOSE_USER:-router}"
RELAY_KEY="${EXPOSE_KEY:-$HOME/.ssh/id_ed25519_relay}"
LOGIN_USER="${EXPOSE_LOGIN:-$(whoami)}"
JUMP_PORT="${EXPOSE_PORT:-22001}"
LOCAL_SSHD_PORT=22
RUNDIR="$HOME/.expose-ssh"
PLIST="$HOME/Library/LaunchAgents/com.local.expose-ssh.plist"
LABEL="com.local.expose-ssh"
HEAL_LABEL="com.local.expose-ssh-heal"
HEAL_PLIST="$HOME/Library/LaunchAgents/$HEAL_LABEL.plist"
PIDFILE="$RUNDIR/tunnel.pid"
LOGFILE="$RUNDIR/tunnel.log"
STATEFILE="$RUNDIR/state"

mkdir -p "$RUNDIR"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

say() { printf '%s\n' "$*"; }

need_sshd() {
    # ⚠️ 不能用 lsof 检测 —— 普通用户看不到 root 监听 22 端口，
    #    会误判成「sshd 没开」。用 nc 实际连一下才准。
    if ! nc -z -G 2 -w 2 127.0.0.1 $LOCAL_SSHD_PORT >/dev/null 2>&1; then
        say "✗ 本机 sshd 没开"
        say ""
        say "  先打开： 系统设置 → 通用 → 共享 → 远程登录"
        say "  或者：   sudo systemsetup -setremotelogin on"
        say "          （这条需要终端有「完全磁盘访问权限」）"
        return 1
    fi
    return 0
}

is_up() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
}

# 定期自检：本地进程看着正常、对端却没监听的情况，只能从对端发现（见 heal）
write_heal_plist() {
    mkdir -p "$(dirname "$HEAL_PLIST")"
    cat >"$HEAL_PLIST" <<HEALEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$HEAL_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SELF</string>
        <string>heal</string>
    </array>
    <key>StartInterval</key><integer>600</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardErrorPath</key><string>$RUNDIR/heal.log</string>
    <key>StandardOutPath</key><string>$RUNDIR/heal.log</string>
</dict>
</plist>
HEALEOF
    plutil -lint "$HEAL_PLIST" >/dev/null
}

cmd_on() {
    # 有 LaunchAgent 就用它 —— 开机自启 + 崩溃自动拉起，比脚本里 while 循环可靠
    if [ -f "$PLIST" ]; then
        write_heal_plist && launchctl bootout "gui/$(id -u)/$HEAL_LABEL" 2>/dev/null;
        launchctl bootstrap "gui/$(id -u)" "$HEAL_PLIST" 2>/dev/null
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
        if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
            sleep 4
            if launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -q "state = running"; then
                say "✓ 已由 launchd 托管（开机自启）  pid=$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | awk '/pid =/{print $3; exit}')"
                sleep 1
                local jh; jh=$(ssh -G "$JUMP_HOST" | awk '/^hostname /{print $2}')
                say ""
                say "  从外面连："
                say "    ssh -p $JUMP_PORT ${LOGIN_USER}@$jh"
                return 0
            fi
        fi
        say "  launchd 启动失败，回退到脚本托管"
    fi

    need_sshd || return 1

    say "→ 建立反向隧道 $JUMP_HOST:$JUMP_PORT -> 127.0.0.1:$LOCAL_SSHD_PORT"
    # -R 0.0.0.0: 需要在跳板机 sshd 配 GatewayPorts clientspecified
    # -R 只写端口号时，跳板机默认绑 127.0.0.1，外部进不来，所以要显式写 0.0.0.0
    # 用一层 while 循环包住 ssh —— 断线后自动重连。
    # 起因: 从热点切到校园网时 TCP 被重置，一次性 ssh -N 不会恢复，
    #       跳板机端口消失，外部连进来是 Connection refused（看起来像认证被拒）。
    (
        while :; do
            ssh -N \
                -i "$RELAY_KEY" -o IdentitiesOnly=yes \
                -o ServerAliveInterval=15 \
                -o ServerAliveCountMax=3 \
                -o ExitOnForwardFailure=yes \
                -o StrictHostKeyChecking=accept-new \
                -o TCPKeepAlive=yes \
                -R "0.0.0.0:${JUMP_PORT}:127.0.0.1:${LOCAL_SSHD_PORT}" \
                "${RELAY_USER}@${JUMP_HOST}" >>"$LOGFILE" 2>&1
            echo "[$(date '+%F %T')] 隧道断开，3 秒后重连" >>"$LOGFILE"
            sleep 3
        done
    ) </dev/null >>"$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    echo "on $(date '+%F %T')" > "$STATEFILE"

    sleep 3
    if is_up; then
        say "✓ 隧道已建立  pid=$(cat "$PIDFILE")"
        say ""
        local jh
        jh=$(ssh -G "$JUMP_HOST" | awk '/^hostname /{print $2}')
        say "  从外面连："
        say "    ssh -p $JUMP_PORT ${LOGIN_USER}@$jh"
        say ""
        say "  中继: ${RELAY_USER}@${JUMP_HOST}，端口 ${JUMP_PORT} 绑 0.0.0.0，单跳可连。"
        say "  如果连不通，先在跳板机确认：ss -lnt | grep ${JUMP_PORT}"
    else
        say "✗ 隧道没起来，看日志: $LOGFILE"
        tail -5 "$LOGFILE" | sed 's/^/    /'
        rm -f "$PIDFILE"
        return 1
    fi
}

cmd_off() {
    launchctl bootout "gui/$(id -u)/$HEAL_LABEL" 2>/dev/null
    rm -f "$HEAL_PLIST"
    local stopped=0
    if [ -f "$PLIST" ]; then
        write_heal_plist && launchctl bootout "gui/$(id -u)/$HEAL_LABEL" 2>/dev/null;
        launchctl bootstrap "gui/$(id -u)" "$HEAL_PLIST" 2>/dev/null
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && stopped=1
        say "  ✓ 已停止 launchd 托管"
    fi
    if is_up; then
        kill "$(cat "$PIDFILE")" 2>/dev/null && stopped=1
        sleep 1
        kill -9 "$(cat "$PIDFILE")" 2>/dev/null
    fi
    rm -f "$PIDFILE"
    echo "off $(date '+%F %T')" > "$STATEFILE"

    # 兜底: 杀掉任何残留的到该跳板机的 -R 隧道
    pkill -f "ssh .*-R 0.0.0.0:${JUMP_PORT}:127.0.0.1:${LOCAL_SSHD_PORT}.*${JUMP_HOST}" 2>/dev/null && stopped=1
    # 循环本身也要杀，否则会马上把 ssh 拉起来
    pkill -f "expose-ssh.*${JUMP_PORT}" 2>/dev/null

    say "✓ 隧道已断"
    [ "$stopped" = "1" ] && say "  跳板机的 $JUMP_PORT 端口随隧道消失，外部无法再连"
}

cmd_status() {
    local jh
    jh=$(ssh -G "$JUMP_HOST" 2>/dev/null | awk '/^hostname /{print $2}')
    say "跳板机      $JUMP_HOST  ($jh)"
    say "公网端口    $JUMP_PORT"
    if nc -z -G 2 -w 2 127.0.0.1 $LOCAL_SSHD_PORT >/dev/null 2>&1; then
        say "本机 sshd   127.0.0.1:$LOCAL_SSHD_PORT 监听中 ✓"
    else
        say "本机 sshd   未监听 ✗"
    fi
    say ""
    if launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -q "state = running"; then
        say "托管方式    launchd（开机自启）"
        say "隧道状态    运行中"
    elif is_up; then
        say "隧道状态    运行中  pid=$(cat "$PIDFILE")"
        say "启动时间    $(cat "$STATEFILE" 2>/dev/null | awk '{print $2" "$3}')"
    else
        say "隧道状态    未运行"
        say "上次操作    $(cat "$STATEFILE" 2>/dev/null || echo '无记录')"
    fi
    say ""
    # ⚠️ 本地进程活着 ≠ 隧道能用。2026-11-21 进程连着、跳板机上却没有监听，
    #    「Error: remote port forwarding failed」刷了几百次，本地完全看不出来。
    #    必须去跳板机确认端口在听、并且真的连到了本机 sshd。
    remote_check
    say ""
    say "最近日志:"
    local logfile="$LOGFILE"
    launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 &&
        [ -s "$RUNDIR/launchd.log" ] && logfile="$RUNDIR/launchd.log"
    tail -3 "$logfile" 2>/dev/null | sed 's/^/    /' || say "    (空)"
}

# 自愈：对端不通就重建隧道（本地进程状态不可信，见 remote_check 的注释）
cmd_heal() {
    # 刚启动时对端还没绑上，先给 3 次机会再判定，避免自己把自己重启掉
    for _ in 1 2 3; do
        remote_alive && break
        sleep 5
    done
    if remote_alive; then
        say "✓ 隧道可用（$JUMP_HOST:$JUMP_PORT → 本机 sshd）"
        return 0
    fi
    say "· 对端不可达，重建隧道"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
    sleep 2
    if [ -f "$PLIST" ]; then
        launchctl bootstrap "gui/$(id -u)" "$PLIST" || { say "✗ launchd 装载失败"; return 1; }
    else
        say "✗ 没有 $PLIST，先跑 on"; return 1
    fi
    for _ in 1 2 3 4 5 6; do
        sleep 3
        remote_alive && { say "✓ 已恢复"; return 0; }
    done
    say "✗ 重建后仍不可达，看 $RUNDIR/launchd.log"
    return 1
}

# 在跳板机上验证：一路连到本机 sshd 才算通（能换到 SSH banner）
# 只连端口不抓 banner 是不够的 —— 端口在听但隧道没连到本机时也"能连上"。
remote_probe() {
    ssh -T -i "$RELAY_KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
        -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
        "${RELAY_USER}@${JUMP_HOST}" \
        "timeout 6 bash -c 'exec 3<>/dev/tcp/127.0.0.1/${JUMP_PORT}; head -c 8 <&3'" 2>/dev/null
}

remote_alive() { remote_probe | grep -q "SSH-2.0"; }

remote_check() {
    local out
    out=$(remote_probe)
    if printf '%s' "$out" | grep -q "SSH-2.0"; then
        say "公网可达    $JUMP_HOST:$JUMP_PORT → 本机 sshd ✓"
    elif [ -n "$out" ]; then
        say "公网可达    $JUMP_HOST:$JUMP_PORT 有响应但不是 SSH ✗"
    else
        say "公网可达    $JUMP_HOST:$JUMP_PORT 连不上 ✗（本地进程活着也没用）"
    fi
}

# 前台跑一条 ssh（不带 while 循环）—— 交给 launchd 的 KeepAlive 重启。
# 比脚本自己 while 循环更可靠：launchd 会在崩溃、唤醒、切网后自动拉起。
cmd_run() {
    need_sshd || return 1
    exec ssh -N \
        -i "$RELAY_KEY" -o IdentitiesOnly=yes \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3 \
        -o ExitOnForwardFailure=yes \
        -o StrictHostKeyChecking=accept-new \
        -o TCPKeepAlive=yes \
        -R "0.0.0.0:${JUMP_PORT}:127.0.0.1:${LOCAL_SSHD_PORT}" \
        "${RELAY_USER}@${JUMP_HOST}"
}

case "${1:-status}" in
    run)    cmd_run ;;
    on)     cmd_on ;;
    off)    cmd_off ;;
    status) cmd_status ;;
    heal)   cmd_heal ;;
    *)      say "用法: $0 {on|off|status}"; exit 1 ;;
esac
