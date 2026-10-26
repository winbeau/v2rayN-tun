# 00 · 整体架构

> **一句话**：v2rayN 只当"节点管理器"，`sing-box` 接管系统流量，本机零系统代理、零环境变量；开关就是 v2rayN 本身的启停。

## 数据流

```
                         ┌──────────────────────────────────────┐
  例外域名                │                                      │
  (微信/教育/政务 22个) ──┤                                      │──→ direct ──→ 真实网络
                         │                                      │
  其他国内方向 ──────────┤        sing-box (root LaunchDaemon)  │──→ cn-via-jp ─→ 直连(当前)
  (geoip-cn/geosite-cn)  │        TUN: utun*  172.19.0.1        │                (可换成任意节点)
                         │        stack=system  auto_route       │
  国外方向 ──────────────┤        mtu=1500 (可调)                │──→ proxy ──→ 127.0.0.1:10808
  (含 AdsPower 例外进程)  │                                      │              └→ xray ─→ 住宅节点
                         └──────────────────────────────────────┘                          66.248.154.224
```

**三条出路**：

| 目标 | 出站 | 出口 IP | 说明 |
|---|---|---|---|
| 例外域名（22 个）| `direct` | 你的真实 IP | 只认国内 IP 的站点，见下 |
| 其他国内方向 | `cn-via-jp` | 直连或任意节点¹ | 当前设为 `direct`；换节点用 switch-cn-node.py |
| 国外方向 | `proxy` → xray → 节点 | `66.248.154.224` 住宅 | Claude 用的就是这条 |

¹ **`cn-via-jp` 只是出站的标签名** —— 它现在是 `type: direct`（不连任何节点），
也可以换成任意节点，标签保持不变，因为它被所有国内路由规则引用着。

```bash
# 国内直连（当前）
sudo ./scripts/switch-cn-node.py apply --node direct
# 换成某个节点
sudo ./scripts/switch-cn-node.py apply --node selab-reality
```

详见 [19 路由实施记录](19-routing-implementation.md)。

**⚠️ 节点参数会被官方静默更改**（实测：住宅节点端口从 `443` 改成 `4561`），
表现为"TCP 通但代理连不上"。排查见 [20](20-node-params-changed.md)。

**豁免进程**（`SunBrowser` 系列）额外有一条：国外目标走 `node-direct`
（vless 直连住宅节点，绕开 xray）—— 因为 xray 看不到"连接来自哪个进程"，
会按自己的路由把国内目标直连。详见 [16](16-cn-direct-ip-leak.md)。

**例外域名**（只能直连，经日本节点实测全部失败）：

```
腾讯/微信   qq.com weixin.qq.com qpic.cn qlogo.cn gtimg.cn tencent.com …
教育网      edu.cn ac.cn chsi.com.cn
政务        gov.cn gov.hk
```

### 两层路由（都要改，只改一层不生效）

| 层 | 组件 | 国内方向 | 角色 |
|---|---|---|---|
| 第 1 层 | sing-box（我们的 TUN）| → `cn-via-jp` 国内出口 | 决定主路径 |
| 第 2 层 | xray（v2rayN 管理）| → `proxy` 节点 | 兜底 |

第 2 层必须选中 **`V4-禁直连(TUN 专用)`** 这个自定义路由配置项
（`scripts/make-routing-profile.py` 生成）。它的兜底是 `proxy` 而不是
`direct` —— 这样第 1 层万一漏了某个国内目标，第 2 层也只会送去节点，
节点到不了中国 → 请求失败，但**不会泄漏真实 IP**（fail-closed）。

## 组件

| 组件 | 层级 | 职责 | 开关 |
|---|---|---|---|
| `com.local.v2rayn-tun` | root daemon | 建/撤 TUN；kill-switch；检测地址变化重建 | v2rayN 启停 |
| `com.local.v2rayn-dnsguard` | root daemon | 网络切换后修正 DNS，避免被 on-link DNS 污染 | 自动 |
| `com.local.v2rayn-sleepguard` | root daemon | 合盖不休眠 + 过热保护 | `no-sleep-timeout` |
| `com.local.v2rayn-quitguard` | 用户 agent | 拦截 Cmd+Q 防误退出 | `allow-quit` |
| `com.local.v2rayn-subserver` | 用户 agent | 把 Clash 订阅转成 v2rayN 认的格式 | 自动 |
| v2rayN（本体） | 用户 app | 节点管理 + xray 进程 | 总开关 |

**只有 v2rayN 是开关**：它一退出，上面所有运行时状态全部自动撤掉（TUN / 路由 /
DNS / 端口 / kill-switch）。守护本身常驻，但不产生任何流量影响。

## 配置文件

