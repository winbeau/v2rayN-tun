#!/bin/bash
# 隐身模式开关 (整层取消国内直连)
# 隐身模式开关
#
#   隐身模式=开: 所有流量都走代理, 国内直连规则全部失效
#                -> 网页无法通过国内 STUN 拿到你的真实 IP
#                -> 国内/国外的响应耗时趋同, 无法靠时间差判断地区
#   隐身模式=关: 恢复"国内直连"的正常配置 (上网快)
#
# 为什么需要它: 见 docs/16-ip-leak-via-cn-direct.md
#
# 用法:
#   ./stealth-mode.sh on          打开 (需要管理员权限: 改 root 所有的配置并重启守护)
#   ./stealth-mode.sh off         关闭
#   ./stealth-mode.sh status      查看当前模式 + 实测 STUN 泄漏
#   ./stealth-mode.sh test        只做泄漏测试, 不改配置
#
# 原理: 默认配置里有 geoip-cn / geosite-cn 两条 direct 规则, 本意是
#       "国内站点不绕道国外"。代价是任何指向国内地址的连接都用真实 IP 出去 ——
#       实测命令行直接发 STUN 请求到 stun.chat.bilibili.com, 对方报出的就是
#       真实中国 IP。因为发生在路由层, 换浏览器、关 WebRTC 都没用。
#
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TUN_DIR=/usr/local/libexec/v2rayn-tun
CONF="$TUN_DIR/config.json"
BAK="$TUN_DIR/config.normal.json"
GEN="$REPO/scripts/stealth-mode.py"
LAUNCH_DAEMON=com.local.v2rayn-tun

need_root() {
    [ "$(id -u)" = "0" ] || { echo "❌ 需要管理员权限 (sudo $0 $1)"; exit 1; }
}

do_test() {
    echo "  ── STUN 泄漏实测 ──"
    python3 - "$@" <<'PY'
import socket, struct, os, sys
MAGIC = 0x2112A442
def q(host, port):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(5)
        s.sendto(struct.pack('!HHI12s', 1, 0, MAGIC, os.urandom(12)), (host, port))
        d, _ = s.recvfrom(2048); s.close()
    except Exception as e:
        return f"失败({type(e).__name__})"
    i = 20
    while i + 4 <= len(d):
        t, l = struct.unpack('!HH', d[i:i+4]); v = d[i+4:i+4+l]
        if t == 0x0020 and len(v) >= 8 and v[1] == 1:
            ip = bytes(a ^ b for a, b in zip(v[4:8], struct.pack('!I', MAGIC)))
            return socket.inet_ntoa(ip)
        i += 4 + l + ((4 - l % 4) % 4)
    return "未解析"
for label, h, p in [("Bilibili(国内)", "stun.chat.bilibili.com", 3478),
                    ("小米(国内)",     "stun.miwifi.com", 3478),
                    ("Google(国外)",   "stun.l.google.com", 19302)]:
    print(f"    {label:<18} {q(h, p)}")
PY
}

case "${1:-status}" in
    on)
        need_root on
        [ -f "$CONF" ] || { echo "❌ 找不到 $CONF"; exit 1; }
        # 第一次开启时把"正常模式"的配置存下来
        [ -f "$BAK" ] || { cp "$CONF" "$BAK"; echo "   已保存正常模式配置 -> $BAK"; }
        "$GEN" generate -o /tmp/stealth-gen.json 2>/dev/null
        sed "s|__USER_HOME__|$HOME|g" /tmp/stealth-gen.json > "$CONF"
        chown root:wheel "$CONF"; chmod 644 "$CONF"
        "$TUN_DIR/sing-box" check -c "$CONF" >/dev/null 2>&1 || { echo "❌ 配置校验失败"; exit 1; }
        launchctl kickstart -k "system/$LAUNCH_DAEMON"
        sleep 6
        echo "✅ 隐身模式已开启 (所有流量走代理, 国内网站会变慢)"
        do_test
        ;;
    off)
        need_root off
        [ -f "$BAK" ] || { echo "❌ 没有保存的正常模式配置 ($BAK), 无法恢复"; exit 1; }
        cp "$BAK" "$CONF"
        chown root:wheel "$CONF"; chmod 644 "$CONF"
        launchctl kickstart -k "system/$LAUNCH_DAEMON"
        sleep 6
        echo "✅ 已恢复正常模式 (国内直连)"
        do_test
        ;;
    test)
        do_test
        ;;
    status)
        echo "  ── 当前模式 ──"
        if [ -f "$CONF" ]; then
            python3 - "$CONF" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
# 看国内方向(cn 规则集)被送到哪个出站
tags = {o.get("tag") for o in d.get("outbounds", [])}
cn_outs = set()
for r in d["route"]["rules"]:
    if set(r.get("rule_set") or []) & {"geoip-cn", "geosite-cn"}:
        cn_outs.add(r.get("outbound"))
if "cn-via-jp" in cn_outs and "cn-via-jp" in tags:
    _mode = "cn-via-jp"     # 标准: 国内走日本
elif "direct" in cn_outs:
    _mode = "direct"        # 旧配置: 国内直连(泄漏)
else:
    _mode = "proxy"         # 隐身/严格: 全走代理
# 三种情况要分开: cn-via-jp(标准) / direct(旧配置) / 都没有(隐身或严格)
print(f"    国内方向出站: {_mode}")
if _mode == "cn-via-jp":
    print("      -> 走日本节点。这是【标准模式】, 不是隐身模式")
    print("         国内站能开, 真实 IP 不泄漏, DNS 也不走国内")
elif _mode == "direct":
    print("      -> 直连！这是旧配置, 真实 IP 会泄漏")
    print("         修: sudo ./scripts/setup-routing.sh --cn-node 日本CN2-3")
else:
    print("      -> 走代理。是隐身模式(--strict)或旧配置状态")
PY
        else
            echo "    读不到 $CONF"
        fi
        echo
        do_test
        echo
        echo "  判读: 国内 STUN 报出【代理/住宅 IP】= 已堵住 ✓"
        echo "        国内 STUN 报出【你的真实中国 IP】= 仍泄漏 ✗"
        ;;
    *)
        echo "用法: $0 {on|off|status|test}"
        exit 1
        ;;
esac
