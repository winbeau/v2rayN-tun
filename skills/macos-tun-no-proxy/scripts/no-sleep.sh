#!/bin/bash
#
# 合盖不休眠 —— 防止代理在休眠/唤醒时泄漏真实 IP
#
# 为什么需要:
#   合盖 -> 'Clamshell Sleep' -> Wi-Fi 关闭, utun 接口被系统撤掉
#   开盖 -> 系统唤醒, Wi-Fi 立刻重连, 但 TUN 需要 ~30 秒才重建
#        -> ★ 这段窗口里所有应用都是【直连】, 真实 IP 会发出去 ★
#   实测证据(2026-10-12):
#     23:34:21 唤醒
#     23:34:52 收到退出信号, 撤掉 TUN      <- 31 秒之后才处理
#     23:34:53 TUN 已启动
#   那个 31 秒就是 dnsguard 的 30 秒轮询周期。
#
#   对 Claude / ChatGPT 这类服务, 一次带真实 IP(中国)的请求就足够触发风控。
#
# 原理:
#   pmset 的 disablesleep 是隐藏设置, 它会阻止【包括合盖在内】的所有睡眠。
#   注意 caffeinate 做不到这一点 —— 实测 caffeinate -d -i -s 跑了 2 天 17 小时,
#   合盖照样睡。
#
# 用法:
#   ./no-sleep.sh on      禁止睡眠 (合盖也不睡)
#   ./no-sleep.sh off     恢复默认 (合盖会睡)
#   ./no-sleep.sh status  查看当前状态与累计休眠次数
#
# ⚠️ 风险(必须知道):
#   · 合盖装进包里会【持续运行并发热】—— 这是这个方案最大的代价,
#     严重时可能损坏机器。不用时请务必关掉。
#   · 电池会持续消耗。用电池时建议关掉。
#   · 它只解决"休眠唤醒"这一种泄漏场景。Wi-Fi 抖动、热点掉线等其他断网
#     仍会有同样的窗口 —— 要彻底解决需要 kill-switch(阻断境外流量)。
#
set -u

case "${1:-status}" in
    on)
        echo "=== 禁止睡眠 (含合盖) ==="
        sudo pmset -a disablesleep 1
        sleep 1
        if pmset -g | grep -q "SleepDisabled.*1"; then
            echo "✓ 已生效: SleepDisabled = 1"
            echo "  合盖后系统不会休眠, Wi-Fi 保持, TUN 不断"
            echo
            echo "  ⚠ 提醒: 合盖装包里会持续发热, 不用时请执行 $0 off"
        else
            echo "✗ 设置未生效"
            exit 1
        fi
        ;;
    off)
        echo "=== 恢复默认睡眠行为 ==="
        sudo pmset -a disablesleep 0
        sleep 1
        echo "✓ 已恢复: $(pmset -g | grep -i SleepDisabled || echo 'SleepDisabled 未设置(即默认)')"
        echo "  合盖会正常休眠"
        ;;
    status)
        echo "=== 当前状态 ==="
        printf "  %-22s %s\n" "SleepDisabled:" "$(pmset -g | awk '/SleepDisabled/{print $2}' | sed 's/^$/0 (默认, 合盖会睡)/')"
        printf "  %-22s %s\n" "电源:" "$(pmset -g batt | head -1 | sed 's/Now drawing from //;s/ .*//')"
        printf "  %-22s %s\n" "电池:" "$(pmset -g batt | tail -1 | awk '{print $3, $4}')"
        printf "  %-22s %s\n" "累计休眠次数:" "$(pmset -g log 2>/dev/null | grep -oE ':[0-9]+$' | tail -1 | tr -d ':')"
        printf "  %-22s %s\n" "caffeinate:" "$(pgrep -x caffeinate >/dev/null && echo '有 (但挡不住合盖)' || echo 无)"
        printf "  %-22s %s\n" "TUN:" "$(ifconfig 2>/dev/null | grep -q '172.19.0.1' && echo '已建立' || echo '未建立')"
        ;;
    *)
        echo "用法: $0 {on|off|status}"
        exit 1
        ;;
esac
