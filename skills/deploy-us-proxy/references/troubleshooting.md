# 故障排查

排查顺序固定：**服务是否在跑 → 流量是否到达主机 → 握手是否成功 → 转发是否正常**。跳步会浪费大量时间，尤其不要在客户端参数上反复调整，而实际上流量根本没到服务器。

## 第 1 层：服务状态

```bash
systemctl is-active xray
systemctl status xray --no-pager -l
journalctl -u xray -n 50 --no-pager
ss -tlnp | grep xray
/usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json
```

| 现象 | 原因与处理 |
|---|---|
| `Active: failed`，日志 `permission denied` | unit 缺 `AmbientCapabilities=CAP_NET_BIND_SERVICE`，非 root 用户无法绑定 1024 以下端口 |
| `address already in use` | 端口被占。`ss -tlnp` 找出占用进程，换端口或停掉对方 |
| 启动即退出，日志有 JSON 报错 | 配置语法错。`xray run -test` 会给出具体行 |
| `failed to read config` | 配置文件权限不对，`xray` 用户读不到。`chown xray:xray` |

## 第 2 层：流量是否到达

这一层最常被跳过，也最常是真凶。判据是**服务端日志有没有出现 `accepted`**。

```bash
journalctl -u xray -f
# 另一侧让客户端发起连接，观察是否有记录
```

日志完全没有记录 = 流量没到主机。按这个顺序查，不要颠倒：

1. **VPS 面板安全组**。云厂商的安全组独立于主机防火墙，是最常见的拦截点。检查入站是否放行了目标端口的 TCP。
2. **云网络 ACL / VPC 规则**（如果有）。
3. **主机防火墙**：

```bash
sudo ufw status
sudo iptables -L INPUT -n --line-numbers
sudo nft list ruleset 2>/dev/null | head -40
```

4. **从外部验证端口可达**。在另一台机器上：

```bash
nc -vz -w 5 <server_ip> 443
curl -sv --max-time 8 telnet://<server_ip>:443
```

连接被拒绝（RST）说明包到了主机但没有服务在听；超时无响应说明被中途丢弃，问题在防火墙或链路。

## 第 3 层：握手

服务端有 `accepted` 但客户端连不通，问题在参数或 dest。

服务端和客户端必须严格一致的三项：

| 服务端字段 | 客户端字段 | 说明 |
|---|---|---|
| `realitySettings.serverNames[0]` | `sni` | 不一致直接握手失败 |
| `privateKey` 对应的公钥 | `pbk` | 客户端用公钥，不是私钥 |
| `shortIds[]` 中的某一项 | `sid` | 必须是服务端列表里存在的值 |

核对公钥是否与服务端私钥匹配：

```bash
sudo /usr/local/bin/xray x25519 -i "$(sudo grep -oP '"privateKey":\s*"\K[^"]+' /usr/local/etc/xray/config.json)"
```

输出的公钥必须与链接里的 `pbk` 完全一致。

其他握手类问题：

- **dest 从服务器不可达**，或 dest 停止支持 TLS 1.3 / X25519。重跑 `scripts/probe_dest.sh` 复核。
- **客户端时间偏差过大**。REALITY 对时间敏感，偏差超过几分钟会失败。`timedatectl` 检查两端。
- **客户端版本过低**。v2rayN 需要 6.x 以上；低版本没有 REALITY 或 Vision 选项，导入链接时会静默丢字段。导入后检查节点详情里 `flow` 是否为 `xtls-rprx-vision`。

## 第 4 层：能连但不正常

