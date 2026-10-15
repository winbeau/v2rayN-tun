#!/usr/bin/env python3
# 让指定进程直连节点 (绕开 xray 的国内直连), 防止真实 IP 泄漏
"""
按进程分流 —— 让指定程序(指纹浏览器 / 终端)【直连节点】, 绕开 v2rayN 的 xray。

要解决什么问题
──────────────
v2rayN 的路由设置是【绕过大陆】: 国内目标直连。它的本意是对的(国内站点不绕道
国外、上网快), 但它带来一个 IP 泄漏:

    任何指向国内地址的连接, 都用你的真实 IP 出去。
    最典型的是 WebRTC 的 STUN 查询 —— Bilibili / 小米 / 芒果TV 都提供公共
    STUN 服务, 网页跑一小段 JS 就能拿到你的真实 IP。

而且这个项目里有【两层】国内直连:

    第 1 层  sing-box (TUN)      config.json 的 geoip-cn / geosite-cn
    第 2 层  xray  (v2rayN 生成)  绕过大陆路由里的 geoip:cn / geosite:cn

xray 看不到"这个连接原本是哪个程序发的" —— 所以只要流量还经过它,
就没法只对某个程序关掉国内直连。

本脚本的做法
────────────
给 sing-box 加一个【直连节点的出站】(vless), 并让指定进程走它:

    SunBrowser / Terminal ─→ sing-box ─→ vless 直连住宅节点 ─→ 目标
                                          完全绕开 xray ✓ 不经过第 2 层 ✓
    其他所有程序 ─────────→ sing-box ─→ socks10808 (xray, 绕过大陆, 现状不变)

于是:
    · 指纹浏览器和终端【永远全代理】, 不管访问国内还是国外, 都不泄漏 ✓
    · 其他程序保持"国内直连"的快速度 ✓
    · 不需要在 v2rayN 里来回切 全局/绕过大陆 ✓

用法
────
    ./per-app-routing.py plan      只显示会怎么改 (不改动)
    ./per-app-routing.py generate  生成改好的配置到 stdout
    ./per-app-routing.py apply     写入 /usr/local/libexec/v2rayn-tun/config.json
                                   (需要 root, 且会重启守护)

节点信息从哪里来
────────────────
从本地订阅服务读 (http://127.0.0.1:18080/links), 取名字含"住宅"的那个节点。
所以订阅更新后重跑一次 apply, 新的节点参数就会同步进来。
"""

import argparse
import collections
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "config", "sing-box.json")
LIVE = "/usr/local/libexec/v2rayn-tun/config.json"
SUBSERVER = "http://127.0.0.1:18080/links"
NODE_TAG = "node-direct"

# ── 走"直连节点"的进程 ──
#
# ⚠️ 这里要写【真正发起连接的那个进程】, 不是"它所在的程序"。
#
#    实测踩过的坑:
#      用户想在 Terminal 里跑 Claude Code 也走节点, 于是写了 "Terminal" ——
#      结果完全不生效。原因: Terminal 只是终端窗口, 它自己不发网络请求;
#      发请求的是它启动的子进程 curl / git / node ...
#      sing-box 匹配到的是 "curl", 名单里没有, 于是走了普通路由。
#
#      所以"让整个 Terminal 走代理"用进程匹配做不到, 必须逐个列出里面的工具。
#      但那代价很大 —— 住宅节点到不了中国大陆, 终端里的 npm 国内镜像、
#      国内 git 仓库、校园网内网都会失效。
#
#    结论: 只豁免【浏览器】就够了。
#      · 浏览器会加载国内域名的资源(图片/脚本), 网页据此能拿到真实 IP ✗
#      · Claude Code 只连 api.anthropic.com(国外), 本来就走代理, 没有泄漏路径 ✓
#
# ⚠️ 必须把 Chromium 的辅助进程也列上。
#    浏览器的网络请求不是主进程发的, 而是 network service 这个 utility 进程,
#    它的可执行名是 "SunBrowser Helper" 而不是 "SunBrowser"。
#    只写主进程会漏掉真正的流量。
TARGET_PROCESSES = [
    # AdsPower 指纹浏览器的实际内核 (名为 SunBrowser)
    "SunBrowser",
    "SunBrowser Helper",
    "SunBrowser Helper (Renderer)",
    "SunBrowser Helper (GPU)",
]


