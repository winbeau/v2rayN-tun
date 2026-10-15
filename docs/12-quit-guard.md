# 12 · 误按 Cmd+Q 保护（quit-guard）

> **一句话**：三次推倒重做，每次都因为一个更基础的前提假设错了 —— 前提错比实现错更致命。

## 问题

v2rayN 没有"退出确认"设置（`guiNConfig.json` 全部键、`UiItem`/`GuiItem` 等嵌套项
都查过）。macOS 的 `Cmd+Q` 是系统级退出，应用自己不做确认就没有确认。

结果：正在下载或跟 ChatGPT 对话时手一抖，TUN 被撤、连接全断。

## 最终方案

用 `CGEventTap` 在系统事件流里把 `Cmd+Q` 吞掉，**v2rayN 根本收不到这个事件**。
它不退出，就不存在"重建"。

```
按住 Cmd+Q（v2rayN 在前台）
   ↓
全屏灰屏糊化 + 红色粗进度条，随按住时长从左到右填充
   ├─ 松手            → 淡出取消，v2rayN 继续运行（什么都没发生）
   └─ 按住满 8 秒     → 主动 terminate v2rayN
```

界面（无边框、无按钮、不抢鼠标，盖住 Dock 与菜单栏）：

```
        v2rayN 没有退出 —— Cmd+Q 已被拦截         ← 32pt 粗体白
        保护中：Terminal、Google Chrome           ← 17pt 半透明
             3.2 秒后退出 · 松手即取消              ← 倒计时在条【上方】
   ████████████████░░░░░░░░░░░░░░░░░░░░░░░░       ← 24px 粗条, 红渐变+发光
```

- 糊化：`NSVisualEffectView(material: .fullScreenUI, blendingMode: .behindWindow)`
  再叠一层 58% 灰色压暗，保证文字对比度
- 进度条：玫红 → 正红 → 橙红渐变 + 红色发光 + 上半高光，60fps + 轻微缓出
- 只对 v2rayN 生效：双重限定（必须是 Cmd+Q，且前台应用 bundle id 是 `2dust.v2rayN`）

实测（按住 3 秒后松手）：

```
v2rayN pid: 42993 -> 42993          ← 进程从未变化
日志: 按住 3.0 秒后松手 -> 取消, v2rayN 全程未退出
```

对照（TextEdit 在前台按 Cmd+Q）：正常退出，拦截计数不变 ✓

---

## 走过的弯路

这一节比结论重要。这个功能前后推倒重做了三次，**每次都是因为一个更基础的
认知错误**，而每个错误都让用户白做了一轮授权操作。

### 弯路 1：做成"退出后拉回来"

第一版是"检测到 v2rayN 退出，如果有程序在用网就把它重新拉起来"。当时的理由是
"第三方拦不住 Cmd+Q，只能事后补救" —— **这个前提本身就是错的**，
`CGEventTap` 完全可以在按键阶段拦截。

错在哪：

1. **v2rayN 真的关过一次** —— 进程重建、窗口重建、连接重建。靠 `run-tun.sh`
   的宽限期只是让 TUN 没来得及撤，应用本身的中断是实打实的。
2. **和 `GRACE` 强耦合** —— 宽限期必须大于弹窗超时，`GRACE` 被迫从 15 拉到 20 秒。
   而这段窗口里流量进 TUN 却没有出口，等于断网。

### 弯路 2：事件回调里阻塞

改成 `CGEventTap` 之后，第一版在回调里用 `sem.wait()` 等弹窗结果。

**`CGEventTap` 的回调阻塞，冻住的是整个系统的键盘输入**，不只是 v2rayN ——
最长会冻 12 秒。

正确做法：回调只做判断后立刻返回，处理全部丢后台队列；需要"放行"时用
`postToPid` 重发事件，并带 `eventSourceUserData` 标记避免被自己再拦一次。

### 弯路 3（最惨）：TCC 授权的连环坑

这一轮折腾最久，因为它把三个独立的问题串成了一条死循环链：

#### 3.1 主动弹窗 + KeepAlive = 弹窗无限循环

代码里调了 `AXIsProcessTrustedWithOptions(prompt: true)` —— **这个 API 会主动
弹系统授权框**。而 LaunchAgent 配了 `KeepAlive=true`，程序没权限就退出、launchd
立刻重启、启动又弹一次 → **弹窗无限循环**。

