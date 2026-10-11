#!/bin/bash
#
# 比对两台 VPS 的代理相关配置是否一致
#
# 用途: 多台服务器做同样的事情时, 很容易出现「一台改了另一台忘了」。
#       这个脚本把关键项拉平成可对比的形式, 一眼看出差异。
#
#       本脚本的存在本身来自一次教训: 两台服务器的 tcp_bbr 模块持久化
#       都缺失, 但各自单看都"正常"(BBR 正在生效), 只有横向比对才暴露出来。
#
# 用法: ./vps-compare.sh <服务器1> <服务器2> [...]
#   例: ./vps-compare.sh 23.165.40.14 216.167.95.77
#
set -u

[ $# -ge 2 ] || { echo "用法: $0 <服务器1> <服务器2> [...]"; exit 1; }

PROBE=$(mktemp)
trap 'rm -f "$PROBE"' EXIT

cat > "$PROBE" <<'SCRIPT'
echo "os|$(lsb_release -ds 2>/dev/null)"
echo "xray|$(xray version 2>/dev/null | head -1 | awk '{print $2}')"
echo "hysteria|$(hysteria version 2>/dev/null | awk '/^Version/{print $2}' | head -1)"
for k in net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max \
         net.core.wmem_max net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_fastopen \
         net.ipv4.tcp_mtu_probing net.core.somaxconn fs.file-max; do
    echo "sysctl:$k|$(sysctl -n $k 2>/dev/null)"
done
echo "bbr-persist|$([ -f /etc/modules-load.d/proxy-tuning.conf ] && grep -qx tcp_bbr /etc/modules-load.d/proxy-tuning.conf && echo yes || echo NO)"
echo "tuning-file|$([ -f /etc/sysctl.d/99-proxy-tuning.conf ] && echo yes || echo NO)"
python3 - <<'PY'
import json
try:
    d = json.load(open('/usr/local/etc/xray/config.json'))
except Exception as e:
    print(f"xray-config|读取失败 {e}"); raise SystemExit
for i in d.get('inbounds', []):
    st = i.get('streamSettings', {}) or {}
    so = st.get('sockopt', {}) or {}
    print(f"inbound:{i.get('tag')}|port={i.get('port')} sec={st.get('security','-')} "
          f"fastopen={so.get('tcpFastOpen')} nodelay={so.get('tcpNoDelay')} "
          f"ka={so.get('tcpKeepAliveInterval')} cc={so.get('tcpCongestion')}")
    if st.get('security') == 'reality':
        r = st.get('realitySettings', {})
        print(f"  reality:{i.get('tag')}|target={r.get('target') or r.get('dest')} "
              f"fields={','.join(sorted(r.keys()))}")
print(f"routing|{'yes' if d.get('routing') else 'NO'}")
print(f"policy|{'yes' if d.get('policy') else 'NO'}")
print(f"loglevel|{(d.get('log') or {}).get('loglevel')}")
PY
HP=$(grep -oP '(?<=cert: ).*' /etc/hysteria/config.yaml 2>/dev/null | head -1)
echo "hy2-cert|$(openssl x509 -in "$HP" -noout -issuer 2>/dev/null | sed 's/issuer=//' | cut -c1-45)"
echo "hy2-expiry|$(openssl x509 -in "$HP" -noout -enddate 2>/dev/null | cut -d= -f2)"
echo "hy2-obfs|$(grep -A2 '^obfs:' /etc/hysteria/config.yaml 2>/dev/null | awk '/type:/{print $2}' || echo none)"
echo "renew-hooks|$(ls /etc/letsencrypt/renewal-hooks/deploy/ 2>/dev/null | tr '\n' ',' )"
SCRIPT

TMPDIR_C=$(mktemp -d); trap 'rm -f "$PROBE"; rm -rf "$TMPDIR_C"' EXIT
i=0
for host in "$@"; do
    i=$((i+1))
    ssh -o BatchMode=yes -o ConnectTimeout=12 "root@$host" 'bash -s' < "$PROBE" \
        > "$TMPDIR_C/$i.txt" 2>/dev/null || echo "  ⚠ $host 连接失败"
done

# 汇总: 每项一行, 各服务器一列
{
  echo -n "项目"
  for host in "$@"; do echo -n " | $host"; done
  echo
  # 去掉行首缩进后再取键, 否则带缩进的键 (如 reality: 子项) 匹配不上
  sed 's/^[[:space:]]*//' "$TMPDIR_C"/*.txt 2>/dev/null | cut -d'|' -f1 | sort -u | while read -r key; do
      [ -z "$key" ] && continue
      echo -n "$key"
      for n in $(seq 1 $#); do
          v=$(sed -n "s/^[[:space:]]*${key}|//p" "$TMPDIR_C/$n.txt" 2>/dev/null | head -1)
          echo -n " | ${v:-—}"
      done
      echo
  done
} | awk -F' \\| ' '
NR==1 { print; next }
{
    same = 1
    for (i=2; i<=NF; i++) if ($i != $2) same = 0
    mark = same ? "  " : "⚠ "
    printf "%s%s\n", mark, $0
}
'
echo
echo "⚠ 标记的行表示两台不一致, 需要人工判断是否有意为之"
