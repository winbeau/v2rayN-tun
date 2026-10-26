# 19 · 路由实施记录

> **一句话**：**「国内直连」这个概念本身被取消了** —— 国内走日本、国外走住宅、只有 22 个域名直连。

本文记录三件事的实施过程与实测：国内方向改走日本节点、第 2 层 xray 改为
fail-closed、以及"切网瞬间会不会泄漏"这个问题。风险清单见 [18](18-risk-register.md)。

---

## 已实施：国内直连 → 日本节点（2026-10-15）

**目的**：让"国内直连"彻底消失 —— 国内方向的流量和 DNS 查询都不再暴露真实中国 IP。

```
豁免进程 (AdsPower)          其他进程
   国内 -> cn-via-jp            国内 -> cn-via-jp      ← 都是日本了
   其他 -> node-direct          其他 -> proxy (住宅)   ← Claude 侧不变

cn-via-jp = 日本CN2-3 (151.242.164.241)
jp-dns    = DoH, detour=cn-via-jp   ← 国内域名从这里解析
```

**实测结果**：

| 项 | 结果 |
|---|---|
| 国内 IP 回显 | `151.242.164.241` 日本东京 ✓ **不再是真实中国 IP** |
| 国外出口 | `66.248.154.224` 住宅 ✓ 不受影响 |
| 国内网站 | baidu/taobao/bilibili/jd ✓；qq 501、163 403（能连上，站点侧限制）|
| 残留的国内 DNS | 只剩 `geosite-private`（本地域名远端解析不了）与手动 Direct 模式 |

**命令**：

```bash
# 应用（会先实测两个节点可用性，不通就拒绝）
sudo ./scripts/per-app-routing.py apply --sub sub2 --cn-node 日本CN2-3

# 只预览
./scripts/per-app-routing.py plan --sub sub2 --cn-node 日本CN2-3
```

**回滚**：

```bash
sudo cp /usr/local/libexec/v2rayn-tun/config.json.bak-<时间戳> \
        /usr/local/libexec/v2rayn-tun/config.json
sudo launchctl kickstart -k system/com.local.v2rayn-tun
```

### 实施中踩的坑

**① sing-box 1.14 移除了旧的 DNS server 格式**

第一版用了 `address` 字段，直接启动失败：

```
dns.servers[4]: legacy DNS server formats are deprecated in sing-box 1.12.0
and removed in sing-box 1.14.0
```

正确形状（照抄本机已在用的 `remote-dns-1`）：

```json
{ "type": "https", "tag": "jp-dns", "server": "cloudflare-dns.com",
  "path": "/dns-query", "domain_resolver": "hosts-dns", "detour": "cn-via-jp" }
```

**② 脚本是"先写文件、再校验"，校验失败时文件已经写坏**

失败后守护仍在跑内存里的旧配置，网络看起来正常 —— **但只要守护重启就会起不来**。
这次靠"配置改动时间晚于 sing-box 启动时间"发现了它。

**改进方向**：校验应发生在写入之前（写到临时文件校验通过再 mv）。

### 直连例外清单（只认国内 IP 的站点）

经日本节点实测**全部 URLError**、直连正常的两类站点，加入直连例外
（`route.rules[14]` + `dns.rules[6]`，排在所有 CN 规则之前）：

| 类别 | 域名 | 实测 |
|---|---|---|
| 腾讯/微信 | `qq.com` `weixin.qq.com` `qpic.cn` `qlogo.cn` `gtimg.cn` `tencent.com` … | 微信发不出图片/文件 |
| 教育网 | `edu.cn` `ac.cn` `chsi.com.cn` | 清华 200 / 北大 200 / 学信网 200 |
| 政务 | `gov.cn` `gov.hk` | 工信部 403（站点侧）/ gov.cn 200 |

**理由**：它们本身就是中国机构，看到中国 IP 完全正常；且大多有国内访问控制，
经境外节点必然失败。与 Claude 的风险无关。

**注意**：没有加 `com.cn` / `org.cn` —— 太宽，会把大量商业站点也放回直连。

### 第 2 层 xray 也改成 fail-closed（2026-10-15 完成）

**问题**：TUN（第 1 层）已把国内方向送去日本，但 xray（第 2 层）仍带
v2rayN 的「绕过大陆」`geoip:cn` / `geosite:cn -> direct`。两层名单来源不同
（sing-box rule-set vs xray geoip.dat），可能漂移 —— 一旦某个 IP 只在
xray 名单里，第 1 层放它去 proxy，第 2 层又把它直连出去。

**解法**：造一个自定义路由项并选中。

