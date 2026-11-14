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

# 默认用 huawei2 (124.71.228.242)。
# 原来默认 huawei1 (1.92.76.152)，但对方经它连总是失败，换 huawei2 就好了。
# 两台配置一样，可以随时用 EXPOSE_JUMP=huawei1 切回去。
JUMP_HOST="${EXPOSE_JUMP:-huawei2}"
JUMP_PORT="${EXPOSE_PORT:-30022}"
LOCAL_SSHD_PORT=22
RUNDIR="$HOME/.expose-ssh"
PIDFILE="$RUNDIR/tunnel.pid"
LOGFILE="$RUNDIR/tunnel.log"
STATEFILE="$RUNDIR/state"

mkdir -p "$RUNDIR"

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

cmd_on() {
    if is_up; then
        say "✓ 隧道已经在跑  pid=$(cat "$PIDFILE")"
        return 0
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
                -o ServerAliveInterval=15 \
                -o ServerAliveCountMax=3 \
                -o ExitOnForwardFailure=yes \
                -o StrictHostKeyChecking=accept-new \
                -o TCPKeepAlive=yes \
                -R "0.0.0.0:${JUMP_PORT}:127.0.0.1:${LOCAL_SSHD_PORT}" \
                "$JUMP_HOST" >>"$LOGFILE" 2>&1
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
        say "    ssh -J $JUMP_HOST -p $JUMP_PORT $(whoami)@127.0.0.1"
        say ""
        say "  说明：跳板机 sshd 的 GatewayPorts 是 no，反向端口只能绑它自己的"
        say "        127.0.0.1，所以外部必须先跳到跳板机（-J），再连 127.0.0.1。"
        say "        想直接 ssh -p $JUMP_PORT ...@$jh，需要在跳板机设 GatewayPorts"
        say "        clientspecified 并重启 sshd。"
    else
        say "✗ 隧道没起来，看日志: $LOGFILE"
        tail -5 "$LOGFILE" | sed 's/^/    /'
        rm -f "$PIDFILE"
        return 1
    fi
}

cmd_off() {
    local stopped=0
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
    if is_up; then
        say "隧道状态    运行中  pid=$(cat "$PIDFILE")"
        say "启动时间    $(cat "$STATEFILE" 2>/dev/null | awk '{print $2" "$3}')"
    else
        say "隧道状态    未运行"
        say "上次操作    $(cat "$STATEFILE" 2>/dev/null || echo '无记录')"
    fi
    say ""
    say "最近日志:"
    tail -3 "$LOGFILE" 2>/dev/null | sed 's/^/    /' || say "    (空)"
}

case "${1:-status}" in
    on)     cmd_on ;;
    off)    cmd_off ;;
    status) cmd_status ;;
    *)      say "用法: $0 {on|off|status}"; exit 1 ;;
esac
