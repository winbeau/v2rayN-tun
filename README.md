# v2rayN TUN 模式（macOS）

把 v2rayN 从「系统代理」升级为「全局 TUN 透明代理」，**免密码、开机自动、网络切换自动恢复**。

```
应用 → sing-box TUN (root) → socks 127.0.0.1:10808 → xray (v2rayN) → 节点
```

国内流量由 sing-box 直接判定（`geoip-cn` / `geosite-cn` → direct），国外流量交给 xray 走节点。

> 📚 **排查记录见 [`docs/`](docs/README.md)** —— 按主题记录了搭建过程中踩过的弯路与解决办法。
> 遇到网络异常时，先看 [`docs/README.md`](docs/README.md) 末尾的「两个真实 bug 速查」。

---

## 为什么需要这套东西

v2rayN 7.25.4 在 macOS 上开 TUN 有两个硬伤，都是源码里写死的：

**1. 每次启动都要输 sudo 密码**

```csharp
// StatusBarViewModel 构造函数：启动时强制关掉 TUN
if (_config.TunModeItem.EnableTun && AllowEnableTun())
    EnableTun = true;
else
    _config.TunModeItem.EnableTun = EnableTun = false;

private bool AllowEnableTun() => AppManager.Instance.LinuxSudoPwd.IsNotEmpty();
```

`LinuxSudoPwd` 是**纯内存变量**，全代码库只有密码框会赋值、从不从配置读取。所以每次启动都必须手动拨开关 + 输密码。

**2. TUN 与 v2rayN 生命周期绑定**

它通过 `run_as_sudo.sh` 里的 `sudo -S` 拉起 sing-box。一旦代理端口抖动或 v2rayN 退出，TUN 就悬空，可能把整机流量丢进死代理。

本项目的做法：**把 TUN 部分独立成 root LaunchDaemon**，sing-box 常驻托管，不依赖 v2rayN 的密码机制。

---

## 文件说明

```
v2rayN-tun/
├── install.sh                     # 安装/更新 (root)
├── uninstall.sh                   # 卸载 (root)
├── config/
│   └── sing-box.json              # TUN 的 sing-box 配置
├── daemon/
│   ├── run-tun.sh                 # TUN 守护包装脚本
│   └── dnsguard.sh                # 网络守护 (DNS 污染 + 网络切换重绑定)
└── launchd/
    ├── com.local.v2rayn-tun.plist      # TUN 守护 (root, KeepAlive)
    ├── com.local.v2rayn-dnsguard.plist # 网络守护 (root, 30s + 监听网络变化)
    └── v2rayN-LaunchAgent.plist        # v2rayN 登录自启 (用户级)
```

脚本与配置里的 `__USER_HOME__` 由 `install.sh` 在安装时替换为实际用户主目录，因此仓库可以直接复用到别的机器。

---

## 安装

```bash
sudo ./install.sh
```

前置条件：**先手动启动过一次 v2rayN**，让它把 sing-box 核心和规则集释放到
`~/Library/Application Support/v2rayN/bin/`。

安装脚本会：

1. 从 v2rayN 复制 `sing-box` 与 4 个 `.srs` 规则集（这两个不入库，因为体积大且随 v2rayN 更新）
2. 替换 `__USER_HOME__` 后安装脚本与配置到 `/usr/local/libexec/`
3. 收紧权限（全部 `root:wheel`，用户不可写 —— 这是安全关键，避免留下提权面）
4. 安装并加载 2 个 LaunchDaemon + 1 个 LaunchAgent
5. 自检连通性

**卸载**：`sudo ./uninstall.sh`

---

## 两个免 sudo 开关

安装后，日常调整不需要密码（最多 5 秒生效）：

```bash
# 临时关闭 TUN（回到纯 v2rayN 本地代理）
touch ~/Library/Application\ Support/v2rayN/tun-disabled
rm    ~/Library/Application\ Support/v2rayN/tun-disabled     # 恢复

# 临时调整 TUN MTU（取值 576-9000，生成后会用 sing-box check 校验，失败自动回退）
echo 1500 > ~/Library/Application\ Support/v2rayN/tun-mtu
rm   ~/Library/Application\ Support/v2rayN/tun-mtu           # 恢复默认 9000
```

两个文件都只影响自己的 TUN，不构成提权面（守护只读它们，不执行其内容）。

---

## 设计要点

### 1. 代理不在就不建 TUN

`run-tun.sh` 每 5 秒探测 `127.0.0.1:10808`：

- 端口就绪 → 拉起 sing-box
- 端口下线 → 立刻撤掉 TUN

**这避免了「v2rayN 没开 = 整机断网」**：没有 TUN 时系统直接走物理网络。

### 2. 路由环路用 process_path 规避

xray / sing-box 自己去连节点的流量**不能被 TUN 再吞一次**，否则形成死循环：

```json
{"outbound": "direct", "process_path": [
  "__USER_HOME__/Library/Application Support/v2rayN/bin/xray/xray",
  "__USER_HOME__/Library/Application Support/v2rayN/bin/sing_box/sing-box",
  "/usr/local/libexec/v2rayn-tun/sing-box"
]}
```