| 现象 | 排查 |
|---|---|
| 速度远低于服务器带宽 | 确认 BBR 生效：`sysctl net.ipv4.tcp_congestion_control`；确认有 AES-NI：`grep -o aes /proc/cpuinfo \| head -1` |
| 延迟正常但吞吐上不去 | 多为链路拥塞或 QoS，不是配置问题。换时段对比，或测同机房其他 IP |
| 部分网站不通 | 服务端路由规则拦了。检查 `routing.rules`，本 Skill 默认屏蔽了私有地址和 BitTorrent |
| UDP / QUIC 不通 | 检查客户端是否开了 UDP 转发；部分网络会整体丢弃 QUIC，可在客户端禁用 QUIC 回落 TCP |
| 时通时断，且服务端日志无记录 | 服务器 IP 可能已被针对性阻断。换 dest 无效，需要换 IP |

## 第 5 层：静默失败的配置陷阱 ⚠️

这一层的共同特征是 **`xray run -test` 报 `Configuration OK`，但功能不正常** ——
语法和已知字段都通过了，问题出在字段语义和运行环境上。

### 5.1 `dest` 已被改名为 `target`

```
可用节点: ['privateKey','serverNames','shortIds','show','target','xver']
出问题的: ['dest','serverNames','privateKey','shortIds']
```

新版 Xray **静默忽略 `dest`** —— 不报错、不警告，`-test` 输出 `Configuration OK`，
但 REALITY 没有回落目标，握手必然失败。

**从旧配置备份还原参数时最容易踩**，因为备份里就是旧名。

```bash
# 一条命令自查
python3 -c "
import json; d=json.load(open('/usr/local/etc/xray/config.json'))
for i in d['inbounds']:
    st=i.get('streamSettings',{})
    if st.get('security')=='reality':
        print(i.get('tag'), sorted(st['realitySettings'].keys()))"
```

正确字段集：`['privateKey','serverNames','shortIds','show','target','xver']`

### 5.2 target 的"表面条件"不足以判断可用性

实测对比（同一台服务器、同样配置，只换 target）：

```
www.microsoft.com  →  REALITY: handshake did not complete successfully
www.intel.com      →  HTTP 204 ✓
```

两者都是 Akamai、都支持 TLS 1.3、都有 AAAA 记录 —— **表面条件完全相同**。

**做法**：先拿一台已知可用节点的 target 跑通，再逐步替换。
探测表（`probe_dest.sh`）只是初筛。

### 5.3 BBR 模块持久化写在了错误的分支里

`tcp_available_congestion_control` 里没有 `bbr` **不等于**内核不支持：

```bash
find /lib/modules/$(uname -r) -name "tcp_bbr*"    # 模块文件存在
modprobe tcp_bbr                                   # 加载后即可用
```

但**持久化必须与「当前是否已加载」解耦**。这个写法是错的：

```bash
if ! grep -qw bbr <<< "$(sysctl -n net.ipv4.tcp_available_congestion_control)"; then
    modprobe tcp_bbr
    echo "tcp_bbr" > /etc/modules-load.d/proxy-tuning.conf   # ← 在 if 里面
fi
```

**一旦模块已被加载过**（例如先手工 `modprobe` 过），分支不再进入，
持久化文件永远不会创建。当时**测不出任何异常**（BBR 正在生效），
**只有重启才会暴露**：BBR 丢失，且 sysctl 静默失败保持 cubic。

```bash
# 正确的写法: 两步独立
sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr || {
    modprobe tcp_bbr
    sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr || exit 1
}
grep -qx tcp_bbr /etc/modules-load.d/proxy-tuning.conf 2>/dev/null || \
    echo "tcp_bbr" >> /etc/modules-load.d/proxy-tuning.conf
```

**教训**：把「让当前状态正确」和「让重启后状态正确」写成两件独立的事。
检查脚本产物时，**要检查它写出的文件，而不是它是否没报错**。

### 5.4 客户端与服务端 Xray 版本差距过大

服务端 26.2.6 配客户端 26.9.9 时 REALITY 握手失败，升到 26.3.27 后正常。
排查时把两端版本一起打出来对比，不要只看一端。

```bash
# 服务端
ssh root@<server> 'xray version | head -1'
# 客户端 (macOS, v2rayN 自带核心)
"$HOME/Library/Application Support/v2rayN/bin/xray/xray" version | head -1
```

