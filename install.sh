#!/bin/bash
#
# v2rayN TUN 模式 —— 安装 / 更新脚本
#
# 必须以 root 运行 (推荐):
#   sudo ./install.sh
# 或由图形授权执行:
#   osascript -e 'do shell script "/bin/bash '"$PWD"'/install.sh" with administrator privileges'
#
# 幂等: 可重复执行, 用于升级脚本或配置
#
set -u

REPO="$(cd "$(dirname "$0")" && pwd)"
BASE_TUN=/usr/local/libexec/v2rayn-tun
BASE_GUARD=/usr/local/libexec/v2rayn-dnsguard
LAUNCHD=/Library/LaunchDaemons

fail() { echo "❌ $*" >&2; exit 1; }

# ---------- 0. 前置检查 ----------
[ "$(id -u)" = "0" ] || fail "需要 root 权限运行 (sudo ./install.sh)"

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

# 先停守护再复制。两个原因:
#   1. 文件被正在运行的 sing-box 占用时 cp 会失败
#   2. macOS 26.4+ 起, 覆盖 adhoc 签名二进制后 taskgated 会判定
#      "Taskgated Invalid Signature" 并直接 SIGKILL —— 必须重新签名
for p in com.local.v2rayn-tun com.local.v2rayn-dnsguard com.local.v2rayn-sleepguard; do
    launchctl bootout "system/$p" 2>/dev/null || true
done
sleep 2
pkill -f "$BASE_TUN/sing-box" 2>/dev/null || true
sleep 1

mkdir -p "$BASE_TUN/rules"

# 删掉再复制: 换 inode 可以让 taskgated 缓存的旧签名判定失效
rm -f "$BASE_TUN/sing-box"
cp "$SB_SRC" "$BASE_TUN/sing-box"

# 重新做 adhoc 签名。少这一步的话二进制会被内核 SIGKILL,
# 表现为 `sing-box version` 无输出、退出码 137, 日志里只剩
# "sing-box 立即退出", 极难从现象定位。
if codesign --force --sign - "$BASE_TUN/sing-box" 2>/dev/null; then
    if "$BASE_TUN/sing-box" version >/dev/null 2>&1; then
        echo "   签名:     ✓ 已重新签名并可执行"
    else
        echo "   ❌ 重新签名后仍无法执行 —— macOS 的签名缓存可能需要重启才刷新"
    fi
else
    echo "   ⚠ codesign 失败, 二进制可能无法执行 (见 README 的 macOS 版本注意)"
fi

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
install_subst "$REPO/daemon/run-tun.sh" "$BASE_TUN/run-tun.sh"   755
install_subst "$REPO/daemon/dnsguard.sh" "$BASE_GUARD/dnsguard.sh" 755
install_subst "$REPO/config/sing-box.json" "$BASE_TUN/config.json" 644
echo "   run-tun.sh / dnsguard.sh / config.json"

# ---------- 2b. 退出保护 (Cmd+Q 拦截器) ----------
# 这个工具用 CGEventTap 在按键阶段就把 Cmd+Q 吞掉, v2rayN 根本收不到,
# 所以它是【不会退出】而不是"退出后被拉回来"。
#
# 硬前提: 辅助功能(Accessibility)权限。macOS 不允许没有该权限的程序拦截键盘。
# 首次运行会弹系统提示, 需要到「系统设置 → 隐私与安全性 → 辅助功能」里勾选。
echo "--- 2b. 编译 Cmd+Q 拦截器 ---"
QG_BIN="$BASE_TUN/quit-guard"

# ⚠️ 必须先停掉旧实例再覆盖二进制。
#    正在运行的二进制文件无法被覆盖 (cp 报 Permission denied) —— 与 sing-box
#    那个"重新签名"的坑同源。bootout 是异步的, 所以要等一下。
QG_LABEL="gui/$(id -u "$TARGET_USER")/com.local.v2rayn-quitguard"
if launchctl print "$QG_LABEL" >/dev/null 2>&1; then
    launchctl bootout "$QG_LABEL" 2>/dev/null || true
    for _ in $(seq 1 10); do
        launchctl print "$QG_LABEL" >/dev/null 2>&1 || break
        sleep 1
    done
    echo "   已停止旧实例以便覆盖二进制"
fi
# ⚠️ 只在源码变了的时候才重新编译。
#    macOS 的辅助功能授权绑定二进制的 CDHash, 而这个二进制是 adhoc 签名、
#    没有 Team ID —— 重新编译等于换了一个程序, 授权立即失效, 拦截器会
#    以"缺少辅助功能权限"退出。无谓的重编译只会逼用户反复去设置里重新添加。
QG_HASH_FILE="$BASE_TUN/.quit-guard.src-hash"
QG_SRC_HASH=$(shasum -a 256 "$REPO/daemon/quit-guard.swift" 2>/dev/null | cut -d' ' -f1)
QG_NEED_BUILD=1
if [ -x "$QG_BIN" ] && [ -f "$QG_HASH_FILE" ] && \
   [ "$(cat "$QG_HASH_FILE" 2>/dev/null)" = "$QG_SRC_HASH" ]; then
    QG_NEED_BUILD=0
    echo "   ✓ 源码未变, 保留现有二进制 (避免让辅助功能授权失效)"
