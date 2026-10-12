---
name: macos-tun-no-proxy
description: Set up and troubleshoot a transparent TUN proxy on macOS where the proxy environment variables and the system HTTP/SOCKS proxy are both OFF — traffic is captured at the IP layer instead. Covers installing a root LaunchDaemon that owns the sing-box TUN independently of the GUI client, eliminating the repeated sudo password prompt, auto-healing DNS after network changes, toggling TUN/MTU without sudo, and diagnosing the two failure modes that only appear after switching networks. Use when the user asks to 开启/配置 TUN 模式, remove 代理变量/system proxy, make v2rayN not ask for a password, fix 微信卡顿/发不出消息 or 程序传输错误 after changing networks, stop IPv6 leaks or fake IPv6 DNS answers, or debug a TUN that silently turned itself off. Do not use for deploying a remote proxy node (use deploy-us-proxy), Clash/sing-box config authoring unrelated to macOS, or Windows/Linux clients.
---

# macOS 透明代理：TUN 模式 + 无代理变量

在 macOS 上把代理从「系统代理 / 环境变量」升级为 **TUN 透明代理**：
应用无需任何代理配置，流量在 IP 层被接管。

**为什么不要代理变量**：环境变量只对读它的程序生效，且会被 TUN 再次捕获造成绕行；
系统代理要每个应用自己支持。TUN 在 IP 层工作，**覆盖全部应用**，且**不需要任何代理变量**。

## 不适用

- 部署远程节点 —— 用 `deploy-us-proxy`。
- 客户端是 v2rayN 但只想用系统代理模式（不用 TUN）—— 那不是本 Skill 的目标形态。
- Windows / Linux 客户端。

## 目标形态

```
应用 ──► TUN (sing-box, root) ──► socks 127.0.0.1:10808 ──► xray ──► 节点
国内流量由 sing-box 判定 geoip-cn / geosite-cn 直接走直连
```

三件事同时成立才算完成：

1. **系统代理关闭**（v2rayN 的 `SysProxyType` = `Unchanged`，即值 2）
2. **没有代理环境变量**（`http_proxy` / `https_proxy` / `all_proxy` 均未设置）
3. **TUN 由 root 守护进程持有**，不依赖 GUI 客户端是否以管理员启动

---

## 为什么必须用独立的 root 守护进程

v2rayN 7.x 在 macOS 上**每次启动都会强制关闭 TUN**，源码依据：

```csharp
// StatusBarViewModel 构造函数
if (_config.TunModeItem.EnableTun && AllowEnableTun())
    EnableTun = true;
else
    _config.TunModeItem.EnableTun = EnableTun = false;

private bool AllowEnableTun() {
    else if (Utils.IsMacOS())
        return AppManager.Instance.LinuxSudoPwd.IsNotEmpty();   // ← 纯内存变量
}
```

`LinuxSudoPwd` **不从配置读取**，只有密码输入框会赋值。所以：

- 改 `run_as_sudo.sh` **没用** —— 它每次启动 TUN 时都会被重新生成
- 把 `EnableTun` 写进配置文件 **没用** —— 每次启动被强制重置

**结论：不要试图让 v2rayN 自己开 TUN，用外部 root 守护进程接管。**

> ⚠️ **不要用 `sudoers` NOPASSWD 方案。** 那条路要让 `sing-box`、
> `kill_as_sudo.sh` 等**用户可写目录下的文件**获得免密 root，等于给账号开了提权通道。
> 本方案的全部资产归 root 所有，**不需要往 `/etc/sudoers.d/` 写任何东西**。

## 硬约束

1. **不要自己跑需要密码的 `sudo`。** 先测 `sudo -n true`；需要密码就把命令交给用户执行。
2. **改动前先备份，改动后立刻自检连通性。** 守护类组件装完不验证，可能整机断网。
3. **`launchctl bootout` 是异步的。** 旧实例（含其子进程）没退干净就 `bootstrap` 会报
   `Bootstrap failed: 5: Input/output error`。必须先轮询等待实例消失，再 bootstrap 并重试。
   详见 [references/known-issues.md](references/known-issues.md)。
4. **不要用 `lsof` 查看 root 进程的连接。** sing-box 以 root 运行，普通用户看不到它的 fd，
   结果恒为空 —— 会得出「没有连接」的错误结论。用 `netstat` 看。
5. **`launchctl` 的 GUI domain 要用 `gui/<uid>`。** root 无法用 `sudo -u` 操作用户的 GUI domain，
   会静默失败。

---

## 工作流

### 1. 前提检查

