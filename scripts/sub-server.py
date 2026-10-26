#!/usr/bin/env python3
# 本地订阅转换服务: 把 Clash 订阅暴露成 v2rayN 能订阅的 URL
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
import re
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
CACHE_TTL = int(os.environ.get("SUB_CACHE_TTL", "10"))
# ↑ 默认 10 秒而不是 60。官方换节点参数(端口/uuid)时不会通知,
#   而上游是 cache-control: no-store 且没有 ETag/Last-Modified,
#   没法做条件请求 —— 只能靠"过期得足够快"来逼近"及时感知"。
#   实测踩过: 端口 443 -> 4561 后, 60 秒窗口内 v2rayN 更新会拿到旧端口,
#   整条住宅线路就连不上了。订阅更新本来就低频, 多等 1 秒无所谓。

# ⚠️ 锁只在读写缓存时持有, 【绝不覆盖网络请求】。
# 早先的版本把整段 fetch 包在锁里, 结果 warmup 线程拉取期间所有 HTTP 请求
# 都堵在锁上, 表现为 v2rayN/curl 拿到空响应 (超时)。
_lock = threading.Lock()
# 每条订阅独立缓存 —— 两条线路的更新节奏互不影响
_cache = {}          # name -> {"at": float, "links": list, "error": str|None}

# 磁盘缓存 —— 见下方 _load_disk / _save_disk 的说明
_cache_dir = os.path.expanduser("~/.v2rayn-tun/subcache")


def _disk_path(name):
    return os.path.join(_cache_dir, f"{name}.txt")


def _save_disk(name, links):
    """把成功拉到的节点列表落到磁盘。

    为什么需要: 内存缓存在进程重启后是空的。如果重启后第一次上游拉取就失败,
    get_links 会返回 502 —— 而 v2rayN 收到 502 会把整个订阅组的节点清空,
    用户看到的就是"组里的东西没了"。磁盘缓存让重启后仍能兜住这一下。
    """
    if not links:
        return
    try:
        os.makedirs(_cache_dir, exist_ok=True)
        tmp = _disk_path(name) + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("\n".join(links))
        os.replace(tmp, _disk_path(name))
    except OSError:
        pass


def _load_disk(name):
    """进程启动后第一次用到某个订阅时，把磁盘缓存读进内存。"""
    try:
        with open(_disk_path(name), encoding="utf-8") as f:
            links = [l.strip() for l in f if l.strip()]
        return links
    except OSError:
        return []
_fetching = {}       # name -> threading.Event


# 订阅来源: 名字 -> 地址文件
#   /sub   -> sub-url      (第 1 条)
#   /sub2  -> sub-url-2    (第 2 条)
# 加新线路只要再放一个 sub-url-N 文件, 不用改代码。
SUB_DIR = os.path.expanduser("~/.v2rayn-tun")


def sub_url_file(name):
    if name == "sub":
        return os.path.join(SUB_DIR, "sub-url")
    return os.path.join(SUB_DIR, f"sub-url-{name[3:]}")


def load_sub_url(name="sub"):
    uf = sub_url_file(name)
    if not os.path.exists(uf):
        raise RuntimeError(f"没有订阅地址文件: {uf}")
    url = open(uf, encoding="utf-8").read().strip()
    if not url.startswith("http"):
        raise RuntimeError(f"订阅地址无效: {url[:40]}...")
    return url


def _do_fetch(name="sub"):
    """真正去拉取并转换。不加锁。"""
    url = load_sub_url(name)
    req = urllib.request.Request(url, headers={"User-Agent": "v2rayN/7.25.4"})
    with urllib.request.urlopen(req, timeout=30) as r:
        text = r.read().decode("utf-8", "replace")
    proxies = parse_proxies(text)
    links = [u for u in (to_uri(p) for p in proxies) if u]
    if not links:
        raise RuntimeError("转换后没有任何节点")
    return links


