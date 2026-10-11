---
name: deploy-us-proxy
description: Turn a Linux VPS (typically US-based) into a working proxy server running VLESS + XTLS-Vision + REALITY and Hysteria2, then emit v2rayN-importable share links for both. Covers host probing, REALITY dest selection and validation, key generation, a Hysteria2 node with a real Let's Encrypt certificate, hardened systemd services, BBR/kernel tuning, end-to-end verification, and failure diagnosis. Use when the user asks to 搭建/部署/刷 Xray 或 Hysteria2 节点, set up a VLESS REALITY node, turn a VPS into a proxy, produce 链接/订阅 for v2rayN, or debug a REALITY/Hysteria2 node that will not connect. Do not use for client-side v2rayN GUI operations or routing rules, Clash/sing-box-only configuration, Shadowsocks-only setups, or macOS transparent-proxy setup (use macos-tun-no-proxy for that).
---

# 在 Linux VPS 上部署 REALITY + Hysteria2 并交付链接

在一台 Linux VPS 上同时部署两条互补的链路，交付可直接导入 v2rayN 的分享链接。

**为什么是这两条**：它们应对不同的失效场景，互为备份。

| 链路 | 协议 | 何时用 |
|---|---|---|
| Hysteria2 | QUIC/UDP | **首选**。延迟显著更低（实测 0.21s vs 1.2s），因为不存在 TCP-in-TCP |
| REALITY + Vision | TCP/TLS | UDP 被限制、或需要更强的抗封锁伪装时 |

**TCP-in-TCP 是跨国代理的隐形税**：REALITY 与 WebSocket 都是在 TCP 隧道里再跑 TCP，
外层丢一个包，内层 TCP 就停顿退避，两层退避叠加，延迟抖动剧烈。
Hysteria2 在 QUIC 上跑，多流无队头阻塞，叠加 `brutal` 拥塞控制（按固定速率发送、
不理会丢包），在丢包链路上优势被放大。**所以不要只部署 TCP 系节点。**

## 不适用

- 客户端侧配置（v2rayN 界面操作、路由规则、分流）。本 Skill 只交付链接。
- macOS 上的透明代理 / TUN 模式 —— 用 `macos-tun-no-proxy`。
- 需要 CDN 中转的传输（WebSocket+TLS、gRPC）。它们比 REALITY 慢，只在必须过 CDN 时考虑。
- 已有面板（x-ui、3x-ui、Marzban）的机器 —— 用面板自身的增删逻辑，不要覆盖它的配置。

## 执行位置

- **就是本机**：直接跑脚本。
- **远程主机**：用持久会话（`tmux`/`ssh -t`）执行，不要用一次性 `ssh host "cmd"` 串联多步，中间状态会丢。
- 从国内机器操作境外服务器时，**SSH 加 `-o BindInterface=en0`**（macOS）绕过本机 TUN，
  否则 SSH 流量会被自己的代理绕一圈，且消耗节点流量。

## 硬约束

1. **不要自己跑需要密码的 `sudo`。** 先测 `sudo -n true`。免密就直接装；需要密码就把完整命令交给用户执行。
2. **不要跳过 `xray run -test`。** Xray 会对危险的 dest 直接告警（apple/icloud 系可能导致服务器 IP 被封），这是选 dest 的权威判据。
3. **`realitySettings` 的字段名是 `target`，不是 `dest`。** 旧名会被**静默忽略** ——
   不报错、不警告，`xray run -test` 照样输出 `Configuration OK`，但握手必然失败。
   从旧配置备份还原参数时尤其容易踩。**验证方法**：把字段集与一台可用节点对比：
   ```bash
   python3 -c "
   import json; d=json.load(open('/usr/local/etc/xray/config.json'))
   for i in d['inbounds']:
       st=i.get('streamSettings',{})
       if st.get('security')=='reality': print(sorted(st['realitySettings'].keys()))"
   # 可用节点: ['privateKey','serverNames','shortIds','show','target','xver']
   # 出现 'dest' 就是中招了
   ```
4. **target 必须实测，不能只看探测表的表面条件。** 实测中 `www.microsoft.com`
   握手失败而 `www.intel.com` 立即通过 —— 两者都是 Akamai、都支持 TLS1.3、都有 AAAA，
   表面条件完全相同。**做法：先用一台已知可用节点的 target 跑通，再换。**
5. **Hysteria2 必须用公开 CA 签发的证书。** Cloudflare Origin 证书只有 Cloudflare 信任，
   直连客户端只能 `insecure`，而新版 Xray **拒绝加载** insecure 节点。这是死路，不是调优问题。
