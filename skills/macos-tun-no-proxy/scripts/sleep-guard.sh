#!/bin/bash
#
# 合盖不休眠 —— 守护进程
#
# 背景(实测数据):
#   合盖 -> 'Clamshell Sleep' -> Wi-Fi 关闭, utun 接口被系统撤掉
#   开盖 -> 唤醒, Wi-Fi 立刻重连, 但 TUN 要 ~30 秒才重建
#        -> 这段窗口里【所有应用都是直连】, 真实 IP 会发出去
#   2026-10-12 的实测:
#     23:34:21 唤醒 / 23:34:52 才撤掉重建 TUN   <- 31 秒, 就是 dnsguard 的轮询周期
#   对 Claude / ChatGPT, 一次带真实(中国)IP 的请求就足够触发风控。
#
# 本脚本管两件事:
#   1. 开机自检: 确保 pmset disablesleep = 1
#      这个值本身写在 /Library/Preferences/com.apple.PowerManagement.plist 里,
#      重启是保持的 —— 但系统大版本升级 / 重置 NVRAM 可能清掉它。
#
#   2. 过热保护: 合盖 + 长时间无操作时, 主动放开睡眠
#      disablesleep 会阻止【包括合盖在内】的所有睡眠。合盖装进包里会持续
#      运行发热, 严重时可能损坏机器。所以设一个超时: 超过 IDLE_LIMIT 秒
#      没有任何输入, 就让它正常睡; 一旦有活动(开盖/触碰)立刻恢复禁止。
#      日常"教学楼走 3-5 分钟"远小于这个阈值, 不会被触发。
#
# 日志: /var/log/v2rayn-sleepguard.log
# 可调: echo 秒数 > "~/Library/Application Support/v2rayN/no-sleep-timeout"

set -u

SLEEP_DISABLE_THRESHOLD=2400   # 默认 40 分钟。合盖空闲超过它就放开睡眠。
POLL=60                        # 检查间隔(秒)
LOG=/var/log/v2rayn-sleepguard.log
TIMEOUT_FLAG="__USER_HOME__/Library/Application Support/v2rayN/no-sleep-timeout"

log() { echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null; }

# 读用户自定义阈值 (秒)
if [ -r "$TIMEOUT_FLAG" ]; then
    v=$(/usr/bin/tr -dc '0-9' < "$TIMEOUT_FLAG" 2>/dev/null)
    [ -n "$v" ] && [ "$v" -ge 60 ] 2>/dev/null && SLEEP_DISABLE_THRESHOLD=$v
fi

# 日志轮转
if [ -f "$LOG" ] && [ "$(/usr/bin/stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
    /usr/bin/tail -200 "$LOG" > "$LOG.tmp" 2>/dev/null && /bin/mv "$LOG.tmp" "$LOG"
fi

sleep_disabled() {
    /usr/bin/pmset -g 2>/dev/null | /usr/bin/grep -qE "SleepDisabled[[:space:]]+1"
}

set_sleep_disabled() {
    /usr/bin/pmset -a disablesleep "$1" >/dev/null 2>&1
}

lid_closed() {
    /usr/sbin/ioreg -r -k AppleClamshellState -d 4 2>/dev/null \
        | /usr/bin/grep -q '"AppleClamshellState" = Yes'
}

idle_seconds() {
    /usr/sbin/ioreg -c IOHIDSystem 2>/dev/null \
        | /usr/bin/awk '/HIDIdleTime/ { printf "%d", $NF/1000000000; exit }'
}

log "=== sleep-guard 启动 (合盖空闲阈值 ${SLEEP_DISABLE_THRESHOLD}s, 轮询 ${POLL}s) ==="

# 开机先确保禁止睡眠
if ! sleep_disabled; then
    set_sleep_disabled 1
    sleep 1
    if sleep_disabled; then
        log "开机自检: 已启用 disablesleep (合盖不休眠)"
    else
        log "⚠ 开机自检失败: 无法设置 disablesleep"
    fi
else
    log "开机自检: disablesleep 已是启用状态"
fi

while true; do
    LID=no;  lid_closed && LID=yes
    IDLE=$(idle_seconds); [ -z "$IDLE" ] && IDLE=0

    if [ "$LID" = "yes" ] && [ "$IDLE" -ge "$SLEEP_DISABLE_THRESHOLD" ]; then
        # 合盖 + 长时间无人操作 -> 放开睡眠, 保护机器
        if sleep_disabled; then
            set_sleep_disabled 0
            log "合盖且空闲 ${IDLE}s (阈值 ${SLEEP_DISABLE_THRESHOLD}s) -> 放开睡眠以保护硬件"
        fi
    else
        # 其他任何情况 -> 确保不睡
        if ! sleep_disabled; then
            set_sleep_disabled 1
            log "检测到活动 (开盖或输入) -> 恢复禁止睡眠"
        fi
    fi

    sleep "$POLL"
done
