# 20 · 节点参数被官方改了怎么办

> **一句话**：节点连不上时，**先比对端口/uuid/公钥有没有变**，再怀疑自己的配置 —— 官方改参数不会通知任何人。

## 现象

住宅节点突然连不上。TCP 能通（`nc -z <ip> 443` 成功），但代理建不起来，20 秒超时。

```
经 node-direct（住宅线路）:  ✗ URLError 20.0s
经日本CN2-3（对照）:        ✓ HTTP 204 1.0s
```

**对照组正常 → 本地没问题；TCP 通但隧道不通 → 服务端那边变了。**

## 定位步骤

### 1. 拉最新的上游订阅，比对参数

```bash
URL=$(cat ~/.v2rayn-tun/sub-url-2)
curl -s --noproxy '*' "$URL" -o /tmp/up.yaml
```

看看和我们配的是不是一样：

| 字段 | 上游（新） | 我们（旧） | 判断 |
|---|---|---|---|
| server | `154.17.27.236` | `154.17.27.236` | ✓ 没变 |
| **port** | **`4561`** | **`443`** | **✗ 变了** |
| uuid | `A7310AE4…` | `A7310AE4…` | ✓ |
| public-key | `gEuRyPLr…` | `gEuRyPLr…` | ✓ |
| short-id | `303a1165…` | `303a1165…` | ✓ |
| servername | `www.cooper.edu` | `www.cooper.edu` | ✓ |

**只有端口变了。** 443 上还有别的东西在监听（所以 TCP 测试是"通"的），
但 vless 服务已经搬到 4561。

### 2. 用两个端口各测一次，确认

```bash
# 用新端口能不能通
# 结果: 443 ✗ 超时 20s / 4561 ✓ HTTP 200, 出口 66.248.154.224, 2.0s
```

**这一步做完就不需要再猜了。**

### 3. 更新线上配置

```bash
sudo ./scripts/per-app-routing.py apply --sub sub2
```

它从 `/sub2` 重新生成 `node-direct` 出站，端口自动跟上。

## 这次的完整根因链

```
① 官方把住宅节点端口 443 -> 4561
② 同时把订阅返回格式从 base64 链接换成了 Clash YAML
   （域名也从 ipequal.com 换到 equalcddn.com）
③ 本地 sub-server 的缓存 TTL 是 60 秒
④ 用户在上游变更后立刻点 v2rayN 的"更新订阅"
   -> 拿到缓存里的旧端口 443
   -> v2rayN 照着写进数据库
   -> 那条住宅线路连不上
```

**三个问题叠在一起，症状却只有一个："连不上"。**

## 已做的改进

| 改动 | 原因 |
|---|---|
| `sub-server` 的 `CACHE_TTL` 60s → **10s** | 上游不提供 `ETag` / `Last-Modified`，且 `cache-control: no-store` —— 没法做条件请求，只能让过期窗口足够短 |
| `/sub`、`/subN` 改为 `block=True` | 过期就等一次真实拉取。宁可慢 1~2 秒，也不把过期参数交给 v2rayN |
| 失败回退保留 | 拉取失败仍返回上次的好数据，不会 502（v2rayN 收到 502 会清空整个订阅组）|
| 磁盘缓存 | 进程重启后仍能兜住第一次失败 |

## 排查清单（下次直接照做）

```
① nc -z <节点IP> <端口>              端口通吗
② 用对照节点测一次                   本地有没有问题
③ 拉上游订阅比对 server/port/uuid/pbk  参数有没有变
④ 用"新参数"单独测一次                确认新参数能用
⑤ 更新配置                            per-app-routing.py apply
```

**关键心态**：**"连不上"的第一反应不该是改自己的配置** ✗ —— 先证明**是外部变了** ✓ 再动手 ✓ 否则会在一个没坏的地方改来改去，把好的东西也改坏 ✓

## 附：一个容易混的点

**"切换了 2-geneva" ≠ "选中了住宅节点"** ✗

```
SubIndexId  决定【左侧显示哪个分组】     <- 用户切的是这个
IndexId     决定【当前用哪个节点】       <- 这个没变, 还是日本CN2-3
```

切完分组后**还要在列表里点一下住宅节点**，出口才会变成住宅 IP。
判断方法：

```bash
# 看当前节点是什么
python3 -c "
import json, os, sqlite3
p = os.path.expanduser('~/Library/Application Support/v2rayN/guiConfigs/guiNConfig.json')
cfg = json.load(open(p, encoding='utf-8'))
db = os.path.expanduser('~/Library/Application Support/v2rayN/guiConfigs/guiNDB.db')
con = sqlite3.connect(f'file:{db}?mode=ro', uri=True); con.row_factory = sqlite3.Row
r = con.execute('select Remarks, Address, Port from ProfileItem where IndexId=?', (str(cfg['IndexId']),)).fetchone()
print(r['Remarks'], f\"{r['Address']}:{r['Port']}\")
"

# 或者直接看出口 IP
curl -s --noproxy '*' https://api.ipify.org
```
