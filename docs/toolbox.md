# 排查工具箱

本项目中真正用得上的命令与技巧。**每一条都是实际定位到问题时用过的**，不是通用清单。

---

## 1. 判断某个 IP / 域名会不会被判为国内

决定它走**直连**还是**走节点**，是排查分流问题的第一步。

```bash
SB=/usr/local/libexec/v2rayn-tun/sing-box
R=/usr/local/libexec/v2rayn-tun/rules

# IP（判断 geoip-cn）
$SB rule-set match -f binary "$R/geoip-cn.srs" 183.47.121.90
#   有 "match rules.[0]" 输出 = 命中 = 走直连

# 域名（判断 geosite-cn）
$SB rule-set match -f binary "$R/geosite-cn.srs" github.com

# 解出完整 CIDR 列表（调试用）
$SB rule-set decompile "$R/geoip-cn.srs" -o /tmp/geoip-cn.json
```

> ⚠️ **必须带 `-f binary`**。`.srs` 是二进制格式，默认按 JSON 解析会报
> `invalid character 'S' looking for beginning of value`。
> 我第一次跑时漏了这个参数，导致**全部 16 个 IP 都被判定为"未命中"**（包括明确的国内 IP），差点得出完全错误的结论。

---

## 2. 判断一条连接实际走的是直连还是节点 ⭐

最可靠的"源端口比对法"。**不依赖日志**（日志可能没开）。

```bash
# 1. 造一条到目标的连接并保持住
python3 -c "
import socket,time
s=socket.socket(); s.settimeout(5); s.connect(('183.47.121.90',80))
print('应用侧本地地址:', s.getsockname())   # 应显示 tun 地址 172.19.0.1:<port>
time.sleep(10); s.close()" &

# 2. 看 sing-box 为它建立的出站
netstat -an -f inet | grep "183.47.121.90.80" | grep ESTABLISHED
```

判读：

| 出站本地地址 | 含义 |
|---|---|
| `<en0 地址>:<同端口>` | **sing-box 直连** → 走 direct |
| `<节点 IP>` | **走了代理** |

> 这是本项目里最有用的技巧。它证明了两件关键事实：单条连接的真实路径，以及
> `auto_detect_interface` 是否正常工作（有无路由自环）。
>
> ⚠️ **不要用 `lsof -p <sing-box pid>`** —— sing-box 以 root 运行，普通用户看不到它的 fd，结果会是空的（我因此误判过好几次）。

---

## 3. 绕过 TUN 做对照实验

排查"是不是 TUN 造成的"时需要一个真基线。

```bash
# 绑定物理网卡（实测可绕过 TUN）
curl --interface en0 --noproxy '*' https://www.google.com/generate-204
#   超时 = 已绕过 TUN（是好基线）；成功 = 没绕过

# 绕过 sing-box 但保留代理（回环地址不进 TUN）
curl -x socks5h://127.0.0.1:10808 https://github.com
```

第 2 种用于**隔离 sing-box 这一层的开销**，非常好用。

---

## 4. 检查 sing-box 绑定是否已失效

网络切换后最隐蔽的故障（见 [04](04-network-switch-bugs.md)）。

```bash
# en0 当前地址
ifconfig en0 | awk '/inet /{print $2}'

# sing-box 出站实际使用的源地址
netstat -an -f inet | grep ESTABLISHED | grep -v 172.19.0.1 | grep -v 127.0.0.1

# 直接看日志里有没有源地址错误
grep "can't assign requested address" /var/log/v2rayn-tun.log
```

**两者不一致 = 绑定已失效**，重启 TUN 即可（正常情况网络守护会自动处理）。

---

## 5. 检查 DNS 是否真的走了隧道

```bash
scutil --dns | grep -E "resolver|nameserver|if_index"
networksetup -getdnsservers Wi-Fi          # 手动设置的值
```

判据不是"查询目标是谁"，而是**该目标是否与本机同网段**。同网段 = on-link = 绕过了 TUN。

```bash
# 验证假 AAAA
dig +short AAAA www.google.com             # 期望：空
dig +short A www.google.com                # 期望：真实 IP
```

---

## 6. 读 DSH 会话日志

会话日志是**多帧拼接的 zstd**（一个会话上千帧）。`zstdDecompressSync` 只解第一帧，流式解压也不出数据。

正确做法：**按魔数扫描逐帧解压**。

```javascript
import fs from 'node:fs'; import zlib from 'node:zlib';
const MAGIC = Buffer.from([0x28,0xb5,0x2f,0xfd]);
const buf = fs.readFileSync(path); const parts = []; let i = 0;
while ((i = buf.indexOf(MAGIC, i)) !== -1) {
  try { const o = zlib.zstdDecompressSync(buf.subarray(i)); if (o.length) parts.push(o); } catch {}
  i += 4;
}
const text = Buffer.concat(parts).toString('utf8');
```

```bash
# Node 24 自带 zstd；macOS 没有 zstd CLI
~/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/node/bin/node script.mjs
```

日志里的关键记录类型：`llm/retry`（含 `failure.code`，如 `TRANSPORT` / `TIMEOUT`）。

---

## 7. macOS 应用健康检查

```bash
# 隔离标记与签名（"已损坏"类问题）
xattr -lr /Applications/Foo.app | grep quarantine
codesign -v --verbose=2 /Applications/Foo.app

# 是否在 Dock（UIElement = 后台 agent，无 Dock 图标）
lsappinfo list | grep -A3 '"Foo"' | grep type

# 网络服务名 ↔ 接口映射
networksetup -listnetworkserviceorder | grep -B1 "Device: en0"

# 日志里核对发起者身份（区分"权限不足"与"竞态失败"）
log show --last 5m --predicate 'process == "launchd"' --style compact | grep -i "你的服务名"
```

---

## 8. 测性能：避开噪声陷阱

这台机器的链路抖动极大（同一配置三次测出 0.062 / 0.074 / 0.189），吃过亏。

- **串行测量** —— 并发跑两个测试会互相污染 CPU 计数（我曾因此把 14% 的改善误报成 59%）
- **取最小值而非中位数** —— 最小值最接近无干扰状态
- **先确认链路是否见顶** —— 4 并发总量 ≈ 单流总量，说明已是链路上限，此时测不出栈的开销
- **延迟要拆开看** —— `curl -w "%{time_namelookup} %{time_connect} %{time_appconnect}"`，`time_appconnect` 含 DNS，「TLS 慢」可能其实是「DNS 慢」

```bash
curl -s -o /dev/null -w "dns=%{time_namelookup} tcp=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer}\n" \
     --noproxy '*' --max-time 20 https://example.com
```

---

## 9. 用 launchctl 判断服务状态

```bash
launchctl print system/<label>          # 完整状态；state/pid/runs/last exit code
launchctl print-disabled gui/$(id -u)   # 是否被禁用
launchctl kickstart -k system/<label>   # 重启（改配置后用）
```

**周期性任务的 `state = not running` 是正常的**（两次运行之间就是空闲的），要看 `runs` 和 `last exit code` 才能判断它是否在正常工作。
