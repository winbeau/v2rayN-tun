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

用 `CGEventTap` 在系统事件流里拦截按键：

```
你按 Cmd+Q（v2rayN 在前台）
   ↓
CGEventTap 回调
   ├─ 不是 Cmd+Q            → 放行
   ├─ 前台不是 v2rayN        → 放行    ← 其他应用完全不受影响
   └─ 是 → 【立刻吞掉事件】并异步处理
             ├─ 有 allow-quit 开关 / 无受保护进程 → 原样重发, 正常退出
             └─ 有受保护进程 → 弹窗
                  ├─ 长按 8 秒   → 主动 terminate v2rayN
                  └─ 取消 / 12 秒超时 → 什么也没发生, v2rayN 一直开着
```

**关键差异：v2rayN 的进程从始至终没有变化。** 实测：

```
测试前 v2rayN pid: 39993
  ...按下 Cmd+Q...
测试后 v2rayN pid: 39993     ← 完全没变
TUN: 全程保持
```

日志：

```
05:11:28  event tap 已启用, 只在 v2rayN 为前台应用时拦截 Cmd+Q
05:11:42  拦截 Cmd+Q: 受保护进程 [Terminal]
05:12:29  用户取消 —— v2rayN 全程未退出
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
