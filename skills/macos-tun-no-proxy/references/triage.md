# 排错工具箱

本 Skill 真正用上的技巧。**每一条都是实际定位到问题时用过的。**

---

## 1. 分层定位（第一原则）

**先证明问题不在本地，再往外查。**

```bash
CN=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 12 https://www.baidu.com)
```

- 国内**不通** → 本地配置/链路问题，**不要往外查**
- 国内通、国外不通 → 第 2 层（路径）或第 3 层（节点）

```bash
scripts/diagnose.sh --node-ip <IP> --sni <SNI>    # 自动跑完三层
```

### 第 2 层的正确工具是 `--interface`

```bash
curl -vsk -o /dev/null --interface en0 --max-time 12 \
     --resolve <SNI>:443:<节点IP> https://<SNI>/
```

`--interface` 设置 `IP_BOUND_IF`，**强制走指定网卡、绕过路由表**，完全跳过 TUN。

### 两个"假绕过"

```bash
# ✗ 绑定源地址 —— 不改变路由查找, 去节点的路由仍指向 TUN
python3 -c "import socket;s=socket.socket();s.bind(('192.168.5.25',0));s.connect((ip,443))"

# ✗ 用域名做对照 —— 非国内域名的 DNS 依赖代理, 代理一断就 connect=0.000000s
#    看起来像"网络不通", 实际是解析就没成功。必须用 IP。
```

### 第 3 层要分开看 TCP 和 TLS

```
* Connected to ... port 443     ← TCP 成功
* (304) (OUT), TLS handshake, Client hello (1):
* Connection timed out          ← TLS 零响应
```

| 结果 | 指向 |
|---|---|
| TCP 通、TLS 不通 | 节点被封 / 服务端进程挂死 |
| TCP 都不通 | 网络封锁或服务器宕机 |

---

## 2. 判断一条连接走的是直连还是代理 ⭐

**源端口比对法**。不依赖日志（日志可能根本没开）。

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

| 出站本地地址 | 含义 |
|---|---|
| `<en0 地址>:<端口>` | **直连**（走了 direct）|
| `<节点 IP>` | **走了代理** |

这是本项目最有用的技巧。它同时证明了单条连接的真实路径，
以及 `auto_detect_interface` 是否正常工作。

> ⚠️ **不要用 `lsof`** —— root 进程的 fd 普通用户看不到，结果恒为空。

---

## 3. 判断分流是否正确

```bash
SB=/usr/local/libexec/v2rayn-tun/sing-box
R=/usr/local/libexec/v2rayn-tun/rules

# IP 是否命中 geoip-cn (命中 = 走直连)
$SB rule-set match -f binary "$R/geoip-cn.srs" 183.47.121.90

# 域名是否命中 geosite-cn
$SB rule-set match -f binary "$R/geosite-cn.srs" github.com
```

**必须带 `-f binary`**（见 [known-issues.md](known-issues.md) 第 8 条）。

---

## 4. DNS 健康检查

```bash
scutil --dns | grep -E 'resolver|nameserver|if_index'
networksetup -getdnsservers Wi-Fi        # 手动设置的值

dig +short AAAA www.google.com           # 期望: 空
dig +short A www.google.com              # 期望: 真实 IP
```

判据不是「查询目标是谁」，而是**该目标是否与本机同网段**。

---

## 5. 检查出站绑定是否失效

```bash
# 主接口当前地址
ifconfig en0 | awk '/inet /{print $2}'

# sing-box 出站实际使用的源地址
netstat -an -f inet | grep ESTABLISHED | grep -v 172.19.0.1 | grep -v 127.0.0.1

# 直接看日志
grep "can't assign requested address" /var/log/v2rayn-tun.log
```

**两者不一致 = 绑定已失效**，重启 TUN 即可（正常情况守护会自动处理）。

---

## 6. 测性能：避开噪声陷阱

这台机器的链路抖动极大（同一配置三次测出 0.062 / 0.074 / 0.189），吃过亏。

- **串行测量** —— 并发跑两个测试会互相污染 CPU 计数
  （曾因此把 14% 的改善误报成 59%）
- **取最小值而非中位数** —— 最小值最接近无干扰状态
- **先确认链路是否见顶** —— 4 并发总量 ≈ 单流总量，说明已是链路上限，
  此时测不出协议栈开销
- **延迟要拆开看**：

```bash
curl -s -o /dev/null -w "dns=%{time_namelookup} tcp=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer}\n" \
     --noproxy '*' --max-time 20 https://example.com
```

`time_appconnect` 含 DNS，「TLS 慢」可能其实是「DNS 慢」。

---

## 7. 服务状态检查

```bash
launchctl print system/<label>          # state / pid / runs / last exit code
launchctl print gui/$(id -u)/<label>    # 用户级
launchctl kickstart -k system/<label>   # 重启
```

**周期性任务的 `state = not running` 是正常的**（两次运行之间就是空闲的），
要看 `runs` 和 `last exit code` 才能判断它是否在正常工作。

---

## 8. 判断应用是否绕过了 TUN

某些应用会绑定特定接口，或用 `--interface` 主动绕过。用第 2 节的源端口比对法确认。

也可临时关 TUN 做对照（这是那个开关存在的主要用途）：

```bash
touch "$HOME/Library/Application Support/v2rayN/tun-disabled"   # 关
rm "$HOME/Library/Application Support/v2rayN/tun-disabled"      # 开
```

---

## 9. 排查的时间维度

**故障是间歇的时候，必须在故障发生时取数。**

本项目发生过：测到「绑定是正确的」就结案，但那一刻网络刚切换完、守护已重启 ——
事后测到的「正常」会误导结案。

做法：

```bash
# 持续采样, 把时间戳和状态一起记下来
while true; do
  printf '%s  %s  %s\n' "$(date +%H:%M:%S)" \
    "$(ifconfig en0 | awk '/inet /{print $2}')" \
    "$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 8 https://www.google.com/generate_204)"
  sleep 10
done | tee /tmp/watch.log
```

然后把「用户报告故障的时间」与日志时间**对齐比对** —— 这是最便宜的定位手段。