```bash
python3 scripts/make-routing-profile.py          # 创建/更新
python3 scripts/make-routing-profile.py --list   # 看清单
python3 scripts/make-routing-profile.py --remove # 删除
# 然后在 v2rayN: 设置 -> 路由设置 -> 选中「V4-禁直连(TUN 专用)」
```

规则结构照抄内置的「V4-全局(Global)」，只是名字写清楚用途：

```
udp 443 -> block / geoip:private -> direct /
geosite:private -> direct / 其余 -> proxy
```

**验证（选中后读 xray 实际生成的配置）**：

```
[0] block   <- udp 443
[1] direct  <- geoip:private
[2] direct  <- geosite:private
[3] proxy   <- 0-65535          ← 兜底 proxy
[4] direct  <- inboundTag=direct-dns-1
[5] proxy   <- inboundTag=dns-module

含 geoip:cn / geosite:cn 的 direct 规则: 没有了 ✓
```

**效果**：第 1 层漏掉的目标会走节点 → 节点到不了中国 → 请求失败，
但**不会泄漏真实 IP**。

### 两个存储字段的坑

| 字段 | 位置 | 说明 |
|---|---|---|
| `RoutingItem.IsActive` | 数据库 | **真正标记"当前选中"的就是它** |
| `RoutingBasicItem.RoutingIndexId` | guiNConfig.json | 一直是 `null`，**不表示选择** —— 曾据此误判"没选中" |

另外 **v2rayN 运行中退出时会覆写数据库**，改库前后要留意；
脚本已在改动前自动备份为 `guiNDB.db.bak-route-<时间戳>`。

## 已实测排除：切网瞬间不会泄漏真实 IP（2026-10-15）

**原先的担心**：切换网络时 TUN 被重建，那几秒路由退回物理网卡 → 直连泄漏。

### 第一次测试（不合格）

只做了 `networksetup -setairportpower en0 off/on` —— 同一个 SSID、同一个
IP、同一个网关，只是断开重连。那不叫切网，TUN 全程没消失，测了个寂寞。

### 第二次测试（真切网，结论有效）

在**两个不同子网之间**来回切：热点 `192.168.5.25/24`（网关 `192.168.5.1`）
↔ WiFi `10.191.159.160/24`（网关 `10.191.159.31`），5 分钟 88 条采样。

**环境确实换了**：

```
15:54:52  en0=192.168.5.25    gw=192.168.5.1      ← 热点
15:55:26  en0=-               gw=-                ← 断开
15:55:29  en0=10.191.159.160  gw=10.191.159.31    ← 换成另一个子网 ✓
15:55:41  ...                 ...    tun=N        ← TUN 消失
15:55:45  ...                 ...    tun=Y        ← 恢复
15:57:10  en0=192.168.5.25    gw=192.168.5.1      ← 切回热点
15:57:21  ...                 ...    tun=N        ← TUN 再次消失
15:57:26  ...                 ...    tun=Y        ← 恢复
```

**结果**：

| 检查项 | 结果 |
|---|---|
| TUN 是否消失 | **会** —— 两个方向各一次，每次不到一个采样间隔（< 2.7s）|
| TUN 消失期间能否上网 | **不能**（`g=000`，`out` 为空）|
| 出口 IP | 全程只有 `66.248.154.224`（住宅）或空 |
| **真实中国 IP** | **一次都没出现** ✓ |
| sing-box 是否绑死在旧地址 | **没有** —— `node_src` 自动跟着网卡地址变：`192.168.5.25` (55 次) → `10.191.159.160` (31 次) → 回来 |

**为什么消失也不泄漏**：TUN 消失时是**没有默认路由**（流量发不出去 = 彻底没网），
不是**路由退回物理网卡**（那才会直连）。前者安全，后者才是泄漏。两种现象在
"不可用"这点上看起来完全一样，只有记录出口 IP 才能区分。

**结论：不需要 pf kill-switch。** 风险表第 6 条改为"实测排除"。

**顺带排除了另一个担心**：README 里"检查 sing-box 绑定是否已失效"提到的场景
（换网后 sing-box 还绑在旧源地址上）**实测没有发生** —— 它跟着变了。

---

## 附：stealth-mode 现在的定位

`scripts/stealth-mode.sh` 是更早的方案 —— 它把配置里**所有** `direct` 规则改成
`proxy`，实现"全代理"。

**现在的架构下它已经不需要了**：

```
旧: 默认配置里国内是 direct -> 泄漏 -> 用 stealth-mode 全改成 proxy
新: 国内方向已经是 cn-via-jp(日本) -> 本来就不泄漏, 不需要改
```

**它现在唯一的用途**是"连那 22 个只认国内 IP 的例外也不许直连"（极端严格场景）。