### 3. IPv6 快速失败而非泄漏

TUN 同时持有 IPv4 与 IPv6 地址以捕获 IPv6，再用 `{"ip_cidr": ["::/0"], "action": "reject"}`
让 IPv6 快速失败；配合 DNS `strategy: ipv4_only`，从源头不返回 AAAA。

**背景**：节点无 IPv6 能力时，若不给 TUN 配 IPv6 地址，IPv6 流量会**完全绕过代理**（实测泄漏为本机真实 IPv6）。

### 4. 网络守护（`dnsguard.sh`）解决两类"网络变化后没切换干净"

**问题 A：DNS 回落到 on-link 地址**

与主机同网段的 DNS（如路由器 `10.236.42.55`、RA 下发的 IPv6 DNS）走链路直连、**不进 TUN**，
因此绕过 sing-box 的 DNS 劫持，返回被污染的结果（实测 `google.com` 解析到 Twitter 的 IP 段）。

判定规则是**因果关系而非白名单比对**：只要主解析器在用 on-link / 私有地址就改回公网 DNS，
因此不会和用户自定义的公网 DNS 打架。

**问题 B：sing-box 出站绑定失效（重要）**

sing-box 在**启动时**检测网络并确定出站绑定。网络切换（换 WiFi / 热点）后旧地址消失，
但它仍用旧地址发包：

```
ERROR write udp 10.236.42.160:...->119.29.29.29:53: can't assign requested address
```

**结果是所有直连出站失败** —— 表现为微信卡住、程序报传输错误、国内网站打不开。
守护检测到本机地址变化就重启 TUN，让它重新绑定（带 60 秒防抖）。

实测：切网后 **11 秒自动恢复**（`05:13:04` 出错 → `05:13:15` 检测 → `05:13:20` 重建完成）。

---

## 已知限制

### 用域名指定的节点存在 DNS 引导死锁

若活动节点用**域名**（而非固定 IP）指定，切换节点时可能死锁：

```
解析节点域名 → 需要走代理 → 代理需要先解析这个节点 → 死锁
```

**规避**：优先使用固定 IP 的节点。若必须用域名节点，需要在 sing-box 的 `dns.rules`
里为该域名加一条走直连解析器的规则。

### 延迟取决于节点位置

TLS 握手耗时 ≈ 到节点的往返延迟 × 2~3。以洛杉矶节点为例实测：
`github.com` TLS 约 0.8-1.2 秒。这是物理距离，配置层面无法改善 —— 换香港/日本/新加坡节点
才能显著降低（可降至约 0.15s）。

### 不能加速的两种情形

- **目标站点在国内不可直连**（实测 `github.com` 直连返回 HTTP 000），必须走代理
- **本地链路带宽见顶**：实测 4 并发吞吐 ≈ 裸链路吞吐，说明已是网络上限而非代理损耗

---

## 排查

```bash
# TUN 守护日志（含 sing-box 输出）
tail -f /var/log/v2rayn-tun.log

# 网络守护日志（DNS 修复 / 网络切换重启）
tail -f /var/log/v2rayn-dnsguard.log

# 守护状态
launchctl print system/com.local.v2rayn-tun
launchctl print system/com.local.v2rayn-dnsguard

# 重启（改配置后用）
sudo launchctl kickstart -k system/com.local.v2rayn-tun

# 判断某个 IP 会不会被判定为国内（决定直连还是走节点）
/usr/local/libexec/v2rayn-tun/sing-box rule-set match -f binary \
    /usr/local/libexec/v2rayn-tun/rules/geoip-cn.srs 1.2.3.4
#   有 "match" 输出 = 命中 = 走直连

# 判断某连接实际走直连还是走节点（源端口比对法）
#   应用侧连接来自 172.19.0.1:<port>
#   sing-box 出站若为 <en0地址>:<port> → 直连；若为 <节点IP> → 走代理
netstat -an -f inet | grep <目标IP>
```

### 检查 sing-box 绑定是否已失效

```bash
# en0 当前地址
ifconfig en0 | awk '/inet /{print $2}'
# sing-box 出站实际用的源地址（应为同一个）
netstat -an -f inet | grep ESTABLISHED | grep -v 172.19.0.1 | grep -v 127.0.0.1
```

两者不一致 = 绑定已失效，重启 TUN 即可（正常情况守护会自动处理）。

---

## 安全说明

- `/usr/local/libexec/` 下全部资产为 `root:wheel`，**用户不可写**
- **不写入任何 sudoers 规则**（`/etc/sudoers.d/` 保持为空）
- 用户开关文件只被读取判断存在性/数字，不执行其内容

作为对比：网上常见的「sudoers NOPASSWD」方案会把免密 sudo 规则指向
`~/Library/Application Support/v2rayN/bin/` 里的**用户可写**文件，
等于给账号开了一条免密 root 通道。本方案刻意避开这一点。
