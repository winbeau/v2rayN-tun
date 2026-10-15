#!/usr/bin/env python3
"""
本地订阅转换服务 —— 让 v2rayN 能"订阅"一个只提供 Clash 格式的机场。

为什么需要
──────────
IPEqual 只给 Clash 格式的订阅。v2rayN 的订阅机制 (SubItem / importsub) 需要
一个返回【节点链接】或【base64 编码的节点链接】的 URL。

v2rayN 里把 vless:// 一条条粘贴进去也能用, 但那是一次性的 —— SubItem 的
自动更新完全不会生效, 下次机场换 IP 又得手动重来。

所以: 在中间架一个本地 HTTP 服务, 把 Clash YAML 实时转成 v2rayN 认的格式。

     v2rayN --订阅--> http://127.0.0.1:18080/sub
                          |
                          v
                    本服务: 拉 Clash 订阅 -> 解析 -> 转 vless:// -> base64
                          |
                          v
                  https://<机场>/use/unsafe/sub.php?t=..&s=..

于是 v2rayN 的「自动更新」终于有意义了。

端点
────
  GET /sub         base64 编码的节点链接 (标准 v2ray 订阅格式) <- v2rayN 订阅这个
  GET /links       明文节点链接, 每行一个 (方便人看 / 剪贴板导入)
  GET /list        节点名 + 类型 + 服务器 (排查用)
  GET /health      健康检查 (返回 JSON)
  GET /            用法说明

配置
────
  订阅地址:  ~/.v2rayn-tun/sub-url   (一行, 含 token, 权限 600)
  端口:      默认 18080, 可用 --port 或环境变量 SUB_PORT 覆盖
  缓存:      默认 600 秒 (避免每次刷新 v2rayN 都去打机场)

依赖: 只用标准库。转换逻辑复用同目录的 clash-sub-to-v2rayn.py。
"""

import argparse
import base64
import json
import os
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    from importlib import import_module
    _conv = import_module("clash-sub-to-v2rayn".replace("-", "_")) if False else None
except Exception:
    _conv = None

# 文件名带连字符, 不能用 import 语句, 用 exec 加载
_HERE = os.path.dirname(os.path.abspath(__file__))
_CONV_PATH = os.path.join(_HERE, "clash-sub-to-v2rayn.py")
_ns = {"__name__": "clash_sub_to_v2rayn", "__file__": _CONV_PATH}
with open(_CONV_PATH, encoding="utf-8") as _f:
    exec(compile(_f.read(), _CONV_PATH, "exec"), _ns)

parse_proxies = _ns["parse_proxies"]
to_uri = _ns["to_uri"]

DEFAULT_URL_FILE = os.path.expanduser("~/.v2rayn-tun/sub-url")
# ⚠️ 缓存要短。
# 机场修好线路后, 客服会要求"在客户端点更新" —— 如果这里缓存太长,
# v2rayN 点了更新却拿到旧节点, 会以为"更新没生效", 白白多等一轮。
# 60 秒足够挡住连点, 又不会让用户误判。
CACHE_TTL = int(os.environ.get("SUB_CACHE_TTL", "60"))

# ⚠️ 锁只在读写缓存时持有, 【绝不覆盖网络请求】。
# 早先的版本把整段 fetch 包在锁里, 结果 warmup 线程拉取期间所有 HTTP 请求
# 都堵在锁上, 表现为 v2rayN/curl 拿到空响应 (超时)。
_lock = threading.Lock()
_cache = {"at": 0.0, "links": [], "error": None}
_fetching = threading.Event()


def load_sub_url():
    uf = os.environ.get("SUB_URL_FILE", DEFAULT_URL_FILE)
    if not os.path.exists(uf):
        raise RuntimeError(f"没有订阅地址文件: {uf}")
    url = open(uf, encoding="utf-8").read().strip()
    if not url.startswith("http"):
        raise RuntimeError(f"订阅地址无效: {url[:40]}...")
    return url


def _do_fetch():
    """真正去拉取并转换。不加锁。"""
    url = load_sub_url()
    req = urllib.request.Request(url, headers={"User-Agent": "v2rayN/7.25.4"})
    with urllib.request.urlopen(req, timeout=30) as r:
        text = r.read().decode("utf-8", "replace")
    proxies = parse_proxies(text)
    links = [u for u in (to_uri(p) for p in proxies) if u]
    if not links:
        raise RuntimeError("转换后没有任何节点")
    return links


