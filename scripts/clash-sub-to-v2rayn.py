#!/usr/bin/env python3
# 把 Clash 订阅 (YAML) 转成 v2rayN 可导入的节点链接
"""
把 Clash 订阅 (Clash YAML) 转成 v2rayN 能直接导入的格式。

为什么需要这个
──────────────
IPEqual 这类机场只提供 Clash 格式的订阅 (proxies: 段), 而 v2rayN 需要的是
节点链接列表 (vless:// vmess:// ...) 或 base64 编码的同类内容。

两边都不肯让步时, 就在中间加一层转换。

实测本项目的场景:
  · Clash Verge 订阅:  https://equaldcdn.com/use/unsafe/sub.php?t=..&s=..
                        (返回 Clash YAML)
  · 同一份内容换成 https://ipequal.com/... 也一样是 Clash YAML
  · v2rayN 直接吃不下 -> 用本脚本转成 vless:// 链接列表

⚠️ 订阅地址里含账号 token, 属于敏感信息:
   · 不要写进代码、不要提交到仓库
   · 本脚本通过 --url / --url-file / 环境变量读取

用法
────
  # 1) 直接把地址当参数 (注意 shell 历史里会留痕)
  ./clash-sub-to-v2rayn.py --url 'https://...../sub.php?t=xxx&s=yyy'

  # 2) 从文件读地址 (推荐)
  echo 'https://...../sub.php?t=xxx&s=yyy' > ~/.v2rayn-tun/sub-url
  chmod 600 ~/.v2rayn-tun/sub-url
  ./clash-sub-to-v2rayn.py                      # 默认读这个文件

  # 3) 已经存了 Clash YAML 文件
  ./clash-sub-to-v2rayn.py --file clash.yaml

  # 输出形式
  ./clash-sub-to-v2rayn.py --format links        # 每行一个 vless:// (默认)
  ./clash-sub-to-v2rayn.py --format base64       # base64 编码 (标准订阅格式)
  ./clash-sub-to-v2rayn.py --format json         # 带解析结果的 JSON

  # 只保留住宅节点 (按名字过滤)
  ./clash-sub-to-v2rayn.py --grep 住宅

输出怎么用
──────────
  · links  : 复制全部内容 -> v2rayN「服务器」->「从剪贴板批量导入」
  · base64 : 存成文件, 用 v2rayN「订阅」->「添加订阅」指向它 (需自建 http 服务)
             或直接复制粘贴导入

依赖: 只用标准库, 不需要 PyYAML。
"""

import argparse
import base64
import json
import os
import re
import sys
import urllib.parse
import urllib.request

DEFAULT_URL_FILE = os.path.expanduser("~/.v2rayn-tun/sub-url")


# ─────────────────────────── Clash YAML 解析 ───────────────────────────
#
# 不引入 PyYAML: Clash 订阅的结构非常规整 (固定缩进、标量为主),
# 一个针对性的解析器比拉一个依赖更可控, 也不受运行环境限制。
#
# 支持的结构:
#   proxies:
#     - name: "节点名"
#       type: vless
#       server: 1.2.3.4
#       port: 443
#       reality-opts:            <- 一层嵌套
#         public-key: xxx
#         short-id: xxx

