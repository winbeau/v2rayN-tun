#!/bin/bash
#
# v2rayN TUN 模式 —— 卸载脚本
#
# 必须以 root 运行:  sudo ./uninstall.sh
#
# 卸载后系统回到"v2rayN 纯粹的本地代理"状态:
#   · 不接管路由 (无 TUN)
#   · 不修改 DNS
#   · 【恢复正常睡眠】—— 见下方"为什么必须恢复 disablesleep"
#   · 不留任何 kill-switch 规则
#
set -u

BASE_TUN=/usr/local/libexec/v2rayn-tun
BASE_GUARD=/usr/local/libexec/v2rayn-dnsguard
BASE_SLEEP=/usr/local/libexec/v2rayn-sleepguard
LAUNCHD=/Library/LaunchDaemons

[ "$(id -u)" = "0" ] || { echo "❌ 需要 root 权限 (sudo ./uninstall.sh)" >&2; exit 1; }

TARGET_USER=$(stat -f '%Su' /dev/console)
TARGET_HOME=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
TARGET_UID=$(id -u "$TARGET_USER" 2>/dev/null || echo "")

echo "--- 1. 停止并移除系统级守护 ---"
# ⚠️ 四个都要清。漏掉 sleepguard 的后果尤其严重(见第 4 步)。
for p in com.local.v2rayn-tun com.local.v2rayn-dnsguard \
         com.local.v2rayn-sleepguard com.local.v2rayn-quitguard; do
    if launchctl print "system/$p" >/dev/null 2>&1; then
        launchctl bootout "system/$p" 2>/dev/null && echo "   已停止 $p"
    fi
    if [ -f "$LAUNCHD/$p.plist" ]; then
        rm -f "$LAUNCHD/$p.plist" && echo "   已删除 $LAUNCHD/$p.plist"
    fi
done

echo "--- 2. 移除用户级 LaunchAgent ---"
if [ -n "${TARGET_HOME:-}" ] && [ -n "${TARGET_USER:-}" ]; then
    for a in v2rayN-LaunchAgent com.local.v2rayn-quitguard; do
        AGENT="$TARGET_HOME/Library/LaunchAgents/$a.plist"
        [ -n "$TARGET_UID" ] && launchctl bootout "gui/$TARGET_UID/$a" 2>/dev/null || true
        if [ -f "$AGENT" ]; then
            rm -f "$AGENT" && echo "   已删除 $AGENT"
        fi
    done
fi

echo "--- 3. 删除程序文件 ---"
for d in "$BASE_TUN" "$BASE_GUARD" "$BASE_SLEEP"; do
    if [ -d "$d" ]; then
        rm -rf "$d" && echo "   已删除 $d"
    fi
done

echo "--- 4. 恢复睡眠设置 (关键) ---"
# ⚠️ 为什么必须做这一步:
#   sleep-guard 会把 pmset 的 disablesleep 设成 1, 用来阻止【包括合盖在内】的
#   所有睡眠 —— 目的是消除"休眠唤醒后 TUN 重建期间真实 IP 泄漏"的窗口。
#   这个值是写进系统电源配置、重启都保持的。
#   如果卸载时不恢复, 用户会得到一个【永远不休眠】的 Mac:
#   合盖装进包里会持续运行发热, 严重时可能损坏硬件。
if /usr/bin/pmset -g 2>/dev/null | grep -qE "SleepDisabled[[:space:]]+1"; then
    /usr/bin/pmset -a disablesleep 0
    sleep 1
    if /usr/bin/pmset -g 2>/dev/null | grep -qE "SleepDisabled[[:space:]]+1"; then
        echo "   ⚠ 无法恢复 disablesleep, 请手动执行: sudo pmset -a disablesleep 0"
    else
        echo "   ✓ 已恢复 disablesleep=0 (合盖会正常休眠)"
    fi
else
    echo "   (disablesleep 本来就未启用, 无需恢复)"
fi

echo "--- 5. 清理用户侧的开关文件 ---"
if [ -n "${TARGET_HOME:-}" ]; then
    D="$TARGET_HOME/Library/Application Support/v2rayN"
    for f in tun-disabled tun-mtu killswitch-always no-sleep-timeout allow-quit; do
        if [ -f "$D/$f" ]; then
            rm -f "$D/$f" && echo "   已删除 $f"
        fi
    done
    # quit-guard 的运行状态
    rm -f /tmp/v2rayn-quitguard.state 2>/dev/null && echo "   已清理 quit-guard 状态文件"
    # 唤醒后重建 tap 的辅助文件(如有)
    rm -rf "$TARGET_HOME/Library/Application Support/v2rayN-tun" 2>/dev/null || true
fi

echo "--- 6. 确认没有残留 ---"
LEFT=0
for p in com.local.v2rayn-tun com.local.v2rayn-dnsguard \
         com.local.v2rayn-sleepguard com.local.v2rayn-quitguard; do
    if launchctl print "system/$p" >/dev/null 2>&1; then
        echo "   ⚠ 仍在运行: $p"; LEFT=1
    fi
done
for d in "$BASE_TUN" "$BASE_GUARD" "$BASE_SLEEP"; do
    [ -d "$d" ] && { echo "   ⚠ 目录仍在: $d"; LEFT=1; }
done
[ "$LEFT" = "0" ] && echo "   ✓ 无残留"

echo "--- 7. 保留的日志 (如需清理请手动删除) ---"
ls -1 /var/log/v2rayn-*.log 2>/dev/null | sed 's/^/   /' || echo "   (无)"

echo
echo "✅ 卸载完成"
echo
echo "注意: v2rayN 的系统代理模式此前被设为 Unchanged(不改变系统代理)。"
echo "      若想恢复由 v2rayN 管理系统代理, 请在 v2rayN 界面把代理模式选回"
echo "      \"Set system proxy\", 或执行:"
echo "        networksetup -setwebproxy Wi-Fi 127.0.0.1 10808"
echo "        networksetup -setsecurewebproxy Wi-Fi 127.0.0.1 10808"
echo "        networksetup -setsocksfirewallproxy Wi-Fi 127.0.0.1 10808"
echo
echo "另外: quit-guard 用的本地代码签名证书仍在钥匙串里 (v2rayN-tun Local Signing)。"
echo "      它只用于给本项目的程序签名, 留着无害。想删可以执行:"
echo "        security delete-identity -c \"v2rayN-tun Local Signing\""
