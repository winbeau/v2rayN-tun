# 16 · 国内直连导致的真实 IP 泄漏（两层规则 + 按进程豁免）

> **⚠️ 现状已变（2026-10-15）**：本文记录的解法是"国内方向直连 + 按进程豁免"。
> 后来整个国内方向都改走**日本节点**了，唯一保留直连的是 22 个"只认国内 IP"的
> 域名（微信/教育/政务）。当前架构见 [00](00-architecture.md)，最新结论见 [18](18-risk-register.md)。
> **本文的价值在于定位方法**（两层规则、按进程豁免、怎么证明泄漏存在），那部分仍然有效。


> **一句话**：**这个项目有两层国内直连规则**，只改一层，泄漏纹丝不动。

## 现象

用指纹浏览器（AdsPower）访问 `https://ipinfo.cv/webrtc-check`，结果：

```
STUN 服务器        看到的源 IP
Bilibili (国内)    124.117.210.115   Ürümqi    ✗ 真实中国 IP
Bilibili (国内)    124.117.210.119   Ürümqi    ✗
Xiaomi  (国内)     116.178.106.41    北京西城   ✗
MGTV    (国内)     124.117.210.115   Ürümqi    ✗
Google  (国外)     154.17.27.236     Los Angeles  ✓ 中转服务器
Cloudflare (国外)  66.248.154.224    Greensboro   ✓ 住宅出口
```

**国外 STUN 正常、国内 STUN 报出真实 IP。**

用户的判断很准：「Claude 也可以通过这些国内网站直连的形式来测我的 DNS 服务器啊，
看我到底是不是中国人」。

## 定位：先把"浏览器层"排除掉

用命令行直接发 STUN 请求（完全绕开浏览器）：

```
Bilibili (国内)  124.117.210.115   ✗
小米     (国内)  116.178.106.8     ✗
Google   (国外)  154.17.27.236     ✓
Cloudflare(国外) 66.248.154.224    ✓
```

**和浏览器测出来的一模一样。** 所以：

```
换指纹浏览器  → 没用 ✗
关 WebRTC     → 没用 ✗
装防泄漏扩展  → 没用 ✗
```

**泄漏发生在路由层，压根没到浏览器。**

## 根因：这个项目有【两层】国内直连规则

```
Chrome / AdsPower / curl
    ↓
sing-box (TUN 层)      geoip-cn / geosite-cn → direct    第 1 层
    ↓
xray (v2rayN 生成的)    geoip:cn / geosite:cn → direct    第 2 层  ★ 真正在漏的
    ↓
  节点
```

- **第 1 层**在 `config/sing-box.json` 的 `route.rules` 里，本项目能改。
- **第 2 层**由 **v2rayN 的「路由设置」**决定（默认「绕过大陆」），
  生成到 `~/Library/Application Support/v2rayN/binConfigs/config.json`。

**⚠️ 只改一层没有用。** 我第一次只改了 sing-box 那层，泄漏纹丝不动 ——
因为 xray 那层照样把国内流量直连放出去。

### 怎么把两层分开

固定同一个目标，对比两条路径：

```bash
# 走 TUN（正常上网路径）
curl -s --noproxy '*' https://ip.3322.net

# 强制走 v2rayN 的 socks（完全绕过 TUN 的路由判定）
curl -s -x socks5h://127.0.0.1:10808 https://ip.3322.net
```

如果**两条都报真实 IP**，说明泄漏在 xray 层（第 2 层）；
如果只有走 TUN 的报，说明在 sing-box 层（第 1 层）。

实测两条都报真实 IP → **主要是第 2 层**。

### 第 2 层的修法

**只能在 v2rayN 界面里改**（我试过直接改 DB 的 `RoutingItem`，v2rayN 会重新
生成默认路由，不生效）：

```
v2rayN 托盘图标 → 右键 → 路由 → 选「全局」
```

改完后 `binConfigs/config.json` 里会变成：

```json
{ "type": "field", "port": "0-65535", "outboundTag": "proxy" }
```

国内直连规则消失 → **`ip.3322.net` 也报住宅 IP 了** ✓

### 但「全局」的代价很大

```
全局:      国内网站全部打不开 ✗
           （实测经住宅节点访问 baidu / bilibili / qq 全部 HTTP 000）
绕过大陆:  国内正常 ✓ 但国内方向泄漏真实 IP ✗
```

**根本原因是：住宅节点（弗吉尼亚）到中国大陆不通。**
经 socks 直接测 baidu/bilibili/qq 都是 000，而直连是 200。
这是节点的固有限制，客户端解决不了。

## 解法：按进程豁免，让浏览器绕开 xray

既然不能全局，那就**只让需要的程序走"直连节点"**：

