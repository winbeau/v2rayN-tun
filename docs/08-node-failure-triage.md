# 08 · 节点故障的分层定位

**现象**：所有需要代理的站点全部失效（HTTP 000），但国内访问正常。

排查第一原则：**先证明问题不在本地**，再往外查。否则会在自己的配置里空转。

---

## 三层隔离法

```
第 1 层  本地配置        国内能否正常访问 → 能就说明 TUN/路由/DNS 都健康
第 2 层  网络路径        绕过本地所有代理，直连节点
第 3 层  节点服务        TCP 与 TLS 分开看
```

### 第 2 层的正确工具是 `--interface en0`

```bash
curl -vsk -o /dev/null --interface en0 --max-time 12 \
     --resolve www.intel.com:443:<节点IP> https://www.intel.com/
```

`--interface` 设置 `IP_BOUND_IF`，**强制走指定网卡、绕过路由表**，因此完全跳过 TUN。

### 第 3 层要分开看 TCP 和 TLS

```
* Connected to ... (216.167.95.77) port 443     ← TCP 成功
* (304) (OUT), TLS handshake, Client hello (1):
* Connection timed out after 12001 milliseconds ← TLS 零响应
```

**TCP 通、TLS 不通** 指向：节点被封（GFW 黑洞）、服务端进程挂死、或 Reality 回落目标不可达。
反过来 **TCP 都不通** 则更可能是网络封锁或服务器宕机。

---

## 三个把方向带偏的弯路

### 弯路 1：用 IP 当 SNI 测 Reality 节点

Reality 节点按 SNI 伪装成真实站点（本例是 `www.intel.com`）。用 IP 连它，服务器不会按预期响应。

→ 必须先从配置里取出真实 SNI：

```bash
# 从 v2rayN 生成的核心配置里读（只取非敏感字段）
python3 -c "
import json
d=json.load(open('~/Library/Application Support/v2rayN/binConfigs/config.json'))
for ob in d['outbounds']:
    if ob.get('tag')=='proxy':
        print(ob['protocol'], ob.get('streamSettings',{}).get('realitySettings',{}).get('serverName'))"
```

再用 `--resolve` 把该域名指到节点 IP。

⚠️ 但要注意：**未授权的客户端可能被 Reality 直接丢弃**，所以这仍不是权威测试。
**权威信号是 v2rayN 自身的连接状态**（见下方"看连接状态"）。

### 弯路 2：用绑定源地址代替 `--interface`

```python
s.bind(("192.168.5.25", 0)); s.connect((node_ip, 443))   # ✗ 无效
```

绑定源地址**不改变路由查找** —— 去节点的路由仍指向 TUN，所以这个"绕过"是假的，测出来的 0.00s 是 TUN 本地应答。

### 弯路 3：用其他国外域名做对照

想验证"是不是整个网络访问不了国外"，于是 `curl --interface en0 https://www3.nhk.or.jp`。
结果全部 `connect=0.000000s` —— **这是 DNS 解析就失败了，连接根本没发起**。

原因：非国内域名的 DNS 要走代理 DoH，而代理正断着。**用域名做对照会被 DNS 失败污染，必须用 IP。**

---

## 看连接状态（比延迟数字可靠）

```bash
netstat -an -f inet | grep <节点IP>
```

| 状态 | 含义 |
|---|---|
| `ESTABLISHED` 且无积压 | 正常 |
| `CLOSING` / `FIN_WAIT` 且 **Send-Q 有值** | 有数据发不出去 —— 节点不通 |
| 完全没有连接 | 核心没在尝试，或已放弃 |

---

## 两个"名不副实"的坑

### 1. 节点名与实际出口不符

```
节点名:  selab-ws-HK        ← 名字写着 HK
出口 IP: 23.165.40.14
ipinfo:  city = Los Angeles, country = US   ← 实际在洛杉矶
```

**不要相信节点名里的机房标识**，用出口 IP 查归属：

```bash
curl -s https://api.ipify.org                                   # 出口 IP
curl -s "https://ipinfo.io/<出口IP>/json" | grep -E 'city|country|org'
```

本例的实测影响：所谓"香港"节点的 TLS 延迟是 1.32-1.57s，**并不比洛杉矶节点（0.8-1.2s）好**。

### 2. 多个节点其实是同一台服务器

```
LA-Reality    216.167.95.77
LA-Hysteria2  hy2.icthub.top   → 216.167.95.77    同一台
selab-hy2     hy.selab.top    → 23.165.40.14
selab-ws-HK   hk.selab.top    → 出口 23.165.40.14  也是同一台
```

→ **换节点等于没换。** 订阅里至少要有一个不同机房、不同 IP 的节点，否则单点故障就是全断。

判断方法：解析各节点域名并对比出口 IP。解析必须**绕过失效的代理**：

```bash
# 国内 DoH 的 IP 属于 geoip-cn，会走直连，不受节点故障影响
# 但 AliDNS 用 RFC8484 的 dns= 参数（base64url 的 wire 格式），不是 name=
```

---

## 节点被核心拒绝（不是网络问题）

v2rayN 日志里出现 `cannot connect via Xray-core versions ... or higher` /
`AllowInsecure is enabled but no certificate is provided` 这类信息时，
**换任何网络、任何协议都连不上** —— 节点未加密且开启 `AllowInsecure`，新版 xray 拒绝加载。

→ 处置：让服务商升级节点配置，或直接弃用该节点。
完整案例与修复方法见 [11 · 修复 Hysteria2](11-hysteria2-real-cert.md)。

---

## 换节点时的 DNS 引导死锁

节点用**域名**指定时会死锁：

```
解析节点域名 → 需要走代理 → 代理需要先解析这个节点 → 死锁
```

日志表现：`router: process DNS packet: dial tcp 127.0.0.1:10808: connect: connection refused`

### 规避方法

**换节点前先退出 v2rayN**：

```bash
# 1. 退出 v2rayN（TUN 会随之撤掉）
# 2. 改配置或从 GUI 切换
# 3. 启动
```

退出后 TUN 不存在 → 域名走直连解析 → 成功；随后核心连上、10808 就绪、TUN 才被创建。

反过来，**在 TUN 运行时切换域名节点会卡死**（本次实测踩到过）。

> 根治办法是在 sing-box 的 `dns.rules` 里为节点域名加一条走直连解析器的规则，
> 但要注意国内解析器对受封域名可能返回污染结果 —— 只对节点域名这样处理是可接受的折中。

### 附带影响

节点故障期间，**非国内域名的 DNS 会一并失效**（因为它们的解析依赖代理 DoH）。
这会让人误判为"DNS 也坏了"，实际它只是代理故障的下游症状。国内域名不受影响。
