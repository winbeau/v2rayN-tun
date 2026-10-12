#!/bin/bash
#
# v2rayN 退出看门狗 —— 防止误按 Cmd+Q 把代理弄断
#
# 为什么需要它:
#   v2rayN 本身没有"退出确认"设置(主配置和 UI 项都查过)。
#   macOS 的 Cmd+Q 是系统级退出, 第三方无法拦截。
#   所以只能事后补救: 检测到它退出时, 如果还有正在用网的程序, 立刻拉回来。
#
# 配合 run-tun.sh 的 GRACE 宽限期, 效果是:
#   误按 Cmd+Q → 约 2 秒内 v2rayN 回来 → TUN 从未撤除 → 下载/对话不受影响
#
# 三种退出方式:
#   1. 直接 Cmd+Q           → 弹出确认窗口, 长按按钮才放行 (默认取消并恢复代理)
#   2. 弹窗里长按 N 秒      → 确认退出
#   3. 开关文件 allow-quit  → 直接放行, 不再拦截
#
# 状态机(关键):
#   ARMED=1  正在保护。v2rayN 若消失, 按上面的规则处理。
#   ARMED=0  刚放行过一次退出。此时**不**再拉回 v2rayN —— 否则你就永远退不出去。
#            等 v2rayN 自己重新启动后, 自动回到 ARMED=1。
#
# 本脚本常驻运行(LaunchAgent + KeepAlive), 不需要重启。
# 日志: ~/Library/Logs/v2rayn-quitguard.log

set -u

# __USER_HOME__ 由 install.sh 替换为实际用户主目录
V2RAYN_APP="/Applications/v2rayN.app"
V2RAYN_PROC="v2rayN"
FLAG_DIR="__USER_HOME__/Library/Application Support/v2rayN"
ALLOW_FLAG="$FLAG_DIR/allow-quit"
STATE_FILE="/tmp/v2rayn-quitguard.state"
LOG="__USER_HOME__/Library/Logs/v2rayn-quitguard.log"
DIALOG="/usr/local/libexec/v2rayn-tun/quit-guard-dialog"

POLL=1            # 轮询间隔(秒)。要短, 否则按下 Cmd+Q 后弹窗迟迟不出现。
HOLD_SECONDS=8    # 弹窗里需要按住多久才确认退出
DIALOG_TIMEOUT=12 # 弹窗自动取消的时间。必须小于 run-tun.sh 的 GRACE,
                  # 否则弹窗还没结束, TUN 就被撤了 —— 那就白保护了。
TUN_ADDR=172.19.0.1

mkdir -p "$(dirname "$LOG")" 2>/dev/null

log() {
    echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null
}

# 日志轮转: 超过 512KB 就只留最后 200 行
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 524288 ]; then
    tail -200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
fi