| 文件 | 角色 |
|---|---|
| `config/sing-box.json` | **唯一事实来源**（仓库） |
| `/usr/local/libexec/v2rayn-tun/config.json` | 安装后的实体 |
| `/usr/local/libexec/v2rayn-tun/config.run.json` | 运行时（只在 `config.json` 基础上换 MTU） |

**v2rayN 侧还有两处独立配置**（GUI 里改，不在仓库）：

| 位置 | 作用 |
|---|---|
| 路由设置 → `V4-禁直连(TUN 专用)` | 决定 xray（第 2 层）怎么走 |
| 用 `scripts/make-routing-profile.py` 生成 | 见上文"两层路由" |

**⚠️ 运行时脚本可能再改线上配置**（如 `per-app-routing.py apply` 会加 `node-direct`
出站和进程规则）。这类改动**不会自动回写仓库** —— 重装后需要重新执行对应脚本。
检查漂移：

```bash
diff <(python3 -m json.tool config/sing-box.json) \
     <(python3 -m json.tool /usr/local/libexec/v2rayn-tun/config.json)
```

## 用户可操作的开关

均为 `~/Library/Application Support/v2rayN/` 下的**文件存在性与内容**：

| 文件 | 作用 |
|---|---|
| `tun-disabled` | 存在则不建 TUN |
| `tun-mtu` | 内容为 MTU 数值（默认 1500） |
| `killswitch-always` | 存在则 v2rayN 退出后也保持 TUN |
| `no-sleep-timeout` | 合盖放开睡眠的空闲秒数（默认 2400） |
| `allow-quit` | 存在则放行 Cmd+Q |

## 脚本

| 脚本 | 用途 | 需要 root |
|---|---|---|
| `install.sh` / `uninstall.sh` | 安装 / 卸载 | ✓ |
| `per-app-routing.py` | 生成并应用"按进程豁免" | ✓ (apply) |
| `stealth-mode.sh` (+ `.py`) | 整层关闭国内直连（全代理） | ✓ |
| `clash-sub-to-v2rayn.py` | Clash YAML → 节点链接 | ✗ |
| `sub-server.py` | 本地订阅转换服务 | ✗ |
| `test-nodes.py` | 逐个实测节点可用性 | ✗ |
| `setup-signing-cert.sh` | 一次性准备签名证书（quit-guard 用） | ✗ |
| `no-sleep.sh` | 合盖不休眠开关 | ✓ |
| `vps-tune.sh` / `vps-compare.sh` | 自建节点调优 / 比对 | ✗ |
| `hysteria-real-cert.sh` | 给 Hysteria2 申请真证书 | ✗ |
| `add-reality-inbound.py` | 给 VPS 加 Reality 入站 | ✗ |

## 排查入口

```bash
# 一眼看全部状态
/usr/local/libexec/v2rayn-tun/sing-box version
launchctl print system/com.local.v2rayn-tun | grep state
scutil --proxy                      # 系统代理应为全关
env | grep -i proxy                 # 环境变量应为空
ifconfig | grep 172.19.0.1          # TUN 存在与否
curl -s --noproxy '*' https://api.ipify.org    # 当前出口

# 日志
tail -f /var/log/v2rayn-tun.log
tail -f /var/log/v2rayn-dnsguard.log
tail -f /var/log/v2rayn-sleepguard.log
tail -f ~/Library/Logs/v2rayn-quitguard.log
```

## 文档地图

| 分类 | 文档 |
|---|---|
| **入门** | [01 打不开](01-gatekeeper.md) · [02 Dock + 免密 TUN](02-dock-and-passwordless-tun.md) |
| **机制** | [03 启动项/IPv6/DNS](03-login-item-ipv6-dns.md) · [04 网络切换 bug](04-network-switch-bugs.md) · [07 仓库与竞态](07-repo-and-bootout-race.md) |
| **性能** | [05 微信卡顿](05-wechat-lag.md) · [06 GitHub 慢](06-github-slow.md) |
| **节点** | [08 故障排查](08-node-failure-triage.md) · [09 VPS 调优](09-vps-tuning.md) · [10 Reality](10-reality-setup.md) · [11 Hysteria2](11-hysteria2-real-cert.md) |
| **安全** | [12 Cmd+Q 拦截](12-quit-guard.md) · [13 IP 泄漏防护](13-ip-leak-protection.md) · [16 国内直连泄漏](16-cn-direct-ip-leak.md) · [17 封号检测调研](17-claude-ban-detection-analysis.md) |
| **运维** | [18 风险登记](18-risk-register.md) · [19 路由实施](19-routing-implementation.md) · [20 节点参数被改](20-node-params-changed.md) |
| **订阅** | [14 节点 SNI 屏蔽](14-node-sni-blocking.md) · [15 Clash 订阅转换](15-clash-sub-to-v2rayn.md) |
| **工具** | [toolbox](toolbox.md) |