```bash
# 客户端已装且至少有一个可用节点 (守护进程从 v2rayN 目录取 sing-box 与规则集)
ls -d "/Applications/v2rayN.app"
ls "$HOME/Library/Application Support/v2rayN/bin/sing_box/sing-box"
ls "$HOME/Library/Application Support/v2rayN/bin/srss/"*.srs

# 没有代理环境变量
env | grep -iE '^(http|https|all|no)_proxy=' && echo "有代理变量, 需清理" || echo "✓ 无代理变量"
```

**sing-box 与规则集由 v2rayN 提供**，所以 v2rayN 必须至少启动过一次以完成自解压。

### 2. 安装

```bash
sudo bash scripts/install-tun.sh
```

脚本负责：从 v2rayN 复制 sing-box 与 `.srs` 规则集 → 安装守护脚本与配置
（路径占位符 `__USER_HOME__` 在安装时替换）→ 写 LaunchDaemon → 加载 → 自检。

**脚本会检测重复执行**：重复运行是安全的，且会正确重建（见硬约束 3 的等待逻辑）。

目标用户通过 `stat -f '%Su' /dev/console` + `dscl` 推导，**不能用 `$HOME`** ——
脚本以 root 运行时它是 `/var/root`。

### 3. 关闭系统代理与代理变量

```bash
# v2rayN 系统代理设为 Unchanged (枚举值 2)
#   ForcedClear=0  ForcedChange=1  Unchanged=2  Pac=3
python3 -c "
import json
p='$HOME/Library/Application Support/v2rayN/guiConfigs/guiNConfig.json'
d=json.load(open(p)); d['SystemProxyItem']['SysProxyType']=2
json.dump(d, open(p,'w'), indent=2, ensure_ascii=False)"

# macOS 系统代理确认关闭
scutil --proxy | grep -E 'HTTPEnable|SOCKSEnable'   # 都应为 0
```

### 4. 免 sudo 开关

两个用户可写的文件（守护进程每次运行都会读）：

```bash
# 临时关闭 TUN (排查「是不是 TUN 造成的」时非常有用)
touch "$HOME/Library/Application Support/v2rayN/tun-disabled"

# 临时改 MTU (范围 576-9000, 守护会做 sing-box check 校验并自动回退)
echo 1500 > "$HOME/Library/Application Support/v2rayN/tun-mtu"
```

**MTU 默认 9000 会出问题，建议设 1500。** 实测四项指标方向一致地改善。

### 5. 验证

```bash
scripts/diagnose.sh
```

或手工：

```bash
ifconfig | grep -A6 utun | grep '172.19.0.1'          # TUN 已建立
scutil --proxy | grep -E 'HTTPEnable|SOCKSEnable'     # 应为 0
env | grep -i proxy                                    # 应为空
curl --noproxy '*' -s -o /dev/null -w '%{http_code}\n' https://www.baidu.com          # 200
curl --noproxy '*' -s -o /dev/null -w '%{http_code}\n' https://www.google.com/generate_204  # 204
```

---

## 两个只在「切换网络后」出现的故障 ⭐

这是本项目最难查的部分。两个 bug 同源（网络变化后没切换干净），但症状完全不同。

### Bug A：DNS 回落到 on-link 地址

**现象**：解析被污染（如 google 返回 Twitter 的 IP 段）。

**根因**：手动设置的公网 DNS 在某些情况下会回落到 DHCP/RA 下发的地址，
而这些地址**与本机同网段（on-link）** —— on-link 流量走链路直连、**根本不进 TUN**，
于是绕过了 sing-box 的 DNS 劫持。

> **关键认知**：`hijack-dns` 拦不住 on-link 的 DNS 服务器。
> 判断标准不是「查询目标是谁」，而是「**该目标是否与本机同网段**」。

**解法**：`dnsguard.sh` 检测主解析器是否全部为公网地址，不是就改回公网 DNS。

判定用**因果关系**而非白名单比对（写成「必须是某个特定 DNS」会和用户自定义的公网 DNS 打架）。
只统计「默认解析器」和「绑定主接口的解析器」，忽略其他接口（iCloud 私密代理、VPN），
因此不会误伤 VPN 自己的 DNS。

### Bug B：sing-box 出站绑定停留在旧地址

**现象**：切网后**所有直连出站失败**，表现五花八门 ——
微信发消息转圈、截图发不出去、程序报传输错误、部分国内网站打不开。

**根因**：sing-box 在**启动时**探测网络接口并确定出站绑定，之后网络怎么变它都不知道。
旧地址消失后它仍用它发包：

```
ERROR write udp 10.20.30.160:56026->119.29.29.29:53:
      write: can't assign requested address
```

