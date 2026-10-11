# 09 · VPS 服务端调优与 Cloudflare 优选 IP

对象：两台自建节点服务器
- `216.167.95.77` — VLESS+Reality:443（XTLS-Vision）/ VLESS+WS:8443 / VMess:2053 / Hysteria2:443
- `23.165.40.14` — VLESS+WS:443 / Hysteria2:443，域名 `hk.selab.top` 走 Cloudflare

---

## 一、内核网络调优

脚本：[`scripts/vps-tune.sh`](../scripts/vps-tune.sh)（幂等，可重复执行）

### 为什么需要

跨国链路普遍有丢包。Linux 默认的 `cubic` 在丢包时会把拥塞窗口砍半，吞吐断崖式下跌；
BBR 基于带宽与时延估计，在 1%~5% 丢包下仍能跑满。

| 参数 | 默认 | 调优后 | 作用 |
|---|---|---|---|
| `tcp_congestion_control` | cubic | **bbr** | 抗丢包 |
| `default_qdisc` | fq_codel | **fq** | BBR 推荐搭配 |
| `rmem_max` / `wmem_max` | 212992 | **33554432** | 高 BDP 链路需要大窗口 |
| `tcp_rmem` / `tcp_wmem` 上限 | 6MB / 4MB | **32MB** | 同上 |
| `tcp_slow_start_after_idle` | 1 | **0** | 见下 |
| `tcp_fastopen` | 1 | **3** | 省一次往返 |
| `tcp_mtu_probing` | 0 | **2** | 隧道链路 MTU 不一致 |
| `somaxconn` / `max_syn_backlog` | 4096 | **8192** | 连接队列 |
| `fs.file-max` | 系统默认 | **1000000** | 代理是 fd 密集型 |

**`tcp_slow_start_after_idle=0` 对代理尤其重要**：代理连接常在空闲后被复用，
默认值会让它每次从最小窗口重新慢启动 —— 表现为**"闲置一会儿后第一个请求特别慢"**。

### 坑：BBR 是模块，默认可能没加载 ⚠️

`23.165.40.14` 上 `sysctl -n net.ipv4.tcp_available_congestion_control` 只返回 `reno cubic`。

**第一反应是"内核不支持"，但这是错的** —— 模块文件明明存在：

```bash
find /lib/modules/$(uname -r) -name "tcp_bbr*"
#   /lib/modules/6.8.0-134-generic/kernel/net/ipv4/tcp_bbr.ko.zst

modprobe tcp_bbr                  # 加载后即可用
sysctl -n net.ipv4.tcp_available_congestion_control
#   reno cubic bbr
```

**关键**：加载是一次性的，重启就没了。必须持久化，否则重启后
`sysctl` 里写 `tcp_congestion_control=bbr` 会**静默失败**（保持 cubic）：

```bash
echo "tcp_bbr" > /etc/modules-load.d/proxy-tuning.conf
```

脚本已内置这一步。

### 实测收益

调优后 GitHub 下载 **2.02-2.32 MB/s**，对比调优前基线 1.97-2.24 MB/s —— **基本持平**。

原因：当前链路带宽本身只有 ~2 MB/s，BBR 主要在**丢包或高带宽**场景发力。
**这是"买了保险"而非立竿见影**，不要在低带宽下期待明显提升。

### 回滚

```bash
rm -f /etc/sysctl.d/99-proxy-tuning.conf
rm -f /etc/modules-load.d/proxy-tuning.conf
sysctl --system      # 或直接重启
```

脚本运行时会自动备份到 `/root/sysctl-backup-<时间戳>/`。

---

## 二、Cloudflare 优选 IP（本次故障的解法）

### 故障现象

代理完全不可用（HTTP 000），但服务器本身正常 —— 其他客户端在用、xray 日志正常、
服务器出网正常。

### 根因：节点域名解析到的 Cloudflare IP 从国内不可达

```
本地 xray → 162.159.130.203:443 (Cloudflare)   ESTABLISHED
sing-box → dial tcp 162.159.81.198:443: i/o timeout (30s)
```

`hk.selab.top` 解析出 162.159.81.198 / 141.82 / 130.203 —— **这几个国内连不上**。
Cloudflare 在国内是**间歇性可达**的，所以同一配置会时好时坏。

### 为什么不能绕过 Cloudflare 直连源站

服务端用的是 **Cloudflare Origin 证书**：