更糟的是那个框的默认按钮是 **`Deny`**（蓝色高亮）。反复弹出时用户很容易顺手
点掉，TCC 就记下拒绝，之后一直授权失败。

**现在**：只用不带 prompt 的 `AXIsProcessTrusted()` 静默查询。没权限就安静
`exit(0)`，靠 `ThrottleInterval=60` 限制重试频率，**不弹任何窗**。

#### 3.2 adhoc 签名 + 重编译 = 授权反复失效

TCC 的判定依据（designated requirement）随签名方式不同：

```
adhoc 签名:  designated => identifier "quit-guard" and cdhash H"c8284874..."
                                              ^^^^^^ 每次重编译都变

证书签名:    designated => identifier "com.local.v2rayn.quitguard"
                           and certificate root = H"c61c98d8..."
                           ^^^^^^^^^^^^^^^^ 稳定
```

这台机器原本没有代码签名证书（`security find-identity` 显示
`0 valid identities found`），只能 adhoc 签名 → **每次重编译都要重新授权**。

我为了修 bug 反复重编译，累计出一堆 CDHash 对不上的 TCC 记录，最终演变成
用户看到的"授权框反复弹出、点了还有"。

**解法**：`scripts/setup-signing-cert.sh` 创建本地自签名证书，`install.sh`
编译后自动用它签名。详见下节。

#### 3.3 全局 `tccutil reset` 的连带伤害

排查时我跑了 `tccutil reset Accessibility`（**不带 bundle id 的全局重置**），
它清掉了**系统里所有应用**的辅助功能授权，包括终端本身 —— 直接导致
`osascript is not allowed assistive access (-25211)`，我的自动化工具全废了。

**教训**：能带标识就带标识；全局重置是不可逆的破坏性操作，影响面远超预期。
这个二进制是裸可执行文件（没有 bundle id），`tccutil reset Accessibility
com.local.v2rayn.quitguard` 会报 `No such bundle identifier` —— 所以当时只能
全局重置。**但正确顺序应该是：先确认影响范围，优先考虑手动在设置里删除条目，
把全局重置当作最后手段。**

### 弯路 4：`NSWorkspace.runningApplications` 触发完全磁盘访问

TCC 日志统计 quit-guard 请求过的服务：

```
14 次  kTCCServiceAccessibility          辅助功能      ← 我们真正需要的
 4 次  kTCCServiceSystemPolicyAllFiles   完全磁盘访问  ← 根本不需要
```

```
tccd: Failed to match existing code requirement for subject
      /usr/local/libexec/v2rayn-tun/quit-guard
      and service kTCCServiceSystemPolicyAllFiles
```

源头是 `NSWorkspace.shared.runningApplications` —— 它**枚举系统里所有 App**，
包括 `/System/Applications` 下受 SIP 保护的应用包，于是触发 FDA 检查，系统弹出
「想控制这台 Mac 并访问你的数据」。

**改成按 bundle id 定向查询**，只查名单里那几个：

```swift
NSRunningApplication.runningApplications(withBundleIdentifier: bid)
```

### 弯路 5：模板 plist 的占位符没替换

手动恢复时我直接 `cp` 了模板 plist，忘了 `__USER_HOME__` 需要替换：

```
launchd: Service could not initialize: Unable to create stdout directory
         (//__USER_HOME__/Library/Logs/v2rayn-quitguard.err)
         error 0x1e - Read-only file system
```

→ `last exit code = 78: EX_CONFIG`，服务起不来。

`install.sh` 里本来就有 `sed "s|__USER_HOME__|$TARGET_HOME|g"`，是我手动操作时
绕过了它。**教训：手工恢复配置时，从安装脚本里抄，不要自己拼。**

---

## 签名证书（一次性）

```bash
./scripts/setup-signing-cert.sh
```

脚本做的事，以及每一步的坑：

