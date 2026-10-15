#!/usr/bin/env python3
"""
隐身模式 —— 让【所有】流量都走代理, 不再有"国内直连"。

为什么需要
──────────
默认配置里有一组"国内直连"规则:

    [15] direct  rule_set=[geoip-cn]     国内 IP 直连
    [16] direct  rule_set=[geosite-cn]   国内域名直连

它们本意是"国内站点不绕道国外、上网快", 对日常使用是对的。

但它带来一个【IP 泄漏】:

    任何指向国内地址的连接, 都用你的真实 IP 出去。
    最典型的是 WebRTC 的 STUN 查询 —— Bilibili / 小米 / 芒果TV 都提供
    公共 STUN 服务, 网页只要跑一小段 JS 去问它们, 就能拿到你的真实 IP。

实测(2026-10-15):

    命令行直接发 STUN 请求 (完全绕开浏览器):
      stun.chat.bilibili.com  -> 报出 124.117.210.115  (真实中国 IP)  ✗
      stun.hitv.com           -> 报出 124.117.210.115                ✗
      stun.miwifi.com         -> 报出 116.178.106.8                   ✗
      stun.l.google.com       -> 报出 154.17.27.236   (中转服务器)     ✓
      stun.cloudflare.com     -> 报出 66.248.154.224  (住宅出口)       ✓

    因为是在【路由层】泄漏的, 所以:
      · 换指纹浏览器没用
      · 关 WebRTC / 装防泄漏扩展没用
      · 必须在这一层改

除了 STUN, 还有第二个更隐蔽的信号: 国内资源明显更快
    (实测 国内 0.259s vs 国外 0.849s, 差 3.3 倍)
即使没有 WebRTC, 网页加载一张国内域名的图片测一下耗时, 也能推断出你在哪。

隐身模式把这两条一起堵掉: 国内流量也走代理, 速度特征趋同。

代价
────
国内网站会变慢 (要绕一圈到国外再回来)。

所以建议: 平时关着, 需要访问对地区敏感的服务时再打开。
本项目提供一个开关脚本, 不用手工改配置。

用法
────
    ./stealth-mode.py generate            # 输出隐身模式配置到 stdout
    ./stealth-mode.py diff                # 显示会改哪些规则
    ./stealth-mode.py generate -o out.json
"""

import argparse
import collections
import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "config", "sing-box.json")

# ── 隐身模式的规则 ──
#
# 思路: 【白名单式】而不是列举。
# 凡是 direct 规则, 除了下面这几类必须保留的, 其余全部改成 proxy。
# 这样以后新增任何直连例外, 隐身模式都会自动把它也代理掉 —— 不会漏。

# 必须保留 direct 的路由规则特征 (改了会出问题):
KEEP_DIRECT_KEYS = {
    "process_path",     # xray/sing-box 自身的豁免, 改了就路由环路 ✗
    "ip_is_private",    # 局域网地址
    "clash_mode",       # 用户手动选的模式, 尊重它
}
KEEP_DIRECT_RULE_SETS = {"geosite-private"}   # 私有/本地域名


def _must_keep_direct(rule):
    if any(k in rule for k in KEEP_DIRECT_KEYS):
        return True
    rs = rule.get("rule_set") or []
    if set(rs) & KEEP_DIRECT_RULE_SETS:
        return True
    return False


def build_stealth(cfg):
    """返回一份把"直连例外"全部改成走代理的配置 (深拷贝)"""
    out = json.loads(json.dumps(cfg))
    changed = []

    # ── 1. 路由规则 ──
    for i, rule in enumerate(out.get("route", {}).get("rules", [])):
        if rule.get("outbound") != "direct":
            continue
        if _must_keep_direct(rule):
            continue
        desc = rule.get("rule_set") or rule.get("domain_suffix") or rule.get("ip_cidr") or "?"
        rule["outbound"] = "proxy"
        changed.append(f"route.rules[{i}] {str(desc)[:52]} direct -> proxy")

    # ── 2. DNS 规则 ──
    dns = out.get("dns", {})
    for i, rule in enumerate(dns.get("rules", [])):
        if rule.get("server") != "direct-dns-1":
            continue
        # 保留: 手动 Direct 模式 / 私有域名 (远端 DoH 解析不了 .local 这类)
        if rule.get("clash_mode") == "Direct":
            continue
        if set(rule.get("rule_set") or []) & KEEP_DIRECT_RULE_SETS:
            continue
        rule["server"] = "remote-dns-1"
        desc = rule.get("rule_set") or rule.get("domain_suffix") or "?"
        changed.append(f"dns.rules[{i}] {str(desc)[:52]} direct-dns-1 -> remote-dns-1")

    return out, changed


def load():
    if not os.path.exists(SRC):
        sys.exit(f"✗ 找不到配置源文件: {SRC}")
    return json.load(open(SRC, encoding="utf-8"), object_pairs_hook=collections.OrderedDict)


def main():
    ap = argparse.ArgumentParser(description="生成「隐身模式」的 sing-box 配置")
    ap.add_argument("action", choices=["generate", "diff"],
                    help="generate=输出配置; diff=只显示会改哪些规则")
    ap.add_argument("-o", "--output", help="输出文件 (默认 stdout)")
    args = ap.parse_args()

    cfg = load()
    stealth, changed = build_stealth(cfg)

    if args.action == "diff":
        print(f"共 {len(changed)} 处改动:")
        for c in changed:
            print(f"  · {c}")
        print()
        print("原配置里 direct 的规则数:",
              sum(1 for r in cfg["route"]["rules"] if r.get("outbound") == "direct"))
        print("隐身模式里 direct 的规则数:",
              sum(1 for r in stealth["route"]["rules"] if r.get("outbound") == "direct"))
        # 保留的 direct 应当只剩 private / 保留地址
        left = [r for r in stealth["route"]["rules"] if r.get("outbound") == "direct"]
        print()
        print("隐身模式下仍走 direct 的规则 (应当只剩: 自身豁免 / 局域网 / 手动模式):")
        for r in left:
            keys = {k: v for k, v in r.items() if k != "outbound"}
            print(f"  {json.dumps(keys, ensure_ascii=False)[:90]}")
        return

    text = json.dumps(stealth, ensure_ascii=False, indent=2)
    if args.output:
        open(args.output, "w", encoding="utf-8").write(text)
        print(f"✓ 已写入 {args.output}  ({len(changed)} 处改动)", file=sys.stderr)
        for c in changed:
            print(f"    · {c}", file=sys.stderr)
    else:
        print(text)


if __name__ == "__main__":
    main()
