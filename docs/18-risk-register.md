# 18 · 技术风险登记表

> **一句话**：IPv6/时区/WebRTC/IP 类型都已干净；剩下 9 条，最重的是 DNS 泄漏和豁免名单覆盖不全。

只列**技术层面**的风险。用法、支付、注册环境不在本文范围。

| # | 风险 | 现状 | 严重度 | 可修 |
|---|---|---|---|---|
| 1 | ~~DNS 泄漏~~ | **已解决**：国内域名改走 `jp-dns`（经日本节点），国内 DNS 不再参与 | — | ✅ 已实施 |
| 2 | **豁免名单只覆盖 SunBrowser** | Chrome / Safari / 其他程序访问国内站仍用真实 IP | ★★★ | 可修（加进程名）|
| 3 | **v2rayN 退出后裸连** | 退出即撤 TUN，此时开浏览器无任何保护 | ★★★ | 设计如此，靠习惯 |
| 4 | **豁免进程到不了中国** | `node-direct` 节点的出口访问 baidu/bilibili/qq 全失败 | ★★ | 不可修（节点限制）|
| 5 | **住宅节点是单点** | 它一挂，豁免进程完全没网 | ★★ | 未做备用 |
| 6 | **切网 1-3 秒直连窗口** | TUN 重建期间路由已恢复直连 | ★★ | 未修 |
| 7 | **xray 死亡不自动重启** | `kill -9` 后 10808 一直不恢复 | ★★ | 未修 |
| 8 | **订阅服务是单点** | 它挂了 v2rayN 更新失败（已有节点仍可用）| ★ | 已缓存兜底 |
| 9 | **机场 SNI 屏蔽列表未知** | 已处理 excalidraw，将来可能还有站点打不开 | ★ | 遇到再查 |

## 已确认干净的项

| 项 | 证据 |
|---|---|
| IPv6 | `::/0 → reject`；`curl -6` 失败；en0 无全局 IPv6 地址 |
| 时区 vs IP | `Intl...timeZone` = `America/New_York` = 出口 IP 时区 |
| 语言 | en-US，与出口一致 |
| WebRTC | AdsPower 已禁 + SunBrowser 已按进程豁免。**实测验证**：`ipinfo.cv/webrtc-check` 11 个 STUN（含国内 Bilibili/小米/MGTV）全部返回 `No WebRTC IP leak detected`；修复前国内 STUN 会报出真实中国 IP `124.117.210.115` |
| IP 类型 | 住宅（Carolina Digital Phone），非机房 |
| 时钟 | SNTP 偏差 +0.013s |
| 系统代理 / 环境变量 | 全空 |

## 前三条的处置建议

**1. DNS 泄漏** —— 实测否决了"改成全走远端 DoH"这个方案。

改后国内域名会解析到**海外 CDN 节点**（例如 `taobao` 从国内的
`118.183.174.52` 变成 `155.102.176.107`）。这些 IP 不命中国内直连，
流量会走代理出去 —— 后果取决于节点：

| 节点类型 | 后果 |
|---|---|
| 无回国优化（如本项目现用的美国住宅节点）| **延迟很高，甚至直接无法访问** |
| 有回国优化（如机场的 CN2 线路）| 影响较小 |

另外 `.local` 这类本地域名会解析不了。

**结论：保持现状。** 这条风险的危害主要是 DNS 查询本身泄漏给腾讯，
不影响访问 Claude（Claude 只连国外域名，本来就走代理）。

**2. 豁免名单覆盖不全** —— 加进程名即可，但要写**真正发起连接的那个进程**：

```bash
# 看当前生效的名单
python3 -c "import json;d=json.load(open('/usr/local/libexec/v2rayn-tun/config.json'));\
print([r.get('process_name') for r in d['route']['rules'] if r.get('outbound')=='node-direct'])"

# 改名单后重新应用 (会先实测节点可用性)
sudo ./scripts/per-app-routing.py apply --sub sub2
```

**3. v2rayN 退出后裸连** —— 这个没有技术解法，只能靠习惯：

```
用敏感服务前先确认 v2rayN 在运行
或: touch ~/Library/Application\ Support/v2rayN/killswitch-always
    (退出后也保留 TUN —— 但会阻断所有境外流量)
```

## 已决策：不修（记录理由，避免反复）

| # | 决策 | 理由 |
|---|---|---|
| 2 | 保持现状，只豁免 AdsPower | **用例本来就是隔离的**：AdsPower 是 Claude 专用，日常浏览器另有需求。给日常浏览器加豁免 = 让它也上不了国内站 ✗ |
| 7 | 暂不做 xray 自动重启 | xray 只服务非豁免进程；它挂了表现为"其他程序都没网"，显式可见。守护里塞自动拉起会引入"擅自操作 v2rayN"的风险 |

### 关于 2 的补充：为什么"加名单"不是好方向

真正卡住的不是名单，是**节点能力** —— 住宅节点到不了中国大陆：

```
豁免进程全走住宅节点  ->  国内站打不开 ✗
所以"再豁免 Chrome"  ->  Chrome 也上不了国内站 ✗
```

如果将来确实需要"豁免进程既能上国内站、又不泄漏真实 IP"，
完整解是**按目标分流**（实测机场的日本 CN2 节点能到中国：`baidu=200` 1.1s）：

```
豁免进程:
   国内目标 -> CN2 节点        能到中国 ✓  不泄漏 ✓
   其他     -> 住宅节点         住宅 IP ✓
```

代价是豁免进程访问国内站时对方看到的是日本机房 IP。**当前决定：不做。**

## 附：WebRTC 泄漏的验证记录

**修复前**（2026-10-15 上午）：

```
国内 STUN:  Bilibili  124.117.210.115   ✗ 真实中国 IP
            Xiaomi    116.178.106.41    ✗
            MGTV      124.117.210.115   ✗
国外 STUN:  Google    154.17.27.236     ✓ 中转服务器
            Cloudflare 66.248.154.224   ✓ 住宅出口
```

**修复后**（同日，实测 `https://ipinfo.cv/webrtc-check`）：

```
11 个 STUN 服务器（含国内 4 个、国外 7 个）全部返回
  No WebRTC IP leak detected
```

**这证明了什么**：WebRTC 不再泄漏真实 IP。

**这没有证明什么**：不能据此推断"所有流量都走了节点" ✗ ——
那是由 `per-app-routing.py` 的进程规则保证的，与 WebRTC 是两回事：

| 层 | 机制 | 覆盖的是 |
|---|---|---|
| WebRTC | AdsPower 关闭 WebRTC | JS 主动去问 STUN 这条路径 |
| 路由 | SunBrowser 按进程豁免 → 全走节点 | 网页加载国内图片/脚本等**任何**国内方向的连接 |

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

## 复检命令

```bash
./scripts/stealth-mode.sh test          # STUN 泄漏实测
python3 ./scripts/test-nodes.py --grep 住宅   # 节点可用性
```

```bash
# 免除进程 vs 普通进程的出口对比 (Terminal 里跑)
curl -s --noproxy '*' https://ip.3322.net   # 普通进程 -> 真实 IP
# AdsPower 里打开 https://ipinfo.cv/webrtc-check  -> 应全是住宅 IP
```
