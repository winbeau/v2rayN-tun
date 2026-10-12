# 已知问题与踩坑记录

按「症状 → 根因 → 解法」组织。**每条都是实际发生过的**，不是通用清单。

---

## 1. TUN 静默失效，每次都要重新输密码

**症状**：明明勾了 TUN，重启客户端后 TUN 不见了，且没有任何报错。

**根因**：v2rayN 7.x 在 macOS 上每次启动强制关闭 TUN：

```csharp
if (_config.TunModeItem.EnableTun && AllowEnableTun())
    EnableTun = true;
else
    _config.TunModeItem.EnableTun = EnableTun = false;

private bool AllowEnableTun() {
    else if (Utils.IsMacOS())
        return AppManager.Instance.LinuxSudoPwd.IsNotEmpty();
}
```

`LinuxSudoPwd` 是**纯内存变量**，全代码库只有密码输入框会赋值、**从不从配置读取**。

**解法**：不要试图让 v2rayN 自己开 TUN，用外部 root 守护进程接管。

**走过的弯路**：改 `run_as_sudo.sh` —— 没用，它由
`CoreAdminManager.RunProcessAsLinuxSudo()` **每次启动 TUN 时重新生成**。

---

## 2. 假 IPv6 与 DNS 污染（Bug A）

**症状**：`www.google.com` 的 AAAA 返回 `2001::1`；A 记录返回 Twitter 的 IP 段。

**走过的弯路**：以为是 sing-box 的 DNS 返回的。

**实际**：`dig +short A www.google.com @223.5.5.5` 返回真实地址，而走系统解析器返回污染结果
—— 说明污染来自**系统解析器走的那个 DNS**。

```bash
scutil --dns | grep -E 'nameserver|if_index'
#   nameserver[0] : 2001:db8:cafe::53    ← 与本机同网段
#   nameserver[1] : 10.20.30.55              ← 网关, 同网段
```

**两个 DNS 都是 on-link** → 流量走链路直连、**根本不进 TUN** → 绕过 DNS 劫持。

> **关键认知**：`hijack-dns` 只对**进入 TUN 的**查询生效。
> 同网段流量永远不会进来，所以拦不住。
> 判断标准是「**目标是否与本机同网段**」，不是「目标是谁」。

**解法**（三处，缺一不可）：

| 改动 | 原因 |
|---|---|
| 系统 DNS → 公网地址（如 `223.5.5.5` `119.29.29.29`）| 不再是 on-link，查询会走默认路由进 TUN |
| TUN 增加 IPv6 地址 + `{"ip_cidr":["::/0"],"action":"reject"}` | 让 IPv6 被捕获后快速失败，而不是泄漏 |
| DNS `strategy: ipv4_only` | 从源头不返回 AAAA |

第 2 条用 reject 而非代理，依据是实测**节点无 IPv6 能力**（经代理请求 IPv6 出口返回的仍是 IPv4）。
reject 能让应用立刻回退 IPv4，避免超时等待。

**连带发现**：开 TUN 时如果只配 IPv4 地址，**IPv6 会完全绕过代理裸奔**：

```bash
curl -6 https://api64.ipify.org    # 返回本机 en0 的真实 IPv6
```

这个比原问题更严重，而且在排查原问题时才顺带发现。

---

## 3. 切网后 sing-box 出站绑定失效（Bug B）⭐

**症状**：切网后**所有直连出站失败**。表现五花八门，极易误判方向：

- 微信发消息转圈、截图发不出去
- 程序报传输错误（本项目里是 DSH 反复重试 `TRANSPORT`）
- 部分国内网站打不开

**根因**：sing-box 在**启动时**探测网络接口并确定出站绑定，之后网络怎么变它都不知道。
旧地址消失后它仍用它发包：

```
ERROR write udp 10.20.30.160:56026->119.29.29.29:53:
      write: can't assign requested address
```

当时 en0 已经是 `192.168.1.25`，而 sing-box 仍在用 `10.20.30.160`。

**走过的弯路**：

1. 归因于「用户切热点」—— 方向对了一半，机制完全错。以为是切换瞬间的抖动，
   没意识到**故障会持续存在**。
2. 怀疑 DNS / 路由 / 代理规则 —— 全部排除。
3. **「确认绑定是正确的」就结案** —— 但那一刻网络刚切换完、守护已重启，
   看到的是好的。**没在故障发生时取数。**

**转折点**：用户说「是不是你网络切换时候没有切换干净」—— 直接指向真因。

**解法**：记录主接口地址，变化则重启 TUN，让 sing-box 重新绑定。60 秒防抖。

