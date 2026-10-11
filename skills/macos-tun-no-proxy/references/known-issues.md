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
#   nameserver[0] : 2408:847a:716:2130::6d    ← 与本机同网段
#   nameserver[1] : 10.236.42.55              ← 网关, 同网段
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
ERROR write udp 10.236.42.160:56026->119.29.29.29:53:
      write: can't assign requested address
```

当时 en0 已经是 `192.168.5.25`，而 sing-box 仍在用 `10.236.42.160`。

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
