#!/usr/bin/env python3
# 生成 sing-box 的「进程豁免」与「国内方向走哪个节点」两条规则
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

# 国内目标走哪个出站。设了就"国内直连"不复存在 —— 包括 DNS 也不再用国内服务器。
CN_TAG = "cn-via-jp"
CN_DNS_TAG = "jp-dns"

# 这些 direct 规则必须保留 (改了会出问题)
KEEP_DIRECT_RULE_SETS = {"geosite-private"}   # 私有/本地域名
KEEP_DIRECT_KEYS = {"process_path", "ip_is_private", "clash_mode"}

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


def pick_node(links, keyword):
    """从节点链接里挑一个 (按名字关键词)"""
    for l in links:
        if keyword in urllib.parse.unquote(urllib.parse.urlparse(l).fragment):
            return l
    return None


def add_cn_routing(out, cn_link):
    """把"国内直连"整体改成走 cn_link 指定的出站, 并让国内 DNS 也从那里解析。

    这一步做完, 本机就再没有"国内直连"了 —— 包括 DNS 查询也不再发给
    国内的 119.29.29.29 之类服务器。
    """
    changed = []

    # (a) 出站
    obs = out.setdefault("outbounds", [])
    jp = build_outbound(cn_link)
    jp["tag"] = CN_TAG
    idx = next((i for i, o in enumerate(obs) if o.get("tag") == CN_TAG), None)
    name = urllib.parse.unquote(urllib.parse.urlparse(cn_link).fragment)
    if idx is None:
        obs.insert(1 if obs else 0, jp)
        changed.append(f"新增出站 [{CN_TAG}] -> {jp['server']}  ({name})")
    else:
        obs[idx] = jp
        changed.append(f"更新出站 [{CN_TAG}] -> {jp['server']}  ({name})")

    # (b) DNS 服务器: 一个专门走 cn-via-jp 的解析器
    dns = out.setdefault("dns", {})
    servers = dns.setdefault("servers", [])
    if not any(sv.get("tag") == CN_DNS_TAG for sv in servers):
        servers.append(collections.OrderedDict([
            # ⚠️ sing-box 1.12+ 用新格式 (type + server + path + domain_resolver)
            #    旧的 address 字段在 1.14 已被移除, 用了会直接启动失败。
            #    形状照抄本机已在用的 remote-dns-1。
            ("type", "https"),
            ("tag", CN_DNS_TAG),
            ("server", "cloudflare-dns.com"),
            ("path", "/dns-query"),
            ("domain_resolver", "hosts-dns"),
            ("detour", CN_TAG),
        ]))
        changed.append(f"新增 DNS 服务器 [{CN_DNS_TAG}] (DoH, 经 {CN_TAG} 发出)")

    # (c) DNS 规则: 原本走 direct-dns-1 的国内相关规则, 全改成走 jp-dns
    #     保留 geosite-private (本地域名, 远端解析不了)
    for i, r in enumerate(dns.get("rules", [])):
        if r.get("server") != "direct-dns-1":
            continue
        if set(r.get("rule_set") or []) & KEEP_DIRECT_RULE_SETS:
            continue
        if r.get("clash_mode") == "Direct":
            continue
        desc = r.get("rule_set") or r.get("domain_suffix") or "?"
        r["server"] = CN_DNS_TAG
        changed.append(f"dns.rules[{i}] {str(desc)[:44]} direct-dns-1 -> {CN_DNS_TAG}")

    # (d) 路由规则: 原本走 direct 的国内相关规则, 全改成走 cn-via-jp
    for i, r in enumerate(out.get("route", {}).get("rules", [])):
        if r.get("outbound") != "direct":
            continue
        if any(k in r for k in KEEP_DIRECT_KEYS):
            continue
        if set(r.get("rule_set") or []) & KEEP_DIRECT_RULE_SETS:
            continue
        desc = r.get("rule_set") or r.get("domain_suffix") or r.get("ip_cidr") or "?"
        r["outbound"] = CN_TAG
        changed.append(f"route.rules[{i}] {str(desc)[:44]} direct -> {CN_TAG}")

    # (e) ★ 最后 ★ 才插入"只认国内 IP"的例外
    #
    #     ⚠️ 顺序很关键: 上面第 (d) 步会把【所有】 direct 规则改成 cn-via-jp。
    #        如果例外先插进去, 它会连同其他国内规则一起被改掉 ——
    #        实测踩过这个坑, 生成出来例外是 0 条。
    #
    #     两类站点经日本节点实测全部 URLError, 直连正常:
    #       · 腾讯/微信 (qpic.cn 是微信图片 CDN, 连不上就发不出图)
    #       · 教育网 / 政务 (高校门户、学信网、工信部等, 有国内访问控制)
    #     它们本身就是中国机构, 看到中国 IP 完全正常, 与 Claude 无关。
    #
    #     DNS 也要一起改: 否则这些域名经 jp-dns 解析到海外节点,
    #     路由写了 direct 也照样连不上 (docs/16 踩过的同一个坑)。
    #     腾讯/微信所在的网络对境外机房 IP 一律拒绝: 实测 qpic.cn /
    #     weixin.qq.com / res.wx.qq.com 经日本节点和住宅节点【全部连不上】,
    #     而直连正常。微信发不出图片/文件就是这个原因。
    #     微信是国产应用, 看到中国 IP 完全正常, 与 Claude 无关。
    #
    #     ⚠️ DNS 也要一起改: 否则这些域名会经 jp-dns 解析到海外节点,
    #        即使路由规则写了 direct, 直连一个海外 IP 照样连不上。
    # 这些站点【只认国内 IP】, 经日本节点实测全部 URLError, 直连正常。
    # 加进直连例外 —— 它们本身就是中国机构, 看到中国 IP 完全正常。
    wx_domains = [
        # ── 腾讯/微信 ── (qpic.cn 是微信图片 CDN, 连不上就发不出图)
        "qq.com", "weixin.qq.com", "wx.qq.com", "wechat.com", "weixin.com",
        "qpic.cn", "qlogo.cn", "gtimg.cn", "qzonestyle.gtimg.cn",
        "tencent.com", "tencent-cloud.net", "myqcloud.com", "qcloud.com",
        "wechatpay.cn", "tenpay.com", "weixinbridge.com",
        # ── 教育网 ── (覆盖全部高校)
        "edu.cn", "ac.cn", "chsi.com.cn", "chsi.cn",
        # ── 政务 ── (含工信部 miit.gov.cn)
        "gov.cn", "gov.hk",
        # ── 代码托管 ──
        "gitcode.com", "gitcode.net", "csdn.net",
        # ── 比赛/评测平台 ──
        "cannjudge.cn",
    ]

    # 外置追加清单: 不用改脚本就能加域名。
    # 一行一个根域名(# 开头是注释), 例如:
    #     echo "example.cn" >> ~/.v2rayn-tun/extra-direct.txt
    # 然后重新 apply 即可。
    extra_file = os.path.expanduser("~/.v2rayn-tun/extra-direct.txt")
    if os.path.exists(extra_file):
        try:
            with open(extra_file, encoding="utf-8") as f:
                for line in f:
                    d = line.split("#")[0].strip()
                    if d and d not in wx_domains:
                        wx_domains.append(d)
                        changed.append(f"外置清单追加: {d}")
        except OSError:
            pass
    rr = out.setdefault("route", {}).setdefault("rules", [])
    rr[:] = [r for r in rr
             if not (r.get("domain_suffix") == wx_domains and r.get("outbound") == "direct")]
    pos = next((i for i, r in enumerate(rr) if r.get("outbound") == CN_TAG), len(rr))
    rr.insert(pos, collections.OrderedDict([
        ("outbound", "direct"),
        ("domain_suffix", wx_domains),
    ]))
    changed.append(f"插入微信直连例外到 route.rules[{pos}] ({len(wx_domains)} 个域名)")

    dd = out.setdefault("dns", {}).setdefault("rules", [])
    dd[:] = [r for r in dd if not (r.get("domain_suffix") == wx_domains)]
    dpos = next((i for i, r in enumerate(dd) if r.get("server") == CN_DNS_TAG), len(dd))
    dd.insert(dpos, collections.OrderedDict([
        ("server", "direct-dns-1"),
        ("domain_suffix", wx_domains),
    ]))
    changed.append(f"插入微信直连解析到 dns.rules[{dpos}]")

    return changed