def node_is_alive(link, timeout=15):
    """起一个临时 xray 实测这个节点能不能通。

    ⚠️ 这一步不能省: node-direct 出站如果不通, 被豁免的进程
       (指纹浏览器 / 终端) 会【完全没有网络】, 比泄漏还糟。
    """
    import socket, subprocess, tempfile, signal, time
    xray = os.path.expanduser("~/Library/Application Support/v2rayN/bin/xray/xray")
    if not os.path.exists(xray):
        return None, "找不到 xray, 跳过预检"
    ob = build_outbound(link)
    cfg = {
        "log": {"loglevel": "error"},
        "inbounds": [{"tag": "in", "listen": "127.0.0.1", "port": 0,
                      "protocol": "socks", "settings": {"auth": "noauth"}}],
        "outbounds": [{
            "tag": "out", "protocol": "vless",
            "settings": {"vnext": [{"address": ob["server"], "port": ob["server_port"],
                                    "users": [{"id": ob["uuid"], "encryption": "none",
                                               **({"flow": ob["flow"]} if ob.get("flow") else {})}]}]},
            "streamSettings": {
                "network": "tcp", "security": "reality",
                "realitySettings": {
                    "serverName": ob.get("tls", {}).get("server_name", ""),
                    "fingerprint": (ob.get("tls", {}).get("utls") or {}).get("fingerprint", "chrome"),
                    "publicKey": (ob.get("tls", {}).get("reality") or {}).get("public_key", ""),
                    "shortId": (ob.get("tls", {}).get("reality") or {}).get("short_id", ""),
                },
            },
        }],
    }
    # 找一个空闲端口
    s0 = socket.socket(); s0.bind(("127.0.0.1", 0)); port = s0.getsockname()[1]; s0.close()
    cfg["inbounds"][0]["port"] = port
    fd, path = tempfile.mkstemp(suffix=".json", prefix="perapp-test-")
    with os.fdopen(fd, "w") as f:
        json.dump(cfg, f)
    proc = None
    try:
        proc = subprocess.Popen([xray, "run", "-c", path],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 4
        while time.time() < deadline:
            if proc.poll() is not None:
                return False, "xray 没起来"
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.3).close()
                break
            except OSError:
                time.sleep(0.15)
        proxy = f"socks5h://127.0.0.1:{port}"
        opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
        t0 = time.time()
        try:
            with opener.open("https://www.google.com/generate_204", timeout=timeout) as r:
                if r.status == 204:
                    return True, f"{time.time()-t0:.2f}s"
            return False, f"HTTP {r.status}"
        except Exception as e:
            return False, type(e).__name__
    finally:
        if proc and proc.poll() is None:
            proc.send_signal(signal.SIGKILL)
            try: proc.wait(timeout=3)
            except Exception: pass
        try: os.unlink(path)
        except OSError: pass


def build_outbound(link):
    """vless:// 链接 -> sing-box outbound"""
    u = urllib.parse.urlparse(link)
    q = dict(urllib.parse.parse_qsl(u.query))
    if not u.hostname or not u.username:
        sys.exit(f"✗ 节点链接缺少必要字段: {link[:80]}")

    ob = collections.OrderedDict([
        ("type", "vless"),
        ("tag", NODE_TAG),
        ("server", u.hostname),
        ("server_port", u.port or 443),
        ("uuid", u.username),
        ("packet_encoding", "xudp"),
    ])
    if q.get("flow"):
        ob["flow"] = q["flow"]

    tls = collections.OrderedDict([("enabled", True)])
    if q.get("sni"):
        tls["server_name"] = q["sni"]
    if q.get("fp"):
        tls["utls"] = {"enabled": True, "fingerprint": q["fp"]}
    if q.get("security") == "reality" or q.get("pbk"):
        tls["reality"] = collections.OrderedDict([
            ("enabled", True),
            ("public_key", q.get("pbk", "")),
            ("short_id", q.get("sid", "")),
        ])
    ob["tls"] = tls
    return ob