fi

if [ "$QG_NEED_BUILD" = "1" ] && command -v swiftc >/dev/null 2>&1; then
    if swiftc -O -o "$QG_BIN" "$REPO/daemon/quit-guard.swift" 2>/tmp/quitguard-build.log; then
        # ---- 用固定证书签名 (关键) ----
        # 辅助功能的 TCC 授权, 对 adhoc 签名是按 CDHash 校验的 —— 每次重编译
        # 都等于换了个程序, 授权立即失效, 用户得反复去设置里重新添加。
        # 用固定证书签名后, designated requirement 变成
        #   identifier "..." and certificate root = H"..."
        # 于是重编译不会影响授权。
        #
        # 证书准备(一次性):
        #   openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        #     -keyout key.pem -out cert.pem \
        #     -subj "/CN=v2rayN-tun Local Signing/O=v2rayN-tun/OU=Local/C=CN" \
        #     -addext "basicConstraints=critical,CA:FALSE" \
        #     -addext "keyUsage=critical,digitalSignature" \
        #     -addext "extendedKeyUsage=critical,codeSigning"
        #   openssl pkcs12 -export -legacy -out id.p12 -inkey key.pem -in cert.pem \
        #     -passout pass:qg-local-2026 -name "v2rayN-tun Local Signing"
        #   security import id.p12 -k ~/Library/Keychains/login.keychain-db \
        #     -P qg-local-2026 -T /usr/bin/codesign
        #   security add-trusted-cert -r trustRoot -p codeSign \
        #     -k ~/Library/Keychains/login.keychain-db cert.pem     # 用户级, 无需管理员
        SIGN_ID="v2rayN-tun Local Signing"
        SIGNED=0
        if sudo -u "$TARGET_USER" security find-identity -v -p codesigning 2>/dev/null \
             | grep -q "$SIGN_ID"; then
            if sudo -u "$TARGET_USER" codesign --force --sign "$SIGN_ID" \
                 --identifier com.local.v2rayn.quitguard --timestamp=none \
                 "$QG_BIN" 2>/tmp/quitguard-sign.log; then
                SIGNED=1
                echo "   ✓ 已用固定证书签名 (重编译不会再让授权失效)"
                echo "     要求: $(codesign -d -r- "$QG_BIN" 2>&1 | tail -1 | sed 's/designated => //')"
            else
                echo "   ⚠ 签名失败:"; head -3 /tmp/quitguard-sign.log | sed 's/^/      /'
            fi
        else
            echo "   ⚠ 找不到签名证书 \"$SIGN_ID\" —— 将使用 adhoc 签名"
            echo "     注意: adhoc 签名下, 每次重编译都会让辅助功能授权失效,"
            echo "           需要重新到「隐私与安全性 → 辅助功能」里添加一次。"
        fi
        [ "$SIGNED" = "0" ] && codesign --force --sign - "$QG_BIN" 2>/dev/null || true

        chown root:wheel "$QG_BIN"; chmod 755 "$QG_BIN"
        echo "$QG_SRC_HASH" > "$QG_HASH_FILE"
        [ "$SIGNED" = "0" ] && echo "   ✓ 已编译 (按键层拦截, 不影响其他应用的 Cmd+Q)"
    else
        echo "   ❌ 编译失败:"
        head -5 /tmp/quitguard-build.log | sed 's/^/      /'
    fi
elif [ "$QG_NEED_BUILD" = "1" ]; then
    echo "   ❌ 缺少 swiftc (Xcode Command Line Tools)"
    echo "      安装: xcode-select --install"
    echo "      没有它就无法做 Cmd+Q 拦截 —— 这个功能必须编译原生代码。"
fi

# ---------- 2c. 合盖不休眠守护 ----------
# 合盖休眠会让 Wi-Fi 断开、utun 被系统撤掉, 唤醒后 TUN 要 ~30 秒才重建,
# 这段窗口里应用是直连的 —— 真实 IP 会漏给目标网站。
# 本守护确保 disablesleep=1 (连合盖睡眠一起挡掉), 同时带过热保护。
echo "--- 2c. 安装合盖不休眠守护 ---"
BASE_SG="/usr/local/libexec/v2rayn-sleepguard"
mkdir -p "$BASE_SG"
install_subst "$REPO/daemon/sleep-guard.sh" "$BASE_SG/sleep-guard.sh" 755
echo "   sleep-guard.sh -> $BASE_SG  (合盖阈值 ${SLEEP_TIMEOUT:-1200}s)"

