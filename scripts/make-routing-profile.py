#!/usr/bin/env python3
# 给 v2rayN 造一个自定义路由配置项: 全程走节点, 不做任何国内直连。
#
# 为什么需要它:
#   我们的 TUN (sing-box) 已经在第 1 层把国内方向送去日本节点了, 但第 2 层
#   xray 还带着 v2rayN 的"绕过大陆"(geoip:cn / geosite:cn -> direct)。
#   万一某个 IP 只在 xray 的名单里, 第 1 层会把它交给 proxy, 第 2 层再把它
#   直连出去 —— 真实 IP 就泄漏了。
#
#   把这个路由项选中后, xray 再也没有 direct 的国内规则: 第 1 层漏掉的东西
#   会走节点, 而节点到不了中国 -> 请求失败, 但【不会泄漏真实 IP】。
#   这叫 fail-closed。
#
# 用法:
#   python3 scripts/make-routing-profile.py            # 造出来
#   python3 scripts/make-routing-profile.py --list     # 看现有的
#   python3 scripts/make-routing-profile.py --remove   # 删掉自造的那个
#
# 之后在 v2rayN 的 GUI 里选中它 (设置 -> 路由设置)。

import json, os, sqlite3, sys, time, random

DB = os.path.expanduser("~/Library/Application Support/v2rayN/guiConfigs/guiNDB.db")
NAME = "V4-禁直连(TUN 专用)"
MARK = "自造-by-v2rayn-tun"   # 用来识别是我们造的, 便于删除


def snowflake():
    """v2rayN 的 Id 是雪花 ID (19 位数字), 这里造一个同形状的"""
    return str((int(time.time() * 1000) << 22) | (random.randint(0, 1023) << 12) | random.randint(0, 4095))


def ruleset():
    """规则形状完全参照 v2rayN 内置的「V4-全局(Global)」"""
    return [
        {"Id": snowflake(), "Port": "443", "Network": "udp",
         "OutboundTag": "block", "Enabled": True, "Remarks": "阻断udp443"},
        {"Id": snowflake(), "OutboundTag": "direct", "Ip": ["geoip:private"],
         "Enabled": True, "Remarks": "绕过局域网IP"},
        {"Id": snowflake(), "OutboundTag": "direct", "Domain": ["geosite:private"],
         "Enabled": True, "Remarks": "绕过局域网域名"},
        {"Id": snowflake(), "Port": "0-65535", "OutboundTag": "proxy",
         "Enabled": True, "Remarks": "最终代理(不走国内直连)"},
    ]


def main():
    con = sqlite3.connect(DB)
    row = con.execute("select Id from RoutingItem where Remarks=?", (NAME,)).fetchone()

    if "--list" in sys.argv:
        print("  现有路由配置项:")
        for r in con.execute("select Id, Remarks, RuleNum, Enabled from RoutingItem order by Sort"):
            mine = "  ← 自造" if r[1] == NAME else ""
            print(f"    {r[1]:<28} 规则={r[2]:<3} 启用={r[3]}{mine}")
        return

    if "--remove" in sys.argv:
        if row:
            con.execute("delete from RoutingItem where Id=?", (row[0],))
            con.commit()
            print(f"  ✓ 已删除「{NAME}」")
        else:
            print(f"  (没有找到「{NAME}」)")
        return

    rs = json.dumps(ruleset(), ensure_ascii=False)
    if row:
        con.execute("update RoutingItem set RuleSet=?, RuleNum=? where Id=?",
                    (rs, len(json.loads(rs)), row[0]))
        con.commit()
        print(f"  ✓ 已更新「{NAME}」 (Id={row[0]})")
    else:
        maxsort = con.execute("select coalesce(max(Sort),0) from RoutingItem").fetchone()[0]
        rid = snowflake()
        con.execute(
            "insert into RoutingItem (Id, Remarks, Url, RuleSet, RuleNum, Enabled, "
            "Locked, CustomIcon, CustomRulesetPath4Singbox, DomainStrategy, "
            "DomainStrategy4Singbox, Sort, IsActive) "
            "values (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (rid, NAME, "", rs, len(json.loads(rs)), 1, 0, "", None, "AsIs", None, maxsort + 1, 0))
        con.commit()
        print(f"  ✓ 已创建「{NAME}」 (Id={rid})")

    print()
    print("  规则:")
    for i, r in enumerate(json.loads(rs)):
        tgt = r.get("OutboundTag")
        if "Ip" in r:        k = f"Ip={r['Ip']}"
        elif "Domain" in r:  k = f"Domain={r['Domain']}"
        elif "Port" in r and r["Port"] != "0-65535": k = f"Port={r['Port']} Network={r.get('Network','')}"
        elif r.get("Port") == "0-65535": k = "其余全部 (0-65535)"
        else: k = json.dumps({a: b for a, b in r.items() if a not in ("Id", "OutboundTag", "Enabled", "Remarks")}, ensure_ascii=False)[:60]
        print(f"    [{i}] {tgt:<8} <- {k}    ({r.get('Remarks','')})")
    print()
    print("  接下来: 打开 v2rayN -> 设置 -> 路由设置 -> 选中上面这个名字")


if __name__ == "__main__":
    main()
