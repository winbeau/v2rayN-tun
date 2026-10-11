# 07 · 建仓与 install.sh 的 bootout 竞态

## 建仓时做的两件事

### 1. 路径参数化

脚本与配置里原本写死了 `/Users/you`。改为 `__USER_HOME__` 占位符，由 `install.sh` 在安装时替换：

```bash
install_subst() {   # $1=源 $2=目标 $3=权限
    sed "s|__USER_HOME__|$TARGET_HOME|g" "$1" > "$2"
    chown root:wheel "$2"; chmod "$3" "$2"
}
```

目标用户通过 `stat -f '%Su' /dev/console` + `dscl` 推导 —— **不能用 `$HOME`**，因为脚本以 root 运行时它是 `/var/root`。

### 2. 入库边界

`.gitignore` 排除从 v2rayN 复制来的运行时文件：`sing-box`（80MB）与 `.srs` 规则集。它们由 `install.sh` 在安装时复制，且规则集会随 v2rayN 更新。

---

## 踩到的 bug：`Bootstrap failed: 5: Input/output error`

首次用新 `install.sh` 部署，`com.local.v2rayn-tun` 加载失败：

```
--- 5. 加载守护进程 ---
Bootstrap failed: 5: Input/output error
   com.local.v2rayn-tun              ← 空，未加载
```

**后果**：TUN 守护没起来，用户的代理降级。已立即手动恢复。

### 根因

**`launchctl bootout` 是异步的。** 旧实例（及其 sing-box 子进程）需要时间退出，紧接着 `bootstrap` 会被 launchd 拒绝。

### 弯路

日志里先看到一条 `Caller not allowed ... uid = 501` —— 那是我自己**以非 root 身份**手动试 bootstrap 留下的记录，与安装脚本无关。差点被带偏（安装脚本本身是 root 运行的）。

→ **教训：看 launchd 日志时要核对失败者的 uid/euid**，否则会混淆"权限不足"和"竞态失败"。

### 修复

```bash
# 1. 先全部 bootout
for p in $SERVICES; do launchctl bootout "system/$p" 2>/dev/null || true; done

# 2. 轮询等待实例真正消失（最多 30 秒）
for _ in $(seq 1 30); do
    still=""
    for p in $SERVICES; do launchctl print "system/$p" >/dev/null 2>&1 && still="$still $p"; done
    [ -z "$still" ] && break
    sleep 1
done

# 3. bootstrap 带 5 次重试
for try in 1 2 3 4 5; do
    launchctl bootstrap system "$LAUNCHD/$p.plist" 2>/dev/null && break
    sleep 2
done
```

### 顺带修的两处

| 问题 | 修复 |
|---|---|
| 自检失败时只打印空行，不醒目 | 区分「已加载/未加载」，未加载用 ❌ 并给出非零提示 |
| `sudo -u <user> launchctl load` 静默失败 | root 无法操作用户的 GUI domain，改用 `launchctl bootstrap gui/<uid> <plist>`（uninstall.sh 同步改）|

---

## 验证：仓库 == 线上

**仓库若与实际部署不一致，就是个谎言。** 所以重新部署后逐项核对：

```bash
sed "s|__USER_HOME__|$HOME|g" config/sing-box.json > /tmp/cmp.json
python3 -c "import json;print(json.load(open('/tmp/cmp.json'))==json.load(open('/usr/local/libexec/v2rayn-tun/config.json')))"

diff -q <(sed "s|__USER_HOME__|$HOME|g" daemon/run-tun.sh) /usr/local/libexec/v2rayn-tun/run-tun.sh
```

结果：无残留占位符、配置结构一致、两个脚本逐字节一致、重复执行两次均正常。

---

## 教训

1. **`launchctl` 的 bootout/bootstrap 不是同步的。** 服务重启要等待 + 重试。
2. **日志里同一条错误可能来自不同的发起者。** 核对 uid 再下结论。
3. **装完要验证"仓库版本 == 部署版本"**，否则版本管理没有意义。
4. **改完守护类组件要立刻自检连通性** —— 这次靠自检才发现 TUN 没起来。
