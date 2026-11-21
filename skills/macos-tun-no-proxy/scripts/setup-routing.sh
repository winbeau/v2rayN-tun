#!/bin/bash
# 初始分流：国内直接出站，国外走 GUI 选中的节点。
#
# 用法:
#   sudo ./scripts/setup-routing.sh                       # 用默认值
#   sudo ./scripts/setup-routing.sh --sub sub2 --cn-node 日本CN2-3
#        ./scripts/setup-routing.sh --check               # 只看现状, 不改
#
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUB="sub2"
CN_NODE="direct"

while [ $# -gt 0 ]; do
    case "$1" in
        --sub)      SUB="$2"; shift 2 ;;
        --cn-node)  CN_NODE="$2"; shift 2 ;;
        --check)    CHECK=1; shift ;;
        -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
        *)          echo "未知参数: $1"; exit 1 ;;
    esac
done

echo "════════ 现状检查 ════════"
CFG=/usr/local/libexec/v2rayn-tun/config.json
if [ -f "$CFG" ]; then
    python3 - "$CFG" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception as e:
    print(f"  读不到配置: {e}"); raise SystemExit
tags = [o.get('tag') for o in d.get('outbounds', [])]
print(f"  出站: {tags}")
for rule in d['route']['rules']:
    if set(rule.get('rule_set') or []) & {'geoip-cn', 'geosite-cn'}:
        print(f"  国内分流 {rule['rule_set']} → {rule.get('outbound')}")
print(f"  进程豁免(node-direct): {'✓ 已配' if 'node-direct' in tags else '✗ 未配'}")
ex = [r for r in d['route']['rules'] if r.get('outbound')=='direct' and r.get('domain_suffix') and 'qq.com' in str(r.get('domain_suffix'))]
print(f"  直连例外({len(ex[0]['domain_suffix']) if ex else 0} 个域名): {'✓ 已配' if ex else '✗ 未配'}")
PY
fi
python3 "$REPO/scripts/make-routing-profile.py" --list 2>/dev/null | sed 's/^/  v2rayN /'

[ -n "${CHECK:-}" ] && exit 0

echo
echo "════════ 1. 造 v2rayN 路由项 ════════"
python3 "$REPO/scripts/make-routing-profile.py"

echo
echo "════════ 2. 应用 sing-box 路由（国内出站：$CN_NODE） ════════"
cd "$REPO"
./scripts/per-app-routing.py apply --sub "$SUB" --cn-node "$CN_NODE"
RC=$?

echo
if [ $RC -eq 0 ]; then
    cat <<'EOF'
════════ 还差最后一步（必须手工）════════

  打开 v2rayN -> 设置 -> 路由设置
  选中：V4-禁直连(TUN 专用)

  不选的话第 2 层 xray 还会带着"绕过大陆"的国内直连规则。

  选完验证:
    ./scripts/setup-routing.sh --check
EOF
else
    echo "⚠️ 应用失败, 线上配置未改动 (脚本是先校验后落盘)"
fi
