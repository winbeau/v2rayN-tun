# 02 · Dock 常驻 + TUN 免密

> **一句话**：v2rayN 把「每次必须输密码」写死在源码里 —— 改用独立 root 守护进程绕开。

两个诉求：让 v2rayN 常驻 Dock，以及 TUN 模式不再每次要密码。

## Dock 常驻（简单）

配置项 `UiItem.MacOSShowInDock`，默认 `false` —— 这是 v2rayN 在 macOS 的**设计行为**：不占 Dock，只驻留菜单栏。所以"关掉窗口后看起来没打开"不是 bug。

```bash
# 停掉 v2rayN 再改，否则退出时会覆盖
"$PY" -c "import json;p='.../guiNConfig.json';d=json.load(open(p));d['UiItem']['MacOSShowInDock']=True;json.dump(d,open(p,'w'),indent=2)"
```

验证方式（比截图可靠）：

```bash
lsappinfo list | grep -A2 '"v2rayN"' | grep type     # UIElement → Foreground
osascript -e 'tell application "System Events" to get name of every process whose background only is false'
```

## TUN 免密：先说结论 —— 改设置做不到

查源码（`v2rayN/ServiceLib/ViewModels/StatusBarViewModel.cs`）：

```csharp
// 构造函数：每次启动强制关掉 TUN
if (_config.TunModeItem.EnableTun && AllowEnableTun())
    EnableTun = true;
else
    _config.TunModeItem.EnableTun = EnableTun = false;

private bool AllowEnableTun()
{
    ...
    else if (Utils.IsMacOS())
        return AppManager.Instance.LinuxSudoPwd.IsNotEmpty();
}
```

`LinuxSudoPwd` 是**纯内存变量**（`AppManager.cs: public string LinuxSudoPwd { get; set; }`），全代码库只有密码框会赋值、**从不从配置读取**。

→ 每次启动都必须手动拨开关 + 输密码，否则 TUN 静默失效。

## 弯路：改 `run_as_sudo.sh` 没用

该脚本内容是 `exec sudo -S -- <sing-box> run -c <configPre.json>`，看起来改掉就行。

但它由 `CoreAdminManager.RunProcessAsLinuxSudo()` **每次启动 TUN 时重新生成**，改动不持久。

## 两条可行路线的取舍

| | A. sudoers NOPASSWD | B. 独立 root 守护进程（已采用） |
|---|---|---|
| 改动量 | 一条 `/etc/sudoers.d/` 规则 | 中等 |
| 免密程度 | 密码框仍需手动填一次（填任意字符即可通过） | 完全零交互 |
| 安全代价 | ⚠️ 被授权的 `sing-box` 和 `kill_as_sudo.sh` 都在**用户可写目录**，等于给账号开了免密 root 通道 | 资产归 root 所有，无提权面 |

选 B。**关键点是 B 不需要往 `/etc/sudoers.d/` 写任何东西。**

## 重要发现：v2rayN 的 TUN 架构自带最优解

读 `configPre.json`（v2rayN 生成的实际 TUN 配置）后发现：

```json
"outbounds": [
  {"type": "socks", "tag": "proxy", "server": "127.0.0.1", "server_port": 10808},
  {"type": "direct", "tag": "direct"}
],
"route": {"final": "proxy", ...}
```

**它自己就是 `TUN → socks → 127.0.0.1:10808 → xray`**，且**不含节点信息**。

→ 结论：**TUN 配置与节点无关**，可以做成静态的、由 root 长期托管；切换节点不需要动它。

## 路由环路如何规避

xray 去连节点的流量不能被 TUN 再吞一次，否则死循环。v2rayN 的做法是 `process_path`：

```json
{"outbound": "direct", "process_path": [
  "<home>/Library/Application Support/v2rayN/bin/xray/xray",
  "<home>/Library/Application Support/v2rayN/bin/sing_box/sing-box",
  "/usr/local/libexec/v2rayn-tun/sing-box"
]}
```

**实测该规则在 `stack: system` 下同样有效**（若失效，google 会因环路而完全打不开 —— 这正好是它的验证方法）。
