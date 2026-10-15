# 00 · 整体架构

> **一句话**：v2rayN 只当"节点管理器"，`sing-box` 接管系统流量，本机零系统代理、零环境变量；开关就是 v2rayN 本身的启停。

## 数据流

```
                         ┌──────────────────────────────────────┐
   AdsPower/SunBrowser ──┤                                      │
   (豁免进程)            │        sing-box (root LaunchDaemon)  │
                         │        TUN: utun*  172.19.0.1        │──→ node-direct ─→ 住宅节点
                         │        stack=system  auto_route       │    (vless, 裸连)
   其他所有进程 ─────────┤        mtu=1500 (可调)                │
   (含 Terminal)         │                                      │──→ proxy ─→ 127.0.0.1:10808
                         └──────────────────────────────────────┘              └→ xray (v2rayN 管理)
                                                                                      └→ 节点
```

**默认路径**：进程 → TUN → sing-box → `proxy`(socks) → xray → 节点
**豁免路径**：名单内进程 → TUN → sing-box → `node-direct` → 节点（绕过 xray）

**为什么豁免要绕过 xray**：xray 看不到"连接来自哪个进程"，它会按自己的路由
把国内目标直连，从而泄漏真实 IP。详见 [16](16-cn-direct-ip-leak.md)。

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
| **订阅** | [14 节点 SNI 屏蔽](14-node-sni-blocking.md) · [15 Clash 订阅转换](15-clash-sub-to-v2rayn.md) |
| **工具** | [toolbox](toolbox.md) |
