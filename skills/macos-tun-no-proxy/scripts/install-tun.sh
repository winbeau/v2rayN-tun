#!/bin/bash
#
# macOS TUN 透明代理 —— 安装 / 更新脚本
#
# 依赖同目录下的 run-tun.sh / dnsguard.sh / uninstall-tun.sh,
# 以及上一级 assets/ 下的 sing-box.json 与 launchd plist。
#
# 必须以 root 运行 (推荐):
#   sudo bash install-tun.sh
# 或由图形授权执行:
#   osascript -e 'do shell script "/bin/bash '"$PWD"'/install-tun.sh" with administrator privileges'
#
# 幂等: 可重复执行, 用于升级脚本或配置
#
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE_TUN=/usr/local/libexec/v2rayn-tun
BASE_GUARD=/usr/local/libexec/v2rayn-dnsguard
LAUNCHD=/Library/LaunchDaemons

fail() { echo "❌ $*" >&2; exit 1; }

# ---------- 0. 前置检查 ----------
[ "$(id -u)" = "0" ] || fail "需要 root 权限运行 (sudo bash install-tun.sh)"

for f in "$SCRIPT_DIR/run-tun.sh" "$SCRIPT_DIR/dnsguard.sh" \
         "$SKILL_DIR/assets/sing-box.json" "$SKILL_DIR/assets/com.local.v2rayn-tun.plist"; do
    [ -f "$f" ] || fail "缺少文件: $f (skill 目录不完整?)"
done

# 定位当前登录用户的 home (root 执行时 \$HOME 是 /var/root, 不能用)
TARGET_USER=$(stat -f '%Su' /dev/console)
TARGET_HOME=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
[ -d "$TARGET_HOME" ] || fail "无法确定登录用户主目录 (user=$TARGET_USER)"
echo "目标用户: $TARGET_USER  ($TARGET_HOME)"

# 依赖: v2rayN 的运行时文件
SB_SRC="$TARGET_HOME/Library/Application Support/v2rayN/bin/sing_box/sing-box"
SRS_SRC="$TARGET_HOME/Library/Application Support/v2rayN/bin/srss"
[ -f "$SB_SRC" ]  || fail "找不到 v2rayN 的 sing-box: $SB_SRC
   请先启动一次 v2rayN, 让它把核心释放到 Application Support 目录"
[ -d "$SRS_SRC" ] || fail "找不到 v2rayN 的规则集目录: $SRS_SRC"

# ---------- 1. 复制 v2rayN 的运行时文件 ----------
echo "--- 1. 复制 sing-box 与规则集 ---"
mkdir -p "$BASE_TUN/rules"
cp "$SB_SRC" "$BASE_TUN/sing-box"
for f in geoip-cn.srs geosite-cn.srs geosite-google.srs geosite-private.srs; do
    if [ -f "$SRS_SRC/$f" ]; then
        cp "$SRS_SRC/$f" "$BASE_TUN/rules/$f"
    else
        echo "   ⚠ 缺少规则集 $f (该路由规则将失效)"
    fi
done
echo "   sing-box: $(du -h "$BASE_TUN/sing-box" | cut -f1)"
echo "   规则集:   $(ls "$BASE_TUN/rules" | tr '\n' ' ')"

# ---------- 2. 安装脚本, 替换用户路径占位符 ----------
echo "--- 2. 安装守护脚本 ---"
mkdir -p "$BASE_GUARD"
install_subst() {   # $1=源  $2=目标  $3=权限
    sed "s|__USER_HOME__|$TARGET_HOME|g" "$1" > "$2"
    chown root:wheel "$2"
    chmod "$3" "$2"
}
install_subst "$SCRIPT_DIR/run-tun.sh" "$BASE_TUN/run-tun.sh"   755
install_subst "$SCRIPT_DIR/dnsguard.sh" "$BASE_GUARD/dnsguard.sh" 755
install_subst "$SKILL_DIR/assets/sing-box.json" "$BASE_TUN/config.json" 644
echo "   run-tun.sh / dnsguard.sh / config.json"

