#!/bin/bash
#
# VPS 代理性能调优 (内核网络栈)
#
# 目标: 跨国链路通常有丢包 + 高 RTT, 默认的 cubic + 小缓冲会严重限制吞吐。
#
# 安全性: sysctl 修改不会中断已有连接, 只影响新建连接。
#         全部写入 /etc/sysctl.d/, 可随时删除该文件并 reboot 回滚。
#
set -e

BACKUP=/root/sysctl-backup-$(date +%Y%m%d-%H%M%S)
CONF=/etc/sysctl.d/99-proxy-tuning.conf

echo "=== 0. 环境检查 ==="
echo "  内核: $(uname -r)"
echo "  可用拥塞控制: $(sysctl -n net.ipv4.tcp_available_congestion_control)"

# BBR 在 Ubuntu 上是模块 (tcp_bbr), 默认不一定加载 —— 必须先加载并持久化,
# 否则 sysctl 写入 tcp_congestion_control=bbr 会静默失败 (保持 cubic)。
if ! sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
    echo "  BBR 未加载, 尝试载入模块..."
    modprobe tcp_bbr 2>/dev/null || true
    if sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
        echo "  ✓ 模块加载成功"
        echo "tcp_bbr" > /etc/modules-load.d/proxy-tuning.conf
        echo "  ✓ 已写入 /etc/modules-load.d/proxy-tuning.conf (重启后自动加载)"
    else
        echo "  ✗ 内核确实不支持 BBR (模块缺失), 终止"; exit 1
    fi
fi
echo "  ✓ BBR 可用"
echo "  最终可用列表: $(sysctl -n net.ipv4.tcp_available_congestion_control)"

echo
echo "=== 1. 备份现有配置 ==="
mkdir -p "$BACKUP"
for f in /etc/sysctl.conf /etc/sysctl.d/*.conf; do
    [ -f "$f" ] && cp -a "$f" "$BACKUP/" 2>/dev/null || true
done
sysctl -a > "$BACKUP/sysctl-current.txt" 2>/dev/null || true
echo "  备份至: $BACKUP"
echo "  回滚命令: rm -f $CONF && sysctl --system   (或直接重启)"

echo
echo "=== 2. 记录修改前的关键值 ==="
for k in net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max \
         net.core.wmem_max net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_fastopen; do
    printf "  %-38s %s\n" "$k" "$(sysctl -n $k 2>/dev/null)"
done

echo
echo "=== 3. 写入调优配置 ==="
cat > "$CONF" <<'EOF'
# 代理服务器网络调优
# 由 v2rayN-tun 项目生成; 删除本文件并执行 sysctl --system 即可回滚

# ---- 拥塞控制: BBR ----
# cubic 在丢包时会把窗口砍半, 跨国链路一旦丢包吞吐断崖式下跌。
# BBR 基于带宽与时延估计, 在 1%~5% 丢包下仍能跑满。
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ---- 套接字缓冲上限 ----
# 高 BDP 链路 (如 中国<->美西, RTT 150ms+ 且带宽 100Mbps+)
# 需要大窗口才能跑满: BDP = 100Mbps * 0.15s ≈ 1.9MB, 缓冲要留足余量。
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# ---- 代理场景专项 ----
# 代理连接常在空闲后被复用, 默认的 slow_start_after_idle=1 会让它
# 每次从最小窗口重新慢启动, 表现为"闲置一会儿后第一个请求特别慢"。
net.ipv4.tcp_slow_start_after_idle = 0
# 3 = 客户端与服务端都启用 TFO, 省掉一次往返
net.ipv4.tcp_fastopen = 3
# 路径 MTU 探测: 隧道/中转链路常因 MTU 不一致导致大包被丢
net.ipv4.tcp_mtu_probing = 2

# ---- 连接队列 ----
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# ---- keepalive: 及时清理死连接, 释放 fd ----
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# ---- 文件句柄 (代理是 fd 密集型) ----
fs.file-max = 1000000
EOF
echo "  已写入 $CONF"

echo
echo "=== 4. 应用 ==="
sysctl --system >/dev/null 2>&1
echo "  已应用"

echo
echo "=== 5. 验证 ==="
printf "  %-38s %s\n" "拥塞控制" "$(sysctl -n net.ipv4.tcp_congestion_control)"
printf "  %-38s %s\n" "qdisc" "$(sysctl -n net.core.default_qdisc)"
printf "  %-38s %s\n" "rmem_max" "$(sysctl -n net.core.rmem_max)"
printf "  %-38s %s\n" "tcp_rmem" "$(sysctl -n net.ipv4.tcp_rmem)"
printf "  %-38s %s\n" "slow_start_after_idle" "$(sysctl -n net.ipv4.tcp_slow_start_after_idle)"
printf "  %-38s %s\n" "fastopen" "$(sysctl -n net.ipv4.tcp_fastopen)"
printf "  %-38s %s\n" "mtu_probing" "$(sysctl -n net.ipv4.tcp_mtu_probing)"
printf "  %-38s %s\n" "somaxconn" "$(sysctl -n net.core.somaxconn)"
printf "  %-38s %s\n" "file-max" "$(sysctl -n fs.file-max)"

echo
echo "=== 6. 服务状态确认 ==="
for s in xray hysteria-server; do
    printf "  %-20s %s\n" "$s" "$(systemctl is-active $s 2>/dev/null)"
done
echo
echo "TUNING_DONE"
