> **一句话**：同一个 IP 从跳板机通、从本机不通 —— 是本地网络的封锁，不是节点坏了；用 SSH 中转把入口搬回来，**出口 IP 不变**。

# 25. 全部代理入口突然不通（本地网络封锁，走跳板机中继）

## 现象（2026-11-21 07:00）

- 所有网站打不开，Claude / 浏览器 / `git pull` 全挂
- `git pull` 报 `LibreSSL SSL_connect: SSL_ERROR_SYSCALL`
- 本机 `nc -z 72.249.203.{69,77,81,245} 12442` 全部 closed，`ping` 100% 丢包
- 但 `1.92.76.152:22`（跳板机）通、Cloudflare 通 —— 网络本身没断

## 怎么定性（关键）

同一批目标，换一个源点测：

```bash
ssh huawei1 'for hp in 72.249.203.81:12442 154.17.27.236:4561 191.101.132.249:443; do
  ip=${hp%:*}; p=${hp#*:}; printf "%-24s " $hp
  timeout 5 bash -c "echo > /dev/tcp/$ip/$p" 2>/dev/null && echo OPEN || echo closed; done'
```

结果：**从 huawei1 全部 OPEN**，从本机全部 closed，而订阅 API 同样如此。
→ 本地网络（校园网 → `10.109.68.1` → `202.201.188.1`）挡这几个目标，
provider 和节点都正常。

## 两个假信号

1. `ping 72.249.203.1` 只有 **0.3 ms** —— 那是 sing-box 的本地回包（原则 29），不是真 RTT。
   真正的入口 `.81` 走的是排除路由（直连），`ping` 100% 丢包才是真结果。
2. `nc -z` 打**非排除**目标一定"成功" —— 只能测排除清单里的 IP。

## 解决：`scripts/residential-relay.sh`

```bash
./scripts/residential-relay.sh on        # 4 条住宅入口各建一条 SSH 本地转发 19442-19445
./scripts/residential-relay.sh point     # 把 v2rayN 那 4 条的 Address 指到 127.0.0.1
./scripts/residential-relay.sh status    # 每个端口是否在听
./scripts/residential-relay.sh restore   # 换回真实入口（离开受限网络时）
./scripts/residential-relay.sh off       # 拆 launchd 任务
```

Reality 是端到端的，跳板机只做 TCP 中继，所以 **Claude 看到的还是 `48.47.154.42`**
（Comcast 家宽，实测）。代价：**~0.25–0.5 MB/s**，多 ~58 ms（跳板机带宽上限）。

## 四个坑

1. **v2rayN 订阅自动更新会把 Address 改回真实 IP**（原来 180 分钟一次）——
   已置 `AutoUpdateInterval=0`。要手动更新时：`restore` → GUI 更新 → `on` → `point`。
2. **`ProfileItem.IndexId` 会随订阅更新变化**，脚本按 `Address+Port` 匹配，不写死 ID。
3. **改 DB 前必须让 v2rayN 退出**，否则它退出时用内存值覆盖回去（脚本已用 osascript 处理）。
4. `fix-loop.sh` / `per-app-routing.py` 会把入口 IP 重新加进排除清单 —— 不影响中继，
   但会让 `nc` 测出"直连"的假象。

## 复发预案

- 先按「怎么定性」从跳板机测一次：**那边通 = 本地封锁**（用中继）；**那边也不通 = provider 故障**（等或换线路）
- 只临时用一次手机热点也能验证，但中继比热点稳
- 离开受限网络后别忘 `restore` + `off`，否则无谓地多绕一跳