# ---------- 3. 权限收紧 ----------
echo "--- 3. 权限 (全部 root 所有, 用户不可写) ---"
chown -R root:wheel "$BASE_TUN" "$BASE_GUARD"
chmod 755 "$BASE_TUN" "$BASE_GUARD" "$BASE_TUN/rules"
chmod 755 "$BASE_TUN/sing-box" "$BASE_TUN/run-tun.sh" "$BASE_GUARD/dnsguard.sh"
chmod 644 "$BASE_TUN/config.json" "$BASE_TUN"/rules/*.srs 2>/dev/null
xattr -dr com.apple.quarantine "$BASE_TUN" "$BASE_GUARD" 2>/dev/null || true

# ---------- 4. 安装 launchd 定义 ----------
echo "--- 4. 安装 LaunchDaemon / LaunchAgent ---"
for p in com.local.v2rayn-tun com.local.v2rayn-dnsguard; do
    cp "$SKILL_DIR/assets/$p.plist" "$LAUNCHD/$p.plist"
    chown root:wheel "$LAUNCHD/$p.plist"; chmod 644 "$LAUNCHD/$p.plist"
done
AGENT_DIR="$TARGET_HOME/Library/LaunchAgents"
mkdir -p "$AGENT_DIR"
cp "$SKILL_DIR/assets/v2rayN-LaunchAgent.plist" "$AGENT_DIR/v2rayN-LaunchAgent.plist"
chown "$TARGET_USER" "$AGENT_DIR/v2rayN-LaunchAgent.plist"
chmod 644 "$AGENT_DIR/v2rayN-LaunchAgent.plist"

# ---------- 5. 日志文件 ----------
touch /var/log/v2rayn-tun.log /var/log/v2rayn-tun.out.log /var/log/v2rayn-tun.err.log \
      /var/log/v2rayn-dnsguard.log /var/log/v2rayn-dnsguard.out.log /var/log/v2rayn-dnsguard.err.log
chown root:wheel /var/log/v2rayn-*.log 2>/dev/null
chmod 644 /var/log/v2rayn-*.log 2>/dev/null

# ---------- 6. 加载 ----------
echo "--- 5. 加载守护进程 ---"
SERVICES="com.local.v2rayn-tun com.local.v2rayn-dnsguard"

# 先全部 bootout。注意: bootout 是异步的, 旧实例(含其子进程)需要时间退出,
# 若立刻 bootstrap 会失败并报 "Bootstrap failed: 5: Input/output error"。
for p in $SERVICES; do
    launchctl bootout "system/$p" 2>/dev/null || true
done

echo -n "   等待旧实例退出"
DRAINED=0
for _ in $(seq 1 30); do
    still=""
    for p in $SERVICES; do
        launchctl print "system/$p" >/dev/null 2>&1 && still="$still $p"
    done
    [ -z "$still" ] && { DRAINED=1; break; }
    echo -n "."
    sleep 1
done
echo
[ "$DRAINED" = "1" ] || echo "   ⚠ 旧实例未在 30 秒内退净, 仍尝试加载"

# bootstrap 带重试
for p in $SERVICES; do
    ok=0
    for try in 1 2 3 4 5; do
        if launchctl bootstrap system "$LAUNCHD/$p.plist" 2>/dev/null; then ok=1; break; fi
        sleep 2
    done
    if [ "$ok" = "1" ] || launchctl print "system/$p" >/dev/null 2>&1; then
        echo "   ✓ $p"
    else
        echo "   ❌ $p 加载失败"
        echo "      手动排查: sudo launchctl bootstrap system $LAUNCHD/$p.plist"
    fi
done

# 记录当前网络地址作为基线, 避免守护误判为"网络变化"
IFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
[ -n "$IFACE" ] && ifconfig "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}' > /var/run/v2rayn-netguard.addr

# 用户级 LaunchAgent (让 v2rayN 登录自启)
# 注意: root 无法用 sudo -u 直接操作用户的 GUI domain, 必须走 gui/<uid>
TARGET_UID=$(id -u "$TARGET_USER")
AGENT_SRC="$AGENT_DIR/v2rayN-LaunchAgent.plist"
launchctl bootout "gui/$TARGET_UID/v2rayN-LaunchAgent" 2>/dev/null || true
if launchctl bootstrap "gui/$TARGET_UID" "$AGENT_SRC" 2>/dev/null; then
    echo "   LaunchAgent 已加载 (v2rayN 将随登录自启)"
elif launchctl print "gui/$TARGET_UID/v2rayN-LaunchAgent" >/dev/null 2>&1; then
    echo "   LaunchAgent 已在运行"
else
    echo "   ⚠ LaunchAgent 未能自动加载。请以该用户身份手动执行:"
    echo "        launchctl load -w \"$AGENT_SRC\""
fi

# ---------- 7. 自检 ----------
echo "--- 6. 自检 ---"
UP=0
for i in $(seq 1 25); do
    sleep 2
    ifconfig 2>/dev/null | grep -q "172.19.0.1" && { UP=1; break; }
done
if [ "$UP" = "1" ]; then
    echo "   TUN 已建立 ✓"
else
    echo "   ⚠ TUN 未建立 (v2rayN 未运行或端口 10808 未监听时会保持关闭, 这是设计行为)"
fi

LOADED_OK=1
for p in com.local.v2rayn-tun com.local.v2rayn-dnsguard; do
    st=$(launchctl print "system/$p" 2>/dev/null | grep -o 'state = [a-z ]*' | head -1)
    if [ -z "$st" ]; then
        printf "   %-28s ❌ 未加载\n" "$p"
        LOADED_OK=0
    else
        printf "   %-28s %s\n" "$p" "$st"
    fi
done
[ "$LOADED_OK" = "0" ] && echo "   ⚠ 有守护未加载, 见上面提示"

if [ "$UP" = "1" ]; then
    echo "   国内: HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 15 --noproxy '*' https://www.baidu.com)"
    echo "   国外: HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 20 --noproxy '*' https://www.google.com/generate_204)"
    echo "   出口: $(curl -s --max-time 15 --noproxy '*' https://api.ipify.org)"
fi

echo
if [ "$LOADED_OK" = "1" ]; then
    echo "✅ 安装完成"
else
    echo "⚠️  安装完成, 但有守护未加载 (见上)"
fi
echo "   日志:   /var/log/v2rayn-tun.log   /var/log/v2rayn-dnsguard.log"
echo "   开关:   touch \"$TARGET_HOME/Library/Application Support/v2rayN/tun-disabled\"    # 临时关 TUN"
echo "           echo 1500 > \"$TARGET_HOME/Library/Application Support/v2rayN/tun-mtu\"   # 临时改 MTU"
echo "   卸载:   sudo $SCRIPT_DIR/uninstall-tun.sh"