def fetch_residential_node(source="sub2"):
    """从本地订阅服务取住宅节点的 vless 链接

    source: "sub" / "sub2" / ...  ->  http://127.0.0.1:18080/<source>
    端点返回的是 base64 (标准 v2ray 订阅格式), 这里兼容 base64 和明文两种。
    """
    url = SUBSERVER.rsplit("/", 1)[0] + "/" + source
    try:
        with urllib.request.urlopen(url, timeout=20) as r:
            raw = r.read().decode("utf-8", "replace").strip()
        if "://" not in raw:
            import base64 as _b64
            pad = raw + "=" * (-len(raw) % 4)
            try:
                raw = _b64.urlsafe_b64decode(pad).decode("utf-8", "replace")
            except Exception:
                try:
                    raw = _b64.b64decode(pad).decode("utf-8", "replace")
                except Exception:
                    pass
        links = [l.strip() for l in raw.splitlines() if l.strip()]
    except Exception as e:
        sys.exit(f"✗ 读不到本地订阅服务 ({url}): {e}\n"
                 f"  先确认它在跑: curl -s http://127.0.0.1:18080/health")
    if not links:
        sys.exit("✗ 订阅服务没返回任何节点")
    for l in links:
        name = urllib.parse.unquote(urllib.parse.urlparse(l).fragment)
        if "住宅" in name:
            return l, name
    return links[0], urllib.parse.unquote(urllib.parse.urlparse(links[0]).fragment)


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
    ap.add_argument("--cn-node", metavar="关键词", default=None,
                    help='把"国内直连"整体改成走该节点 (含 DNS)。例如 --cn-node 日本CN2-3')
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

    # 可选: 把国内直连整体换成走某个节点
    if args.cn_node:
        # 拿到全部节点链接来挑选
        u0 = SUBSERVER.rsplit("/", 1)[0] + "/" + args.sub
        rawb = urllib.request.urlopen(u0, timeout=20).read().decode().strip()
        if "://" not in rawb:
            import base64 as _b
            rawb = _b.urlsafe_b64decode(rawb + "=" * (-len(rawb) % 4)).decode()
        all_links = [l.strip() for l in rawb.splitlines() if l.strip().startswith("vless://")]
        cn_link = pick_node(all_links, args.cn_node)
        if not cn_link:
            sys.exit(f"✗ 找不到名字含「{args.cn_node}」的节点")
        if not args.skip_check:
            print(f"  预检国内出口节点 ...", file=sys.stderr)
            ok2, info2 = node_is_alive(cn_link)
            if ok2 is False:
                sys.exit(f"✗ 国内出口节点不可用 ({info2})")
            print(f"  ✓ 可用 ({info2})", file=sys.stderr)
        changed += add_cn_routing(newcfg, cn_link)
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

    # ⚠️ 必须先写临时文件、校验通过、再 mv 到正式位置。
    # 早先是"先写 LIVE 再 check" —— 校验失败时 LIVE 已经是坏的了,
    # 守护虽然还在跑内存里的旧配置(网络看起来正常), 但只要重启就起不来。
    tmp = LIVE + ".new"
    open(tmp, "w", encoding="utf-8").write(text)
    os.chmod(tmp, 0o644)
    subprocess.run(["chown", "root:wheel", tmp])

    r = subprocess.run(["/usr/local/libexec/v2rayn-tun/sing-box", "check", "-c", tmp],
                       capture_output=True, text=True)
    if r.returncode != 0:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        sys.exit(f"✗ 配置校验失败, 线上文件未改动:\n{r.stderr[:500]}")
    print("  ✓ 配置校验通过", file=sys.stderr)

    os.replace(tmp, LIVE)

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