def _slot(name):
    with _lock:
        if name not in _cache:
            disk = _load_disk(name)
            _cache[name] = {"at": 0.0, "links": disk, "error": None}
            if disk:
                print(f"    [cache] {name}: 从磁盘恢复 {len(disk)} 个节点", file=sys.stderr)
        return _cache[name]


def get_links(name="sub", force=False, block=True):
    """返回 (links, error)。

    name        : 订阅名 ("sub" / "sub2" / ...)
    block=True  : 缓存过期就同步拉取 (会等)
    block=False : 缓存过期就【先返回旧数据】并在后台刷新 (不阻塞 HTTP)
    """
    slot = _slot(name)
    with _lock:
        fresh = (time.time() - slot["at"]) < CACHE_TTL
        if fresh and not force and slot["links"]:
            return list(slot["links"]), slot["error"]
        stale = list(slot["links"])
        err = slot["error"]

    if not block:
        def bg():
            try:
                links = _do_fetch(name)
                with _lock:
                    slot.update(at=time.time(), links=links, error=None)
                    _save_disk(name, links)
            except Exception as e:
                with _lock:
                    slot["error"] = str(e)
        ev = _fetching.setdefault(name, threading.Event())
        if not ev.is_set():
            ev.set()
            def wrap():
                try:
                    bg()
                finally:
                    ev.clear()
            threading.Thread(target=wrap, daemon=True).start()
        return stale, err

    try:
        links = _do_fetch(name)
        with _lock:
            previous = list(slot["links"])
            slot.update(at=time.time(), links=links, error=None)
            _save_disk(name, links)

        # 节点参数变了就记一笔 —— 换端口 / 换 uuid 官方不会通知，
        # 日志里是唯一能看出"什么时候变的"的地方。
        if previous and previous != links:
            print(f"    [change] {name}: {len(previous)} -> {len(links)} 个节点")
        return links, None
    except Exception as e:
        with _lock:
            slot["error"] = str(e)
            if slot["links"]:
                return list(slot["links"]), str(e)
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

        if path in ("/sub", "/subscribe") or re.fullmatch(r"/sub[0-9]+", path):
            name = "sub" if path in ("/sub", "/subscribe") else path[1:]
            # block=True: 缓存过期就等一次真实拉取。宁可慢 1~2 秒,
            # 也不要把过期参数交给 v2rayN —— 它会照着写进节点配置。
            # 拉取失败时 get_links 仍退回上次的好数据, 不会 502。
            links, err = get_links(name=name, block=True)
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

        elif path in ("/refresh",) or re.fullmatch(r"/refresh[0-9]+", path):
            name = "sub" if path == "/refresh" else "sub" + path[len("/refresh"):]
            links, err = get_links(name=name, force=True)
            self._send(json.dumps({"count": len(links), "error": err},
                                  ensure_ascii=False) + "\n",
                       ctype="application/json")

        elif path == "/health":
            # 非阻塞: 健康检查绝不能因为缓存过期而挂住 (会误导成"服务挂了")
            out = {}
            for nm in _cache.keys() | {"sub"}:
                links, err = get_links(name=nm, block=False)
                slot = _slot(nm)
                out[nm] = {
                    "ok": bool(links),
                    "count": len(links),
                    "age": int(time.time() - slot["at"]) if slot["at"] else None,
                    "error": err,
                }
            self._send(json.dumps(out, ensure_ascii=False, indent=2) + "\n",
                       ctype="application/json")

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
        for nm in ("sub", "sub2"):
            if not os.path.exists(sub_url_file(nm)):
                continue
            links, err = get_links(name=nm, force=True, block=True)
            if links:
                print(f"[sub-server] {nm} 就绪: {len(links)} 个节点", flush=True)
            else:
                print(f"[sub-server] ⚠ {nm} 拉取失败: {err}", flush=True)

    threading.Thread(target=warmup, daemon=True).start()

    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
