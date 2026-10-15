# 15 · 机场只给 Clash 订阅，怎么让 v2rayN 自动更新

## 起因

用户发现一个重要线索：**同一个 IPEqual 机场，Clash Verge 那边一切正常，v2rayN 这边节点全挂。**

顺着查下去，暴露出两个独立的问题。

## 问题一：v2rayN 里的"订阅"是个假的

查 v2rayN 的数据库：

```
SubItem:
  Url                   https://llmapi.pro          ← 这是个「LLM API 中转站」的官网 ✗
  AutoUpdateInterval    0                            ← 自动更新关闭
  UpdateTime            0                            ← 从未更新过

ProfileItem:
  subid                 全部为空                      ← 16 个节点和订阅没有任何关联
guiNConfig:
  SubIndexId            None                         ← 没有选中任何订阅
```

**那 16 个节点是一次性导入的孤儿**，没有任何东西在更新它们。

### 后果：机场换 IP，v2rayN 全挂

```
Clash 里 (会自动更新, 今天 06:30 刚拉过):     v2rayN 里 (从未更新):
  专属纯净静态住宅  154.17.29.33   ✓ 没变      154.17.29.33
  日本CN2          154.16.248.109             151.242.165.73     ✗
  韩国CN2          61.111.247.112             61.111.247.177     ✗
  日本CN2-2        103.232.213.94             151.242.164.131    ✗
  韩国CN2-2        210.216.173.100            61.111.247.22      ✗
  日本CN2-3        151.242.164.241            151.242.164.177    ✗
  美国CN2          154.64.236.177             154.64.236.180     ✗
  美国CN2-2        154.64.236.39              154.64.236.32      ✗
  美国CN2-3        154.17.5.144               64.186.237.196     ✗
  韩国CN2-3        61.111.247.66              61.111.247.80      ✗
  德国CN2          189.24.106.167             189.24.106.64      ✗
```

**11 个节点里 10 个的 IP 已经变了。** 这看起来像"机场跑路了"，实际只是订阅没更新。

> ⚠️ **教训**：排查"节点全挂"时，先确认订阅是不是在更新，再去怀疑服务商。
> 我一开始就误判成了"IPEqual 服务故障"。

### 真实订阅地址在 Clash Verge 里

```
~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles.yaml

  - uid: RaRSHntfO0Rb
    type: remote
    name: IPEqual
    url: https://equaldcdn.com/use/unsafe/sub.php?t=<token>&s=<sha256>
    option:
      update_interval: 180        # 180 分钟
      allow_auto_update: true
```

URL 里的 `t=` 是 base64 的 JSON，解出来就是节点参数：

```json
{"uuid":"9DDAB30D-...","server":"154.17.29.33","port":"443",
 "public_key":"9OC_cGI4...","short_id":"4fb94eb8b29eea32",
 "servername":"www.cooper.edu","total":150323855360,"expire":1794392842}
```

## 问题二：直接把 vless:// 粘进 v2rayN 也不行

v2rayN 里逐条粘贴 `vless://` 能用，但那是**一次性导入** ——
`SubItem` 的自动更新完全不会碰它们。机场下次换 IP，又得手动重来。

**用户的原话很准确：「要 importsub 的方式，不要 vless 这种，好像自动更新不了」。**

## 方案：本地订阅转换服务

```
   v2rayN  ──订阅──>  http://127.0.0.1:18080/sub
                            │
                     sub-server.py  (拉取 + 转换 + 缓存)
                            │
                            v
                https://<机场>/use/unsafe/sub.php?t=..&s=..
                        (Clash YAML)
```

这样 v2rayN 的「自动更新」终于有了意义。

### 两个组件

**`scripts/clash-sub-to-v2rayn.py`** —— 转换核心

- 把 Clash YAML 的 `proxies:` 段转成 `vless://` / `vmess://` / `trojan://` / `ss://` / `hysteria2://`
- **零依赖**：不引入 PyYAML，自己按缩进层级解析（Clash 订阅结构很规整）
- 支持 `--format links|base64|json`、`--grep` 过滤、`--list` 列举

**`scripts/sub-server.py`** —— 本地 HTTP 服务

| 端点 | 用途 |
|---|---|
| `/sub` | base64 节点订阅 ← **v2rayN 订阅这个** |
| `/links` | 明文节点链接（人看 / 剪贴板导入） |
| `/list` | 节点名 + 服务器（排查用） |
| `/refresh` | 强制刷新缓存 |
| `/health` | 健康检查（JSON） |

