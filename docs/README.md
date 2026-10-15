# 排查文档

本项目从「v2rayN 打不开」一路做到「TUN 模式托管」的全部排查记录。

记录重点是**走过的弯路**：每篇写明「当时怎么想的、为什么错、怎么纠正」。结论会过时，误判的模式不会。

> 看整体逻辑先读 [00 整体架构](00-architecture.md)；看当前风险读 [18 风险登记表](18-risk-register.md)。

| # | 主题 | 一句话（教训）|
|---|---|---|
| [01](01-gatekeeper.md) | v2rayN 报「已损坏，应移到废纸篓」 | 隔离标记与签名损坏是**两个独立问题**，只修一个不够。 |
| [02](02-dock-and-passwordless-tun.md) | Dock 常驻 + TUN 免密 | v2rayN 把「每次必须输密码」写死在源码里 —— 改用独立 root 守护进程绕开。 |
| [03](03-login-item-ipv6-dns.md) | 登录项 + 假 IPv6 + DNS 污染 | `hijack-dns` 拦不住**同网段**的 DNS；假 IPv6 会把它引到错误的解析器。 |
| [04](04-network-switch-bugs.md) | 网络切换引发的两个真实 bug | 长驻进程「启动时探测一次」= 定时炸弹；`stop_tun` 里的 kickstart 会造成无限重建。 |
| [05](05-wechat-lag.md) | 微信卡顿排查（三次错误结论） | **空日志 ≠ 没有事件** —— 三次错误结论都源于此。 |
| [06](06-github-slow.md) | GitHub 访问慢（含一次把服务搞断的失误） | 延迟与吞吐要分开查；本文含一次把服务搞断的失误。 |
| [07](07-repo-and-bootout-race.md) | 建仓与 install.sh 的 bootout 竞态 | `launchctl` 的 `bootout`/`bootstrap` **不是同步的**。 |
| [08](08-node-failure-triage.md) | 节点故障的分层定位 | 先证明问题不在本地，再往外查 —— 端口 → TUN → DNS → 节点。 |
| [09](09-vps-tuning.md) | VPS 服务端调优与 Cloudflare 优选 IP | CDN 前置的节点，故障点可能在 CDN 而不在 VPS。 |
| [10](10-reality-setup.md) | 在自建服务器上启用 Reality + XTLS-Vision | 旧配置的 `dest` 已被**静默改名**为 `target`。 |
| [11](11-hysteria2-real-cert.md) | 修复 Hysteria2 节点（换真实证书） | QUIC 无法躲在 CDN 后面；TCP-in-TCP 是隐形税。 |
| [12](12-quit-guard.md) | 误按 Cmd+Q 保护（quit-guard） | 三次推倒重做，每次都因为一个更基础的前提假设错了 —— 前提错比实现错更致命。 |
| [13](13-ip-leak-protection.md) | 真实 IP 泄漏防护 | **「代理断了就恢复直连」是危险的默认值** —— 对强风控服务，默认应是阻断。 |
| [14](14-node-sni-blocking.md) | 商业节点会按 SNI 选择性屏蔽 | **「节点只是中转」是错误的心智模型** —— 商业节点会按 SNI 屏蔽。 |
| [15](15-clash-sub-to-v2rayn.md) | 机场只给 Clash 订阅，怎么让 v2rayN 自动更新 | **「粘贴节点」和「订阅」是两种东西** —— 前者一次性，后者才会更新。 |
| [16](16-cn-direct-ip-leak.md) | 国内直连导致的真实 IP 泄漏（两层规则 + 按进程豁免） | **这个项目有两层国内直连规则**，只改一层，泄漏纹丝不动。 |
| [17](17-claude-ban-detection-analysis.md) | Claude 封号检测机制调研（含一次证伪） | **细节的具体程度不是可信度** —— 风控看的是「矛盾」，不是「伪装」。 |
| [18](18-risk-register.md) | 技术风险登记表 | 9 条风险里 2 条已解决、2 条实测排除、2 条已决策不修，真正待观察的只有 3 条。 |
| [19](19-routing-implementation.md) | 路由实施记录 | **「国内直连」这个概念本身被取消了** —— 国内走日本、国外走住宅、只有 22 个域名直连。 |

另见 [toolbox](toolbox.md) —— 实际定位问题时用过的命令。
