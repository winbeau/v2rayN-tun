# EasyConnect 与国内 DNS 查询冲突

2026-11-13，EasyConnect 已连接（utun5，10.99.1.106）时，DeepSeek Harness
显示 `DeepSeek Messages transport failed`。国内域名查询超时，Google 正常。

## 已取得的证据

- 系统 DNS 是 223.5.5.5 / 119.29.29.29，均进入 sing-box TUN。
- sing-box 的 `local-local` / `direct-dns-1` 使用 UDP 119.29.29.29。
- 国内域名从系统 DNS、显式 UDP DNS 和显式 TCP DNS查询均超时。
- 日志里同一个源端口的 DNS 包持续进入 TUN，进程归属为 EasyConnect 的
  `svpnservice`。日志快速增长至数 GB，sing-box / svpnservice 持续高 CPU。
- 通过本地 SOCKS 访问 DeepSeek，及用正常 DoH 解析出的 IP 配合
  `curl --resolve` 访问 DeepSeek，均收到 HTTP 401。测试没有发送密钥，
  401 只证明 TLS/HTTP 链路可达，不证明登录或模型推理正常。
- 独立 sing-box 只监听 loopback 高端口，将这两个国内 DNS 上游改为
  AliDNS HTTPS 后，DeepSeek 和百度查询均成功（该次约 143 ms），Google
  查询也成功。测试进程已退出，未重建线上 TUN。

这些证据把故障定位在国内明文 DNS 路径，并强烈支持 EasyConnect DNS
转发与 TUN 相互捕获形成循环。完整环路仍需应用修复后观察日志/CPU确认。

## 修复与应用

`scripts/fix-easyconnect-dns.py` 将两个 DNS 上游改为
`https://dns.alidns.com/dns-query`，用已有 hosts-dns 静态引导和 direct
出站；保留 DNS 分流、业务流量路由和所有代理节点。安装模板同步修正。

```bash
python3 scripts/fix-easyconnect-dns.py plan
# 关闭 Claude、Claude Code、AdsPower 后，由用户在终端执行：
sudo python3 scripts/fix-easyconnect-dns.py apply
```

plan 及 apply 都先校验配置，并用独立监听器验证国内/国外 DNS。
apply 检查客户端进程、备份配置、原子写入、重启 TUN，等待新 sing-box
进程与 TUN 地址出现，再验证系统 DNS 和 DeepSeek HTTPS。失败返回非零；
备份路径在写入前打印。脚本不删除已有日志，不修改 EasyConnect。

本次截至准备脚本时：预检通过，线上仍为原 UDP 配置；sudo 需要用户密码。
正式应用后还需确认 svpnservice 重复流量和 CPU 占用下降，以及 DeepSeek
真实对话恢复。不要把独立 DNS 预检写成“应用已恢复”。

## 同时核对的边界

- 10.103.92.120 经 EasyConnect utun5，1027 端口返回真实 OpenSSH 横幅。
  尚未用私钥验证登录。
- 默认 TUN 与显式 SOCKS 的本次 ipinfo 查询均返回 84.37.218.45。
  此结果不代表按进程分流的所有 Claude 客户端一定使用相同出口。
- EasyConnect 添加了多个公网 /32 路由，它们比 TUN 的 /8、/7 更具体。
  “TUN 能胜过 /1”不能推导为“VPN 绝不抢公网流量”。
- 旧 `check-exit.sh` 只检查少量固定 IP 和默认路由。其 ipinfo 请求并非
  Claude 请求，且归属查询失败时仍可能打印“境外正常”，不应作为安全保证。

## 连带问题：日志涨到 4.1 GB

环路期间 sing-box 每来一个 DNS 包就写一行，日志涨到 **4.1 GB**，磁盘可用空间
从 35 GB 掉到 31 GB。

**已处理**：

```bash
# 先留证据（最后 3000 行）
sudo tail -3000 /var/log/v2rayn-tun.log \
  > /usr/local/libexec/v2rayn-tun/logs-evidence/loop-before-fix-20261113.log

# 再截断
sudo truncate -s 0 /var/log/v2rayn-tun.log   # 或用 : > 
```

**加体积上限**，写进 `/etc/newsyslog.conf`：

```
/var/log/v2rayn-tun.log                 640  3     51200  *     J
```