`launchd/com.local.v2rayn-subserver.plist` 让它常驻（用户级 LaunchAgent，
只监听 127.0.0.1，不需要 root）。

订阅地址放在 `~/.v2rayn-tun/sub-url`（含 token，权限 600，**在仓库外**）。

v2rayN 侧的 `SubItem`：

```
Remarks              import_sub
Url                  http://127.0.0.1:18080/sub
Enabled              1
AutoUpdateInterval   180      # 分钟
ConvertTarget        (空)     # 已经是 v2ray 格式, 不需要再转换
```

## 踩到的三个坑

### 1. 必须「先监听，再拉数据」

第一版是 `get_links()` → `serve_forever()`。拉取要几秒到几十秒，这段时间
**端口根本没在听**，v2rayN 直接连不上（表现为 HTTP 000）。

改成先 `serve_forever()`，用后台线程 warmup。

### 2. 锁不能覆盖网络请求

第二版把整个 fetch 包在 `threading.Lock()` 里，结果 warmup 拉取期间
**所有 HTTP 请求都堵在锁上**，curl/v2rayN 拿到空响应（超时）。

改成：锁只用于读写缓存，网络请求在锁外；HTTP 端点在缓存过期时先返回旧数据，
后台异步刷新。

### 3. XML 注释里不能出现 `--`

LaunchAgent 的 plist 注释里写了 `v2rayN --订阅--> http://...`，
其中的 `--` 会**提前结束 XML 注释**：

```
plutil -lint: (Unexpected character h at line 9)
```

`plutil -lint` 是这类问题唯一可靠的检查手段，写 plist 后一定要跑。

### 4. `/health` 不应该是阻塞的

健康检查走了同步拉取，缓存一过期就要等 30 秒，看起来像"服务挂了"。
健康检查必须立即返回。

## 验证

```
/health   HTTP 200  {"ok": true, "count": 11, "age": 5, "error": null}
/list     HTTP 200  专属纯净静态住宅节点  154.17.29.33:443
/sub      HTTP 200  4828 字节 (base64, 11 个节点)
/refresh  HTTP 200  {"count": 11, "error": null}

解码 /sub 后:
  vless://9DDAB30D-...@154.17.29.33:443?encryption=none&flow=xtls-rprx-vision
        &type=tcp&security=reality&sni=www.cooper.edu&fp=chrome
        &pbk=9OC_cGI4...&sid=4fb94eb8b29eea32#专属纯净静态住宅节点
```

参数完整性检查（`pbk` / `sid` / `sni` / `fp` / `flow` 一个都不能少）——
11 个节点全部通过。**`sid` 缺失是实测踩过的坑**：Reality 少了 short-id 会连不上，
而我的第一版解析器因为嵌套处理写得绕，恰好把它丢了。

## 排查这类问题的方法

**「机场节点全挂」时按这个顺序：**

| 步骤 | 命令 | 判读 |
|---|---|---|
| 1. 订阅在更新吗 | `sqlite3 guiNDB.db "select Remarks,Url,AutoUpdateInterval,UpdateTime from SubItem;"` | `AutoUpdateInterval=0` / `UpdateTime=0` → 没在更新 |
| 2. 节点和订阅关联了吗 | `sqlite3 guiNDB.db "select distinct subid from ProfileItem;"` | 为空 → 是一次性导入的孤儿 |
| 3. 到 Clash 那边对一下 | `grep -A12 'name: <机场名>' profiles.yaml` | 拿到真实订阅地址 |
| 4. 拉一次对比 IP | `curl -A 'v2rayN/7.25.4' '<url>'` | IP 变了 → 就是没更新 |
| 5. 节点本身通不通 | 用 xray 直接跑一份最小配置 | 通了 → 问题在客户端配置 |

**第 5 步很关键** —— 它能把"节点坏了"和"客户端配置坏了"彻底分开。
实测中住宅节点用独立 xray 跑是 204，而 v2rayN 里 000，就是靠这一步定位的。

## 教训

1. **「粘贴节点」和「订阅」是两种东西。** 前者一次性，后者才会更新。
   要自动更新就必须走 `SubItem`。
2. **排查"节点全挂"先看订阅。** 我误判成机场故障，多绕了一大圈。
3. **中间加一层转换是正当解法。** 机场不改、客户端不改时，本地服务是最小代价。
4. **plist 写完必须 `plutil -lint`。** XML 注释里的 `--` 这种坑，不 lint 发现不了。
5. **服务要先监听再拉数据，锁不要覆盖网络 IO。** 两个都是会让客户端"连不上"
   的经典错误，而且症状一模一样（HTTP 000）。
