#!/bin/bash
#
# v2rayN TUN 模式 —— 卸载脚本
#
# 必须以 root 运行:  sudo bash uninstall-tun.sh
# 卸载后系统回到"v2rayN 纯粹的本地代理"状态, 不做任何 TUN 接管。
#
set -u

BASE_TUN=/usr/local/libexec/v2rayn-tun
BASE_GUARD=/usr/local/libexec/v2rayn-dnsguard
LAUNCHD=/Library/LaunchDaemons

[ "$(id -u)" = "0" ] || { echo "❌ 需要 root 权限 (sudo bash uninstall-tun.sh)" >&2; exit 1; }

TARGET_USER=$(stat -f '%Su' /dev/console)
TARGET_HOME=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')

echo "--- 1. 停止并移除守护进程 ---"
for p in com.local.v2rayn-tun com.local.v2rayn-dnsguard; do
    launchctl bootout "system/$p" 2>/dev/null && echo "   已停止 $p"
    rm -f "$LAUNCHD/$p.plist" && echo "   已删除 $LAUNCHD/$p.plist"
done

echo "--- 2. 移除用户级登录项 ---"
if [ -n "${TARGET_HOME:-}" ] && [ -n "${TARGET_USER:-}" ]; then
    AGENT="$TARGET_HOME/Library/LaunchAgents/v2rayN-LaunchAgent.plist"
    # root 需通过 gui/<uid> 操作用户的 GUI domain
    launchctl bootout "gui/$(id -u "$TARGET_USER")/v2rayN-LaunchAgent" 2>/dev/null || true
    rm -f "$AGENT" && echo "   已删除 $AGENT"
fi

echo "--- 3. 删除程序文件 ---"
rm -rf "$BASE_TUN" "$BASE_GUARD"
echo "   已删除 $BASE_TUN"
echo "   已删除 $BASE_GUARD"

echo "--- 4. 保留的日志 (如需清理请手动删除) ---"
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