### 5.5 节点被客户端核心拒绝加载

```
cannot connect via Xray-core versions 26.2.6 or higher
Insecure configuration detected: AllowInsecure is enabled but no certificate is provided
```

**这不是网络问题，换什么都没用** —— 客户端在加载阶段就拒绝了。
根因通常是服务端用了 Cloudflare Origin 证书，客户端只能 `insecure`。
解法是换公开 CA 签发的证书（见 [hysteria2.md](hysteria2.md)）。

---

## 用最小配置做排查 ⭐

**不要用 v2rayN 生成的完整配置做测试。** 它带分流规则，引用 `geosite.dat` 等相对路径文件，
在 v2rayN 的工作目录外会直接启动失败，把真正的问题掩盖掉：

```
failed to load config files: illegal domain rule: geosite:google >
failed to open geosite.dat > stat .../geosite.dat: no such file or directory
```

用最小配置，只保留目标节点：

```json
{
  "log": { "loglevel": "debug" },
  "inbounds": [
    { "tag": "t", "port": 10899, "listen": "127.0.0.1",
      "protocol": "socks", "settings": { "udp": true } }
  ],
  "outbounds": [ <只放目标节点>, { "protocol": "freedom", "tag": "direct" } ]
}
```

```bash
xray run -c /tmp/test-client.json    # debug 日志直接给出 EOF / reality 错误
curl -x socks5h://127.0.0.1:10899 https://www.google.com/generate_204
```

### 两端报错要对照看

| 位置 | 输出 | 含义 |
|---|---|---|
| 客户端 | `failed to find an available destination > common/retry: [EOF]` | TCP 连上了但被服务端立即关闭 → 握手失败 |
| 服务端 | `REALITY: processed invalid connection from <ip>: handshake did not complete successfully` | 收到连接但认证不通过 |

**合起来才能确定是握手参数问题，而不是网络问题。**

服务端默认 `loglevel: warning` **不打印**这条，需要临时改 `debug`：

```bash
python3 -c "
import json; p='/usr/local/etc/xray/config.json'
d=json.load(open(p)); d['log']={'loglevel':'debug'}
json.dump(d, open(p,'w'), indent=1)"
systemctl restart xray
# 排查完记得改回 warning
```

### 用可用节点做基准对照

怀疑参数错误时，**对比一台能用的同类节点**比凭空猜测快得多：

```bash
# 1. 对比配置字段集
ssh root@<可用节点> 'python3 -c "..."'   # 见 5.1
# 2. 对比公钥推导是否正确
ssh root@<可用节点> 'xray x25519 -i "<该节点的私钥>"'
sqlite3 ~/Library/Application\ Support/v2rayN/guiConfigs/guiNDB.db \
  "select PublicKey from ProfileItem where Remarks='<可用节点>';"
#   两者一致 → 推导方法与字段语义都正确, 可以排除密钥问题
```

`xray x25519 -i <私钥>` 输出的 **`Password` 字段就是公钥**（对私钥的确定性推导）。

---

## 多机一致性检查

```bash
scripts/vps-compare.sh <server1> <server2>
```

差异行标 ⚠。**单看每台都"正常"的问题只有横向比对才会暴露** ——
上面的 5.3（BBR 持久化）就是这样发现的。

---

## 回滚

配置变更前脚本都会留带时间戳的备份：

```bash
ls -la /usr/local/etc/xray/config.json.bak.*
sudo cp -a /usr/local/etc/xray/config.json.bak.<时间戳> /usr/local/etc/xray/config.json
sudo /usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json
sudo systemctl restart xray
```

## 完全卸载

```bash
sudo systemctl disable --now xray
sudo rm -f /etc/systemd/system/xray.service /etc/sysctl.d/99-xray-tune.conf
sudo systemctl daemon-reload
sudo rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray /usr/local/bin/xray
sudo userdel xray 2>/dev/null || true
sudo sysctl --system >/dev/null
```
