#!/usr/bin/env python3
"""
逐个测试节点是否真的能通 —— 用独立 xray 实例, 不干扰 v2rayN。

为什么需要
──────────
"服务器 TCP/TLS 可达" 和 "节点能用" 是两回事:
  · 机场的中转服务器可能通, 但它背后的出口坏了 -> 照样不能用
  · 在 v2rayN 里逐个切换节点测试很慢 (每次要重启 xray + 等 TUN)
  · 而且切换过程中你的正常上网会断

本脚本给每个节点起一个临时 xray, 测完就关, 全程不动 v2rayN。

用法
────
  ./test-nodes.py                      # 测订阅里的所有节点 (从本地订阅服务拉)
  ./test-nodes.py --from-v2rayn        # 测 v2rayN 数据库里的所有节点
  ./test-nodes.py --grep 住宅          # 只测名字含某串的
  ./test-nodes.py --timeout 12         # 每个节点超时秒数

原理
────
  1. 生成一份最小 xray 配置 (socks 入站 + 单节点出站)
  2. 起 xray, 监听一个临时端口
  3. 经它请求 https://www.google.com/generate_204
  4. 记录结果, 杀掉 xray

判断标准
────────
  204       节点完全可用 (Google 的 generate_204 返回 204 是标准成功响应)
  403/其他  能连出去, 但被目标站挡了 (通常是 Cloudflare 的机器人检查)
  000       不通 —— 节点坏的
"""

import argparse
import json
import os
import re
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import base64

XRAY = os.path.expanduser("~/Library/Application Support/v2rayN/bin/xray/xray")
SUBSERVER = "http://127.0.0.1:18080/links"
V2RAYN_DB = os.path.expanduser("~/Library/Application Support/v2rayN/guiConfigs/guiNDB.db")
V2RAYN_CFG = os.path.expanduser("~/Library/Application Support/v2rayN/guiConfigs/guiNConfig.json")

TEST_URL = "https://www.google.com/generate_204"


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


# ─────────────── 取节点列表 ───────────────

def nodes_from_subserver():
    with urllib.request.urlopen(SUBSERVER, timeout=15) as r:
        return [l.strip() for l in r.read().decode().splitlines() if l.strip().startswith("vless://")]


def nodes_from_v2rayn():
    """把 v2rayN 数据库里的节点转回 vless:// 链接"""
    con = sqlite3.connect(V2RAYN_DB)
    cols = [r[1] for r in con.execute("pragma table_info(ProfileItem)")]
    out = []
    for row in con.execute(f"select {','.join(cols)} from ProfileItem"):
        p = dict(zip(cols, row))
        if not p.get("Address"):
            continue
        proto = "vless"
        q = {
            "encryption": "none",
            "type": "tcp" if (p.get("Network") or "raw") == "raw" else (p.get("Network") or "tcp"),
            "security": p.get("StreamSecurity") or "none",
            "sni": p.get("Sni") or "",
            "fp": p.get("Fingerprint") or "",
        }
        if q["security"] == "reality":
            q["pbk"] = p.get("PublicKey") or ""
            q["sid"] = p.get("ShortId") or ""
        flow = ""
        try:
            flow = json.loads(p.get("ProtoExtra") or "{}").get("Flow", "")
        except Exception:
            pass
        if flow:
            q["flow"] = flow
        qs = urllib.parse.urlencode({k: v for k, v in q.items() if v})
        name = urllib.parse.quote(p.get("Remarks") or p["Address"])
        out.append(f"{proto}://{p.get('Password','')}@{p['Address']}:{p.get('Port') or 443}?{qs}#{name}")
    con.close()
    return out


# ─────────────── 单个节点测试 ───────────────

def build_config(link, port):
    u = urllib.parse.urlparse(link)
    qs = dict(urllib.parse.parse_qsl(u.query))
    net = qs.get("type", "tcp")
    sec = qs.get("security", "none")

    stream = {"network": net, "security": sec}
    if sec == "reality":
        stream["realitySettings"] = {
            "serverName": qs.get("sni", ""),
            "fingerprint": qs.get("fp", "chrome"),
            "publicKey": qs.get("pbk", ""),
            "shortId": qs.get("sid", ""),
        }
    elif sec == "tls":
        stream["tlsSettings"] = {
            "serverName": qs.get("sni", ""),
            "allowInsecure": False,
            "fingerprint": qs.get("fp", "chrome"),
        }
    if net == "ws":
        stream["wsSettings"] = {"path": qs.get("path", "/"), "headers": {"Host": qs.get("host", "")}}
    if net == "grpc":
        stream["grpcSettings"] = {"serviceName": qs.get("serviceName", "")}

    user = {"id": u.username or "", "encryption": qs.get("encryption", "none")}
    if qs.get("flow"):
        user["flow"] = qs["flow"]

    return {
        "log": {"loglevel": "error"},
        "inbounds": [{
            "tag": "in", "listen": "127.0.0.1", "port": port,
            "protocol": "socks", "settings": {"auth": "noauth", "udp": False},
        }],
        "outbounds": [{
            "tag": "out", "protocol": "vless",
            "settings": {"vnext": [{
                "address": u.hostname, "port": u.port or 443, "users": [user],
            }]},
            "streamSettings": stream,
        }],
    }


