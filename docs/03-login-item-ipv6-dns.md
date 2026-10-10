# 03 · 登录项 + 假 IPv6 + DNS 污染

## 3.1 登录项：光改配置不够

v2rayN 的 `GuiItem.AutoRun` 用 **LaunchAgent** 实现（`AutoStartupHandler.SetTaskOSX()`），写到 `~/Library/LaunchAgents/v2rayN-LaunchAgent.plist`。

**弯路**：把配置改成 `AutoRun: true` 后重启，登录项并没有生成。

原因 —— `AutoStartupHandler.UpdateTask()` 全代码库**只有一个调用点**：

```
v2rayN/ServiceLib/ViewModels/OptionSettingViewModel.cs:407
```

即**只在设置窗口保存时调用，启动时不检查**。

→ 解决：按它自己的模板手写 plist，并同步把配置改成 `true`（这样 GUI 开关与实际状态一致）。

唯一改动：`ProgramArguments` 用 `/usr/bin/open -a` 而非直接执行二进制，保证正确的 app 激活行为。

## 3.2 假 IPv6：根因不在 sing-box

**现象**：`www.google.com` 的 AAAA 返回 `2001::1`（伪造地址）。

**弯路**：以为是 sing-box 的 DNS 返回的。**错。**

实测证据：`dig +short A www.google.com @223.5.5.5` 返回真实的 `2001:4860:...`，而走系统解析器返回 `2001::1` —— 说明污染来自**系统解析器走的那个 DNS**。

真因（`scutil --dns`）：

```
nameserver[0] : 2408:847a:716:2130::6d    ← IPv6，与本机同网段
nameserver[1] : 10.236.42.55              ← 网关，同网段
```

两个 DNS 都在 **on-link 网段** → 流量走链路直连、**根本不进 TUN** → 绕过 sing-box 的 DNS 劫持。

**这就是关键**：sing-box 的 `hijack-dns` 只对**进入 TUN 的**查询生效，同网段流量永远不会进来。

## 3.3 连带发现：IPv6 完全泄漏

排查过程中顺手测出来的，**比原问题更严重**：

```bash
curl -6 https://api64.ipify.org
#  2408:847a:716:2130:f1e3:244a:8ad6:f7e7   ← 这是本机 en0 的真实地址!
```

TUN 当时**只有 IPv4 地址**（`172.19.0.1/30`），所以 IPv6 流量完全没有被接管。

→ 开 TUN 只配 IPv4 = IPv6 裸奔。

## 解决（三处）

| # | 改动 | 原因 |
|---|---|---|
| 1 | 系统 DNS → `223.5.5.5 119.29.29.29` | 公网地址不再 on-link，查询会走默认路由进 TUN 被劫持 |
| 2 | TUN 增加 IPv6 地址 `fdfe:dcba:9876::1/126` + `{"ip_cidr":["::/0"],"action":"reject"}` | 让 IPv6 被捕获后**快速失败**，而不是泄漏 |
| 3 | DNS `strategy: ipv4_only` | 从源头不返回 AAAA |

第 2 条用 reject 而非代理，依据是实测**节点无 IPv6 能力**：经代理请求 IPv6 出口，返回的仍是 IPv4 `216.167.95.77`。reject 能让应用立刻回退 IPv4，避免超时等待。

## 验证

```bash
dig +short AAAA www.google.com     # 空 → 假 IPv6 已消除
dig +short A www.google.com        # 142.251.x.x → 真实（此前是 104.244.x.x，Twitter 段，污染）
curl -6 "https://[2606:4700:4700::1111]/cdn-cgi/trace"   # 无响应 → 已拦截
```

## 教训

`hijack-dns` 拦截不了 on-link 的 DNS 服务器。判断"DNS 是否走隧道"的标准不是看查询目标，而是看**该目标是否与本机同网段**。
