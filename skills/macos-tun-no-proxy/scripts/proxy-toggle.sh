#!/bin/bash
#
# 终端代理开关 —— 需要时显式开启，不用时不留痕迹
#
# 为什么需要它:
#   macOS 的「系统代理」是给 GUI 应用读的配置（浏览器会读）。
#   终端工具（curl / git / gh / wget / python-requests …）**不读它**，
#   只认环境变量 http_proxy / https_proxy / all_proxy。
#   所以 Clash 开着系统代理，终端照样直连。
#
# 用法（在 ~/.zshrc 里 source 本文件）:
#     source ~/Developer/tools/v2rayN-tun/skills/macos-tun-no-proxy/scripts/proxy-toggle.sh
#
#     proxy-on       # 让终端走 Clash
#     proxy-off      # 还原（默认状态）
#     proxy-status   # 查看当前状态
#
# 设计取舍:
#   本方案是**显式**的 —— 变量只在你手动开启后存在，关闭即彻底清除。
#   这符合本项目「不留代理变量」的原则：不会有隐藏状态在你忘了的时候生效。
#
#   如果你希望「终端自动跟着 Clash 走」而不想手动开，
#   更干净的做法是让 Clash 也用 TUN 模式（界面里开启「虚拟网卡」），
#   那样终端无需任何变量即可走代理，与 v2rayN-tun 是同一套机制。
#

# Clash 的混合端口；若你的配置不同，改这里
CLASH_PROXY_HOST=127.0.0.1
CLASH_PROXY_PORT=7897
CLASH_PROXY_URL="socks5h://${CLASH_PROXY_HOST}:${CLASH_PROXY_PORT}"

# 本项目的 TUN 地址 —— 它开着的时候不能再用代理变量，否则双重代理
TUN_ADDR=172.19.0.1

_proxy_tun_up() {
    ifconfig 2>/dev/null | grep -q "$TUN_ADDR"
}

_proxy_clash_up() {
    lsof -nP -iTCP:"$CLASH_PROXY_PORT" -sTCP:LISTEN >/dev/null 2>&1
}

proxy-on() {
    if _proxy_tun_up; then
        echo "⚠ v2rayN 的 TUN 正在运行（$TUN_ADDR）。"
        echo "  此时设代理变量会双重代理：流量 → Clash → 再被 TUN 抓一次。"
        echo "  请先退出 v2rayN，或直接让 TUN 接管（终端无需变量即可走代理）。"
        return 1
    fi
    if ! _proxy_clash_up; then
        echo "⚠ Clash 未在 $CLASH_PROXY_PORT 监听，设置了也走不通。"
        echo "  请先启动 Clash Verge。"
        return 1
    fi
    export http_proxy="$CLASH_PROXY_URL"
    export https_proxy="$CLASH_PROXY_URL"
    export all_proxy="$CLASH_PROXY_URL"
    export no_proxy="localhost,127.0.0.1,::1,*.local,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
    echo "✓ 终端代理已开启 → $CLASH_PROXY_URL"
    echo "  出口验证: curl -s https://api.ipify.org"
}

proxy-off() {
    unset http_proxy https_proxy all_proxy no_proxy
    echo "✓ 终端代理已关闭（变量已清除）"
}

proxy-status() {
    if _proxy_tun_up; then
        echo "  TUN:      运行中（$TUN_ADDR）→ 终端无需代理变量即可走代理"
    else
        echo "  TUN:      未运行"
    fi
    if _proxy_clash_up; then
        echo "  Clash:    $CLASH_PROXY_HOST:$CLASH_PROXY_PORT 监听中"
    else
        echo "  Clash:    未运行"
    fi
    if [ -n "${https_proxy:-}" ]; then
        echo "  代理变量: $https_proxy  ← 已开启"
    else
        echo "  代理变量: 无（默认状态）"
    fi
}