| 步骤 | 坑 |
|---|---|
| `openssl req -x509 ... -addext "extendedKeyUsage=critical,codeSigning"` | EKU 必须是 codeSigning，否则不能用于签名 |
| `openssl pkcs12 -export` | **必须加 `-legacy`**。OpenSSL 3/4 的新默认算法 macOS 不认，报 `MAC verification failed (wrong password?)` —— 而密码其实是对的，极易误判 |
| `security import -P <非空密码>` | **空密码 macOS 不接受**，同样报上面那个误导性错误 |
| `security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/.../login.keychain-db` | **必须用用户级域（不加 `-d`）**。用系统域（`-d -k /Library/Keychains/System.keychain`）会报 `authorization was denied since no user interaction was possible` —— 即使用 sudo/osascript 提权也过不去，trustd 要求交互式授权 |

验证：

```bash
security find-identity -v -p codesigning
codesign -d -r- /usr/local/libexec/v2rayn-tun/quit-guard
# 期望看到 certificate root = H"..."，而不是 cdhash H"..."
```

---

## TCC 问题的排查方法

**不要靠反复点设置界面。** 直接看 tccd 的日志，它把每一次授权变更和判定都记下来：

```bash
# 某个程序被授予/撤销的记录
log show --last 20m --predicate 'subsystem == "com.apple.TCC"' --style compact \
  | grep -i "quit-guard"

# 它请求过哪些服务（用来发现"意外的权限请求"）
log show --last 30m --predicate 'subsystem == "com.apple.TCC"' --style compact \
  | grep "quit-guard" | grep -oE "service=kTCCService[A-Za-z]+" | sort | uniq -c
```

典型输出与判读：

```
type=Modify, service=kTCCServiceAccessibility, identifier_type=Path, identifier=...   ← 用户授权成功
type=Delete, ...                                                                      ← 用户删掉条目
AUTHREQ_SUBJECT: subject=/usr/local/libexec/.../quit-guard                            ← 程序在请求
Failed to match existing code requirement for subject ... and service ...             ← 记录与二进制对不上!
```

`Failed to match existing code requirement` 就是"CDHash 变了、授权已失效"的
明确信号 —— 看到它就该重新添加一次，而不是怀疑别的。

### 那个弹窗是谁显示的

```
AUTHREQ_ATTRIBUTION: accessing={... universalAccessAuthWarn ...} requesting={WindowServer}
```

`/System/Library/PrivateFrameworks/UniversalAccess.framework/.../universalAccessAuthWarn.app`
就是显示「**"X" would like to control this Mac and access your data**」的那个进程。
它可能**卡住不走**，即使触发它的程序已经退出：

```bash
killall universalAccessAuthWarn     # 关掉卡住的对话框
```

### 三边对齐才能定位

| 看哪里 | 命令 | 含义 |
|---|---|---|
| TCC 记录 | `log show ... \| grep <程序名>` | 系统认为授权是什么状态 |
| 二进制身份 | `codesign -dv --verbose=4 <二进制> \| grep CDHash` | 它是谁 |
| 程序自述 | `~/Library/Logs/v2rayn-quitguard.log` | 它认为自己有没有权限 |

**这次就是靠它才发现"TCC 显示已授权，但服务压根没启动"** ——
光看设置界面永远查不出来。

---

## 放行条件

| 条件 | 说明 |
|---|---|
| `touch "…/v2rayN/allow-quit"` | 永久逃生舱，存在就直接放行 |
| 没有任何受保护进程 | 没程序在用网，退出不影响什么 |
| TUN 没开 | 代理本就没生效，不该拦 |

## 已知取舍

1. **必须是原生代码。** `osascript` 做不到拦截键盘 —— 它只能显示对话框，
   而那时 v2rayN 已经退出了。所以 `install.sh` 用 `swiftc` 现场编译，
   没有 Xcode Command Line Tools 就装不了（`xcode-select --install`）。
2. **只拦 Cmd+Q。** 菜单里的 Exit、Dock 右键退出、`killall` 都不经过按键事件，
   拦不到。这符合"防手误"的定位：手误基本都是快捷键，走菜单是明确意图。
3. **`swiftc` 编译出的二进制必须签名**，否则每次重编译都会让辅助功能授权失效
   （见弯路 3.2）。
4. `run-tun.sh` 的 `GRACE` 是 8 秒 —— 纯粹是防抖（给 v2rayN 崩溃后自动重启留个
   窗口），不再需要兜住"关掉再拉起来"那套。