```
SunBrowser (AdsPower) ─→ sing-box ─→ vless 直连住宅节点
                                    完全绕开 xray ✓ 国内国外都走节点 ✓ 不泄漏
其他所有程序 ──────────→ sing-box ─→ socks10808 → xray (绕过大陆, 国内快 ✓)
```

实现：`scripts/per-app-routing.py`

1. 从本地订阅服务取住宅节点（自动**实测可用性**，不通就拒绝应用）
2. 生成一个 sing-box 的 `vless` 出站（`node-direct`）
3. 插入一条 `process_name` 规则，**放在 `geoip-cn` / `geosite-cn` 之前**

```json
{
  "process_name": ["SunBrowser", "SunBrowser Helper",
                   "SunBrowser Helper (Renderer)", "SunBrowser Helper (GPU)"],
  "outbound": "node-direct"
}
```

### 两个必须注意的点

**① 必须写真正发起连接的那个进程**

用户想在 Terminal 里让 Claude Code 也走节点，写了 `"Terminal"` —— **完全不生效**。
因为 Terminal 只是终端窗口，**它自己不发网络请求**；发请求的是它启动的子进程
`curl` / `git` / `node`。sing-box 匹配到的是 `curl`，名单里没有 → 走普通路由。

**验证方法**：临时把 `curl` 加进名单，`ipinfo.io` 立刻变成节点 IP `154.17.27.236`
→ 证明机制可用，只是名字要写对。

```
✗ "让整个 Terminal 走代理" 用进程匹配做不到（要逐个列出里面的工具）
✗ 而且代价大: 住宅节点到不了中国, 终端里的 npm 国内镜像 / 国内 git 仓库 /
              校园网内网都会失效
✓ 结论: 只豁免浏览器就够了
       · 浏览器会加载国内域名的资源(图片/脚本), 网页据此能拿到真实 IP ✗
       · Claude Code 只连 api.anthropic.com(国外), 本来就走代理, 没有泄漏路径 ✓
```

**② 必须把 Chromium 的辅助进程也列上**

浏览器的网络请求不是主进程发的，而是 network service 这个 utility 进程，
它的可执行名是 `SunBrowser Helper` 而不是 `SunBrowser`。只写主进程会漏掉真正的流量。

### 节点可用性预检不能省

开发过程中它救了一次：脚本默认取了**已被阻断**的 `154.17.29.33`。
如果直接应用，被豁免的浏览器的**完全没有网络** —— 比泄漏更糟。

```python
ok, info = node_is_alive(node_link)
if ok is False:
    sys.exit("✗ 节点不可用 —— 拒绝应用")
```

## 最终状态

```
SunBrowser (AdsPower)  →  node-direct (154.17.27.236) ✓ 全代理, 不泄漏
其他一切(含 Terminal)   →  绕过大陆 ✓ 国内快
                          Claude Code 只连国外, 本来就走代理 ✓

v2rayN 路由设置保持「绕过大陆」✓ 不需要来回切
```

## 常用命令

```bash
./scripts/per-app-routing.py plan --sub sub2     # 看会改什么
sudo ./scripts/per-app-routing.py apply --sub sub2
./scripts/per-app-routing.py verify              # 看当前生效的配置

# 整层关闭国内直连（全代理, 代价是国内网站不可用）
./scripts/stealth-mode.sh on
./scripts/stealth-mode.sh off
./scripts/stealth-mode.sh test                   # 实测 STUN 泄漏
```

**回滚**：

```bash
sudo cp /usr/local/libexec/v2rayn-tun/config.json.bak-perapp \
        /usr/local/libexec/v2rayn-tun/config.json
sudo launchctl kickstart -k system/com.local.v2rayn-tun
```

## 教训

1. **"国内直连"是一个会泄漏真实 IP 的默认值。** 它的出发点是"上网快"，
   代价是任何指向国内的连接都用真实 IP 出去。对地区敏感的服务（Claude、
   ChatGPT）来说，这比"慢"严重得多。

2. **★★ 本项目有【两层】国内直连规则，只改一层没用。★★**
   sing-box 一层、xray（v2rayN 路由）一层。第一次排查时我漏了第二层，
   白白折腾了好几轮。**定位方法是"固定目标、对比走 TUN 与强制走 socks"。**

3. **fingerprint 浏览器防不住这一层。** 用户用 AdsPower 并禁用了 WebRTC，
   方向是对的 —— 但泄漏不在浏览器层，命令行 curl 一样漏。

4. **进程匹配要写"发起连接的那个进程"。** `Terminal` 不是，`curl` 才是。
   想让"整个终端"走代理，进程匹配无能为力。

5. **给被豁免的进程配节点时，必须先验证节点可用。**
   配错了不是"泄漏"，而是"完全没网"，体验上更糟。
