#!/bin/bash
# 扫描 ~/.ssh/config 里的主机, 把【中国境内】的 IP 加进直连例外。
#
# 为什么需要: SSH 到国内服务器时没有域名可匹配, sing-box 只按 IP 的
# geoip-cn 判定 -> 走日本节点 -> 服务器看到陌生源 IP -> 直接断连,
# 报 "Connection closed by ... port N"。
#
# 用法:
#   ./scripts/ssh-hosts-direct.sh            # 扫描并列出, 问你要不要加
#   ./scripts/ssh-hosts-direct.sh --write    # 直接写进清单
#   ./scripts/ssh-hosts-direct.sh --list     # 只看当前清单
#
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIST="$HOME/.v2rayn-tun/extra-direct-ip.txt"
WRITE=0
[ "${1:-}" = "--write" ] && WRITE=1

mkdir -p "$(dirname "$LIST")"
[ -f "$LIST" ] || cat > "$LIST" <<'EOF'
# 只认国内 IP 的【服务器地址】—— 按 IP/CIDR 放行直连。
# 一行一个 IP 或 CIDR, # 开头是注释。不带掩码的按 /32 处理。
EOF

if [ "${1:-}" = "--list" ]; then
    echo "  当前 IP 例外清单: $LIST"
    grep -v '^#' "$LIST" | grep -v '^$' | sed 's/^/    /' || echo "    (空)"
    exit 0
fi

echo "════════ 扫描 ~/.ssh/config ════════"
python3 - "$WRITE" "$LIST" <<'PY'
import re, os, sys, socket, subprocess, json, ipaddress

WRITE = sys.argv[1] == "1"
LIST = sys.argv[2]
cfg = os.path.expanduser("~/.ssh/config")

blocks, cur = [], None
for line in open(cfg, encoding="utf-8"):
    line = line.split("#")[0].rstrip()
    m = re.match(r'\s*(\w+)\s+(.+)', line)
    if not m: continue
    k, v = m.group(1).lower(), m.group(2).strip()
    if k == "host":
        cur = {"names": v.split(), "hostname": None}
        blocks.append(cur)
    elif cur is not None and k == "hostname":
        cur["hostname"] = v

seen, rows = set(), []
for b in blocks:
    hn = b["hostname"]
    if not hn or any("*" in n for n in b["names"]): continue
    try:
        ip = socket.gethostbyname(hn)
    except Exception:
        continue
    if ip in seen: continue
    seen.add(ip)
    # 私有地址本来就直连, 跳过
    try:
        if ipaddress.ip_address(ip).is_private:
            rows.append((b["names"][0], hn, ip, "内网", False)); continue
    except ValueError:
        pass
    try:
        r = subprocess.run(["curl","-s","--noproxy","*","--max-time","10",
             f"http://ip-api.com/json/{ip}?fields=country,isp"],
             capture_output=True, text=True)
        d = json.loads(r.stdout); country = d.get("country") or "?"
    except Exception:
        country = "?"
    rows.append((b["names"][0], hn, ip, country, country == "China"))

print(f"  {'别名':<16} {'地址':<28} {'IP':<17} 归属")
print("  " + "─" * 78)
need = []
for name, hn, ip, country, is_cn in rows:
    mark = "  ★ 加入" if is_cn else ""
    print(f"  {name:<16} {hn:<28} {ip:<17} {country}{mark}")
    if is_cn: need.append(ip)

if not need:
    print("\n  没有需要加入的中国 IP。"); raise SystemExit

print(f"\n  需要直连的中国 IP: {len(need)} 个")
existing = set()
if os.path.exists(LIST):
    for l in open(LIST, encoding="utf-8"):
        t = l.split("#")[0].strip()
        if t: existing.add(t.split("/")[0])
new = [ip for ip in need if ip not in existing]
print(f"    已在清单里: {len(need) - len(new)}   新增: {len(new)}")
for ip in new: print(f"      + {ip}")

if WRITE and new:
    with open(LIST, "a", encoding="utf-8") as f:
        for ip in new: f.write(ip + "\n")
    print(f"\n  ✓ 已写入 {LIST}")
    print("  生效: sudo ./scripts/per-app-routing.py apply --sub sub2 --cn-node 日本CN2-3")
elif new:
    print("\n  加 --write 可直接写入")
PY
