> **一句话**：隧道「本地进程活着」不等于「外面能连」—— 断线时远端转发可能只批了一半，验收必须去跳板机抓 SSH banner。

# 26. 公网 SSH 挂了：本地看着正常，跳板机没监听

## 结构

```
外部 ── ssh -p 22001 winbeau@1.92.76.152 ──▶ huawei1:22001
                                              │ 反向隧道（router 用户，端口池 22001-22007）
                                              └──▶ 本机 127.0.0.1:22
```

## 事故（2026-11-21）

- `./scripts/expose-ssh.sh status` 显示「隧道状态 运行中」，本机 sshd 也在听
- 但外部连不上 —— 去 huawei1 上看：`ss -ltn` **没有 22001**（只有 22003、22007）
- `~/.expose-ssh/launchd.log` 在刷 `Error: remote port forwarding failed for listen port 22001`，
  launchd 重启了 **424 次**；最后一次"成功建立 TCP"的进程活着，却始终没拿到远端监听
- `launchctl kickstart -k` 重建后立刻恢复

**教训**：`launchctl print` 的 `state = running` 只说明**进程**在跑。
远端转发失败时 ssh 会退出（`ExitOnForwardFailure=yes`），但重启风暴里总有一次
"连上了、转发没成"，于是本地一切正常、外面全断。

## 验收（三处，缺一不可）

```bash
# 1. 跳板机自己回环 —— 证明隧道+本机 sshd 整条链
ssh -i ~/.ssh/id_ed25519_relay router@huawei1 \
  "timeout 6 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22001; head -c 8 <&3'"   # → SSH-2.0-

# 2. 另一台机器（公网路径）
ssh huawei2 'nc -z -w3 1.92.76.152 22001 && echo OPEN'
ssh huawei2 'ssh -p 22001 -o PreferredAuthentications=none winbeau@1.92.76.152 true'  # Permission denied (publickey) = 通了

# 3. 第三方（pi4）
ssh pi4 'nc -z -w3 1.92.76.152 22001 && echo OPEN'
```

`Permission denied (publickey)` 是**成功**信号：banner 换过了、认证才开始。
只 `nc -z` 不够 —— 端口在听但链路没通时它也会"成功"。

## 现在的 status 会自己验

```
$ ./scripts/expose-ssh.sh status
公网可达    huawei1:22001 → 本机 sshd ✓
```

对端不通时：

```
$ ./scripts/expose-ssh.sh heal
· 对端不可达，重建隧道
✓ 已恢复
```

`heal` 只在**对端不可达**时才重建（对端正常就什么都不动），可以放进定时任务。

## 坑

1. **`head -c 30` 读 banner 会超时** —— banner 只有 21 字节，`head` 等满 30 字节就卡住。
   用 `head -c 8`（够匹配 `SSH-2.0-`）。
2. **`ss` 在跳板机的非交互 PATH 里不一定有**，改用 `/dev/tcp` 探测更稳。
3. 跳板机 `90-router.conf` 里 `PermitListen *:22001 … *:22007` 是端口池的**唯一**依据，
   换端口必须两边一起改。