**解法**：`dnsguard.sh` 记录主接口地址，变化则重启 TUN，让 sing-box 重新绑定。
60 秒防抖避免网络抖动导致反复重建。

实测切换后 **11 秒自动恢复**。

详见 [references/known-issues.md](references/known-issues.md)。

---

## 排错：分层定位

**第一原则：先证明问题不在本地，再往外查。**

```
第 1 层  本地配置    国内能否正常访问?  ── 能就说明 TUN/路由/DNS 都健康
第 2 层  网络路径    绕过本地所有代理, 直连节点
第 3 层  节点服务    TCP 与 TLS 分开看
```

### 第 2 层的正确工具是 `--interface`

```bash
curl -vsk -o /dev/null --interface en0 --max-time 12 \
     --resolve <SNI域名>:443:<节点IP> https://<SNI域名>/
```

`--interface` 设置 `IP_BOUND_IF`，**强制走指定网卡、绕过路由表**，完全跳过 TUN。

⚠️ **有两种看起来像绕过、实际没绕过（或没测到）的写法** —— 绑定源地址不改变路由查找，
用域名做对照会被 DNS 失败污染。**排查前务必先看
[references/triage.md](references/triage.md) 第 1 节**，否则会得出完全错误的结论。

### 常见误判

| 误判 | 为什么错 |
|---|---|
| 「xray 日志里没有该应用的流量 → 没被代理」 | 日志级别是 `warning` 时**访问日志根本没开**。空日志有两种含义：「没有事件」和「没有在记」 |
| 「只有 2 条连接 → 没有长连接」 | 单次快照不能证明「不存在」。监控 90 秒后发现长连接一直稳定存活 |
| 「`lsof` 看不到连接 → 没有连接」 | root 进程的 fd 普通用户看不到，见硬约束 4 |
| 改了参数就好了 | 根因未明时改参数会把多个变量搅在一起，之后更难分离 |

### 故障是间歇的时候

**必须在故障发生时取数。** 事后测到的「正常」会误导你结案 ——
本项目就发生过「测到绑定是正确的就结案」，但那一刻网络刚切换完、守护已重启。

---

## 成功标准

1. `ifconfig` 显示 TUN 地址（默认 `172.19.0.1`）。
2. `scutil --proxy` 的 `HTTPEnable` / `SOCKSEnable` 均为 `0`。
3. `env | grep -i proxy` 为空。
4. 国内 HTTP 200 且国外 HTTP 204。
5. `launchctl print system/<label>` 的 `state = running`。
6. **切换一次网络后，守护日志出现「网络地址变化 → 重启 TUN」，且 15 秒内恢复。**
7. **退出 v2rayN 后系统无残留** —— TUN 接口/路由消失、系统代理关闭、
   **DNS 还原为「自动」**（不是留着我们设的公网 DNS）、10808 端口释放。
   验证：`networksetup -getdnsservers Wi-Fi` 应输出 *There aren't any DNS Servers set*。
8. **（可选）装了 Cmd+Q 拦截器时**：`codesign -d -r- /usr/local/libexec/v2rayn-tun/quit-guard`
   应显示 `certificate root = H"..."` 而**不是** `cdhash H"..."`。
   是 cdhash 就说明没签名 —— 每次重编译都会让辅助功能授权失效，
   用户得反复授权。见 [known-issues.md](references/known-issues.md) 第 11 条。

第 6 条最容易被跳过，但它是这套方案的核心价值所在。

## 可选：Cmd+Q 误退出保护（quit-guard）

防止手抖按到 `Cmd+Q` 把代理弄断。用 `CGEventTap` 在按键阶段吞掉事件，
**v2rayN 根本收不到，所以它不会退出**（不是"退出后拉回来"）。

```
按住 Cmd+Q（v2rayN 在前台）
   → 全屏灰屏糊化 + 红色进度条，随按住时长填充
   松手        → 取消，v2rayN 继续运行
   按住满 8 秒 → 主动退出
```

**只对 v2rayN 生效**：双重限定（必须是 Cmd+Q，且前台应用 bundle id 是
`2dust.v2rayN`）。别的应用按 Cmd+Q 完全不受影响。

### 安装前必须先做这一步

```bash
./scripts/setup-signing-cert.sh      # 一次性, 本地代码签名证书
```

**为什么**：拦截键盘需要**辅助功能**权限，而 macOS 的 TCC 授权对 adhoc 签名
是按 CDHash 校验的 —— **每次重新编译都等于换了个程序，授权立即失效**。

| 签名方式 | designated requirement | 重编译后 |
|---|---|---|
| adhoc | `identifier "quit-guard" and cdhash H"..."` | **授权失效** ✗ |
| 证书 | `identifier "..." and certificate root = H"..."` | 保持有效 ✓ |

