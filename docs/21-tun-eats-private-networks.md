# 21 · TUN 把内网也吃掉了

> **一句话**：`auto_route` 的覆盖路由会把 `10/8`、`192.168` 这些内网一起抓进 TUN —— 校园网、WireGuard、路由器后台全废。

## 现象

TUN 起来之后：

```
路由器后台打不开
ping 校园网关 不通
WireGuard 对端连不上 → NAS 隧道跟着断
SMB 走 41445 那条路径不通
```

**但同一个 Mac 上，`192.168.5.0/24` 里的东西是好的** —— 因为那条有更具体的 `en0` 路由。

## 根因

`auto_route` 会往系统里插这些覆盖路由（为了抓全流量）：

```
1         -> utun5
2/7       -> utun5      ← 2.0.0.0   – 3.255.255.255
4/6       -> utun5      ← 4.0.0.0   – 7.255.255.255
8/5       -> utun5      ← ★ 8.0.0.0 – 15.255.255.255 ★
16/6      -> utun5
...
128.0/4   -> utun5
```

**`8.0.0.0/5` 正好把 `10.0.0.0/8` 包进去了** ✗

而 `10.0.0.0/8` 里躺着：

| 地址 | 是什么 |
|---|---|
| `10.109.68.1` | 校园网网关 |
| `10.109.69.103` | 417 路由器 WAN |
| `10.109.69.169` | 411 路由器 WAN —— **也是 WireGuard 对端** |

**最阴的一点**：WireGuard 的对端 `10.109.69.169:41444` 也被抓进 TUN 了。
它之所以还能通，是因为 sing-box 的 `auto_detect_interface` 让 direct 出站绑到了物理网卡 ——
多绕一层用户态，而且**代理一挂，NAS 隧道跟着挂**。

## 怎么验证

```bash
for ip in 10.109.69.169 10.109.68.1 192.168.99.1 192.168.5.1; do
  printf "%-16s " "$ip"
  route -n get "$ip" 2>/dev/null | awk '/interface:/{print $2}'
done
```

**期望**：内网地址都是 `en0`（或隧道自己的 `utun6`）。
**实际**：`utun5` 就是被吃了。

## 修法

### 1. 写进排除清单

```bash
cat >> ~/.v2rayn-tun/tun-exclude.txt <<'EOF'
10.0.0.0/8          # 校园网
192.168.99.0/24     # WireGuard 隧道段
EOF
```

**格式**：每行一个 CIDR，`#` 开头是注释。

### 2. 让守护每次启动都合并

`daemon/run-tun.sh` 的 `prepare_conf()` 里调用 `apply_excludes`：

```bash
apply_excludes() {
    /usr/bin/python3 - "$RUN_CONF" "$EXCLUDE_FILE" <<'PYEOF' || true
    # 读 tun-exclude.txt，合并进 inbounds[tun].route_exclude_address
    # 再加一条「目标在排除网段内 -> direct」的规则（双保险）
PYEOF
}
```

**为什么必须在守护里兜底**：`fix-loop.sh` / `per-app-routing.py` 会重写
`route_exclude_address`，只留节点 IP。不兜底的话排除清单会被冲掉。

### 3. 重启

```bash
sudo launchctl kickstart -k system/com.local.v2rayn-tun
```

## 踩过的三个坑

### ① `bind_interface: en0` 在 macOS 上不生效

给 `direct` 出站加 `bind_interface` 想让它走物理网卡 —— **没用** ✗
macOS 上必须在**路由层**排除（`route_exclude_address`）。

### ② 脚本把清单覆盖掉了

`fix-loop.sh` 原来写的是：

```python
t['route_exclude_address'] = ips          # ★ 覆盖 ★
```

改成：

```python
merged = sorted(old | set(ips))           # ✓ 追加 ✓
```

**否则跑一次 `fix-loop.sh`，校园网排除就没了。**

### ③ sing-box 拒绝规则里的自定义字段

为了标记"这条规则是我加的"，给它塞了个 `_tun_excl: true`：

```
FATAL decode config: route.rules[30]._tun_excl: json: unknown field "_tun_excl"
```

**sing-box 对未知字段是硬失败** ✗ —— 而且失败后守护会**静默回退**到未合并的配置 ✗

**正解**：靠内容识别（`ip_cidr` 集合相等），不塞自定义字段。

## 现在的排除清单

```
10.0.0.0/8          校园网（含 WireGuard 对端）
192.168.99.0/24     WireGuard 隧道段
+ 15 个代理节点 IP（防环路，见 19）
```

## 顺带：一个必须记住的区别

**`192.168.5.87`（Pi NAS）ping 不通是正常的** ✓

它挂在 **411 路由器**的 LAN 上，和 417 **撞段**（都是 `192.168.5.0/24`）。
从 417 这边只能在**同一个 /24 里**以为连得上，实际不路由。
**要访问 Pi 必须走 411 的端口转发**：

```
TCP 41445 -> 192.168.5.87:445     (SMB)
UDP 41444 -> 192.168.5.87:41444   (WireGuard)
```

**Mac 到 NAS 的正常路径是 WireGuard（`192.168.99.1`），不是 `192.168.5.87`。**