def _unquote(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ('"', "'"):
        s = s[1:-1]
    return s


def _scalar(s):
    """把 YAML 标量转成 Python 值"""
    s = s.strip()
    if s in ("true", "True"):
        return True
    if s in ("false", "False"):
        return False
    if s in ("null", "~", ""):
        return None
    # 纯数字 (端口等)
    if re.fullmatch(r"-?\d+", s):
        return int(s)
    return _unquote(s)


def parse_proxies(text):
    """从 Clash YAML 文本里抽出 proxies 段, 返回 list[dict]

    实现方式: 按缩进层级归位。
      indent 2  ->  "- " 开新节点
      indent 4  -> 该节点的普通键
      indent 6+ -> 归入最近一个 indent-4 的字典键 (如 reality-opts)
    """
    lines = text.splitlines()

    # 定位 proxies: 段
    start = None
    for i, ln in enumerate(lines):
        if re.match(r"^proxies:\s*$", ln):
            start = i + 1
            break
    if start is None:
        return []

    key_re = re.compile(r"^(\s*)([A-Za-z0-9_.-]+):\s*(.*)$")
    item_re = re.compile(r"^(\s*)-\s*(.*)$")

    proxies, cur, parent_key = [], None, None

    for ln in lines[start:]:
        # 顶层键出现 -> proxies 段结束
        if re.match(r"^[A-Za-z_][A-Za-z0-9_-]*:\s*", ln):
            break
        if not ln.strip() or ln.lstrip().startswith("#"):
            continue

        mi = item_re.match(ln)
        if mi:
            # 新节点
            if cur is not None:
                proxies.append(cur)
            cur = {}
            parent_key = None
            rest = mi.group(2).strip()
            if rest:
                km = key_re.match("      " + rest)
                if km:
                    cur[km.group(2)] = _scalar(km.group(3))
            continue

        if cur is None:
            continue

        km = key_re.match(ln)
        if not km:
            continue
        indent, key, val = len(km.group(1)), km.group(2), km.group(3)

        if val.strip() == "":
            # 打开一个嵌套字典
            cur[key] = {}
            parent_key = key
            continue

        if indent >= 6 and parent_key and isinstance(cur.get(parent_key), dict):
            cur[parent_key][key] = _scalar(val)
        else:
            cur[key] = _scalar(val)
            parent_key = None

    if cur is not None:
        proxies.append(cur)

    return [p for p in proxies if p.get("server")]


# ─────────────────────────── 节点 -> URI ───────────────────────────

def _q(**kw):
    """构造 query string, 跳过空值"""
    items = [(k, str(v)) for k, v in kw.items() if v not in (None, "", False)]
    return urllib.parse.urlencode(items)


def to_uri(p):
    """把一个 Clash proxy 字典转成节点 URI。不支持的类型返回 None。"""
    t = (p.get("type") or "").lower()
    server = p.get("server")
    port = p.get("port")
    if not server or not port:
        return None
    name = urllib.parse.quote(str(p.get("name") or f"{server}:{port}"))

    net = (p.get("network") or "tcp").lower()
    tls = bool(p.get("tls"))
    reality = p.get("reality-opts") or {}
    sni = p.get("servername") or p.get("sni") or ""
    fp = p.get("client-fingerprint") or ""
    flow = p.get("flow") or ""
    ws = p.get("ws-opts") or {}
    grpc = p.get("grpc-opts") or {}

    security = "none"
    if reality.get("public-key"):
        security = "reality"
    elif tls:
        security = "tls"

    common = dict(
        type=net,
        security=security,
        sni=sni,
        fp=fp,
    )
    if net == "ws":
        common["path"] = ws.get("path", "/")
        common["host"] = (ws.get("headers") or {}).get("Host", "")
    if net == "grpc":
        common["serviceName"] = grpc.get("grpc-service-name", "")

    if t == "vless":
        q = dict(
            encryption=p.get("encryption", "none"),
            flow=flow,
            **common,
        )
        if security == "reality":
            q["pbk"] = reality.get("public-key", "")
            q["sid"] = reality.get("short-id", "")
            if p.get("spider-x") or p.get("spiderx"):
                q["spx"] = p.get("spider-x") or p.get("spiderx")
        auth = p.get("uuid") or ""
        return f"vless://{auth}@{server}:{port}?{_q(**q)}#{name}"

    if t == "vmess":
        obj = {
            "v": "2",
            "ps": str(p.get("name") or ""),
            "add": server,
            "port": str(port),
            "id": p.get("uuid") or "",
            "aid": str(p.get("alterId") or p.get("alterid") or 0),
            "scy": p.get("cipher") or "auto",
            "net": net,
            "type": "none",
            "host": common.get("host", ""),
            "path": common.get("path", ""),
            "tls": "tls" if tls else "",
            "sni": sni,
        }
        b = base64.b64encode(json.dumps(obj, ensure_ascii=False).encode()).decode()
        return f"vmess://{b}"

    if t == "trojan":
        q = dict(sni=sni, fp=fp, type=net)
        return f"trojan://{p.get('password','')}@{server}:{port}?{_q(**q)}#{name}"

    if t in ("ss", "shadowsocks"):
        cipher = p.get("cipher") or ""
        pwd = p.get("password") or ""
        userinfo = base64.urlsafe_b64encode(f"{cipher}:{pwd}".encode()).decode().rstrip("=")
        return f"ss://{userinfo}@{server}:{port}#{name}"

    if t in ("hysteria2", "hy2"):
        q = dict(sni=sni, insecure=str(bool(p.get("skip-cert-verify"))).lower())
        return f"hysteria2://{p.get('password','')}@{server}:{port}?{_q(**q)}#{name}"

    if t == "hysteria":
        return (f"hysteria://{server}:{port}?protocol=udp&auth={p.get('auth-str','')}"
                f"&peer={sni}&insecure=0#{name}")

    return None


# ─────────────────────────── 入口 ───────────────────────────

def fetch(url, ua="v2rayN/7.25.4", timeout=30):
    req = urllib.request.Request(url, headers={"User-Agent": ua})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("utf-8", "replace")


def main():
    ap = argparse.ArgumentParser(
        description="把 Clash 订阅转换成 v2rayN 可导入的格式",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--url", help="订阅地址 (含 token, 注意 shell 历史留痕)")
    src.add_argument("--url-file", help=f"从文件读订阅地址 (默认 {DEFAULT_URL_FILE})")
    src.add_argument("--file", help="本地的 Clash YAML 文件")
    ap.add_argument("--format", choices=["links", "base64", "json"], default="links",
                    help="输出形式 (默认 links)")
    ap.add_argument("--grep", help="只保留名字里含该串的节点 (对住宅节点用 '住宅')")
    ap.add_argument("--list", action="store_true", help="只列出节点名和类型, 不转换")
    args = ap.parse_args()

    # ── 取内容 ──
    if args.file:
        text = open(args.file, encoding="utf-8").read()
    else:
        url = args.url
        if not url:
            uf = args.url_file or DEFAULT_URL_FILE
            if not os.path.exists(uf):
                sys.exit(f"✗ 没有订阅地址。请用 --url 指定, 或把地址写到 {uf}")
            url = open(uf, encoding="utf-8").read().strip()
        try:
            text = fetch(url)
        except Exception as e:
            sys.exit(f"✗ 拉取订阅失败: {e}")

    # ── 解析 ──
    proxies = parse_proxies(text)
    if not proxies:
        sys.exit("✗ 没解析出任何节点。确认这是 Clash 格式的订阅 (含 proxies: 段)")

    if args.grep:
        proxies = [p for p in proxies if args.grep in str(p.get("name", ""))]
        if not proxies:
            sys.exit(f"✗ 没有名字含「{args.grep}」的节点")

    # ── 只列举 ──
    if args.list:
        print(f"共 {len(proxies)} 个节点:\n")
        for p in proxies:
            print(f"  {str(p.get('name',''))[:36]:<38} "
                  f"{p.get('type',''):<10} {p.get('server')}:{p.get('port')}")
        return

    # ── 转换 ──
    uris, skipped = [], []
    for p in proxies:
        u = to_uri(p)
        if u:
            uris.append(u)
        else:
            skipped.append(f"{p.get('name')} (type={p.get('type')})")

    if not uris:
        sys.exit("✗ 没有可转换的节点 (类型都不支持?)")

    if args.format == "links":
        print("\n".join(uris))
    elif args.format == "base64":
        print(base64.b64encode("\n".join(uris).encode()).decode())
    else:
        print(json.dumps({"count": len(uris), "uris": uris,
                          "skipped": skipped}, ensure_ascii=False, indent=2))

    if skipped and args.format != "json":
        print(f"\n# 跳过 {len(skipped)} 个不支持的类型: {', '.join(skipped)}", file=sys.stderr)


if __name__ == "__main__":
    main()
