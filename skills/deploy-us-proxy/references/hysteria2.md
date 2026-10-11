# Hysteria2 部署要点

## 为什么 Hysteria2 值得单独部署

实测同一台服务器、同一客户端（中美链路）：

| 指标 | Hysteria2 | REALITY (TCP) | WS + Cloudflare |
|---|---|---|---|
| google TLS | **0.21s** | 1.19-1.22s | 1.01-1.29s |
| github TLS | **0.32-0.58s** | 1.27-2.02s | 1.33-1.62s |
| 下载均值 | 2.36 MB/s | ~2.25 MB/s | ~2.17 MB/s |
| 下载峰值 | **4.52 MB/s** | 2.38 MB/s | 2.32 MB/s |

延迟差 5-6 倍，且 10 次采样里 8 次稳定在 0.21s。

**原因是 TCP-in-TCP**：REALITY / WebSocket 都在 TCP 隧道里再跑 TCP，外层丢包会让内层停顿退避，
两层叠加。Hysteria2 跑在 QUIC 上，多流无队头阻塞。再叠加 `brutal` 拥塞控制
（按固定速率发送、不理会丢包），在丢包链路上优势被放大。

---

## 证书是硬约束，不是可选项

Hysteria2 走 **QUIC/UDP**，而 Cloudflare 的代理只转发 TCP(HTTP/HTTPS)。
所以：

- WS + TLS 那条**可以**躲在 Cloudflare 后面用 **Cloudflare Origin 证书**
  （因为验证证书的是 Cloudflare，不是客户端）
- **Hysteria2 不行** —— 它必须直连，验证证书的是客户端，必须是**公开 CA 签发**的证书

用 Origin 证书的后果是一条死路：

```
issuer = CloudFlare Origin SSL Certificate Authority
```

客户端无法验证 → 只能 `insecure` 跳过校验 → 新版 Xray **拒绝加载**：

```
The current node uses an unencrypted connection...
For security reasons, nodes of this type cannot connect via Xray-core versions
26.2.6 or higher. Insecure configuration detected: AllowInsecure is enabled but
no certificate is provided.
```

**换网络、换端口、换协议都无用**，因为这是客户端在加载阶段就拒绝了。

---

## 签发前提

```bash
# 1. 域名必须直接解析到本机 (不能是 Cloudflare 橙色云)
dig +short A hy.example.com
#   203.0.113.10   ✓ 直连源站

# 2. TCP 80 必须空闲
ss -tln | grep ':80 '
```

### 测 80 端口可达性必须用境外机器 ⚠️

Let's Encrypt 的验证服务器在境外。**从国内测试机测出的结果不能代表它能否访问。**

```bash
# 从另一台境外服务器验证
ssh root@<另一台境外机器> 'curl -s -o /dev/null -w "%{time_connect}\n" http://<源站IP>/'
#   0.000954s   ✓ TCP 可达
```

（`HTTP 000` 是正常的 —— 裸 `nc` 监听不会回 HTTP 响应，只要 TCP 连上就说明可达。）

**这是签发失败最常见的原因**，且报错信息通常不会直接说是网络问题。

---

## 证书权限：必须复制，不能直接引用

`/etc/letsencrypt/live/` 下是 root-only，而 hysteria 以 `hysteria` 用户运行，**读不到**。
所以必须用续期钩子复制一份并重设属主：

```bash
cat > /etc/letsencrypt/renewal-hooks/deploy/hysteria-reload.sh <<'SH'
#!/bin/bash
set -e
install -o hysteria -g hysteria -m 644 /etc/letsencrypt/live/<域名>/fullchain.pem /etc/hysteria/tls.crt
install -o hysteria -g hysteria -m 600 /etc/letsencrypt/live/<域名>/privkey.pem  /etc/hysteria/tls.key
systemctl restart hysteria-server
SH
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/hysteria-reload.sh
```

配置里指向复制后的路径：

```yaml
tls:
  cert: /etc/hysteria/tls.crt
  key:  /etc/hysteria/tls.key
```

### 必须验证续期链路

```bash
certbot renew --dry-run
```

**没有这一步，90 天后证书到期，服务会静默失效** —— 没有告警，只是突然连不上。

---

## salamander 混淆

```yaml
obfs:
  type: salamander
  salamander:
    password: <随机字符串>
```

作用是给 QUIC 包加一层混淆，降低被识别为 Hysteria 流量的概率。
**客户端必须配置相同的密码**，否则完全连不上（服务端不会报错，客户端表现为超时）。

链接里对应 `&obfs=salamander&obfs-password=<密码>`。

> 排查时如果客户端一直连不上而服务端无日志，先核对这个密码。
> 它容易被漏掉，因为它不影响 TLS 层，报错也不指向它。

---

## `brutal` 拥塞控制与吞吐波动

客户端默认 `brutalUp` / `brutalDown` 常被设为 **100 mbps**（v2rayN 硬编码，界面不暴露）。

`brutal` 的策略是**按固定速率发送、不理会丢包**。设得远高于实际链路
（实测链路只有约 16-32 Mbps）会**撑爆链路队列导致丢包**，表现为吞吐忽高忽低：

```
实测 8 次: 1.50 / 3.92 / 2.69 / 2.15 / 1.79 / 2.83 / 2.60 / 2.04 MB/s
```

这是**预期行为而非故障**。若要压榨吞吐，把 `brutalUp`/`brutalDown` 调到接近实际链路带宽
（约 30-40 mbps），但 v2rayN 未暴露该参数，需手改生成的核心配置或换客户端。

---

## UDP 的固有风险

Hysteria2 依赖 UDP。**部分网络会限制或封锁 UDP**（企业网、部分校园网、某些移动网络）。

所以：

- **不要只部署 Hysteria2**，同时保留一条 TCP 系节点作为回落。
- 「服务端自检通过」**不能**证明 UDP 从客户端可达 —— 只有真实客户端能证明。
- 客户端连不上且服务端零日志时，**先怀疑 UDP 被限制**，再查配置。

---

## 交付检查清单

- [ ] 证书签发者是公开 CA（`openssl x509 -noout -issuer` 不含 Cloudflare）
- [ ] `certbot renew --dry-run` 通过
- [ ] 续期钩子存在且会重启服务
- [ ] `/etc/hysteria/` 属主是 `hysteria`
- [ ] 客户端 `insecure` 已关闭（生成的配置里无 `allowInsecure` / `insecure=1`）
- [ ] salamander 密码两端一致
- [ ] 分享链接里 `sni` 与证书域名一致