6. **交付前必须实测。** 只看 `systemctl is-active` 不够，必须跑通一次真实握手。
7. **私钥不出服务器。** 客户端链接里只放公钥。不要把私钥回显给用户或写进文档。
8. **分享链接内含 UUID / auth，等于账号凭证。** 交付时明确说明不能公开分发。

## 工作流

### 1. 探测主机

```bash
whoami; id -u; uname -m; cat /etc/os-release | head -3
systemctl list-units --type=service | grep -iE 'xray|hysteria|sing-box'
ss -tlnp; ss -ulnp
curl -s -4 https://api.ipify.org; echo
sysctl net.ipv4.tcp_congestion_control
sysctl -n net.ipv4.tcp_available_congestion_control
```

需要确认：架构、是否已有代理在跑、**端口占用**（Reality 用 TCP 443、Hysteria2 用 UDP 443，
两者不冲突）、公网 IPv4、机房位置、BBR 状态。

已有 Xray 在跑时先问清楚是覆盖还是新增节点，不要直接改现有配置。

### 2. 选 REALITY target

```bash
scripts/probe_dest.sh                      # 用内置候选表
scripts/probe_dest.sh www.intel.com ...    # 或指定候选
```

检查 TLS 1.3 + X25519 + HTTP/2 ALPN，按延迟排序，对已知风险域名打标。

优先级：必须三项齐全 → 无风险标记 → 从**服务器**看延迟最低 → SNI 在客户端所在地区看起来合理。

**探测表只是初筛**，选定后必须经第 3 步的 `xray run -test` 复核，并做一次真实握手（硬约束 4）。
延迟差 50ms 以内按稳定性选，不必死抠最低值。

详见 [references/dest-selection.md](references/dest-selection.md)。

### 3. 生成 REALITY 配置

```bash
scripts/setup_reality.sh --dest www.intel.com --remark "US-Reality"
```

生成 UUID / x25519 密钥对 / shortId，渲染服务端配置，跑 `xray run -test`，
输出 `params.env` 与 `share-link.txt`。

**保持 443 端口。** Xray 对非 443 端口会告警 `Listening on non-443 ports may get your IP
blocked by the GFW` —— REALITY 的伪装前提就是流量看起来像访问 443 上的正常 HTTPS 站点。
只有 443 已被占用且无法腾出时才改，并向用户说明代价。

### 4. 部署 Hysteria2

```bash
sudo bash scripts/setup_hy2.sh --domain hy.example.com --salamander <随机密码> --remark "US-Hy2"
```

脚本负责：前提检查 → certbot 签发 Let's Encrypt 证书 → 安装续期钩子 →
装二进制与独立 `hysteria` 系统用户 → 写配置 → 装 systemd unit → 自检 → 输出链接。

**前提条件**（脚本会检查，不满足则明确报错）：

1. 域名**直接解析到本机**（不是 Cloudflare 橙色云）。橙色云会让 HTTP-01 验证失败。
2. **TCP 80 空闲且从公网可达** —— Let's Encrypt 的验证服务器需要访问它。

> ⚠️ **测 80 端口可达性要用境外机器。** 从国内测试机测出的结果不能代表
> Let's Encrypt 验证服务器能否访问。这是签发失败最常见的原因。

**必须验证续期链路**（脚本已内置，但交付前确认一次）：

```bash
certbot renew --dry-run
```

没有续期钩子的话，90 天后证书到期，服务会**静默失效** —— 没有任何告警。

详见 [references/hysteria2.md](references/hysteria2.md)。

### 5. 安装 REALITY 服务

需要 root，按硬约束 1 处理提权：

```bash
sudo bash scripts/install_service.sh --workdir ./xray-build
```

装二进制、配置（模式 600）、独立 `xray` 系统用户、用
`CAP_NET_BIND_SERVICE` 绑定 443 而非以 root 运行、开 BBR + fq 与 TCP 缓冲调优、
ufw 处于 active 时放行端口。

已存在配置会带时间戳备份，不会静默覆盖。

> **BBR 是模块，默认可能没加载。** `tcp_available_congestion_control` 里没有 `bbr`
> **不等于**内核不支持 —— 先 `modprobe tcp_bbr` 再判断。
> 且**持久化必须与「当前是否已加载」解耦**：只把 `echo tcp_bbr > /etc/modules-load.d/...`
> 写在「未加载」分支里的写法，在模块已加载时永远不会执行，重启后 BBR 丢失且
> sysctl 静默失败。详见 [references/troubleshooting.md](references/troubleshooting.md)。

