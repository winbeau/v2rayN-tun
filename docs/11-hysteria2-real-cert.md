# 11 · 修复 Hysteria2 节点（换真实证书）

> **一句话**：QUIC 无法躲在 CDN 后面；TCP-in-TCP 是隐形税。

**现象**：`selab-hy2` 节点无法连接，v2rayN 日志报：

```
selab-hy2: The current node uses an unencrypted connection...
For security reasons, nodes of this type cannot connect via Xray-core versions 26.2.6 or higher.
Insecure configuration detected: AllowInsecure is enabled but no certificate is provided.
```

**换网络、换协议、换端口都无用** —— 这是客户端主动拒绝加载该节点。

---

## 根因：服务端用的是 Cloudflare Origin 证书

```
issuer = CloudFlare Origin SSL Certificate Authority
subject = CN = CloudFlare Origin Certificate
SAN: DNS:*.example.net
```

**Cloudflare Origin 证书只有 Cloudflare 自己信任。** 直连源站的客户端无法验证它，只能：

| 做法 | 结果 |
|---|---|
| 正常校验 | 证书链不受信任，连接失败 |
| `AllowInsecure` 跳过校验 | 新版 Xray **拒绝加载**（上面那条日志） |

**死路。必须给服务端换一张公开受信任的证书。**

---

## 为什么不能像 WS 那条一样走 Cloudflare

Cloudflare 的代理只处理 HTTP/HTTPS（TCP）。**Hysteria2 是 QUIC/UDP**，Cloudflare 普通代理不转发任意 UDP。

所以 WS+TLS 那条可以躲在 Cloudflare 后面用 Origin 证书，**Hysteria2 不行** —— 它必须直连，
因此必须有自己的真证书。

---

## 解法：Let's Encrypt（HTTP-01）

### 前提检查（这步决定方案可行性）

```bash
# 1. 域名必须解析到源站, 不能是 Cloudflare 橙色云
dig +short A hy.example.net
#   198.51.100.10   ✓ 直连源站

# 2. 80 端口必须空闲且从公网可达 (Let's Encrypt 的验证服务器要能访问)
#    从一台境外机器验证最可靠 —— 我的测试机在国内, 测不出境外可达性
ssh root@<另一台境外服务器> 'curl -s -o /dev/null -w "%{time_connect}\n" http://<源站IP>/'
#   0.000954s  ✓ TCP 可达 (HTTP 000 是正常的, 裸 nc 监听不回响应)
```

### 签发

```bash
apt-get install -y certbot
certbot certonly --standalone -d hy.example.net \
  --non-interactive --agree-tos --register-unsafely-without-email \
  --preferred-challenges http
```

### 让 hysteria 用上（关键：权限）

`/etc/letsencrypt/live/` 下是 root-only，而 hysteria 以 `hysteria` 用户运行，**读不到**。
用续期部署钩子同步一份：

```bash
cat > /etc/letsencrypt/renewal-hooks/deploy/hysteria-reload.sh <<'SH'
#!/bin/bash
set -e
install -o hysteria -g hysteria -m 644 /etc/letsencrypt/live/hy.example.net/fullchain.pem /etc/hysteria/tls.crt
install -o hysteria -g hysteria -m 600 /etc/letsencrypt/live/hy.example.net/privkey.pem  /etc/hysteria/tls.key
systemctl restart hysteria-server
SH
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/hysteria-reload.sh
```

再改 `/etc/hysteria/config.yaml`：

```yaml
tls:
  cert: /etc/hysteria/tls.crt     # 原为 origin.crt
  key:  /etc/hysteria/tls.key     # 原为 origin.key
```

### 验证续期链路

```bash
certbot renew --dry-run
#   Congratulations, all simulated renewals succeeded
```

**一定要跑这一步** —— 否则 90 天后证书到期，服务会静默挂掉。
（钩子里已 `systemctl restart hysteria-server`，无需手工干预。）

### 客户端

关闭节点的 `AllowInsecure`（服务端证书已可信，不再需要跳过校验）：

