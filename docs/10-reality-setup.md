# 10 · 在自建服务器上启用 Reality + XTLS-Vision

目标：给 `23.165.40.14` 增加一条**不依赖 Cloudflare** 的高速链路，并接入本机 v2rayN。

---

## 最终架构

```
23.165.40.14
├── TCP 8443   VLESS + Reality + XTLS-Vision   ← 新增，直连，主用
├── TCP 443    VLESS + WS + TLS                ← 保留，经 Cloudflare 回源，备用
└── UDP 443    Hysteria2                       ← 保留
```

**为什么 Reality 放 8443 而不是 443**：443 已被 Cloudflare 回源占用。把 Reality 放空闲端口
**不需要改动 Cloudflare 控制台**，零中断。性能与端口无关。

**为什么要保留 WS 那条**：Reality 直连会暴露源站 IP。万一 IP 被封，Cloudflare 前置那条仍可用
（Cloudflare 是 anycast，换优选 IP 即可）。两条路径互为备份。

---

## 调试过程：三个叠加的问题

### 问题 1：`dest` 已改名为 `target` ⚠️

从 5 月的配置备份里还原 Reality 参数时，用的是旧字段名：

```json
"realitySettings": { "dest": "www.microsoft.com:443", ... }   // ✗ 旧名
```

**新版 Xray 静默忽略 `dest`** —— 不报错、不警告，`xray run -test` 照样输出 `Configuration OK`，
但 Reality 没有回落目标，握手必然失败。

对比一台能用的服务器才看出来：

```
可用的: settings keys: ['show','target','xver','serverNames','privateKey','shortIds']
出错的: settings keys: ['dest','serverNames','privateKey','shortIds']
```

→ 正确字段是 **`target`**，并补上 `show: false` / `xver: 0`。

**教训**：还原旧配置时，字段名要对照**当前版本**的实现，不能照抄备份。
`-test` 通过不代表配置被完整识别。

### 问题 2：Xray 版本过旧

服务端 `26.2.6`，客户端 `26.9.9`，可用节点 `26.3.27`。升级到 **26.3.27**。

```bash
systemctl stop xray          # 必须先停, 否则 cp 会报 "Text file busy"
curl -sL -o /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o -q /tmp/xray.zip -d /tmp/xray-new
cp /tmp/xray-new/xray /usr/local/bin/xray
# geoip.dat / geosite.dat 也要一起更新 (routing 里用到 geoip:private)
systemctl start xray
```

### 问题 3：target 的选择（最后卡住的那个）⭐

修好前两个问题后**仍然失败**。最后把 target/SNI 从 `www.microsoft.com` 换成
`www.intel.com`（与可用节点一致），**立刻通过**。

```
www.microsoft.com  →  REALITY: handshake did not complete successfully
www.intel.com      →  HTTP 204 ✓
```

两者都是 Akamai、都支持 TLS 1.3、都有 AAAA 记录 —— 表面条件相同，结果不同。
Reality 对回落目标有隐含要求，**必须实测**。

→ **做法：拿一台能用的节点的 target 做基准**，先跑通再换。

---

## 报错特征（定位用）

| 位置 | 输出 | 含义 |
|---|---|---|
| 客户端 | `failed to find an available destination > common/retry: [EOF]` | TCP 连上了但被服务端立即关闭 → Reality 认证/握手失败 |
| 服务端 | `REALITY: processed invalid connection from <ip>: handshake did not complete successfully` | 收到了连接但认证不通过 |

**两端都要看**：客户端说 EOF，服务端说 invalid connection，合起来才能确定是握手参数问题
而不是网络问题。

服务端默认 `loglevel: warning` **不打印**这条 —— 需要临时改 `debug` 才能看到：

```bash
python3 -c "
import json; p='/usr/local/etc/xray/config.json'
d=json.load(open(p)); d['log']={'loglevel':'debug'}
json.dump(d, open(p,'w'), indent=1)"
systemctl restart xray
# 排查完记得改回 warning
```

---

## 密钥处理

从旧备份复用私钥时，**先验证推导关系**再填客户端：

```bash
xray x25519 -i "<私钥>"          # 输出 PrivateKey / Password / Hash32
```

