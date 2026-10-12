# 12 · 误按 Cmd+Q 保护（quit-guard）

## 问题

v2rayN 没有"退出确认"设置（`guiNConfig.json` 全部键、`UiItem`/`GuiItem` 等嵌套项
都查过）。macOS 的 `Cmd+Q` 是系统级退出，应用自己不做确认就没有确认。

结果：正在下载或跟 ChatGPT 对话时手一抖，TUN 被撤、连接全断。

## 走过的弯路

**第一版做成了"检测到退出后把 v2rayN 拉回来"。** 这是错的设计，两个硬伤：

1. **v2rayN 真的关过一次** —— 进程重建、窗口重建、连接重建。靠 `run-tun.sh`
   的宽限期只是让 TUN 没来得及撤，应用本身的中断是实打实的。
2. **和 `GRACE` 强耦合** —— 宽限期必须大于弹窗超时，`GRACE` 被迫拉到 20 秒。
   而这段窗口里流量进 TUN 却没有出口，等于断网；真要退出时得等 20 秒才恢复直连。

**正确做法是在按键阶段就拦下来**，让 v2rayN 根本收不到 `Cmd+Q`。
它不退出，就不存在"重建"这回事。

## 现在的实现

用 `CGEventTap` 在系统事件流里拦截按键。交互是**一个手势**：按住 Cmd+Q。

```
按住 Cmd+Q（v2rayN 在前台）
   ↓
全屏灰屏糊化 + 红色粗进度条, 随按住时长从左到右填充
   ├─ 松手            → 淡出取消, v2rayN 继续运行（什么都没发生）
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
- 进度条：玫红 → 正红 → 橙红渐变 + 红色发光 + 上半高光，60fps 渲染 + 轻微缓出
- 层级：`level = .screenSaver` 盖住 Dock 和菜单栏；`ignoresMouseEvents = true`

**关键点：v2rayN 的进程从始至终没有变化。** 实测（按住 3 秒后松手）：

```
v2rayN pid: 42993 -> 42993
日志: 拦截 Cmd+Q: 受保护进程 [Terminal]
      按住 3.0 秒后松手 -> 取消, v2rayN 全程未退出
