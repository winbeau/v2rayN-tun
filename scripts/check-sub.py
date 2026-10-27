#!/usr/bin/env python3
# 检查订阅 URL 是否还能拉到「与 token 一致」的节点。
#
# 背景: 订阅 URL 里的 t= 参数是一段 base64, 里面写着 server/port/uuid/
# public_key/short_id/servername —— 这些【只是元数据】, 服务端并不依赖它们
# 来生成节点列表。所以:
#
#   · 官方改节点参数(端口 443 -> 4561)时, 旧 URL 依然能拉到新参数 ✓
#   · 但如果官方作废了某条订阅, 旧 URL 会回 403 / 空内容 ✗
#
# 这个工具做两件事:
#   1. 把 token 里说的参数, 和实际拉到的节点列表比对 —— 不一致时提示
#      (说明 token 已经过时, 但不是故障; 顺手换成新 URL 更好)
#   2. 真正能拉到现在可用的节点吗 —— 拉不到说明订阅本身坏了
#
# 用法:
#   python3 scripts/check-sub.py            # 检查 sub-url 和 sub-url-2
#   python3 scripts/check-sub.py sub-url    # 只查一个
import base64, json, os, re, sys, urllib.parse, urllib.request

SUB_DIR = os.path.expanduser("~/.v2rayn-tun")


def parse_token(url):
    q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
    t = q.get("t", [""])[0]
    if not t:
        return None
    try:
        return json.loads(base64.urlsafe_b64decode(t + "=" * (-len(t) % 4)))
    except Exception:
        return None


def fetch_nodes(url):
    """返回 [(名称, server, port)]"""
    req = urllib.request.Request(url, headers={"User-Agent": "v2rayN/7.25.4"})
    raw = urllib.request.urlopen(req, timeout=30).read().decode("utf-8", "replace")
    body = raw.strip()

    # 标准 v2ray 订阅: base64
    if "://" not in body and "proxies:" not in body:
        try:
            body = base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)).decode("utf-8", "replace")
        except Exception:
            pass

    out = []
    # Clash YAML
    if "proxies:" in body:
        for m in re.finditer(r"name:\s*[\"']?([^\"',\n]+)", body):
            seg = body[m.start(): m.start() + 600]
            s = re.search(r"server:\s*[\"']?([^\s\"',\n]+)", seg)
            p = re.search(r"port:\s*(\d+)", seg)
            if s and p:
                out.append((m.group(1).strip(), s.group(1), int(p.group(1))))
        return out

    # vless/vmess 链接
    for line in body.splitlines():
        line = line.strip()
        if not line.startswith(("vless://", "vmess://")):
            continue
        try:
            u = urllib.parse.urlparse(line)
            name = urllib.parse.unquote(u.fragment)
            if u.port:
                out.append((name, u.hostname, u.port))
        except Exception:
            pass
    return out


def main():
    names = sys.argv[1:] or ["sub-url", "sub-url-2"]
    rc = 0
    for name in names:
        path = os.path.join(SUB_DIR, name)
        print(f"══ {name} ══")
        if not os.path.exists(path):
            print("  文件不存在"); rc = 1; continue
        url = open(path, encoding="utf-8").read().strip()
        host = urllib.parse.urlparse(url).netloc
        print(f"  订阅域名: {host}")

        tok = parse_token(url)
        if tok:
            print(f"  token 里写的: {tok.get('server')}:{tok.get('port')}  "
                  f"uuid={str(tok.get('uuid'))[:8]}")
        else:
            print("  token 解析失败")

        try:
            nodes = fetch_nodes(url)
        except Exception as e:
            print(f"  ✗ 拉取失败: {type(e).__name__}: {str(e)[:60]}")
            print("     → 订阅本身可能已作废, 需要向服务商要新 URL")
            rc = 1
            print()
            continue

        print(f"  拉到 {len(nodes)} 个节点")
        if not nodes:
            print("  ✗ 一个节点都没有 → 订阅不可用")
            rc = 1
            print()
            continue

        # 找住宅节点
        for n, s, p in nodes:
            if "住宅" in n:
                mark = ""
                if tok and (tok.get("server"), int(tok.get("port") or 0)) != (s, p):
                    mark = "  ⚠ token 里的参数已过时(不影响使用, 但建议换新 URL)"
                print(f"    ★ {n}: {s}:{p}{mark}")
        print()
    return rc


if __name__ == "__main__":
    sys.exit(main())
