# 22 · 怎么判断一个出口 IP 是不是真住宅

> **一句话**：看 **whois/BGP + PTR**，别看 `ip-api` 的 ISP 字段 —— 它会告诉你 Comcast，实际是别家的段。

## 为什么在意这件事

用 Claude 这类服务时，「出口 IP 的画像」比「能不能连」更重要。
一个机房 IP 能连上，但风控标记不一样。

**要回答三个问题**：

1. 这是机房还是宽带？
2. 如果是宽带，是**消费级**还是**企业专线**？
3. 和前一个 IP 比，画像变了多少？

## 不可靠的信号

### `ip-api.com` 的 `isp` 字段

```
48.47.19.120
  ip-api 说:  ISP = Comcast Cable Communications, LLC
  whois 说:   48.44.0.0/14 -> AviationAI (AL-3130)
```

**两个源打架** ✗ —— `ip-api` 的 `isp` 是启发式推断，经常错。

**而且**：`hosting=false` / `proxy=false` 这两个字段**只能说明它不在已知的机房/代理名单里**，
**不能证明它是住宅** ✗ —— 新段、小段、租赁段都不在名单里。

### `ipinfo.io` 的 `city` / `loc`

```
66.248.154.224  ->  37.2768,-79.1008   Rustburg, Virginia
48.47.19.120    ->  40.7143,-74.0060   New York City
198.3.122.187   ->  40.7143,-74.0060   New York City
```

**两个 NY 的 IP 坐标完全一样** —— 这是**城市质心**，不是真实位置 ✗
只能用来算「大概多远」，不能用来区分两个 IP。

## 可靠的信号

### ① RIPEstat（权威 BGP）

```bash
curl -s "https://stat.ripe.net/data/network-info/data.json?resource=48.47.19.120"
# {"prefix": "48.47.16.0/22", "asns": ["7922"]}

curl -s "https://stat.ripe.net/data/as-overview/data.json?resource=AS7922"
# {"holder": "COMCAST-7922 - Comcast Cable Communications, LLC"}
```

**BGP 是路由事实** —— 谁的 AS 在宣告这个段，谁就是当前的网络所有者 ✓

### ② whois（段的注册者）

```bash
whois 66.248.154.224 | grep -E "NetName|OrgName|NetRange"
```

**注意**：whois 可能滞后于 BGP（段的转让/租赁在 ARIN 记录里更新慢）。
**两者冲突时，信 BGP。**

### ③ PTR（反向 DNS）—— 区分住宅和企业的关键

```bash
dig +short -x 198.3.122.187
# nww187.nww.com        <- ★ 有企业域名 ★

dig +short -x 48.47.19.120
# （空）                 <- ★ 典型家宽特征 ★
```

**`nww.com` = "neuwerk · Engineering expertise"** —— 一家工程公司 ✗

**→ 结论：`198.3.122.187` 是某家公司的**企业专线**，不是家庭宽带 ✓**

**典型模式**：

| PTR | 含义 |
|---|---|
| 空 / `undefined.hostname.localhost` | 家宽（很多 ISP 不给 PTR）|
| `c-xx-xx-xx-xx.hsd1.xx.comcast.net` | Comcast 家宽（动态/静态）|
| `nww187.nww.com` | **企业专线** ✗ |
| `ec2-xx-xx-xx-xx.compute.amazonaws.com` | 机房 ✗ |

## 实战对比（本项目实测）

| 信号 | 原 `66.248.154.224` | `48.47.19.120` (1-brivan) | `198.3.122.187` (2-geneva) |
|---|---|---|---|
| BGP ASN | **26407** Carolina Digital Phone | **7922** Comcast | **701** Verizon Business |
| AS 性质 | 小型区域 ISP | 大型 Cable | 大型电信**企业段** |
| whois 段 | `66.248.128.0/19` | `48.44.0.0/14` AviationAI | `198.3.0.0/17` Verizon Business |
| PTR | `undefined.hostname.localhost` | 无 | **`nww187.nww.com`** |
| `ip-api` hosting | False | False | False |
| 城市 | Rustburg, VA | New York, NY | New York, NY |
| **判定** | **真住宅 ✓** | **家宽 ✓ 较接近** | **企业专线 ✗** |

**结论：`1-brivan` 更接近原 IP 的画像**（同为消费级 ISP 宽带）。

## 物理距离

```
Rustburg, VA (37.28, -79.11)  ->  New York City (40.71, -74.01)
  大圆距离 582 km / 362 miles
```

**而两条线之间：0 km**（城市级定位重合）✗

**→ 距离无法用来区分这两条线，只能靠 ISP 类型。**

## ⚠️ 在 TUN 模式下测这些，数字全是假的

**这是本项目反复踩的坑，单独强调**：

| 命令 | 在 TUN 下会怎样 |
|---|---|
| `ping <公网IP>` | **返回 0.3-1ms**（sing-box 直接应答）✗ |
| `nc -z <IP> <任意端口>` | **一律显示"成功"**（连不存在的端口也成功）✗ |
| `curl -w '%{time_connect}'` 经 SOCKS | **0ms**（只反映到本地代理的握手）✗ |
| `lsof` 看节点连接源地址 | 显示 `172.19.0.1`，**看不出是否走 TUN** ✗ |

**唯一有效的做法**：**起一个独立客户端（xray / sing-box）走物理网卡，用它去测**。

**验证测法本身是否可靠的办法**：**拿一个绝对不存在的目标做阳性对照**
（例如 `nc -z <IP> 59999`，如果也显示"成功"，这个测法就是假的）。
