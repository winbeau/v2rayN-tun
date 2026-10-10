# 01 · v2rayN 报「已损坏，应移到废纸篓」

**现象**：双击 v2rayN 无法打开，系统提示应将它移到废纸篓。用户描述为"因为三方权限，一打开就让我搞进废纸篓"。

## 弯路

一开始以为是权限/Dock 相关的问题，方向错了。实际是两个**互相独立**的问题叠加。

## 诊断

```bash
# 1. 隔离标记：整个 bundle 内每个文件都带，来源戳显示 LocalSend
xattr -lr /Applications/v2rayN.app | head
#   v2rayN.app/Contents/MacOS/v2rayN: com.apple.quarantine: 0182;...;LocalSend;

# 2. 签名完整性
codesign -v --verbose=2 /Applications/v2rayN.app
#   code has no resources but signature indicates they must be present
```

| 问题 | 表现 |
|---|---|
| 隔离标记 | 经 LocalSend/AirDrop/浏览器传输的文件会被自动打上 `com.apple.quarantine`，Gatekeeper 因此拦截 |
| 签名损坏 | adhoc 签名但封印不匹配。**即使绕过 Gatekeeper，Apple Silicon 也会直接 `Killed: 9`** |

## 解决

```bash
xattr -dr com.apple.quarantine /Applications/v2rayN.app

# 先签内层可执行文件与 dylib，再签整个 bundle
codesign --force --sign - <xray / sing-box / mihomo / *.dylib / AmazTool>
codesign --force --deep --sign - /Applications/v2rayN.app
```

验证：`valid on disk` + `satisfies its Designated Requirement`。

## 要点

- `spctl -a` 仍会显示 `rejected` —— 这是 adhoc 无公证的正常结果，**隔离标记清掉后它不再影响启动**，不必当成失败。
- 只做第 1 步不够：签名损坏会让进程被内核直接杀掉，表现为"闪退"而非"打不开"。

## 附带踩坑

排查时用 `/usr/bin/strings` 触发了一个**无关的 Xcode 命令行工具安装弹窗**（该命令是 CLT 的 shim）。

替代方案（不需要 CLT）：

```bash
# .NET 程序的字符串是 UTF-16，先去掉 NUL 字节再 grep
tr -d '\0' < binary | grep -aoE '[ -~]{4,120}' | grep -i keyword
```
