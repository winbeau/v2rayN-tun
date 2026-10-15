# AGENTS.md

本仓库是**代理工具链**的唯一归口：Linux VPS 的服务端部署 + macOS 客户端的透明代理。
所有代理相关的配置、脚本、记录都放在这里。

## 目录导航

| 目录 | 内容 |
|---|---|
| [`skills/`](skills/) | **技能包**（agent 入口）。开始相关任务前先读对应的 `SKILL.md` |
| [`docs/`](docs/README.md) | 排查记录：18 份按主题组织的「弯路 + 解法」 |
| [`scripts/`](scripts/) | 服务端调优、运维工具、签名证书准备（可独立使用） |
| `config/` `daemon/` `launchd/` | TUN 守护进程与 Cmd+Q 拦截器的安装源文件 |
| `install.sh` `uninstall.sh` | TUN 守护进程的安装 / 卸载 |

### 装完之后先跑这个（只在新机器上需要）

```bash
./scripts/setup-signing-cert.sh      # 本地代码签名证书, 一次性
```

`daemon/quit-guard.swift` 需要**辅助功能**权限，而 macOS 的 TCC 授权对 adhoc
签名是按 CDHash 校验的 —— **每次重编译都等于换了个程序，授权立即失效**，
用户得反复去设置里重新添加。用固定证书签名后授权绑定证书，重编译不再失效。

**没有这个证书时，`install.sh` 会回退 adhoc 签名并打印警告 —— 功能能用，
但每次改代码都会让用户白授权一轮。** 详见 [docs/12](docs/12-quit-guard.md)。

## 技能索引

技能放在 [`skills/`](skills/)。**开始相关任务前先读对应的 `SKILL.md`。**

| 技能 | 用途 | 入口 |
|---|---|---|
| [`deploy-us-proxy`](skills/deploy-us-proxy/SKILL.md) | 把一台 Linux VPS 刷成 **REALITY + Hysteria2** 节点，输出可导入 v2rayN 的分享链接 | [SKILL.md](skills/deploy-us-proxy/SKILL.md) |
| [`macos-tun-no-proxy`](skills/macos-tun-no-proxy/SKILL.md) | macOS 上把代理整成 **TUN 透明模式**（无系统代理、无代理环境变量），并排查切网后的疑难故障 | [SKILL.md](skills/macos-tun-no-proxy/SKILL.md) |

两个技能是配套的：前者产出节点链接，后者在本机把流量透明地送过去。

### 什么时候用哪个

| 用户说 | 用 |
|---|---|
| 搭建 / 部署 / 刷节点、要链接、节点连不上 | `deploy-us-proxy` |
| 开 TUN、去掉代理变量、微信卡、切网后程序报错、IPv6 泄漏 | `macos-tun-no-proxy` |

## 两条链路的分工

部署出来的两条链路**不是冗余重复，而是应对不同失效场景**：

| 链路 | 协议 | 定位 |
|---|---|---|
| Hysteria2 | QUIC/UDP | **首选**。延迟显著更低（实测 0.21s vs 1.2s）——不存在 TCP-in-TCP |
| REALITY + Vision | TCP/TLS | 备用。UDP 被限制、或需要更强抗封锁伪装时 |

**不要只部署其中一条。** 只部署 Hysteria2 会在 UDP 受限的网络里全断；
只部署 REALITY 会白丢 5-6 倍的延迟优势。

## 贯穿两份技能的几条原则

这些是踩坑换来的，优先级高于「看起来更省事」的做法：

1. **先分层定位，再动手。** 证明问题不在本地，再往外查。
   国内能通就说明 TUN / 路由 / DNS 都健康，不要在自己的配置里空转。
2. **间歇性故障必须在故障发生时取数。** 事后测到的「正常」会误导结案。
3. **不要相信"没报错"。** 检查脚本产物时要检查它**写出的文件**：
   - `xray run -test` 输出 `Configuration OK`，仍可能因为字段改名（`dest` → `target`）而完全不可用
   - 调优脚本「执行成功」，仍可能因为持久化写在错误的分支里，重启后静默失效
4. **字段/参数的"表面条件"不足以判断可用性，必须实测。**
   两个都是 Akamai、都支持 TLS 1.3 的站点，一个能用作 REALITY target 一个不能。
5. **用户的体感描述是一手数据，优先级高于推断。**
   本项目两次「已排除」都是错的，而用户的两次直觉都指向了真因。
6. **不要用 `sudoers` NOPASSWD 走捷径。** 它会让用户可写目录下的文件获得免提权能力。
7. **不要自己跑需要密码的 `sudo`。** 把命令交给用户执行。
8. **不要把"需要用户授权"的步骤排在改动链的中间。** 每改一次代码就要用户重新
   授权一次（见下条），所以相关改动要**攒够了一次性做完**，否则用户会白做好几轮。
9. **涉及 TCC 权限的功能，先解决签名的稳定性再动代码。**
   adhoc 签名的二进制，TCC 授权绑 CDHash，**重编译即失效**。本项目因此让用户
   反复授权了五六轮，最后演变成"授权框反复弹出、点了还有"。
   正确顺序是：先把 `scripts/setup-signing-cert.sh` 跑通，再开始改。
10. **破坏性命令要算影响面。** `tccutil reset Accessibility`（不带标识）会清掉
   **系统里所有应用**的辅助功能授权，包括终端本身 —— 一次误用就能让整机的
   自动化工具全废。能带标识就带标识；带不了就优先手动操作。
11. **"代理断了就恢复直连"是危险的默认值。** 它的出发点是"不让用户断网"，
   但对 Claude / ChatGPT 这类强风控服务，代价是**把真实 IP 交出去** ——
   用户因此被封过号。对这类场景，代理不可用时的正确默认是**阻断**而不是放行。