# ---------- 3. 权限收紧 ----------
echo "--- 3. 权限 (全部 root 所有, 用户不可写) ---"
chown -R root:wheel "$BASE_TUN" "$BASE_GUARD"
chmod 755 "$BASE_TUN" "$BASE_GUARD" "$BASE_TUN/rules"
chmod 755 "$BASE_TUN/sing-box" "$BASE_TUN/run-tun.sh" "$BASE_GUARD/dnsguard.sh"
[ -f "$BASE_TUN/quit-guard" ] && chmod 755 "$BASE_TUN/quit-guard"
chmod 644 "$BASE_TUN/config.json" "$BASE_TUN"/rules/*.srs 2>/dev/null
xattr -dr com.apple.quarantine "$BASE_TUN" "$BASE_GUARD" 2>/dev/null || true

# ---------- 4. 安装 launchd 定义 ----------
echo "--- 4. 安装 LaunchDaemon / LaunchAgent ---"
for p in com.local.v2rayn-tun com.local.v2rayn-dnsguard com.local.v2rayn-sleepguard; do
    cp "$REPO/launchd/$p.plist" "$LAUNCHD/$p.plist"
    chown root:wheel "$LAUNCHD/$p.plist"; chmod 644 "$LAUNCHD/$p.plist"
done
AGENT_DIR="$TARGET_HOME/Library/LaunchAgents"
mkdir -p "$AGENT_DIR"
cp "$REPO/launchd/v2rayN-LaunchAgent.plist" "$AGENT_DIR/v2rayN-LaunchAgent.plist"
chown "$TARGET_USER" "$AGENT_DIR/v2rayN-LaunchAgent.plist"
chmod 644 "$AGENT_DIR/v2rayN-LaunchAgent.plist"

# 退出看门狗 (用户级: 要弹窗 + 要 open -a v2rayN)
sed "s|__USER_HOME__|$TARGET_HOME|g" "$REPO/launchd/com.local.v2rayn-quitguard.plist" \
    > "$AGENT_DIR/com.local.v2rayn-quitguard.plist"
chown "$TARGET_USER" "$AGENT_DIR/com.local.v2rayn-quitguard.plist"
chmod 644 "$AGENT_DIR/com.local.v2rayn-quitguard.plist"
echo "   LaunchAgent: v2rayN-LaunchAgent / com.local.v2rayn-quitguard"

# ---------- 5. 日志文件 ----------
touch /var/log/v2rayn-tun.log /var/log/v2rayn-tun.out.log /var/log/v2rayn-tun.err.log \
      /var/log/v2rayn-dnsguard.log /var/log/v2rayn-dnsguard.out.log /var/log/v2rayn-dnsguard.err.log
chown root:wheel /var/log/v2rayn-*.log 2>/dev/null
chmod 644 /var/log/v2rayn-*.log 2>/dev/null

# ---------- 6. 加载 ----------
echo "--- 5. 加载守护进程 ---"
SERVICES="com.local.v2rayn-tun com.local.v2rayn-dnsguard com.local.v2rayn-sleepguard"

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

# 退出看门狗 (用户级 LaunchAgent)
# KeepAlive=true 它会常驻; bootout 后重新 bootstrap 即可刷新脚本
QG_AGENT="$AGENT_DIR/com.local.v2rayn-quitguard.plist"
launchctl bootout "gui/$TARGET_UID/com.local.v2rayn-quitguard" 2>/dev/null || true
sleep 1
if launchctl bootstrap "gui/$TARGET_UID" "$QG_AGENT" 2>/dev/null \
   || launchctl print "gui/$TARGET_UID/com.local.v2rayn-quitguard" >/dev/null 2>&1; then
    sleep 2
    if launchctl print "gui/$TARGET_UID/com.local.v2rayn-quitguard" 2>/dev/null | grep -q "state = running"; then
        echo "   ✓ Cmd+Q 拦截器已运行"
    else
        echo "   ⚠ Cmd+Q 拦截器未能运行 —— 多半是缺辅助功能权限, 见下方说明"
    fi
else
    echo "   ⚠ Cmd+Q 拦截器未能加载。手动执行:"
    echo "        launchctl bootstrap gui/$TARGET_UID \"$QG_AGENT\""
fi

# 辅助功能权限自检 —— 没有它 Cmd+Q 拦截器起不来
echo "--- 辅助功能权限 ---"
if [ -f "$BASE_TUN/quit-guard" ]; then
    echo "   ⚠ Cmd+Q 拦截器需要【辅助功能】权限, 首次安装必须手动授予:"
    echo "     1. 系统设置 → 隐私与安全性 → 辅助功能"
    echo "     2. 点 + 添加:  $BASE_TUN/quit-guard"
    echo "        (在 Finder 里按 Cmd+Shift+G 可直接跳转到该路径)"
    echo "     3. 勾选它, 然后:  launchctl kickstart -k gui/$TARGET_UID/com.local.v2rayn-quitguard"
    echo "   未授权时拦截器会退出并留下提示, 其余功能不受影响。"
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
for p in com.local.v2rayn-tun com.local.v2rayn-dnsguard com.local.v2rayn-sleepguard; do
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
echo "   卸载:   sudo $REPO/uninstall.sh"
