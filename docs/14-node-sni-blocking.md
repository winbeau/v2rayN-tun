# 14 · 商业节点会按 SNI 选择性屏蔽

## 现象

用户报告 `excalidraw.com` 在 Chrome 里打不开。排查后发现：

```
app.excalidraw.com     HTTP 200  ✓
plus.excalidraw.com    HTTP 200  ✓
excalidraw.com         HTTP 000  ✗   ← 只有主域名
www.excalidraw.com     HTTP 000  ✗
```

**子域名正常，主域名不通** —— 这个模式本身就说明不是"网站挂了"。

## 定位过程（关键是把范围一步步缩小）

### 第一步：分清是本地问题还是节点问题

```
经代理 (socks5h://127.0.0.1:10808):  216.150.1.1:443  ->  HTTP 000  ✗
直连 (--interface en0):              216.150.1.1:443  ->  HTTP 200  ✓
```

**直连能通、走代理不通** —— 方向反了（正常应该是直连被墙、代理能通），所以问题在节点侧。

> 那个 `socks5h://127.0.0.1:10808` 的测试**绕过了 sing-box 的路由规则**，
> 直接走 xray → 节点 → 目标。所以它测的是"节点出口能不能到"，与本地配置无关。

### 第二步：排除"整段 IP 被封"

```
excalidraw.com      216.150.1.1     代理=000  直连=200
excalidraw.com      216.150.16.1    代理=000  直连=200
app.excalidraw.com  76.76.21.123    代理=200  直连=200   ← 同一家云, 能通
vercel.com          76.76.21.21     代理=200  直连=200   ← 同一家云, 能通
www.google.com      142.251.x.x     代理=200  直连=000   ← 正常(直连被墙)
```

两个 IP 都是 `AS16509 Amazon / Walnut, California`，而能通的 `76.76.21.x` 也是 AWS。
**同一家云、不同网段，一个通一个不通。**

### 第三步：决定性实验 —— 固定 IP，只换 SNI

```
同一个 IP (76.76.21.123), 同一个代理:

  SNI=excalidraw.com          HTTP 000  ✗   ← 只有它失败
  SNI=app.excalidraw.com      HTTP 200  ✓
  SNI=example.com             HTTP 200  ✓
  SNI=www.cloudflare.com      HTTP 200  ✓
```

**同一个 IP、同一个代理，只换 SNI 结果就不同 → 节点按域名（SNI）做了选择性屏蔽。**

## 为什么只能是节点做的

```
Chrome → TUN → sing-box → xray → 节点 → 目标
                                 ↑
                    GFW 看不到这里的 SNI (流量是加密的)
```

到节点这一段是加密的 vless/reality，**GFW 看不到 SNI**。所以按 SNI 拦截
只能是**节点自己**（或其出口）做的。

**这是一个反直觉的结论**：商业节点不只是"中转"，它会**按域名做选择性屏蔽** ——
可能为了防止滥用、规避某些风险，或就是白名单策略。

## 解法：把域名加进"直连例外"

`excalidraw.com` 直连是通的（实测 200，GFW 并没封它），所以让它走直连即可。

### ⚠️ 必须同时改**两处**，否则只是"半直连"

这是本项目踩过的一个细节。看 DNS 规则就明白：

```
【DNS 规则】
  [7] rule_set=[geosite-cn]  ->  direct-dns-1    ← 微信走这条
  [8] (默认)                 ->  remote-dns-1    ← 其他都走这条

【DNS 服务器】
  direct-dns-1   119.29.29.29        国内 DNS, 直连
  remote-dns-1   cloudflare-dns.com  Cloudflare DoH, 经代理
```

**微信的"直连"其实是两件事同时直连**：DNS 用 `direct-dns-1`、流量走 `direct`。
因为它命中 `geosite-cn`，**DNS 规则和路由规则都被命中**。

只加路由规则的话：

```
DNS 查询  -> remote-dns-1 (经代理)   ✗ 还是代理
流量      -> direct                  ✓
```

能用，但状态不一致 —— 将来节点侧的 DNS 出问题就解析不了了。

### 实际改动

```json
// 1. DNS 规则: 插在 geosite-cn 那条【之前】(优先级最高)
{ "server": "direct-dns-1", "domain_suffix": ["excalidraw.com"] }

// 2. 路由规则: 插在 geoip-cn 那条【之前】
{ "outbound": "direct", "domain_suffix": ["excalidraw.com"] }
```

`domain_suffix` 会连带覆盖所有子域，这是想要的（保持一致）。

### 验证

```
excalidraw.com (经 TUN):  HTTP 200  ✓   ← 修复前是 000
www.excalidraw.com:       HTTP 301  ✓
app.excalidraw.com:       HTTP 200  ✓

对照(不受影响):
  google.com   204 ✓    github.com  200 ✓    baidu.com  200 ✓
  其他流量出口 IP   48.47.17.149 (仍是住宅 IP ✓)
```

**DNS 也换了解析器 —— 这是 DNS 规则生效的铁证**：

```
修复前: dig excalidraw.com → 216.150.1.1    216.150.16.1
修复后: dig excalidraw.com → 216.150.1.193  216.150.1.129
```

同一个域名、换了 DNS 服务器（Cloudflare DoH → 119.29.29.29）就返回不同 IP。

## 排查这类问题的方法

**"某个网站莫名打不开，但别的都好"** 时按这个顺序：

| 步骤 | 命令 | 判读 |
|---|---|---|
| 1. 分清代理还是直连的问题 | `curl -x socks5h://127.0.0.1:10808 <url>` vs `curl --interface en0 <url>` | 只有代理不通 → 节点侧 |
| 2. 看是不是整段 IP | 对比同域名其他 IP、同云其他域名 | 单个 IP vs 整段 |
| 3. ★ **固定 IP 只换 SNI** | `curl -k --resolve '<sni>:443:<ip>' https://<sni>` | **只有某个 SNI 失败 → 按域名屏蔽** |
| 4. 确认直连是否可用 | `curl --interface en0 <url>` | 可用 → 可以加直连例外 |

**第 3 步是这个方法的核心** —— 它能把"IP 问题"和"域名问题"彻底分开。

## 教训

1. **"节点只是中转"是错误的心智模型。** 实测证明商业节点会按 SNI 做选择性屏蔽。
   遇到"某个网站打不开但其他都正常"，要把节点本身列为嫌疑对象。
2. **DNS 和路由是两套规则，要一起改。** 只改一处会得到"半直连"这种不一致状态。
3. **国内名单（WeChat 那类）和直连例外是两回事**，但机制相同。
   理解微信为什么直连（DNS + 路由双命中），就能正确套用到例外清单上。
4. **阳性对照不能省。** 排查时我第一次用 `sing-box rule-set match` 得到了
   "qq.com 不在国内名单里"这种荒谬结果 —— 因为**命令参数顺序错了**
   （正确是 `match <rule-set> <domain> -f binary`，文件在前）。
   用确定命中的 `qq.com` 做对照才发现是工具用错了，而不是数据有问题。
