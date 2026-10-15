# 17 · Claude 封号检测机制调研（含一次证伪）

## 起因

用户提出一个准确的质疑：

> 「用代理用 Claude Code 的那么多，不都还是被核查出来是中国用户了吗，没有那么简单」

于是 clone 了 GitHub 上 6 个与 Claude 封号相关的仓库做调研：

| 仓库 | 定位 |
|---|---|
| [newtv-ai/CLAUDE-SHIELD](https://github.com/newtv-ai/CLAUDE-SHIELD) | 环境穿透检测 + 一键代理配置 |
| [TZZ520/claude-environment-check](https://github.com/TZZ520/claude-environment-check) | 桌面/网页环境检测 |
| [xnydl/claude-code-guard](https://github.com/xnydl/claude-code-guard) | 固定出口 + 清理登录残留 |
| [yacuo/check-cc](https://github.com/yacuo/check-cc) | 40+ 项环境信号检测 |
| [aicxd/aicxd-skills](https://github.com/aicxd/aicxd-skills) | 声称 Claude Code 内有"隐写标记" |
| [codingauto/claude_cli](https://github.com/codingauto/claude_cli) | 住宅代理服务 |

**结论先行**：最有传播力的那个说法（隐写标记）**经反汇编验证不成立** ✗；
真正起作用的是**环境一致性**。

---

## 一、证伪：所谓"隐写标记"

`aicxd-skills/claude-ban-guard` 声称：

> Anthropic 在 Claude Code 里埋了隐写术标记，靠 3 个本地信号判断你是不是中国大陆用户：
> 1. 系统时区是 `Asia/Shanghai` / `Asia/Urumqi`
> 2. 设置了 `ANTHROPIC_BASE_URL`
> 3. `ANTHROPIC_BASE_URL` 命中内置的中转站/大厂域名表（147 个 + 11 个 AI 实验室，base64 + XOR 91 混淆）
>
> 命中后，在系统提示词的 `Today's date is ...` 那行做两处肉眼不可见的改动：
> 单引号 `U+0027` 换成 `U+2019`/`U+02BC`/`U+02B9`，日期分隔符 `-` 换成 `/`。

**验证方法**：直接检查本机安装的 Claude Code 二进制。

```
$ which claude
/Users/winbeau/.local/bin/claude -> ~/.local/share/claude/versions/2.1.296
$ file ...
Mach-O 64-bit executable arm64      (230 MB, Bun 编译的单文件)
```

在这个二进制里搜索声称依赖的字面量：

```
声称的时区信号                实际出现次数
  Asia/Shanghai               0   ✗
  Urumqi                      0   ✗
  Asia/                       0   ✗   ← 连前缀都没有

声称的隐写撇号
  U+2019                      0   ✗
  U+02BC                      0   ✗
  U+02B9                      0   ✗

声称的域名表关键词
  DeepSeek / Moonshot / MiniMax /
  Zhipu / Baichuan / Meituan / Xiaohongshu    全部 0   ✗

"Today's date is"             存在 ✓ 但用的是【普通 U+0027】✓

阳性对照（证明明文确实可读，排除"搜索方法有问题"）
  ANTHROPIC_BASE_URL          115 次 ✓
  api.anthropic.com            72 次 ✓
  claude.ai                  1439 次 ✓
  ANTHROPIC_API_KEY           154 次 ✓
```

**决定性的一条**：如果代码真的做 `replace("'", "\u2019")`，
那个 `\u2019` 字面量**必然存在于二进制里** —— 它不存在 ✗。

**结论**：该说法在 v2.1.296 上不成立 ✗。声称的"混淆域名表"确实搜不到（因为混淆了），
但 `Asia/Shanghai` 和三个撇号被描述为**直接字面量**，它们集体缺席是决定性的。

**保留意见**：声明说"自 2.1.91 起就有"，而本机是更新的 2.1.296 ——
理论上可能被移除了。但声明同时说该逻辑**至今仍在**，与实测矛盾。

> 💡 **方法论提醒**：这类"细节极其具体"的说法最容易让人信（147 个域名、
> XOR 密钥 91、具体到 `U+02B9`）。**细节的具体程度不是可信度** ——
> 唯一可靠的办法是**去实际验证它**。

---

## 二、真正的机制：环境一致性

对照其余仓库，共识非常一致（`CLAUDE-SHIELD`、`check-cc`、
`claude-environment-check`、`claude-code-guard` 都指向同一点）：

> **风控不是查"你有没有伪装"，而是查各信号之间是否自相矛盾。**
> **"伪装不一致"比"根本没伪装"更像在藏东西。**

`CLAUDE-SHIELD` 的原话：

> 只有当节点 IP 良好，仅由于本地"东八区时区""中文语言"或"WebRTC 泄漏"
> 导致异常时，本方案才能生效。**如果节点 IP 本身已在黑名单中，
> 任何本地指纹伪装都无济于事。**

### 检测面清单

| 检测面 | 原理 | 本项目状态（修复前）|
|---|---|---|
| **DNS 泄漏** | 国内域名走国内 DNS → 对方看到真实 IP + 返回国内 CDN IP → 流量直连 | ✗ 有问题 |
| **IPv6 直连** | IPv4 走代理、IPv6 走真实网络，绕过代理 | ✓ 已关闭 |
| **WebRTC** | JS 查 STUN 拿真实 IP | ✓ 已禁 + 已按进程豁免 |
| **时区 vs IP** | IP 在美国但系统时区是东八区 | ✗ 不一致 → **已修** |
| **语言 vs IP** | `zh-CN` + 美国 IP | ✓ en-US |
| **IP 类型** | 机房 IP 被标记 | ✓ 住宅 |
| **IP 稳定性** | 频繁换节点 = 账号共享/异地登录 | ✗ 换过多次 |
| **支付方式** | 中国信用卡是硬信号 | ? |
| **注册环境** | 注册时的 IP/时区/语言 | ? |
| **用量模式** | 自动化/批量调用 | ? |

---

## 三、本项目做的环境审计与修复

### 修复：时区与出口 IP 对齐

```
修复前:  系统 America/Los_Angeles (美西)
         出口 66.248.154.224 = Rustburg, Virginia = America/New_York (美东)
         → 跨 3 个时区, 矛盾 ✗

修复后:
  readlink /etc/localtime                      -> America/New_York
  Intl.DateTimeFormat().resolvedOptions().timeZone  -> America/New_York  ✓
  new Date().getTimezoneOffset()                -> 240 (EDT) ✓
  出口 IP 时区                                  -> America/New_York  ✓
  时钟偏差                                      -> +0.013s ✓ (时区不影响时钟)
```

**命令**（`systemsetup -settimezone` 在本机报 `Error:-99`，
且中间态会让 `date` 短暂显示 UTC；用符号链接更可靠）：

```bash
sudo ln -sf /var/db/timezone/zoneinfo/America/New_York /etc/localtime
```

### 已确认无问题的项

```
IPv6:      Off ✓ (en0 无 IPv6 地址, curl -6 失败)
系统语言:  en-US ✓
系统地区:  en_US ✓
出口类型:  住宅 (Carolina Digital Phone) ✓ 非机房
WebRTC:    AdsPower 已禁 ✓ + SunBrowser 已按进程豁免 ✓
```

### 仍存在的问题：DNS 泄漏

```
sing-box 的 DNS 规则:
  国内域名 (geosite-cn)  ->  direct-dns-1 = 119.29.29.29 (腾讯国内 DNS)
  国外域名               ->  remote-dns-1 = Cloudflare DoH (走代理 ✓)

后果 A: 腾讯 DNS 看到真实中国 IP           ✗
后果 B: 返回国内 CDN 节点 -> 流量可能直连   ✗
```

**权衡**：改法有两种，都不是纯赚 ——

```
A. 所有域名都用 Cloudflare DoH (走代理)
   代价: .local 这类本地域名解析不了, 国内站变慢
B. 保持现状
   代价: DNS 查询泄漏给腾讯 (但不影响流量走哪条路径)
```

---

## 四、为什么"用代理还是被抓"—— 三类原因

### 第一类：环境自相矛盾（可修）

最常见的翻车方式**不是"没伪装"，而是"伪装不一致"**：

```
出口 IP 在美国  +  DNS 解析走腾讯 119.29.29.29   -> 矛盾 ✗
出口 IP 在美东  +  系统时区是美西                 -> 矛盾 ✗ (本项目修掉了)
出口 IP 在美国  +  IPv6 直连                     -> 矛盾 ✗ (本项目已关)
出口 IP 在美国  +  WebRTC 暴露真实内网 IP        -> 矛盾 ✗ (本项目已禁)
出口 IP 在美国  +  系统语言 zh-CN                -> 矛盾 ✗ (本项目是 en-US)
```

任意一条被读到，"这个人声称在美国"就崩了。

### 第二类：IP 质量与稳定性（半可修）

```
✗ 机房 IP          -> 直接被标记
✓ 住宅 IP          -> 通过
✗ 频繁换节点       -> 看起来像账号共享 / 异地登录
✗ 多账号共用出口   -> 关联封禁
```

`xnydl/claude-code-guard` 的设计选择印证这一点：**默认只指定一个完整叶子名**，
不做白名单、负载均衡、随机选择或多节点轮换；链式代理"只允许入口结构不同，
不能改变当前最终出口"。

### 第三类：支付与注册环境（网络手段治不了）★

**这很可能是"那么多人被抓"的最主要原因**，而且**不在网络层**：

```
· 用中国信用卡订阅 Claude Pro        -> 硬信号 ✗
· 账号注册时的 IP / 时区 / 语言       -> 硬信号 ✗
· 手机号 / 账单地址                   -> 硬信号 ✗
· 账号年龄很短却高频用量              -> 行为信号 ✗
```

**网络做得再干净，一张中国信用卡就把一切都交代了。**

---

## 五、结论与边界

**可做的四件事（按性价比）：**

1. ✅ **时区与出口 IP 对齐** —— 已完成
2. ⬜ **固定出口，不再切换** —— 最重要的一条
   ```
   ✗ 不再在 全局/绕过大陆 之间切
   ✗ 不再换住宅线路
   ✗ 不再换节点测试
   ✓ 就用现在这一条, 用下去
   ```
3. ⬜ **DNS 加固** —— 有代价，自行权衡（见上）
4. ⬜ **支付方式** —— 若账号用中国支付方式订阅，网络层面无法弥补

**必须说清的边界：**

- 从中国使用 Claude **违反 Anthropic 的服务条款**，中国不在其支持地区。
- **没有任何技术手段能保证不封号。** 本文分析的是检测机制原理与本项目的
  环境配置问题，不是"绕过封禁的方案"。
- 账号一旦被限制过一次，再次触发通常**更难恢复**。

---

## 教训

1. **细节的具体程度不是可信度。** "147 个域名 + XOR 密钥 91 + U+02B9"
   听起来像深度逆向，实际反汇编后一个字面量都对不上。
   **唯一可靠的办法是去实际验证它。**

2. **验证要有阳性对照。** 搜不到 `Asia/Shanghai` 时，必须同时确认
   `ANTHROPIC_BASE_URL` 能搜到 —— 否则无法排除"搜索方法本身有问题"。
   本项目此前已在 `sing-box rule-set match` 上踩过同一个坑（参数顺序错了，
   导致把 `qq.com` 判成"不在国内名单里"）。

3. **风控看的是"矛盾"，不是"伪装"。** 把每个信号都改成美国只是一半；
   更重要的是让它们**互相对得上**。

4. **网络层之外还有更硬的信号。** 支付方式、注册环境、账号行为 ——
   这些不是代理能解决的。把全部精力放在网络伪装上是**方向性错误**。
