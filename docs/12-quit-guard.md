# 12 · 误退出保护（quit-guard）

## 问题

v2rayN 本身**没有"退出确认"设置**（`guiNConfig.json` 的全部键、`UiItem`/`GuiItem`
等嵌套项都查过）。而 macOS 的 `Cmd+Q` 是**系统级退出**，第三方无法拦截。

结果就是：正在下载或跟 ChatGPT 对话时手一抖按到 `Cmd+Q`，TUN 被撤、代理断掉，
所有连接一起失败。

## 为什么不能"拒绝退出"

逻辑上做不到拦截 —— 我们是外部进程，只能**事后补救**。所以目标不是"不让它退出"，
而是**让退出的代价降到零**：

```
你按 Cmd+Q
   ↓
quit-guard 检测到 v2rayN 消失（轮询 1 秒）
   ↓
弹确认窗口：需要【按住按钮 8 秒】才放行
   ├─ 长按满 8 秒  → 确认退出
   ├─ 松手 / 点取消 → 取消
   └─ 12 秒无操作  → 超时取消
   ↓
取消 → 立刻把 v2rayN 拉回来
```

**关键在时序**：`run-tun.sh` 有一个 `GRACE=20` 秒的宽限期 —— 代理掉线后不立刻
撤 TUN，先等 20 秒。而弹窗最长只持续 12 秒，所以：

> TUN 从来来不及被撤掉，v2rayN 就已经回来了。**网络中断 = 0 秒。**

实测（`sing-box` 的 pid 全程没变，说明 TUN 一次都没重建）：

```
 2 秒: TUN=up  v2rayN=no   sing-box=39654   -         ← 检测到退出
 4 秒: TUN=up  v2rayN=no   sing-box=39654   弹窗中     ← 弹窗出现
 …
18 秒: TUN=up  v2rayN=no   sing-box=39654   弹窗中
20 秒: TUN=up  v2rayN=yes  sing-box=39654   -         ← 自动恢复
```

## 组件

| 文件 | 作用 |
|---|---|
| `daemon/quit-guard.sh` | 看门狗本体，常驻运行 |
| `daemon/quit-guard-dialog.swift` | 确认窗口（长按进度条 + 倒计时），`install.sh` 用 `swiftc` 现场编译 |
| `launchd/com.local.v2rayn-quitguard.plist` | 用户级 LaunchAgent（`KeepAlive`） |
| `run-tun.sh` 的 `GRACE` | TUN 撤除宽限期，配合看门狗做到零中断 |

## 为什么是 LaunchAgent 而不是 LaunchDaemon

- 需要**弹窗** → 必须跑在用户的 GUI 会话里（`LimitLoadToSessionType: Aqua`）
- 需要 `open -a v2rayN` → 必须以用户身份启动
- 需要检测用户进程 → 同会话才准

## 状态机（这是最容易写错的地方）

```
ARMED=1   正在保护。v2rayN 消失就按上面的流程处理。
ARMED=0   刚放行过一次退出。此时【绝不】再拉回 v2rayN。
```

`ARMED=0` 这一条是必需的 —— 少了它就变成"**永远退不出去**"：你确认退出 →
看门狗又把它拉起来 → 你再退出 → 再拉起来，死循环。状态存在
`/tmp/v2rayn-quitguard.state`，所以 launchd 重启脚本也不会误判。

等 v2rayN **自己**重新运行（你手动打开），才回到 `ARMED=1`。

## 受保护进程

用 `pgrep -x` 精确匹配**主进程名**，不会误命中 `Google Chrome Helper` 之类的子进程：

- **终端**：Terminal / iTerm2 / Warp / kitty / WezTerm / Alacritty / Hyper / Tabby / ghostty
- **浏览器**：Safari / Google Chrome / Firefox / Edge / Arc / Brave / Vivaldi / Opera
- **AI 应用**：ChatGPT / Claude / Perplexity / Cursor / LM Studio
- **浏览器装的 App（PWA）**：以 `--app=` 或 `--app-id=` 启动的独立窗口。
  这类窗口没有独立进程名，只能从命令行参数识别。

要增删名单，改 `quit-guard.sh` 顶部的三个数组。

## 三种退出方式

| 方式 | 结果 |
|---|---|
| 直接 `Cmd+Q` | 弹窗，长按 8 秒才放行；否则自动恢复代理 |
| 弹窗里长按 8 秒 | 确认退出 |
| `touch "…/v2rayN/allow-quit"` | 直接放行，不再拦截（永久逃生舱） |

**`TUN 没开时不拦截** —— 代理本来就没生效，退出不影响任何东西。这条避免了
"只想关掉 v2rayN 却被拦"的无谓打扰。

## 已知取舍

1. **真的要退出时会多等 `GRACE` 秒**（20 秒）网络才恢复直连。这段窗口里流量
   进 TUN 却没有出口，等于断网。`GRACE` 不能设太大。
2. **弹窗会抢焦点**。这是刻意的 —— 长按确认需要你的注意力，才叫"防手误"。
3. **`swiftc` 不可用时自动回退** 到 `osascript` 静态对话框（功能等价，只是没有
   长按进度条）。装 Xcode Command Line Tools 即可：`xcode-select --install`。