def patch(cfg, node_link):
    """返回 (新配置, 改动说明列表)"""
    out = json.loads(json.dumps(cfg))
    changed = []

    ob = build_outbound(node_link)
    name = urllib.parse.unquote(urllib.parse.urlparse(node_link).fragment)

    # ── 1. 加/更新出站 ──
    obs = out.setdefault("outbounds", [])
    idx = next((i for i, o in enumerate(obs) if o.get("tag") == NODE_TAG), None)
    if idx is None:
        # 插在第一个出站前面 (保持它在文件里靠前, 便于阅读)
        obs.insert(0, ob)
        changed.append(f"新增出站 [{NODE_TAG}] -> {ob['server']}:{ob['server_port']}  ({name})")
    else:
        obs[idx] = ob
        changed.append(f"更新出站 [{NODE_TAG}] -> {ob['server']}:{ob['server_port']}  ({name})")

    # ── 2. 加/更新进程规则 ──
    rules = out.setdefault("route", {}).setdefault("rules", [])
    # 先删掉旧的同名规则
    before = len(rules)
    rules[:] = [r for r in rules if r.get("outbound") != NODE_TAG]

    rule = collections.OrderedDict([
        ("process_name", list(TARGET_PROCESSES)),
        ("outbound", NODE_TAG),
    ])

    # 插到"流量分流"的最前面 —— 必须在 geoip-cn / geosite-cn 之前,
    # 否则这些进程访问国内站还是会被判成直连。
    # 但必须排在 DNS 劫持之后 (规则 [3]/[7]), 让 DNS 照常走 sing-box 的 dns。
    insert_at = None
    for i, r in enumerate(rules):
        if r.get("action") == "hijack-dns" or r.get("type") == "logical":
            insert_at = i + 1
    if insert_at is None:
        # 找不到劫持规则就插在最前面 (保守)
        insert_at = 0
    rules.insert(insert_at, rule)
    changed.append(f"插入进程规则到 route.rules[{insert_at}]: "
                   f"{', '.join(TARGET_PROCESSES)} -> {NODE_TAG}")
    if before != len(rules) - 1:
        changed.append(f"(清理了 {before - (len(rules) - 1)} 条旧规则)")

    return out, changed


def load(path):
    if not os.path.exists(path):
        sys.exit(f"✗ 找不到配置: {path}")
    return json.load(open(path, encoding="utf-8"), object_pairs_hook=collections.OrderedDict)