**⚠️ 已修的一个冲突**：它的老逻辑会把那 22 个例外也改成 proxy ——
那会让**微信发不出图片**。现在：

| 命令 | 例外域名 | 后果 |
|---|---|---|
| `stealth-mode.sh on` | **保留直连** ✓ | 微信/教育/政务正常 |
| `stealth-mode.sh on --strict` | 也走代理 | 微信发不出图片（明确选择的代价）|

`stealth-mode.sh status` 现在能分辨三种状态：

```
国内方向出站: cn-via-jp   -> 标准模式（国内走日本，不是隐身模式）
国内方向出站: direct      -> 旧配置, 真实 IP 会泄漏, 要跑 setup-routing.sh
国内方向出站: proxy       -> 隐身/严格模式
```

---

## 遇到"某国内站打不开 / 浏览器报不安全"怎么办

**症状**：浏览器说网站不安全、或一直转圈打不开；但同一时刻百度等站点正常。

**原因**：那个站属于"只认国内 IP"那一类 —— 经日本节点失败，浏览器把 TLS
握手被重置报成"证书不安全"。

**自助诊断**（不用等人）：

```bash
./scripts/check-site.sh gitcode.com
```

它把"经 TUN（走日本）"和"直连"并列对比，直接给结论：

| 经 TUN | 直连 | 结论 |
|---|---|---|
| 失败 | 成功 | ★ 只认国内 IP → 加进例外 |
| 失败 | 失败 | 站点问题或 DNS |
| 成功 | — | 不是路由问题 |

**加例外**：不用改脚本，追加到外置清单即可（一行一个根域名，子域自动匹配）：

```bash
echo "example.cn" >> ~/.v2rayn-tun/extra-direct.txt
sudo ./scripts/per-app-routing.py apply --sub sub2 --cn-node 日本CN2-3
```

脚本内置的那批（腾讯/教育/政务/代码托管）在 `per-app-routing.py` 的
`wx_domains` 里；外置文件是给它**追加**用的。

**⚠️ 不要加 `com.cn` / `org.cn` 这类大范围后缀** —— 会把大量商业站点也放回直连,
"国内走日本"就白做了。判断标准只有一个：**这个站是不是中国的机构/服务**。

### 目前已收录的例外（三类）

| 类别 | 域名 | 为什么 |
|---|---|---|
| 腾讯/微信 | `qq.com` `weixin.qq.com` `qpic.cn` `qlogo.cn` `gtimg.cn` `tencent.com` … | 微信发不出图片/文件 |
| 教育网 | `edu.cn` `ac.cn` `chsi.com.cn` | 清华/北大/学信网等有国内访问控制 |
| 政务 | `gov.cn` `gov.hk` | 工信部等 |
| 代码托管 | `gitcode.com` `gitcode.net` `csdn.net` | 华为云 IP，实测经日本 TLS 被重置 |
| 比赛/评测 | `cannjudge.cn` | 华为云 IP，实测经日本 URLError |

---

## 目标是一台服务器（没有域名）时怎么办

**症状**：`ssh user@<国内IP>` 报 `Connection closed by ... port N` —— 服务端接受
TCP 后立刻断开。浏览器打不开国内服务器上的服务，也是同类。

**原因**：sing-box 是**按 IP 的 `geoip-cn` 判定**国内方向的，没有域名可匹配。
所以域名清单（`extra-direct.txt`）对它无效，必须按 IP 放行。

**改法（推荐：自动扫描 `~/.ssh/config`）**：

```bash
./scripts/ssh-hosts-direct.sh            # 扫描并列出哪些是中国 IP
./scripts/ssh-hosts-direct.sh --write    # 写进清单
./scripts/ssh-hosts-direct.sh --list     # 看当前清单
sudo ./scripts/per-app-routing.py apply --sub sub2 --cn-node 日本CN2-3
```

它会解析每个 Host 的 HostName、查归属地，把**中国境内**的加进清单，
并自动跳过内网地址（`10.x` 之类本来就直连）。

**手工加也行**：`~/.v2rayn-tun/extra-direct-ip.txt`，一行一个 IP 或 CIDR。

生成 `route.rules[N] direct <- ["1.92.76.152/32"]`，插在 `geoip-cn` 之前。

**实测对照**：

| | 结果 |
|---|---|
| 加之前 | `Connection closed by 1.92.76.152 port 22002` —— 服务端秒断 |
| 加之后 | `Permission denied (publickey,password)` —— 握手成功，只是没认证 |

**实测（一次加了 4 台）**：