### 6. 端到端验证

```bash
scripts/verify_reality.sh --workdir ./xray-build
```

在服务器本机起临时客户端连自己的服务端，验证握手与吞吐，结束自动清理。

判读要点：

- **在服务器本机跑时，经代理的出口 IP 必然等于服务器 IP** —— 这不能证明转发正确。
  真正的判据是：握手成功 + 吞吐接近直连 + 服务端日志出现 `accepted` 记录。
- 代理开销正常在 5% 以内。开销明显偏大先查 CPU 有无 AES-NI（`grep -o aes /proc/cpuinfo | head -1`）。
- **本机验证不覆盖公网可达性**，交付时必须说明，并给出排查顺序：
  VPS 面板安全组 → 云厂商网络 ACL → 主机 ufw/iptables。

**Hysteria2 还要从客户端实测**（UDP 是否被限制只有真实客户端能证明）。

### 7. 交付

给出两条链接、参数对照表，以及：

- 已验证什么、未验证什么（尤其是公网可达性、UDP 可用性）。
- **推荐顺序**：Hysteria2 首选（低延迟），REALITY 备用（UDP 受限时）。
- 客户端版本要求：v2rayN 6.x 以上才支持 `xtls-rprx-vision` + REALITY，旧版导入会丢参数。
- 凭证安全提示。
- 运维命令：配置 `/usr/local/etc/xray/config.json`、`/etc/hysteria/config.yaml`；
  重启 `systemctl restart xray|hysteria-server`；日志 `journalctl -u <unit> -f`。

## 多机一致性

多台服务器做同样的事情时，很容易「一台改了另一台忘了」。横向比对：

```bash
scripts/vps-compare.sh <server1> <server2> ...
```

比对项：xray/hysteria 版本、sysctl 关键值、BBR 模块持久化、
各入站的 sockopt 与 reality 字段、routing/policy、证书与续期钩子。差异行标 ⚠。

**这个脚本的存在本身来自一次教训**：两台服务器的 `tcp_bbr` 持久化都缺失，
但单看每台都「正常」（BBR 正在生效），只有横向比对才暴露。

## 成功标准

1. `systemctl is-active xray hysteria-server` 均为 `active`，`ss -tlnp` / `ss -ulnp` 显示端口由它们监听。
2. `xray run -test` 无告警通过。
3. REALITY 握手成功、吞吐损耗在合理范围；**Hysteria2 从客户端实测连通**。
4. `certbot renew --dry-run` 成功。
5. 服务已 `systemctl enable`，重启后自动拉起。
6. 用户拿到两条链接，且已被告知公网可达性 / UDP 可用性未在本机验证。

## 故障判断

| 现象 | 首查方向 |
|---|---|
| 客户端连不上，服务端日志无任何记录 | 流量没到主机：VPS 面板安全组 → 云 ACL → ufw，顺序不要颠倒 |
| **日志有 `accepted` 但客户端超时** | **`realitySettings` 里出现了 `dest` 而非 `target`** —— 旧名被静默忽略（硬约束 3） |
| 客户端报 REALITY 握手失败 | target 换一个**实测可用**的（硬约束 4），不要只信探测表 |
| 服务端日志 `REALITY: processed invalid connection ... handshake did not complete successfully` | 同客户端报错的两面：握手参数不匹配，优先查 target |
| 客户端 `failed to find an available destination > common/retry: [EOF]` | 服务端在 TCP 连上后立刻关闭 → 握手失败，不是网络问题 |
| Hysteria2 客户端被核心拒绝加载 | 节点 `insecure` + 无证书。换公开 CA 证书（硬约束 5） |
| Hysteria2 完全连不上、服务端无日志 | UDP 被限制，或服务端证书不可信。先确认不是 Cloudflare Origin 证书 |
| 能连但速度慢 / 忽高忽低 | `brutal` 速率设得远高于实际链路会撑爆队列。降低 `brutalUp/Down` |
| 时通时断 | 服务器 IP 可能已被针对性阻断，换 IP 比换 target 有效 |

更多见 [references/troubleshooting.md](references/troubleshooting.md)。

## 环境注意

- 脚本在 zsh 下也会被 `bash` 执行，但**手工敲带 `?` 的 URL 必须加引号**，
  否则 zsh 会当通配符报 `no matches found`。
- `curl -w` 与 `--max-time` 组合时超时会返回部分字段，判读前先确认退出码。
- macOS 无 `/usr/bin/timeout`；用命令自带的超时选项（如 `ssh -o ConnectTimeout`）。