实测切换后 **11 秒自动恢复**。

---

## 4. `launchctl bootout` 是异步的

**症状**：重复执行安装脚本时守护加载失败：

```
Bootstrap failed: 5: Input/output error
```

**根因**：`bootout` 是异步的，旧实例（及其子进程）需要时间退出，
紧接着 `bootstrap` 会被 launchd 拒绝。

**解法**：

```bash
# 1. 全部 bootout
for p in $SERVICES; do launchctl bootout "system/$p" 2>/dev/null || true; done
# 2. 轮询等待实例真正消失 (最多 30 秒)
for _ in $(seq 1 30); do
    still=""
    for p in $SERVICES; do launchctl print "system/$p" >/dev/null 2>&1 && still=1; done
    [ -z "$still" ] && break
    sleep 1
done
# 3. bootstrap 带重试
for try in 1 2 3 4 5; do launchctl bootstrap system "$PLIST" 2>/dev/null && break; sleep 2; done
```

**弯路**：日志里先看到 `Caller not allowed ... uid = 501`，差点被带偏 ——
那是以**非 root 身份手动测试**留下的记录，与安装脚本无关。
**看 launchd 日志要核对失败者的 uid/euid。**

---

## 5. root 无法操作用户的 GUI domain

**症状**：`sudo -u <user> launchctl load -w <plist>` **静默失败**，登录项没装上。

**解法**：用 `gui/<uid>` domain：

```bash
launchctl bootstrap "gui/$(id -u "$TARGET_USER")" "$PLIST"
```

---

## 6. `lsof` 看不到 root 进程的连接

sing-box 以 root 运行，普通用户看不到它的 fd，`lsof -p <pid>` 结果**恒为空**。
用它推断「没有连接」会得出完全错误的结论。

用 `netstat` 代替（见 [triage.md](triage.md) 的源端口比对法）。

---

## 7. 应用签名与 Gatekeeper

**症状**：应用提示「已损坏，应移到废纸篓」。

**这是两个独立问题**，只修一个不够：

| 问题 | 表现 |
|---|---|
| 隔离标记 `com.apple.quarantine` | Gatekeeper 拦截（经 AirDrop/LocalSend/浏览器传输的文件会被自动打上）|
| 签名损坏 | **即使绕过 Gatekeeper，Apple Silicon 也会直接 `Killed: 9`** |

```bash
xattr -dr com.apple.quarantine /Applications/Foo.app
# 先签内层可执行文件与 dylib, 再签整个 bundle
codesign --force --sign - <嵌套二进制与 dylib>
codesign --force --deep --sign - /Applications/Foo.app
```

`spctl -a` 对 adhoc 签名仍显示 `rejected` 是正常的，**不影响启动**。

**附带坑**：`/usr/bin/strings` 是 Xcode CLT 的 shim，会触发**无关的安装弹窗**。
替代方案：

```bash
tr -d '\0' < binary | grep -aoE '[ -~]{4,120}' | grep -i keyword
```

---

## 8. `sing-box rule-set match` 必须带 `-f binary`

漏掉 `-f binary` 会报 `invalid character 'S' looking for beginning of value`。
更隐蔽的是：如果吞掉错误继续跑，**全部 IP 都会被判定为「未命中」**（包括明确的国内 IP），
从而得出完全相反的结论。

```bash
sing-box rule-set match -f binary rules/geoip-cn.srs 183.47.121.90
```

---

## 9. macOS 26.4+ 会 SIGKILL 掉 adhoc 签名的二进制 ⚠️

**症状**：守护进程日志只留下这一行，没有任何错误输出：

```
TUN 已启动 sing-box pid=19032 (mtu=default)
sing-box 立即退出, 请检查上方错误输出
```

手动执行也没有输出、没有报错：

```bash
$ sudo /usr/local/libexec/v2rayn-tun/sing-box version
$ echo $?
137          # 128+9 = 被 SIGKILL
```

**极易误判**：`codesign -v` 显示 `valid on disk` / `satisfies its Designated Requirement`，
`xattr` 没有任何隔离标记，文件权限也正常。**从表象完全看不出是签名问题。**

**真正的证据在崩溃报告里**：

```bash
sudo ls -t /Library/Logs/DiagnosticReports/sing-box* | head -1
```

```
"exception"   : {"type":"EXC_CRASH","signal":"SIGKILL (Code Signature Invalid)"}
"termination" : {"namespace":"CODESIGNING","indicator":"Taskgated Invalid Signature"}
```