```

## 三个必须写对的点

### 1. 事件回调绝不能阻塞

`CGEventTap` 的回调如果卡住，**冻住的是整个系统的键盘输入**，不只是 v2rayN。

所以回调里只做极快的判断然后立刻返回，弹窗和后续处理全部丢到后台队列。
需要"放行"时用重发事件的方式补回去：

```swift
original.setIntegerValueField(.eventSourceUserData, value: EVENT_MARKER)
original.postToPid(v2raynPID)
```

**重发必须带标记**，否则会被自己的 tap 再拦一次 —— 死循环。

（第一版就踩了这个坑：在回调里用 `sem.wait()` 等弹窗结果，那会把整机键盘冻住
最长 12 秒。）

### 2. 只对 v2rayN 生效

```swift
guard keycode == KEYCODE_Q, event.flags.contains(.maskCommand) else { 放行 }
guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "2dust.v2rayN" else { 放行 }
```

对照实测（TextEdit 在前台按 Cmd+Q）：

```
TextEdit pid: 41178 -> 已退出      ← 正常退出
拦截次数:     2 -> 2               ← 拦截器完全没插手
```

### 3. 受保护应用用 Bundle ID，不用进程名

```swift
let PROTECTED_BUNDLE_IDS: Set<String> = [
    "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", …
    "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", …
    "com.openai.chat", "com.anthropic.claudefordesktop", …
]
```

用 `NSWorkspace.runningApplications` 按 bundle id 匹配，比 `pgrep` 精确，
不会误命中 `Google Chrome Helper` 之类的子进程。

**浏览器装的 App（PWA）不需要单独处理** —— 它仍然是浏览器主进程在跑，
列了浏览器就覆盖了。

## 硬前提：辅助功能权限

**macOS 不允许没有辅助功能（Accessibility）权限的程序拦截键盘事件。** 没有它
`CGEventTap` 直接创建失败。

首次启动时程序会调 `AXIsProcessTrustedWithOptions(prompt: true)` 弹出系统提示并
把注册项加进列表。**需要在「系统设置 → 隐私与安全性 → 辅助功能」里手动勾选**：

```
/usr/local/libexec/v2rayN-tun/quit-guard
```

勾选后重启服务：

```bash
launchctl kickstart -k gui/$(id -u)/com.local.v2rayn-quitguard
```

实测观察到一个细节：第一次启动报"未授权"，10 秒后 launchd 的 `KeepAlive` 把它
重启，这次就显示"已授权"并且 tap 创建成功 —— 系统提示本身会触发注册。
如果一直起不来，去设置里检查那一项。

## 为什么是 LaunchAgent

- `CGEventTap` 作用于**当前登录会话** → 必须在 GUI 会话里
- 要弹窗、要读用户目录下的开关文件
- 辅助功能权限是按「用户 + 程序」授予的，系统级守护进程拿不到

## 放行条件（两个）

| 条件 | 说明 |
|---|---|
| `touch "…/v2rayN/allow-quit"` | 永久逃生舱，存在就直接放行 |
| 没有任何受保护进程 | 没程序在用网，退出不影响什么，没必要拦 |

## 已知取舍

1. **必须是原生代码。** `osascript` 做不到拦截键盘 —— 它只能显示对话框，
   而那时 v2rayN 已经退出了。所以 `install.sh` 用 `swiftc` 现场编译，
   没有 Xcode Command Line Tools 就装不了（`xcode-select --install`）。
2. **弹窗会抢焦点。** 刻意的 —— 长按确认需要你的注意力，才叫"防手误"。
3. **只拦 Cmd+Q。** 菜单里的 Exit、Dock 右键退出、`killall` 都不经过按键事件，
   拦不到。这符合"防手误"的定位：手误基本都是快捷键，走菜单是明确意图。
4. `run-tun.sh` 的 `GRACE` 已调回 8 秒 —— 它现在纯粹是防抖（给 v2rayN 崩溃后
   自动重启留个窗口），不再需要兜住"关掉再拉起来"。

---

## 踩过的三个坑（都在这一版修掉了）

### 坑 1：未授权时退出 -> 弹窗无限循环

最初写的是"没权限就 `exit(2)`"。而 LaunchAgent 配了 `KeepAlive=true` —— launchd
立刻把它重启，每次启动又调一次权限请求，**系统弹窗无限循环**。

更糟的是那个弹窗的默认按钮是「**Deny**」（蓝色高亮）。反复弹出时很容易顺手点掉，
TCC 就记下拒绝，之后一直授权失败。

**现在**：未授权时**留在原地**每 2 秒重试，拿到权限立刻继续，全程不需要重启服务。
弹窗只出现一次。

### 坑 2：计时器在模态循环里不触发

第一版用 `NSApp.runModal` 显示窗口，而 `Timer.scheduledTimer` 注册在 `.default`
run loop 模式 —— **模态循环跑的是 `.modalPanel` 模式，计时器根本不触发**。

实测表现为"12 秒超时"实际 47 秒才触发，而且**长按检测也是坏的**（同一个机制）。

**现在**：全部改成 `RunLoop.current.add(timer, forMode: .common)`，
并且新版没有模态循环。

### 坑 3：重新编译会让辅助功能授权失效

TCC 的授权绑定二进制的 **CDHash**。这个二进制是 adhoc 签名、没有 Team ID
（`security find-identity` 显示 `0 valid identities found`），
**重新编译等于换了一个程序**，授权立即失效。

**现状**：`install.sh` 会比对源码哈希，没变就跳过编译：

```
✓ 源码未变, 保留现有二进制 (避免让辅助功能授权失效)
```

**彻底解法**（未做）：用自签名证书给二进制签名。那样 TCC 基于证书而非 CDHash，
重编译也不失效。需要动钥匙串，属于可选优化。

### 排查这类问题的正确方法

**看 TCC 的系统日志**，它会把每一次授权变更都记下来：

```bash
log show --last 10m --predicate 'subsystem == "com.apple.TCC"' --style compact \
  | grep -i "quit-guard"
```

输出形如：

```
05:27:41  Publishing <TCCDEvent: type=Modify, service=kTCCServiceAccessibility,
                       identifier_type=Path, identifier=/usr/local/libexec/.../quit-guard>
05:27:49  Publishing <TCCDEvent: type=Delete, ...>     ← 删掉旧的
05:27:53  Publishing <TCCDEvent: type=Modify, ...>     ← 重新添加
```

**比在设置界面里反复点有用得多** —— 它能直接告诉你授权是"成功了但程序没跑"，
还是"根本没记录"。

对照一下二进制自身的身份：

```bash
codesign -dv --verbose=4 /usr/local/libexec/v2rayn-tun/quit-guard 2>&1 | grep CDHash
```

以及程序的自我报告（`~/Library/Logs/v2rayn-quitguard.log`）：

```
=== quit-guard 启动: 尚未获得辅助功能权限 ===     ← 它认为自己没权限
event tap 已启用: 只有 v2rayN 在前台时…          ← 它认为自己有权限
```

**三边对齐才能定位问题。** 这次就是"TCC 显示已授权，但服务压根没启动" ——
光看设置界面永远查不出来。