**`Password` 就是公钥**（对私钥的确定性推导）。验证方法：

```bash
# 生成新对, 再用私钥反推, 确认能复现同一 Password
xray x25519
xray x25519 -i "<刚生成的私钥>"
```

更可靠的交叉验证：**拿一台能用的节点的私钥推导，与客户端 DB 里记录的公钥对比** ——
一致就说明推导方法和字段语义都对。

```bash
# 服务端私钥 → 推导公钥
ssh root@<可用节点> 'xray x25519 -i "$(私钥)"'
# 与下面这个值比对
sqlite3 ~/Library/Application\ Support/v2rayN/guiConfigs/guiNDB.db \
  "select PublicKey from ProfileItem where Remarks='<可用节点>';"
```

本次实测两者完全一致，确认推导无误 —— 从而把嫌疑正确地排除掉。

---

## 接入 v2rayN

**必须先在托盘菜单 Exit 退出 v2rayN**，否则运行时修改 DB 会被覆盖。

节点记录的关键字段（VLESS + Reality）：

| 字段 | 值 |
|---|---|
| `ConfigType` | `5`（VLESS）|
| `Network` | `raw`（即 TCP）|
| `StreamSecurity` | `reality` |
| `Password` | **存的是 UUID** |
| `Sni` | target 域名 |
| `PublicKey` / `ShortId` | Reality 参数 |
| `Fingerprint` | `chrome` |
| `ProtoExtra` | `{"Flow":"xtls-rprx-vision","VlessEncryption":"none"}` |
| `TransportExtra` | `{"RawHeaderType":"none","Host":"","Path":""}` |

改完启动，生成的客户端配置应形如：

```json
{ "protocol": "vless",
  "settings": { "address": "23.165.40.14", "port": 8443,
                "id": "...", "encryption": "none", "flow": "xtls-rprx-vision" },
  "streamSettings": { "network": "raw", "security": "reality",
    "realitySettings": { "serverName": "www.intel.com", "fingerprint": "chrome",
                         "publicKey": "...", "shortId": "..." } },
  "mux": { "enabled": false } }
```

> XTLS-Vision **不要开 mux**，会破坏其零拷贝优化。

---

## 实测结果

| 指标 | Reality (8443 直连) | WS+TLS (经 Cloudflare) |
|---|---|---|
| GitHub 下载 | 2.11-2.38 MB/s | 2.02-2.32 MB/s |
| github TLS | 1.27-2.02s | 1.33-1.62s |
| google TLS | 1.19-1.22s | 1.01-1.29s |

**吞吐基本持平** —— 瓶颈是中美链路带宽（~2.3 MB/s），不是协议开销。

**Reality 的价值在可靠性而非速度**：
- 不依赖 Cloudflare，没有优选 IP 失效问题
- 直连少一跳
- Reality 伪装成真实站点，抗封锁能力更强

---

## 排查用的最小客户端配置

不要用 v2rayN 生成的完整配置做测试 —— 它带分流规则，引用 `geosite.dat` 等相对路径文件，
在 v2rayN 的工作目录外会直接启动失败，掩盖真正的问题。用最小配置：

```json
{
  "log": {"loglevel": "debug"},
  "inbounds": [{"tag":"t","port":10899,"listen":"127.0.0.1","protocol":"socks","settings":{"udp":true}}],
  "outbounds": [ <只放目标节点>, {"protocol":"freedom","tag":"direct"} ]
}
```

```bash
xray run -c /tmp/test-client.json       # debug 日志直接给出 EOF/reality 错误
curl -x socks5h://127.0.0.1:10899 https://www.google.com/generate_204
```

---

## 教训汇总

1. **旧配置备份不能照抄** —— 字段名会变，且旧名常被静默忽略。
2. **`-test` 通过 ≠ 配置被识别** —— 它只校验语法和已知字段。
3. **Reality 的 target 必须实测** —— 表面条件相同的两个站点，一个能用一个不能。
4. **排查要两端对照** —— 客户端的 EOF 和服务端的 invalid connection 是同一件事的两面。
5. **用已知可用的同类配置做基准** —— 对比字段集合、对比公钥推导，比凭空猜测快得多。
6. **升级二进制前先停服务** —— 否则 `cp` 报 `Text file busy`。