**触发条件**：`cp` 覆盖一个**已存在**的 adhoc 签名二进制。macOS 26.4 起
taskgated 会缓存该路径的签名判定，覆盖后缓存与实际文件不匹配，于是直接杀掉进程。

**解法**（`install.sh` 已内置）：

```bash
# 1. 先停守护, 否则文件被占用, cp/codesign 会报 Permission denied 或 Text file busy
launchctl bootout system/com.local.v2rayn-tun
sleep 2; pkill -f 'v2rayn-tun/sing-box'

# 2. 删掉再复制 —— 换 inode 可以让 taskgated 的旧缓存失效
rm -f /usr/local/libexec/v2rayn-tun/sing-box
cp "<v2rayN 的 sing-box>" /usr/local/libexec/v2rayn-tun/sing-box

# 3. 重新 adhoc 签名 (关键步骤)
codesign --force --sign - /usr/local/libexec/v2rayn-tun/sing-box

# 4. 必须验证能执行, 而不是只看 codesign 的输出
/usr/local/libexec/v2rayn-tun/sing-box version
```

**教训**：

1. **`codesign -v` 通过 ≠ 能执行。** 唯一的判据是**真的跑一下**。
2. **"进程立即退出且无输出"优先怀疑签名**，不要在看到 `codesign -v` 的
   `valid on disk` 之后就排除它。
3. **崩溃报告在 root 的目录**（`/Library/Logs/DiagnosticReports/`），
   不在 `~/Library/Logs/DiagnosticReports/` —— 守护进程以 root 运行时看前者。
4. `do shell script` **不加 `with administrator privileges` 就是普通用户**，
   排查权限问题时漏掉这个会得出完全错误的结论（本项目就把"权限不足"
   误判成了"系统卷已密封只读"）。

---

## 10. 退出 v2rayN 后 DNS 会残留

**症状**：退出 v2rayN 后 TUN、路由、系统代理都干净了，但
`networksetup -getdnsservers Wi-Fi` 还是 `223.5.5.5 119.29.29.29`。

**原因**：改 DNS 是为了让查询跟随默认路由进 TUN（on-link 的 DNS 会绕过劫持）。
TUN 不在了这个改动就失去意义，但没人把它改回去。

**解法**：`dnsguard.sh` 在改 DNS 前先把原值记到
`/usr/local/libexec/v2rayn-dnsguard/origdns`，检测到代理端口下线时还原：

```
代理端口 10808 已下线 -> 还原 DNS「Wi-Fi」为原值: Empty
```

「Empty」即 macOS 的"自动"，由 DHCP/RA 下发。另外 `run-tun.sh` 撤掉 TUN 时会
主动 `kickstart` 网络守护，让还原立即发生，而不是等下一次 30 秒轮询。

**注意**：只有在当前 DNS 仍等于我们设的值时才还原，避免覆盖用户后来手动改的设置。

---

## 11. Cmd+Q 拦截器的 TCC 授权连环坑 ⚠️⚠️

这是本项目**代价最大**的一组问题：功能本身不复杂，但因为一个更基础的前提假设
错了（"重编译不影响授权"），导致用户被迫反复授权五六轮，最后演变成
「授权框反复弹出、点了还有」。

### 11.1 反复弹授权框（最典型的表现）

**症状**：系统不断弹出

```
"quit-guard" would like to control this Mac and access your data.
```

用户每次点击后，**在新位置又出现一个新的**，无止境。

**三个叠加的原因**：

1. **代码里调了 `AXIsProcessTrustedWithOptions(prompt: true)`** —— 这个 API
   会主动弹框。配合 LaunchAgent 的 `KeepAlive=true`（没权限就退出 → launchd
   立刻重启 → 又弹）就是无限循环。

   更糟：那个框的默认按钮是 **`Deny`**（蓝色高亮），反复弹出时用户很容易
   顺手点掉，TCC 就记下拒绝，之后一直授权失败。

   **修法**：只用不带 prompt 的 `AXIsProcessTrusted()` 静默查询；没权限就
   安静 `exit(0)`，靠 `ThrottleInterval=60` 限制重试。**绝不主动弹窗。**

2. **adhoc 签名下，重编译必然让授权失效**（见 11.2）。

3. **弹框进程可能卡住不走**，即使触发它的程序已经退出：

   ```bash
   killall universalAccessAuthWarn      # 关掉卡住的对话框
   ```

   `/System/Library/PrivateFrameworks/UniversalAccess.framework/.../universalAccessAuthWarn.app`
   就是显示那个框的进程（由 `WindowServer` 代为请求）。

### 11.2 adhoc 签名的二进制，TCC 授权绑 CDHash