def get_links(force=False, block=True):
    """返回 (links, error)。

    block=True  : 缓存过期就同步拉取 (会等)
    block=False : 缓存过期就【先返回旧数据】并在后台刷新 (不阻塞 HTTP)
    """
    with _lock:
        fresh = (time.time() - _cache["at"]) < CACHE_TTL
        if fresh and not force and _cache["links"]:
            return list(_cache["links"]), _cache["error"]
        stale = list(_cache["links"])

    if not block:
        # 后台刷新, 本次先用旧的
        def bg():
            try:
                links = _do_fetch()
                with _lock:
                    _cache.update(at=time.time(), links=links, error=None)
            except Exception as e:
                with _lock:
                    _cache["error"] = str(e)
        if not _fetching.is_set():
            _fetching.set()
            def wrap():
                try:
                    bg()
                finally:
                    _fetching.clear()
            threading.Thread(target=wrap, daemon=True).start()
        return stale, _cache["error"]

    # 同步路径: 拉取时不持锁
    try:
        links = _do_fetch()
        with _lock:
            _cache.update(at=time.time(), links=links, error=None)
        return links, None
    except Exception as e:
        with _lock:
            _cache["error"] = str(e)
            if _cache["links"]:
                return list(_cache["links"]), str(e)
        return [], str(e)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        # 只记错误, 正常请求不刷屏
        if not str(a[1] if len(a) > 1 else "").startswith("2"):
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % a))

    def _send(self, body, ctype="text/plain; charset=utf-8", code=200):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        # 有些客户端会看这个头来拿流量信息
        self.send_header("Subscription-Userinfo", "upload=0; download=0; total=0; expire=0")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/") or "/"

        if path in ("/sub", "/subscribe"):
            links, err = get_links(block=False)
            if not links:
                self._send(f"# 转换失败: {err}\n", code=502)
                return
            body = base64.b64encode("\n".join(links).encode()).decode()
            self._send(body)

        elif path == "/links":
            links, err = get_links(block=False)
            if not links:
                self._send(f"# 转换失败: {err}\n", code=502)
                return
            self._send("\n".join(links) + "\n")

        elif path == "/list":
            links, err = get_links(block=False)
            import urllib.parse
            out = []
            for u in links:
                p = urllib.parse.urlparse(u)
                name = urllib.parse.unquote(p.fragment)
                out.append(f"{name:<36} {p.hostname}:{p.port}")
            self._send("\n".join(out) + "\n")

        elif path == "/refresh":
            links, err = get_links(force=True)
            self._send(json.dumps({"count": len(links), "error": err},
                                  ensure_ascii=False) + "\n",
                       ctype="application/json")

        elif path == "/health":
            # 非阻塞: 健康检查绝不能因为缓存过期而挂住 (会误导成"服务挂了")
            links, err = get_links(block=False)
            self._send(json.dumps({
                "ok": bool(links),
                "count": len(links),
                "age": int(time.time() - _cache["at"]) if _cache["at"] else None,
                "error": err,
            }, ensure_ascii=False) + "\n", ctype="application/json")

        else:
            self._send(
                "本地订阅转换服务\n\n"
                "  /sub     base64 节点订阅  <- 在 v2rayN 里订阅这个\n"
                "  /links   明文节点链接\n"
                "  /list    节点清单\n"
                "  /refresh 强制刷新缓存\n"
                "  /health  健康检查\n"
            )


def main():
    ap = argparse.ArgumentParser(description="本地订阅转换服务")
    ap.add_argument("--port", type=int, default=int(os.environ.get("SUB_PORT", "18080")))
    ap.add_argument("--host", default="127.0.0.1")
    args = ap.parse_args()

    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    srv.daemon_threads = True
    print(f"[sub-server] 监听 {args.host}:{args.port} (后台拉取订阅中...)", flush=True)

    # ⚠️ 必须【先监听再拉数据】。
    # 之前的顺序是先 get_links() 再 serve_forever() —— 拉取要几秒到几十秒,
    # 这段时间端口没在听, v2rayN 会直接连不上 (表现为 000)。
    def warmup():
        links, err = get_links(force=True, block=True)
        if links:
            print(f"[sub-server] 就绪: {len(links)} 个节点", flush=True)
        else:
            print(f"[sub-server] ⚠ 拉取失败: {err}", flush=True)

    threading.Thread(target=warmup, daemon=True).start()

    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