```
subject = O="CloudFlare, Inc.", OU="CloudFlare Origin CA", CN="CloudFlare Origin Certificate"
SAN: DNS:*.selab.top
```

**Origin 证书只有 Cloudflare 自己信任**，公开客户端不认。所以架构必须是
`客户端 → Cloudflare → 源站`，不能改直连（除非改用 `allowInsecure`，而新版 xray 已拒绝该配置）。

### 解法：优选 IP

Cloudflare 是 anycast + 按 SNI 路由，因此**任何 Cloudflare IP + 正确 SNI 都能到达你的 zone**。

⚠️ **必须用配置里的真实 SNI**。本例 SNI 是 `proxy.selab.top`（不是节点名里的 `hk.selab.top`），
用错 SNI 扫出来的结果不可信。

```bash
# 扫描可用 IP（务必 --interface en0 绕过本机 TUN）
for ip in 104.16.0.1 104.18.0.1 104.26.0.1 162.159.0.1 ...; do
  curl -sk -o /dev/null --interface en0 --max-time 6 \
    --resolve proxy.selab.top:443:$ip \
    -w "$ip  TCP %{time_connect}s / TLS %{time_appconnect}s / HTTP %{http_code}\n" \
    https://proxy.selab.top/
done
```

本次结果：21 个候选里 13 个可用，**`104.18.0.1` 最快（TLS 0.174s）**。

判读：**TLS 成功即已到达你的 zone**；HTTP 403/404 是 Cloudflare 拒绝无正确路径的请求，属正常。

### 应用

在 v2rayN 里把节点的**地址**改成优选 IP，**SNI 保持域名不变**：

```bash
sqlite3 ~/Library/Application\ Support/v2rayN/guiConfigs/guiNDB.db \
  "update ProfileItem set Address='104.18.0.1' where Remarks='selab-ws-HK';"
```

改前先退出 v2rayN（否则运行时会被覆盖）并备份 DB。生成的核心配置应形如：

```json
{ "settings": { "address": "104.18.0.1", "port": 443 },
  "streamSettings": { "network": "ws", "security": "tls",
    "tlsSettings": { "serverName": "proxy.selab.top" },
    "wsSettings": { "path": "/ccd1igv2", "host": "proxy.selab.top" } } }
```

**地址是 IP、serverName 是域名** —— 这是优选 IP 的标准形态。

> ⚠️ 优选 IP 会**随封锁变化**，需要定期重扫。本次是手工扫描，
> 后续可考虑做成定时任务自动挑选。

---

## 三、勘察中发现的其他问题

| 发现 | 说明 |
|---|---|
| `selab-hy2` 节点不可用 | 未加密 + `AllowInsecure`，**新版 xray 拒绝加载**（日志有明确提示）。换网络换协议都无用，建议弃用或让服务商升级 |
| 节点名与实际出口不符 | `selab-ws-HK` 出口 IP `23.165.40.14` 归属**洛杉矶**，不是香港 |
| 多节点同源 | `hy.selab.top` 与 `hk.selab.top` 的后端都是 `23.165.40.14`；旧的一对 LA 节点共用 `216.167.95.77` |
| `216.167.95.77` 实为可用 | 一度出现 "TCP 通 / TLS 零响应"，实测是**暂时性故障**，现已恢复（Reality 握手 TLS 1.67s、HTTP 301）。它有 Reality+XTLS-Vision，比 Cloudflare+WS 更快且不依赖 Cloudflare，适合作备用节点 |
| 流量异常偏大 | `216.167.95.77` 五天累计 RX 217G / TX 289G。个人代理这个量偏大，但当前只有 2 条连接，未见滥用迹象 —— 若与实际使用量不符，值得排查 |

---

## 教训

1. **`tcp_available_congestion_control` 里没有 bbr ≠ 内核不支持** —— 先 `modprobe`，再判断。
2. **模块加载必须持久化**，否则 sysctl 会静默失败（不报错，就是不生效）。
3. **代理故障要分层**：本地配置 → 网络路径 → 服务端。用 `--interface en0` 一次就能划清界限。
4. **CDN 前置的节点，故障点可能在 CDN 而不是你的服务器** —— 服务器一切正常，客户端却连不上。
5. **改生产配置前备份**，并且注意"运行时修改会被覆盖"（v2rayN 退出时会重写配置）。
