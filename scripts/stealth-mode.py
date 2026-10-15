#!/usr/bin/env python3
# 生成「隐身模式」的 sing-box 配置 (所有流量走代理, 取消国内直连)
#
# ⚠️ 2026-10-15 之后的架构下, 这个工具的用途已经变了 ——
#
#   现在默认配置里【已经没有 "国内直连"】了:
#     国内方向 -> cn-via-jp (日本节点)   ← 不是 direct, 也不泄漏
#     例外域名 -> direct                 ← 22 个只认国内 IP 的站点
#
#   所以:
#     · 它不再需要用来"堵国内直连" —— 那是 cn-via-jp 干的事
#     · 它现在唯一的用途是"连那 22 个例外也不许直连"(极端严格场景)
#       —— 代价是微信发不出图片、教育网和政务站打不开
#     · 它【不会】动 cn-via-jp, 那是另一条出站, 不是 direct
#
#   想恢复标准的"少数直连 + 国内走日本 + 国外走住宅":
#     ./scripts/setup-routing.sh --cn-node 日本CN2-3
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


# 只认国内 IP、经境外节点必然失败的域名。隐身模式默认【保留】它们的直连,
# 否则微信发不出图片、教育网和政务站打不开。要连它们也一起代理, 用 --strict。
KEEP_DIRECT_DOMAINS = [
    "qq.com", "weixin.qq.com", "qpic.cn", "qlogo.cn", "gtimg.cn",
    "tencent.com", "myqcloud.com", "wechatpay.cn",
    "edu.cn", "ac.cn", "chsi.com.cn", "gov.cn", "gov.hk",
]


def _is_domestic_only(rule):
    """这条规则是不是"只认国内 IP"的例外域名"""
    ds = rule.get("domain_suffix") or []
    if not isinstance(ds, list):
        return False
    return any(d == k or d.endswith("." + k) for d in ds for k in KEEP_DIRECT_DOMAINS)


def _must_keep_direct(rule, strict=False):
    # 路由环路 / 局域网 / 本地域名 —— 无论如何都要保留
    if any(k in rule for k in KEEP_DIRECT_KEYS):
        return True
    if set(rule.get("rule_set") or []) & KEEP_DIRECT_RULE_SETS:
        return True
    # "只认国内 IP"的例外: 默认保留, --strict 时连它们也代理
    if not strict and _is_domestic_only(rule):
        return True
    return False


def build_stealth(cfg, strict=False):
    """返回一份把"直连例外"全部改成走代理的配置 (深拷贝)"""
    out = json.loads(json.dumps(cfg))
    changed = []

    # ── 1. 路由规则 ──
    for i, rule in enumerate(out.get("route", {}).get("rules", [])):
        if rule.get("outbound") != "direct":
            continue
        if _must_keep_direct(rule, strict):
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
    ap.add_argument("--strict", action="store_true",
                    help="连「只认国内 IP」的例外域名(微信/教育/政务)也一起走代理。"
                         "默认保留它们, 否则微信发不出图片")
    args = ap.parse_args()

    cfg = load()
    stealth, changed = build_stealth(cfg, strict=args.strict)

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
        print("隐身模式下仍走 direct 的规则:")
        for r in left:
            if _is_domestic_only(r):
                print(f"  ★ 例外域名 ({len(r['domain_suffix'])} 个) —— 默认保留,"
                      f" 加 --strict 可连它们也代理 (但微信会发不出图片)")
            else:
                keys = {k: v for k, v in r.items() if k != "outbound"}
                print(f"  保留 {json.dumps(keys, ensure_ascii=False)[:88]}")
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
