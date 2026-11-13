#!/bin/bash
# 查当前出口：Claude 的流量到底从哪出去。
#
# 用它的场景：装了 EasyConnect / 其他 VPN 之后，确认没有把外网流量
# 抢到校园出口上去（那会让 Claude 看到学校 IP）。
#
# 判定标准:
#   ✓ 出口是住宅/运营商宽带 -> 正常
#   ✗ 出口是校园网 / 机房 / 未知 -> 有问题
set -uo pipefail

echo "════════ 1. 网卡 ════════"
for i in 0 1 2 3 4 5 6 7 8 9; do
    a=$(ifconfig utun$i 2>/dev/null | grep "inet " | awk '{print $2}')
    [ -n "$a" ] && printf "  utun%-2s %s\n" "$i" "$a"
done
printf "  en0    %s\n" "$(ipconfig getifaddr en0 2>/dev/null)"

echo
echo "════════ 2. 关键目标走哪个接口 ════════"
printf "  %-22s %-10s %s\n" "目标" "接口" "说明"
for pair in \
    "1.1.1.1:外网" \
    "160.79.104.10:anthropic" \
    "10.109.68.1:校园网关" \
    "192.168.99.1:NASS" ; do
    ip=${pair%%:*}; label=${pair##*:}
    iface=$(route -n get "$ip" 2>/dev/null | awk '/interface:/{print $2}')
    printf "  %-22s %-10s %s\n" "$ip" "${iface:-?}" "$label"
done

echo
echo "════════ 3. Claude 出口 IP ════════"
IP=$(curl -s --noproxy '*' --max-time 15 https://ipinfo.io/ip 2>/dev/null || echo "")
if [ -z "$IP" ]; then
    echo "  ✗ 取不到出口 IP（可能代理断了）"
else
    echo "  出口: $IP"
    INFO=$(curl -s --noproxy '*' --max-time 15 "https://ipinfo.io/$IP/json" 2>/dev/null)
    echo "$INFO" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(f\"  组织: {d.get('org','?')}\")
    print(f\"  位置: {d.get('city','?')}, {d.get('region','?')}, {d.get('country','?')}\")
except Exception:
    print('  (归属查询失败)')
" 2>/dev/null
    # 判定
    if echo "$INFO" | grep -qiE '"country": *"CN"'; then
        echo
        echo "  ★★★ 出口在中国 —— 有问题 ✗ ★★★"
        echo "      大概率是 VPN 把外网流量抢走了，Claude 会看到国内 IP"
    else
        echo
        echo "  ✓ 出口在境外，正常"
    fi
fi

echo
echo "════════ 4. 代理链路健康 ════════"
for u in "https://claude.ai|claude.ai" "https://api.anthropic.com|api.anthropic" "https://www.google.com/generate_204|google"; do
    url=${u%%|*}; name=${u##*|}
    code=$(curl -s -o /dev/null -A 'Mozilla/5.0' --noproxy '*' --max-time 15 -w '%{http_code}' "$url" 2>/dev/null)
    printf "  %-16s HTTP %s\n" "$name" "$code"
done

echo
echo "════════ 5. 有没有别的 VPN 在插路由 ════════"
sudo -n netstat -rn -f inet 2>/dev/null | awk '$1=="default" || $1=="0.0.0.0/1" || $1=="128.0.0.0/1" {printf "  %-16s %-16s %s\n", $1, $2, $NF}' 2>/dev/null \
    || netstat -rn -f inet 2>/dev/null | awk '$1=="default" || $1=="0.0.0.0/1" || $1=="128.0.0.0/1" {printf "  %-16s %-16s %s\n", $1, $2, $NF}'
echo "  （出现 0.0.0.0/1 或 128.0.0.0/1 说明有 VPN 在抢默认路由）"
