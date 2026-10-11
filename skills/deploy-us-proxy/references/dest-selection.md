# REALITY dest 选择

REALITY 让服务器在握手阶段借用一个真实站点（dest）的证书。选错 dest 会直接导致握手失败或服务器 IP 被针对性阻断，这是部署里最容易埋雷的一步。

## 硬性条件

dest 必须同时满足，缺一不可：

- **TLS 1.3**：REALITY 只在 TLS 1.3 握手中工作。
- **X25519 密钥交换**：`Server Temp Key: X25519`。只支持 P-256 的站点不能用。
- **HTTP/2 ALPN**：客户端会协商 h2，dest 不支持会造成指纹不一致。
- **从服务器可达且稳定**：dest 是服务器主动去连的，客户端所在地能否访问不影响握手。

`scripts/probe_dest.sh` 会逐项检查并按延迟排序。

## 软性条件

- **同区域优先**。dest 延迟直接叠加在握手上。美西机器选美国站点，日本机器选日本站点。
- **SNI 在客户端地区要合理**。SNI 是明文可见的，一台美国 IP 反复出现某个本地小众站点的 SNI 反而显眼。选跨国大站更自然。
- **站点要长期稳定**。dest 换证书、下线或改配置会让节点突然握手失败。挑运营多年的站点。
- **避开自己也要访问的站点**。dest 流量和真实访问混在一起时排查困难。

## 必须避开

Xray 在 `run -test` 阶段会对部分域名直接告警，最典型的是 apple / icloud 系：

```
[Warning] infra/conf: REALITY: Choosing apple, icloud, etc. as the target
may get your IP blocked by the GFW
```

这类告警是权威判据，出现就换 dest，不要带着告警上线。除此之外还应避开：

- 中国大陆可直连的站点（借用它伪装没有意义）。
- 位于 Cloudflare、Fastly 等共享 CDN 后且 IP 高度共享的站点，指纹容易和大量真实流量冲突，但更主要的问题是这些 IP 段本身可能已被重点关注。
- 已知被大规模用作 REALITY dest 的少数域名。用的人越多，该 SNI 越容易成为特征。

## 端口也是伪装的一部分

dest 选得再好，端口不对也白搭。REALITY 的整个伪装建立在「这是一次访问 443 端口 HTTPS 站点的正常连接」之上，监听非 443 端口会让流量特征立刻脱离这个假设。Xray 对此有独立告警：

```
[Warning] infra/conf: REALITY: Listening on non-443 ports may get your IP
blocked by the GFW
```

除非 443 确实被别的服务占用且无法腾出，否则不要改端口。

## 更换 dest

dest 可以随时换，**不需要重新生成密钥**。改服务端配置里 `realitySettings.target` 和 `serverNames`，然后同步更新客户端的 `sni`：

```bash
sudo sed -i 's|old.example.com|new.example.com|g' /usr/local/etc/xray/config.json
sudo /usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json
sudo systemctl restart xray
```

服务端和客户端的 SNI 必须一致，否则握手失败。改完记得重新签发分享链接。

## 什么时候换 dest 解决不了问题

节点时通时断、或全时段不通但服务端日志无任何记录时，问题通常在服务器 IP 本身已被阻断，换 dest 无效。判断方法：从受限网络对该 IP 的目标端口做 TCP 连接测试，若 SYN 无响应而同机房其他 IP 正常，就是 IP 被封，只能换 IP。
