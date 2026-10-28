#!/bin/bash
# 把【所有已知节点的 IP】从 TUN 的覆盖路由里排除，并加一条"目标节点 -> direct"规则。
#
# 为什么必须做（这是个会反复踩的坑）:
#
#   sing-box 的 auto_route 会加 1/8、2/7 … 128/1 这些覆盖路由，把【一切】
#   流量指向 utun。于是：
#
#       xray 连节点 -> 被覆盖路由抓进 TUN -> sing-box 收到
#         -> 匹配"目标=节点 -> direct" -> direct 出站【又去连节点】
#         -> 再次被抓进 TUN -> ... 无限环
#
#   症状：请求约 3.00 秒固定超时、成功率只有 20-40%、到节点堆积几十个僵死连接。
#
#   给 direct 出站加 bind_interface: en0 在 macOS 上【不生效】，必须在路由层排除。
#
# 为什么要把数据库里【所有】节点的 IP 都排除，而不是只排当前那个:
#
#   在 v2rayN 里换节点时，新节点 IP 如果没有被排除，环路立刻回来。
#   实测踩过：只排了 154.17.29.33，切到 154.17.27.236 后成功率立刻掉回 30%。
#
# 用法:
#   sudo ./scripts/fix-loop.sh          # 修复并重启
#   ./scripts/fix-loop.sh --check       # 只看现状
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE=/usr/local/libexec/v2rayn-tun/config.json

if [ "${1:-}" = "--check" ]; then
    /usr/bin/python3 - "$LIVE" <<'PY'
import json, sys, subprocess
d = json.load(open(sys.argv[1], encoding='utf-8'))
t = d['inbounds'][0]
excl = t.get('route_exclude_address') or []
print(f"  TUN route_exclude_address: {len(excl)} 条")
for x in excl: print(f"    {x}")
bad = 0
for x in excl:
    ip = x.split('/')[0]
    out = subprocess.run(['route','-n','get',ip], capture_output=True, text=True).stdout
    if 'utun' in out:
        print(f"  ✗ {ip} 仍然走 utun -> 环路会回来"); bad += 1
if bad == 0:
    print("  ✓ 全部走物理网卡，没有环路")
PY
    exit 0
fi

if [ "$(id -u)" != "0" ]; then
    echo "需要 sudo: sudo $0"; exit 1
fi

/usr/bin/python3 - "$LIVE" <<'PY'
import json, collections, shutil, subprocess, os, sys, datetime, sqlite3, pwd
LIVE = sys.argv[1]
home = pwd.getpwuid(int(os.environ.get('SUDO_UID', 0))).pw_dir if os.environ.get('SUDO_UID') else os.path.expanduser('~')
stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
shutil.copy2(LIVE, f"{LIVE}.bak-loop-{stamp}")

d = json.load(open(LIVE, encoding='utf-8'), object_pairs_hook=collections.OrderedDict)

ips = set()
# 1. v2rayN 数据库里所有节点
try:
    con = sqlite3.connect(f"file:{home}/Library/Application Support/v2rayN/guiConfigs/guiNDB.db?mode=ro", uri=True)
    for (addr,) in con.execute("select distinct Address from ProfileItem"):
        if addr and addr.replace('.', '').isdigit():
            ips.add(addr + '/32')
except Exception as e:
    print(f"  读 v2rayN 数据库失败: {e}", file=sys.stderr)
# 2. sing-box 出站里的节点
for o in d['outbounds']:
    if o.get('type') == 'vless' and o.get('server'):
        s = o['server']
        if s.replace('.', '').isdigit():
            ips.add(s + '/32')

ips = sorted(ips)
if not ips:
    print("  ✗ 没找到任何节点 IP"); raise SystemExit(1)

t = d['inbounds'][0]
old = set(t.get('route_exclude_address') or [])
t['route_exclude_address'] = ips
added = sorted(set(ips) - old)
print(f"  排除 {len(ips)} 个节点 IP" + (f"（新增 {len(added)} 个: {added}）" if added else "（无变化）"))

rules = d['route']['rules']
rules[:] = [r for r in rules if not (r.get('outbound') == 'direct' and r.get('ip_cidr') == ips)]
pos = next((i for i, r in enumerate(rules) if r.get('action') == 'hijack-dns'), len(rules))
rules.insert(pos, collections.OrderedDict([("outbound", "direct"), ("ip_cidr", ips)]))
print(f"  rules[{pos}] = 目标任一节点 -> direct")

tmp = LIVE + '.new'
json.dump(d, open(tmp, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
os.chmod(tmp, 0o644); subprocess.run(['chown', 'root:wheel', tmp])
r = subprocess.run(['/usr/local/libexec/v2rayn-tun/sing-box', 'check', '-c', tmp], capture_output=True, text=True)
if r.returncode:
    os.unlink(tmp); print("  ✗ 校验失败:", r.stderr[:300]); raise SystemExit(1)
os.replace(tmp, LIVE)
print("  ✓ 校验通过, 已落盘")
subprocess.run(['launchctl', 'kickstart', '-k', 'system/com.local.v2rayn-tun'])
print("  ✓ 守护已重启")
PY
sleep 6

echo
echo "════════ 验证 ════════"
/usr/bin/python3 - "$LIVE" <<'PY'
import json, sys, subprocess
d = json.load(open(sys.argv[1], encoding='utf-8'))
excl = d['inbounds'][0].get('route_exclude_address') or []
bad = [x for x in excl if 'utun' in subprocess.run(['route','-n','get',x.split('/')[0]],
        capture_output=True, text=True).stdout]
print(f"  排除 {len(excl)} 条, 其中仍走 utun 的: {len(bad)}")
if bad: print(f"  ✗ {bad}")
else:   print("  ✓ 全部走物理网卡")
PY