def main():
    ap = argparse.ArgumentParser(description="让指定进程直连节点, 绕开 xray 的国内直连")
    ap.add_argument("action", choices=["plan", "generate", "apply", "verify"])
    ap.add_argument("-o", "--output", help="输出文件")
    ap.add_argument("--sub", default="sub2",
                    help="用哪条订阅的住宅节点 (默认 sub2; 本地服务里 /sub 和 /sub2)")
    ap.add_argument("--skip-check", action="store_true", help="跳过节点可用性预检 (不推荐)")
    args = ap.parse_args()

    if args.action == "verify":
        return verify()

    base = LIVE if args.action == "apply" else (LIVE if os.path.exists(LIVE) else SRC)
    cfg = load(base)
    node_link, node_name = fetch_residential_node(args.sub)

    print(f"节点来源: 订阅 {args.sub}   用的是「{node_name}」", file=sys.stderr)

    # ★ 预检: node-direct 不通的话, 被豁免的进程会完全没网 —— 比泄漏更糟
    if not args.skip_check:
        print("  正在实测这个节点能否连通 ...", file=sys.stderr)
        ok, info = node_is_alive(node_link)
        if ok is False:
            sys.exit(f"✗ 节点不可用 ({info}) —— 拒绝应用。\n"
                     f"  如果这条线路被阻断了, 用 --sub sub 试试另一条:\n"
                     f"    ./per-app-routing.py plan --sub sub")
        print(f"  ✓ 节点可用 ({info})", file=sys.stderr)

    newcfg, changed = patch(cfg, node_link)
    for c in changed:
        print(f"  · {c}", file=sys.stderr)

    if args.action == "plan":
        print(file=sys.stderr)
        print("改后的路由规则 (只列前 8 条):", file=sys.stderr)
        for i, r in enumerate(newcfg["route"]["rules"][:8]):
            keys = {k: v for k, v in r.items()}
            print(f"  [{i}] {json.dumps(keys, ensure_ascii=False)[:120]}", file=sys.stderr)
        return

    text = json.dumps(newcfg, ensure_ascii=False, indent=2)
    if args.action == "generate":
        if args.output:
            open(args.output, "w", encoding="utf-8").write(text)
            print(f"✓ 已写入 {args.output}", file=sys.stderr)
        else:
            print(text)
        return

    # apply
    if os.geteuid() != 0:
        sys.exit("✗ apply 需要 root: sudo ./per-app-routing.py apply")
    if not os.path.exists(LIVE):
        sys.exit(f"✗ 找不到 {LIVE}")
    bak = LIVE + ".bak-perapp"
    if not os.path.exists(bak):
        subprocess.run(["cp", LIVE, bak])
        print(f"  已备份 -> {bak}", file=sys.stderr)
    open(LIVE, "w", encoding="utf-8").write(text)
    os.chmod(LIVE, 0o644)
    subprocess.run(["chown", "root:wheel", LIVE])

    r = subprocess.run(["/usr/local/libexec/v2rayn-tun/sing-box", "check", "-c", LIVE],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"✗ 配置校验失败, 未重启:\n{r.stderr[:500]}")
    print("  ✓ 配置校验通过", file=sys.stderr)

    subprocess.run(["launchctl", "kickstart", "-k", "system/com.local.v2rayn-tun"])
    print("  ✓ 守护已重启", file=sys.stderr)


def verify():
    """实测: 对比豁免进程和其他进程看到的 IP"""
    print("  对照方式: 同一个国内目标, 不同程序去访问, 看各自看到的源 IP")
    print()
    print("  ① 用 curl (非豁免进程) 访问国内 IP 回显:")
    r = subprocess.run(["curl", "-s", "--noproxy", "*", "--max-time", "15",
                        "https://ip.3322.net"], capture_output=True, text=True,
                       env={**os.environ, "http_proxy": "", "https_proxy": ""})
    print(f"       {r.stdout.strip() or '失败'}")
    print("       (应显示你的真实中国 IP —— 因为 curl 不在豁免名单里)")
    print()
    print("  ② 用 curl 但假装成豁免进程做不到, 请在 Terminal 里直接跑:")
    print("       curl -s --noproxy '*' https://ip.3322.net")
    print("       (Terminal 整个走代理 -> 应显示住宅 IP ✓)")
    print()
    print("  ③ 用指纹浏览器打开:")
    print("       https://ipinfo.cv/webrtc-check")
    print("       (国内 STUN 那几行应显示住宅 IP, 不再出现真实中国 IP ✓)")
    print()
    print("  ④ 检查配置里有没有生效:")
    try:
        d = json.load(open(LIVE, encoding="utf-8"))
        obs = [o.get("tag") for o in d.get("outbounds", [])]
        rule = next((r for r in d["route"]["rules"] if r.get("outbound") == NODE_TAG), None)
        print(f"       出站列表: {obs}")
        print(f"       进程规则: {json.dumps(rule, ensure_ascii=False) if rule else '✗ 没有'}")
    except Exception as e:
        print(f"       读不到配置: {e}")


if __name__ == "__main__":
    main()