```bash
sqlite3 ~/Library/Application\ Support/v2rayN/guiConfigs/guiNDB.db \
  "update ProfileItem set AllowInsecure=NULL where Remarks='selab-hy2';"
```

生成的客户端配置应当**不含** `allowInsecure`：

```json
{ "protocol": "hysteria",
  "settings": { "address": "hy.example.net", "port": 443, "version": 2 },
  "streamSettings": { "security": "tls",
    "tlsSettings": { "serverName": "hy.example.net" },
    "hysteriaSettings": { "version": 2, "auth": "..." } } }
```

---

## 意外收获：Hysteria2 明显快于 TCP 系协议

修好之后实测，延迟差距非常大：

| 指标 | Hysteria2 | Reality (TCP) | WS+Cloudflare |
|---|---|---|---|
| **google TLS** | **0.21s** | 1.19-1.22s | 1.01-1.29s |
| **github TLS** | **0.32-0.58s** | 1.27-2.02s | 1.33-1.62s |
| GitHub 下载 (均值) | 2.36 MB/s | ~2.25 MB/s | ~2.17 MB/s |
| GitHub 下载 (峰值) | **4.52 MB/s** | 2.38 MB/s | 2.32 MB/s |

延迟 **快 5-6 倍**，且 10 次采样里 8 次稳定在 0.21s。

### 为什么差这么多：TCP-in-TCP

- **Reality / WS 都是「TCP 隧道里跑 TCP」**。外层 TCP 丢一个包，内层 TCP 就停顿并触发退避，
  **两层退避叠加** → 跨国丢包链路上延迟抖动剧烈、吞吐塌陷。
- **Hysteria2 是「QUIC/UDP 隧道里跑 TCP」**。QUIC 的多流没有队头阻塞，丢包只影响那一条流。

再叠加 Hysteria2 的 **`brutal` 拥塞控制**（按固定速率发送、不理会丢包），在丢包链路上优势进一步放大。

### 吞吐波动是正常的

实测 1.50 ~ 4.52 MB/s，波动明显。原因是 `brutal` 按固定速率发送，而客户端默认设的是
**100 mbps**（v2rayN 硬编码，配置里没有暴露），远高于实际链路（约 2-4 MB/s）。
**速率设得过高会撑爆链路队列导致丢包**，表现为吞吐忽高忽低。

> 如果后续要压榨吞吐，可考虑把 `brutalDown` 调到接近实际链路带宽（约 30-40 mbps）。
> 但 v2rayN 没有暴露该参数，需要手改生成的核心配置或换客户端。

---

## 结论

**Hysteria2 现在是综合最优的节点**（延迟 5-6 倍优势、吞吐持平或更好），
Reality 保留作为备用（Hysteria2 依赖 UDP，个别网络可能限制 UDP）。

| 节点 | 协议 | 定位 |
|---|---|---|
| `selab-hy2` | Hysteria2 / QUIC | **首选** —— 低延迟 |
| `selab-reality` | VLESS+Reality+Vision | 备用 —— UDP 受限时用 |
| `selab-ws-HK` | VLESS+WS+TLS (Cloudflare) | 兜底 —— 源站 IP 被封时用 |

---

## 教训

1. **"节点不可用"要先分清楚是网络问题还是客户端拒绝加载** —— 后者换什么都没用，日志里写得很清楚。
2. **证书的信任链是硬约束** —— Cloudflare Origin 证书只在 Cloudflare 后面有意义，直连场景必须换真证书。
3. **HTTPS 能靠 CDN 前置，QUIC 不能** —— 这决定了两种协议的证书策略必须分开设计。
4. **签完证书必须验证续期链路**（`certbot renew --dry-run`），否则 90 天后静默失效。
5. **测境外可达性要用境外机器** —— 国内测试机的结果不能代表 Let's Encrypt 验证服务器能否访问。
6. **TCP-in-TCP 是跨国代理的隐形税** —— 同样的线路，换成 QUIC 承载能差 5 倍延迟。