含义：50 MB 触发轮转、保留 3 份、bzip2 压缩。`install.sh` 的 `setup_logrotate`
会自动加，`uninstall.sh` 不管它（留着无害）。

验证：

```bash
sudo newsyslog -n -v | grep v2rayn
# /var/log/v2rayn-tun.log <3J>: size (Kb): 8 [51200] --> skipping
```

**待改进**：`sing-box` 的 `log.level` 现在是 `info`，每条连接都记一行。
如果不需要审计，改成 `warn` 能再降一个数量级。但排障时会失去证据，所以暂时保持。

## 修复后的实测（2026-11-13 10:30）

| 项目 | 结果 |
|---|---|
| 国内 DNS 解析 | `api.deepseek.com` 32 ms、`baidu.com` 73 ms、`taobao.com` 72 ms ✓ |
| `api.deepseek.com` | HTTP 401，0.30 s（401 = 缺密钥，链路通）✓ |
| `chat.deepseek.com` | HTTP 200，0.35 s ✓ |
| 日志增长 | 5 秒 1 KB，基本归零 ✓ |
| sing-box CPU | 1.2%（故障时打满）✓ |
| svpnservice CPU | 0.8% ✓ |
| 日志里 svpnservice 占比 | 最近 500 行里 2 行（故障时几乎全是）✓ |

## 路由分工实测

EasyConnect 连上后：

```
10.103/16       -> utun5 (EasyConnect, 10.99.1.106)   ✓ VPN 内网
外网            -> utun7 (sing-box TUN, 172.19.0.1)   ✓ 走代理
192.168.99.0/24 -> utun6 (WireGuard)                   ✓ NAS
```

**纠正一个旧结论**：早期判断「TUN 的 `/8`、`/7` 能胜过 EasyConnect 的 `/1`，
所以不会冲突」**不充分**。EasyConnect 实际插的是 **`10.103/16`** ——
比我们的 `10.0.0.0/8` 排除**更具体**，所以它赢。这才是 VPN 能正常工作的真实原因，
而不是「我们的大网段压过它的 /1」。

## 未验证的部分（不要当成已修复）

- **DeepSeek 真实对话**：只验到 HTTP 401/200 和 TLS 可达，没有密钥，没有跑真实补全。
- **Claude 实际客户端**：`AdsPower` 里的 `SunBrowser` 走 `node-direct` 出站，
  和普通 curl 的路径不同。**没有启动 AdsPower 验证，不能拿 curl 的出口代表它。**
- **`check-exit.sh` 不能当账号安全保证**：它只测少量固定 IP，归属查询失败时
  可能误报「境外正常」。

## 三隧道共存时的路由分工

```
接口      地址              谁             负责的网段
utun5     10.99.1.106       EasyConnect    10.103/16
utun6     192.168.99.2      WireGuard      192.168.99.0/24
utun7     172.19.0.1        sing-box TUN   其余全部
```

**接口编号每次都不一样**，别写死。用 `ifconfig` 重新认。

## 如果复发怎么查

**症状**：国内域名解析超时、日志疯涨、`svpnservice` 和 `sing-box` 双双高 CPU。

```bash
# ① 看日志涨没涨
ls -lh /var/log/v2rayn-tun.log

# ② 看是不是同一批 DNS 包在打转
sudo tail -200 /var/log/v2rayn-tun.log | grep -c svpnservice

# ③ 确认 DNS 上游还是 HTTPS（被改回 UDP 就是复发了）
sudo python3 -c "
import json
d = json.load(open('/usr/local/libexec/v2rayn-tun/config.json'))
for s in d['dns']['servers']:
    if s['tag'] in ('local-local', 'direct-dns-1'):
        print(s['tag'], s.get('type'), s.get('server'))
"
# 期望: https dns.alidns.com

# ④ 复发就重跑修复
python3 scripts/fix-easyconnect-dns.py plan
sudo python3 scripts/fix-easyconnect-dns.py apply
```

**注意**：`apply` 会重启 TUN，重启前必须确认 Claude / Claude Code / AdsPower 已关闭。

## 一个还没做的优化

`sing-box` 的 `log.level` 是 `info`，每条连接一行，实测约 **88 MB/天**。
有 newsyslog 的 50MB × 3 兜着不会失控，但会一天触发两次轮转。

改成 `warn` 能降一个数量级，代价是失去连接级排障证据。