def test_node(link, timeout=12):
    """返回 (状态, 耗时, 说明)"""
    name = urllib.parse.unquote(urllib.parse.urlparse(link).fragment)
    port = free_port()
    cfg = build_config(link, port)
    fd, path = tempfile.mkstemp(suffix=".json", prefix="node-test-")
    with os.fdopen(fd, "w") as f:
        json.dump(cfg, f)

    proc = None
    try:
        proc = subprocess.Popen([XRAY, "run", "-c", path],
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        # 等端口就绪
        deadline = time.time() + 4
        ready = False
        while time.time() < deadline:
            if proc.poll() is not None:
                break
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.3).close()
                ready = True
                break
            except OSError:
                time.sleep(0.15)
        if proc.poll() is not None:
            return name, "启动失败", 0, "xray 未起来"
        if not ready:
            return name, "启动超时", 0, "端口未就绪"

        proxy = f"socks5h://127.0.0.1:{port}"
        opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
        t0 = time.time()
        try:
            with opener.open(TEST_URL, timeout=timeout) as r:
                code = r.status
            dt = time.time() - t0
            if code == 204:
                return name, "✓ 可用", dt, f"HTTP {code}"
            return name, f"△ HTTP {code}", dt, "能连出去但被目标挡"
        except urllib.error.HTTPError as e:
            dt = time.time() - t0
            return name, f"△ HTTP {e.code}", dt, "能连出去但被目标挡"
        except Exception as e:
            dt = time.time() - t0
            return name, "✗ 不通", dt, type(e).__name__
    finally:
        if proc and proc.poll() is None:
            proc.send_signal(signal.SIGKILL)
            try:
                proc.wait(timeout=3)
            except Exception:
                pass
        try:
            os.unlink(path)
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser(description="逐个测试节点是否真的能通")
    ap.add_argument("--from-v2rayn", action="store_true",
                    help="测 v2rayN 数据库里的节点 (默认测本地订阅服务里的)")
    ap.add_argument("--grep", help="只测名字含该串的节点")
    ap.add_argument("--timeout", type=int, default=12, help="单节点超时秒数")
    ap.add_argument("--sort", action="store_true", help="按耗时排序输出")
    args = ap.parse_args()

    if not os.path.exists(XRAY):
        sys.exit(f"✗ 找不到 xray: {XRAY}")

    src = "v2rayN 数据库" if args.from_v2rayn else "本地订阅服务"
    try:
        links = nodes_from_v2rayn() if args.from_v2rayn else nodes_from_subserver()
    except Exception as e:
        sys.exit(f"✗ 取节点失败 ({src}): {e}")

    if args.grep:
        links = [l for l in links
                 if args.grep in urllib.parse.unquote(urllib.parse.urlparse(l).fragment)]
    if not links:
        sys.exit("✗ 没有节点可测")

    print(f"测试来源: {src}   共 {len(links)} 个节点   单节点超时 {args.timeout}s")
    print()
    print(f"  {'节点':<34} {'结果':<12} {'耗时':>8}  说明")
    print("  " + "─" * 74)

    results = []
    for link in links:
        name, status, dt, note = test_node(link, args.timeout)
        results.append((name, status, dt, note))
        print(f"  {name[:32]:<34} {status:<12} {dt:>7.2f}s  {note}", flush=True)

    ok = [r for r in results if r[1] == "✓ 可用"]
    print()
    print(f"  可用: {len(ok)}/{len(results)}")
    if ok:
        best = min(ok, key=lambda r: r[2])
        print(f"  最快: {best[0]}  ({best[2]:.2f}s)")
    print()
    if args.sort:
        for name, status, dt, note in sorted(results, key=lambda r: r[2]):
            print(f"  {dt:>7.2f}s  {status:<12} {name}")


if __name__ == "__main__":
    main()