# ---------- 状态存取 ----------
# 存到文件里, 这样脚本被 launchd 重启后不会把"已放行"误判成"需要保护"
ARMED=1
LAST_BLOCK=0
if [ -r "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE" 2>/dev/null || true
fi
save_state() {
    printf 'ARMED=%s\nLAST_BLOCK=%s\n' "$ARMED" "$LAST_BLOCK" > "$STATE_FILE" 2>/dev/null
}

# ---------- 受保护进程 ----------
# 用 pgrep -x 精确匹配主进程名, 不会误命中 Chrome Helper / Safari 后台服务。
PROTECTED_TERMINALS=(
    Terminal iTerm2 iTerm Warp kitty wezterm WezTerm Alacritty Hyper Tabby ghostty
)
PROTECTED_BROWSERS=(
    Safari "Google Chrome" "Google Chrome Canary" Firefox firefox
    "Microsoft Edge" Arc "Brave Browser" Vivaldi Opera
)
PROTECTED_AI=(
    ChatGPT Claude Perplexity Cursor Bolt "LM Studio"
)

# 输出正在运行的受保护进程(逗号分隔), 可能为空
protected_apps() {
    local found=() name
    for name in "${PROTECTED_TERMINALS[@]}" "${PROTECTED_BROWSERS[@]}" "${PROTECTED_AI[@]}"; do
        /usr/bin/pgrep -x "$name" >/dev/null 2>&1 && found+=("$name")
    done
    # 浏览器"安装的 app"(PWA): Chrome/Edge 以 --app= 或 --app-id= 起的独立窗口。
    # 这类窗口没有独立进程名, 只能从命令行参数识别。
    if /usr/bin/pgrep -f -q -- '--app-id=' 2>/dev/null || /usr/bin/pgrep -f -q -- '--app=' 2>/dev/null; then
        found+=("浏览器PWA")
    fi
    if [ "${#found[@]}" -eq 0 ]; then return 0; fi
    printf '%s\n' "${found[@]}" | /usr/bin/awk 'NF' | /usr/bin/sort -u | /usr/bin/paste -sd, -
}

notify() {
    # 双引号和反斜杠必须清掉, 否则 osascript 会语法错误
    local msg="${1//\\/}"
    msg="${msg//\"/}"
    /usr/bin/osascript -e "display notification \"$msg\" with title \"v2rayN 退出保护\" sound name \"Basso\"" >/dev/null 2>&1
}

# 弹确认窗口。返回 0 = 用户确认退出, 非 0 = 取消。
# 优先用编译好的原生对话框(有真实倒计时和长按进度条);
# 编译不可用时退回到 osascript 静态对话框(功能等价, 只是没有进度条)。
ask_confirm() {
    local apps="$1"
    if [ -x "$DIALOG" ]; then
        "$DIALOG" "$apps" "$HOLD_SECONDS" "$DIALOG_TIMEOUT"
        return $?
    fi
    log "⚠ 原生对话框缺失($DIALOG), 回退到 osascript"
    local out
    out=$(/usr/bin/osascript <<OSA 2>/dev/null
display dialog "检测到以下程序仍在使用网络：

$apps

退出会中断正在进行的下载和会话。
确需退出请点「强制退出」。" buttons {"取消退出", "强制退出"} ¬
    default button "取消退出" with title "v2rayN 退出保护" ¬
    with icon caution giving up after $DIALOG_TIMEOUT
OSA
)
    case "$out" in
        *"强制退出"*) return 0 ;;
        *)            return 1 ;;
    esac
}

v2rayn_running() { /usr/bin/pgrep -x "$V2RAYN_PROC" >/dev/null 2>&1; }
tun_is_up()      { /sbin/ifconfig 2>/dev/null | /usr/bin/grep -q "$TUN_ADDR"; }

log "=== quit-guard 启动 (ARMED=$ARMED, 轮询 ${POLL}s, 长按 ${HOLD_SECONDS}s, 弹窗超时 ${DIALOG_TIMEOUT}s) ==="

while true; do
    if v2rayn_running; then
        # v2rayN 回来了 -> 重新武装
        if [ "$ARMED" != "1" ]; then
            ARMED=1
            LAST_BLOCK=0
            save_state
            log "v2rayN 已重新运行, 恢复保护"
        fi
        sleep "$POLL"
        continue
    fi

    # ---- v2rayN 不在运行 ----
    if [ "$ARMED" != "1" ]; then
        # 已经放行过一次, 等它自己回来。绝不能在这里拉回 —— 否则永远退不出去。
        sleep "$POLL"
        continue
    fi

    # 1. 开关文件: 明确要求退出
    if [ -e "$ALLOW_FLAG" ]; then
        log "检测到 allow-quit 开关, 放行退出并解除保护"
        ARMED=0; LAST_BLOCK=0; save_state
        sleep "$POLL"
        continue
    fi

    # 2. 只有 TUN 本当在用的时候才保护
    #    TUN 没开 = 代理本就没生效, 退出不影响任何东西, 不该拦。
    if ! tun_is_up; then
        log "退出放行: TUN 未启用, 代理本就没生效"
        ARMED=0; LAST_BLOCK=0; save_state
        sleep "$POLL"
        continue
    fi

    APPS=$(protected_apps)
    if [ -z "$APPS" ]; then
        log "退出放行: TUN 在运行但无受保护进程"
        ARMED=0; LAST_BLOCK=0; save_state
        sleep "$POLL"
        continue
    fi

    # 3. 有受保护进程 -> 弹确认窗口, 让用户长按确认
    NOW=$(/bin/date +%s)
    LAST_BLOCK=$NOW
    save_state
    log "拦截退出: 检测到 [$APPS] -> 弹出确认窗口(需长按 ${HOLD_SECONDS}s)"

    if ask_confirm "$APPS"; then
        log "用户在弹窗中确认退出, 放行"
        ARMED=0; LAST_BLOCK=0; save_state
        sleep "$POLL"
    else
        log "弹窗未确认(取消或超时), 重新拉起 v2rayN"
        /usr/bin/open -a "$V2RAYN_APP" >/dev/null 2>&1
        notify "已取消退出：$APPS 仍在运行"
        sleep 4
    fi
done