```
adhoc 签名:  designated => identifier "quit-guard" and cdhash H"c8284874..."
                                              ^^^^^^ 每次重编译都变
证书签名:    designated => identifier "com.local.v2rayn.quitguard"
                           and certificate root = H"c61c98d8..."
                           ^^^^^^^^^^^^^^^^ 稳定
```

没有签名证书时（`security find-identity` 显示 `0 valid identities found`），
**每次重新编译都等于换了一个程序，授权立即失效**。

**先跑 `scripts/setup-signing-cert.sh` 再动代码。** 该脚本的坑：

| 步骤 | 坑 |
|---|---|
| `openssl pkcs12 -export` | **必须加 `-legacy`**。OpenSSL 3/4 的新默认算法 macOS 不认，报 `MAC verification failed (wrong password?)` —— 密码其实是对的，极易误判 |
| `security import -P <密码>` | **空密码 macOS 不接受**，报同样的误导性错误 |
| `security add-trusted-cert` | **必须用用户级域（不加 `-d`）**。用系统域会报 `authorization was denied since no user interaction was possible` —— 即使用 sudo/osascript 提权也过不去，trustd 要求交互式授权 |

验证：

```bash
codesign -d -r- /usr/local/libexec/v2rayn-tun/quit-guard
# 期望 certificate root = H"..."，而不是 cdhash H"..."
```

### 11.3 排查靠 tccd 日志，不要靠设置界面

```bash
# 授权变更与判定
log show --last 20m --predicate 'subsystem == "com.apple.TCC"' --style compact | grep -i quit-guard

# 它请求过哪些服务 —— 用来发现"意外的权限请求"
log show --last 30m --predicate 'subsystem == "com.apple.TCC"' --style compact \
  | grep "quit-guard" | grep -oE "service=kTCCService[A-Za-z]+" | sort | uniq -c
```

关键信号：

```
Failed to match existing code requirement for subject ... and service ...
```

→ 记录与当前二进制对不上，**授权已失效**。看到它就该重新添加，
而不是怀疑别的地方。

**三边对齐才能定位**：

| 看哪里 | 命令 |
|---|---|
| TCC 记录 | `log show ... \| grep quit-guard` |
| 二进制身份 | `codesign -dv --verbose=4 <二进制> \| grep CDHash` |
| 程序自述 | `~/Library/Logs/v2rayn-quitguard.log` |

本项目就是靠这个才发现「TCC 显示已授权，但服务压根没启动」——
光看设置界面永远查不出来。

### 11.4 `tccutil reset` 不要全局跑

```bash
tccutil reset Accessibility                       # ✗ 清掉【所有应用】的授权!
tccutil reset Accessibility <bundle-id>           # ✓ 精确
```

裸可执行文件没有 bundle id，带标识会报 `No such bundle identifier` ——
**但即便如此也不要直接全局重置**：它会清掉终端本身的授权，直接导致
`osascript is not allowed assistive access (-25211)`，整机自动化工具全废。

**优先手动在设置里删除条目，全局重置是最后手段。**

### 11.5 事件回调绝不能阻塞

`CGEventTap` 的回调卡住会冻住**整个系统**的键盘输入，不只是目标应用。

```swift
// ✗ 在回调里 sem.wait() 等弹窗结果 —— 最长冻 12 秒
// ✓ 回调只判断后立刻返回, 处理丢后台队列
//   需要"放行"时用 postToPid 重发事件, 并带 eventSourceUserData 标记,
//   否则会被自己的 tap 再拦一次 -> 死循环
```

### 11.6 `NSWorkspace.runningApplications` 会触发完全磁盘访问

TCC 日志统计（修复前）：

```
14 次  kTCCServiceAccessibility          辅助功能      ← 需要的
 4 次  kTCCServiceSystemPolicyAllFiles   完全磁盘访问  ← 不需要!
```

`NSWorkspace.shared.runningApplications` **枚举系统里所有 App**，包括
`/System/Applications` 下受 SIP 保护的应用包 → 触发 FDA 检查 → 系统弹
「想控制这台 Mac 并访问你的数据」。

**改成按 bundle id 定向查询**：

```swift
NSRunningApplication.runningApplications(withBundleIdentifier: bid)
```

### 11.7 模板 plist 的占位符

```
launchd: Service could not initialize: Unable to create stdout directory
         (//__USER_HOME__/Library/Logs/v2rayn-quitguard.err)  →  last exit code = 78: EX_CONFIG
```

手工恢复配置时别直接 `cp` 模板 —— `install.sh` 里用
`sed "s|__USER_HOME__|$TARGET_HOME|g"`，从脚本里抄。