```
huawei1    1.92.76.152      华为云   ✓ 握手成功
huawei2    124.71.228.242   华为云   ✓ 握手成功
h200-jump  152.136.172.95   腾讯云   ✓ 握手成功
h200       222.29.136.226   北大     ✓ 走到密码提示（跳板后目标机）
```

**怎么判断是不是这个原因**：服务端"接受 TCP 又立刻断开"，且该 IP 属于国内
（`ip-api.com` 查是中国机房）—— 基本就是这个。加进 IP 清单立刻见效。

⚠️ **只加你确实需要的具体 IP，不要加整段 CIDR**。写成 `1.92.76.0/24` 就等于
把整个网段放回直连了，"国内走日本"的保护在那里就没了。

---

## 更换国内出口节点（日本节点不可用时）

`cn-via-jp` 是**出站的标签名，不代表它一定是日本节点**。节点换掉后标签保留，
因为它被 `jp-dns` 的 detour 和所有国内路由规则引用着 —— 改名要动一大片。

```bash
python3 scripts/switch-cn-node.py plan  --node selab-reality    # 只校验+实测，不改
sudo python3 scripts/switch-cn-node.py apply --node selab-reality
```

`plan` 会：校验完整配置 → 独立实测新节点访问百度 / DeepSeek API / DoH →
不改线上文件。`apply` 在相同预检通过后：备份 → 原子写入 → 重启 TUN →
验证 TUN 实际能访问 DeepSeek。

**它会保留**：DNS detour、国内路由、直连例外（域名 + IP）、国外出站。
**它只换**：`cn-via-jp` 这一个出站。

**节点从哪来**：v2rayN 数据库里按名称精确取，所以 `selab-reality` 这种
**不在商业订阅里**的节点也能用，也不需要动 v2rayN 的全局节点选择。

### 2026-10-16 实际切换记录

从 `(赠送)日本CN2-3专线娱乐节点`（`151.242.164.241`）换成 `selab-reality`
（`23.165.40.14:8443`，SNI `www.intel.com`）。

| 项 | 切换前 (日本CN2-3) | 切换后 (selab-reality) |
|---|---|---|
| baidu | 200 / 0.95s | 200 / 1.77s |
| 国内站覆盖 | 4/6 | **9/9 全部可连** |
| 国内回显 IP | 151.242.164.241 | 23.165.40.14 |
| 真实 IP 泄漏 | 无 ✓ | 无 ✓ |

**慢了一倍左右，但覆盖面更全**（qq / 163 / DeepSeek 都能连上了）。

⚠️ 测这个节点时踩过一个坑：用 `urllib` 的 `socks5h://` 走 sing-box 的
SOCKS 入站会报 `process connection: invalid argument`，导致**误判成节点不通**。
手工做 SOCKS5 握手（ATYP=3 域名）就正常。**是测试方法的问题，不是节点的问题。**

---

## 国内改回直连（`--node direct`）

`switch-cn-node.py` 现在支持 `--node direct` —— 不是换节点，而是把
`cn-via-jp` 这个出站**本身改成 `type: direct`**。所有国内路由继续引用
同一个标签，只是它不再连任何节点。

```bash
python3 scripts/switch-cn-node.py plan  --node direct
sudo python3 scripts/switch-cn-node.py apply --node direct
```

**它同时改 DNS**：`jp-dns` 是 `https://cloudflare-dns.com`，直连模式下会
直接去问它，国内既慢又可能不通 —— 所以把走 `jp-dns` 的规则全部改回
`direct-dns-1`（`119.29.29.29`）。

**实测（2026-10-25）**：

| | 走节点（selab / 日本CN2-3） | 直连 |
|---|---|---|
| 国内回显 | 23.165.40.14 / 45.202.245.223 | **124.117.210.115**（真实 IP）|
| baidu | 2.10s | **0.26s** |
| taobao | 1.48s | **0.19s** |
| bilibili | 1.02s | **0.21s** |
| jd | 1.02s | **0.06s** |
| 国外出口 | 66.248.154.224 住宅 | 66.248.154.224 住宅 ✓ 不变 |

**代价**：国内方向的流量重新以真实 IP 出去 —— 网页只要加载一个国内域名的
资源就能据此判断地理位置。这是明确的选择，不是回归。

**回滚**：`apply --node <节点名>` 换回任意节点即可，或用
`config.json.bak-cn-<时间戳>` 恢复。

### 顺带修的一个权限问题

`switch-cn-node.py` 原来用 `chmod(0o600)` 写配置，导致仓库里以普通用户
身份运行的工具（`stealth-mode.sh status`、`check-site.sh`、以及本脚本的
`plan`）全部 `PermissionError`。改成 644 —— 文件在 `/usr/local/libexec`
下是 root 所有，普通用户改不了，读没问题。
