#!/bin/bash
# 诊断"某个国内网站打不开 / 浏览器报不安全"是不是因为国内方向走了日本节点。
#
# 判断逻辑:
#   经 TUN (走日本) 失败  +  直连成功   -> 属于"只认国内 IP", 应加进直连例外
#   两条都不通                          -> 是别的问题(站点挂了/DNS)
#   两条都通                            -> 不是路由问题
#
# 用法:
#   ./scripts/check-site.sh gitcode.com www.gitcode.com
#   ./scripts/check-site.sh --sub sub2 --cn-node 日本CN2-3 example.edu.cn
#
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUB=sub2; CN_NODE="日本CN2-3"
HOSTS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --sub)     SUB="$2"; shift 2 ;;
        --cn-node) CN_NODE="$2"; shift 2 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *)         HOSTS+=("$1"); shift ;;
    esac
done
[ ${#HOSTS[@]} -eq 0 ] && { sed -n '2,14p' "$0"; exit 1; }

echo "════════ 逐个网站对比：经 TUN（走日本） vs 直连 ════════"
printf "  %-26s %-22s %-22s %s\n" "域名" "经 TUN(日本)" "直连(en0)" "结论"
printf "  %s\n" "────────────────────────────────────────────────────────────────────────────"

VERDICT=()
for h in "${HOSTS[@]}"; do
    # 经 TUN
    a=$(curl -s -o /dev/null --noproxy '*' --max-time 15 \
        -w '%{http_code}/%{time_total}s' "https://$h" 2>/dev/null || echo "000/-")
    # 直连
    b=$(curl -s -o /dev/null --interface en0 --max-time 15 \
        -w '%{http_code}/%{time_total}s' "https://$h" 2>/dev/null || echo "000/-")
    # a/b 形如 "200/1.23s"; 取状态码时先掐掉时间部分, 否则会粘在一起
    ac=$(echo "$a" | cut -d/ -f1 | tr -dc '0-9')
    bc=$(echo "$b" | cut -d/ -f1 | tr -dc '0-9')
    [ -z "$ac" ] && ac=000
    [ -z "$bc" ] && bc=000
    if [ "$ac" = "000" ] && [ "$bc" != "000" ]; then
        v="★ 只认国内 IP -> 建议加例外"; VERDICT+=("$h")
    elif [ "$ac" = "000" ] && [ "$bc" = "000" ]; then
        v="两条都不通（站点问题或 DNS）"
    elif [ "$ac" != "000" ]; then
        v="正常（不是路由问题）"
    else
        v="?"
    fi
    printf "  %-26s %-20s %-20s %s\n" "$h" "$a" "$b" "$v"
done

echo
if [ ${#VERDICT[@]} -eq 0 ]; then
    echo "  没有需要加例外的域名。"
    exit 0
fi

echo "════════ 建议加进直连例外的域名 ════════"
for h in "${VERDICT[@]}"; do echo "    $h"; done
cat <<EOF

  改法（改之前先自己判断一下：这个站是不是"中国的机构/服务"）:

    脚本里有两处要同步加:
      · 根域名 -> scripts/per-app-routing.py 的 wx_domains
        （写根域名即可，子域自动匹配，例如加 gitcode.com 就覆盖 www/api）
      · 第 2 层 xray 不需要动 —— 它已经全程走节点

    改完执行:
      sudo ./scripts/per-app-routing.py apply --sub $SUB --cn-node $CN_NODE

  ⚠️ 不要图省事加 com.cn / org.cn 之类的大范围后缀 ——
     那会把大量商业站点也放回直连，"国内走日本"就白做了。
EOF