**不先解决这个就改代码，用户会被迫反复去设置里重新授权。** 本项目踩过这个坑，
详见 [docs/12](../../docs/12-quit-guard.md)。

### 两条绝不能犯的错

1. **事件回调里不能阻塞。** `CGEventTap` 回调卡住会冻住**整个系统的键盘输入**，
   不只是目标应用。回调只做判断就返回，处理丢后台队列；要"放行"时用
   `postToPid` 重发事件并带 `eventSourceUserData` 标记，否则会被自己再拦一次。
2. **不要调 `AXIsProcessTrustedWithOptions(prompt: true)`。** 那个 API 会主动弹
   系统授权框，配合 LaunchAgent 的 `KeepAlive` 就是**弹窗无限循环**；而那个框的
   默认按钮是 `Deny`，用户顺手点掉就会让 TCC 记下拒绝。
   只用不带 prompt 的 `AXIsProcessTrusted()` 静默查询，没权限就安静退出，
   靠 `ThrottleInterval` 限制重试。

## 故障判断

| 现象 | 首查方向 |
|---|---|
| 国内也打不开 | TUN 把整机流量吞了但代理不可用。守护应在 10808 下线时撤掉 TUN —— 检查日志是否有「代理端口已下线, 撤掉 TUN 以免断网」 |
| 国外全挂、国内正常 | 节点问题（见 `deploy-us-proxy`）或 DNS 污染。先跑第 1/2 层定位 |
| **握手正常但慢到不可用** | **流量超限被服务商限速**。握手只需几 KB，限速掐的是带宽 —— 必须实测吞吐才能发现。实测案例：节点握手 0.64s 正常，但 100KB 传输 15 秒都传不完 |
| 解析被污染 / 出现假 IPv6 | Bug A：`scutil --dns` 看是否有同网段 DNS |
| 切网后微信卡、程序报传输错误 | Bug B：查绑定是否失效 |
| 某个应用不生效 | 该应用可能绑定了特定接口或用 `--interface` 绕过；也检查 `process_path` 规则是否把它排除了 |
| IPv6 泄漏 | TUN 必须同时持有 IPv6 地址 + `::/0` reject 规则，否则 IPv6 完全绕过代理 |
| 改完守护不生效 | `launchctl kickstart -k system/<label>`；或确认 `bootout` 已异步完成（硬约束 3） |
| **守护日志只有「sing-box 立即退出」、无任何报错** | **macOS 26.4+ 的签名问题** —— adhoc 二进制被 `cp` 覆盖后 taskgated 会直接 SIGKILL。`codesign -v` 仍显示 valid，别被它骗过。见 [known-issues.md](references/known-issues.md) 第 9 条 |
| **Cmd+Q 拦截器反复弹授权框、点了还有** | 别在设置界面里反复点。看 TCC 日志定位：`log show --last 20m --predicate 'subsystem == "com.apple.TCC"' --style compact \| grep quit-guard`。搜 `Failed to match existing code requirement` —— 那是"CDHash 变了、授权已失效"。另外 `killall universalAccessAuthWarn` 关掉卡住的对话框 |
| **launchd `last exit code = 78: EX_CONFIG`** | plist 里的 `__USER_HOME__` 占位符没替换，日志路径不存在。`install.sh` 会用 `sed` 替换，手工恢复时别直接 `cp` 模板 |

两个 bug 的速查命令：

```bash
# Bug A: DNS 是否回落到 on-link
scutil --dns | grep nameserver        # 出现同网段地址就是中招

# Bug B: 出站绑定是否失效
ifconfig en0 | awk '/inet /{print $2}'                            # 主接口实际地址
grep "can't assign requested address" /var/log/v2rayn-tun.log     # 有输出就是中招
```

修复通常只需重启 TUN（正常情况下网络守护会在 11 秒内自动处理）：

```bash
sudo launchctl kickstart -k system/com.local.v2rayn-tun
```

## 环境注意

- macOS **没有 `/usr/bin/timeout`**，用命令自带超时（`ssh -o ConnectTimeout`、`curl --max-time`）。
- `spctl -a` 对 adhoc 签名的应用显示 `rejected` 是正常的，不代表不能运行。
- `sing-box rule-set match` **必须带 `-f binary`**，`.srs` 是二进制格式；漏掉会导致
  **全部 IP 判定为「未命中」**，得出完全相反的结论。
- 判断一条连接实际走直连还是代理，用 **netstat 源端口比对法**，
  见 [references/triage.md](references/triage.md)。