12. **判断代理健康不能只看端口。** 休眠时进程还在、socket 还在，但网络栈已被
   系统拆掉。必须同时确认"接口是否真的存在"。
13. **轮询周期就是泄漏窗口。** 30 秒轮询 = 30 秒暴露。能用事件驱动就别轮询。
14. **不要假设"节点只是中转"。** 实测商业节点会按 SNI 选择性屏蔽域名。
    "某个网站打不开但其他都正常"时, 节点本身要列为嫌疑对象。
    定位方法: 固定 IP 只换 SNI —— `curl -k --resolve '<sni>:443:<ip>' https://<sni>`。
15. **DNS 和路由是两套规则, 加直连例外时必须一起改。** 只改一处会得到
    "DNS 走代理、流量走直连"的不一致状态。参考微信为什么直连: 两处都命中
    `geosite-cn`。
16. **"粘贴节点"和"订阅"是两种东西。** 前者一次性, 后者才会更新。
    要自动更新就必须走 SubItem。排查"节点全挂"时【先看订阅有没有在更新】,
    再去怀疑服务商 —— 本项目曾因此误判成"机场跑路"。
17. **写完 plist 必须 `plutil -lint`。** XML 注释里出现 `--` 会提前结束注释,
    报错信息 (`Unexpected character h at line 9`) 完全指不到真正原因。
18. **本地服务要先监听再拉数据, 且锁不能覆盖网络 IO。** 两个错误都表现为
    客户端拿到 HTTP 000, 症状一模一样。
19. **★★ 改路由规则前先数清楚有几层。★★**
    本项目有【两层】国内直连: sing-box 一层、xray(v2rayN 路由)一层。
    只改一层, 泄漏纹丝不动。定位方法: 固定同一个目标, 对比"走 TUN"和
    "强制走 socks5h://127.0.0.1:10808", 结果不同就说明是后一层在直连。
20. **按进程匹配要写【真正发起连接的那个进程】, 不是它所在的程序。**
    用户想在 Terminal 里让 Claude Code 走代理, 写 "Terminal" 完全不生效 ——
    发请求的是子进程 curl / git / node。验证方法: 临时把 curl 加进名单看是否立即生效。
21. **给被豁免的进程配节点时, 必须先实测节点可用性。**
    配错了不是"泄漏"而是"完全没网", 体验上更糟。本项目实测中被这一步救过一次
    (默认取了已被阻断的节点)。
22. **细节的具体程度不是可信度。** 流行的"Claude Code 隐写标记"说法列了
    147 个域名 + XOR 密钥 91 + 三个具体 Unicode 码点, 听起来像深度逆向 ——
    实际反汇编后一个字面量都对不上。**要验证, 不要相信具体感。**
23. **验证必须带阳性对照。** 搜不到目标字符串时, 必须同时确认一个已知存在的
    字符串能搜到, 否则无法排除"方法本身错了"。本项目在 rule-set match 上
    踩过同一个坑(参数顺序错把 qq.com 判成不在国内名单里)。

## 常用命令

```bash
# 服务端：横向比对多台服务器的一致性（差异行标 ⚠）
skills/deploy-us-proxy/scripts/vps-compare.sh <server1> <server2>

# 客户端：TUN 健康检查与三层定位
skills/macos-tun-no-proxy/scripts/diagnose.sh --node-ip <IP> --node-port 8443 --sni <SNI>

# 客户端：两个免 sudo 开关
touch "$HOME/Library/Application Support/v2rayN/tun-disabled"    # 临时关 TUN
echo 1500 > "$HOME/Library/Application Support/v2rayN/tun-mtu"   # 临时改 MTU

# 客户端：Cmd+Q 拦截器的日志与身份核对
tail -f "$HOME/Library/Logs/v2rayn-quitguard.log"
codesign -d -r- /usr/local/libexec/v2rayn-tun/quit-guard   # 应显示 certificate root, 不是 cdhash

# 排查 TCC 授权问题（比在设置界面反复点有用得多）
log show --last 20m --predicate 'subsystem == "com.apple.TCC"' --style compact | grep -i quit-guard
killall universalAccessAuthWarn        # 关掉卡住的授权对话框
```

## 扩展阅读

**遇到技能里没覆盖的问题，先去 [`docs/`](docs/README.md) 翻记录。**
技能是从那份实战记录提炼的压缩版，`docs/` 保留了三倍的上下文，
包括每次误判的完整推理过程 —— 排查没思路时，误判的模式比结论更有用。

> 当前风险清单见 [docs/18 风险登记表](docs/18-risk-register.md)。
> 完整清单见 [docs/README.md](docs/README.md) —— 每篇都有一句话概述。
> **如果只读一份**：读 [12 Cmd+Q 拦截器](docs/12-quit-guard.md)。它记录的不是某个
> 配置怎么写，而是"前提假设错了，实现再漂亮也没用"这个模式。


## 维护提示

- **技能包内的脚本是自包含副本**，便于单独分发。改动时两边都要更新，
  用 `diff -rq scripts/ skills/macos-tun-no-proxy/scripts/` 校验一致性。
- **`config/` `daemon/` `launchd/` 是 TUN 守护进程的安装源**，
  `skills/macos-tun-no-proxy/` 下是同样内容的副本。`install.sh` 读的是根目录这份。
- **技能包独有的两个文件**（根目录没有对应物，属正常）：
  `install-tun.sh`（技能包自己那套布局的安装脚本，根目录用 `install.sh`）
  与 `proxy-toggle.sh`（终端代理开关）。
