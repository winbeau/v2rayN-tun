#!/usr/bin/env python3
# 切换节点 / 重建 TUN 之前检查有没有「正在用代理的客户端」。
#
# 为什么需要: 任何节点切换都要重启 sing-box, 期间 TUN 会被撤掉约 1~3 秒,
# 那段时间流量走【直连】—— 如果有 Claude 的请求正好在飞, 源地址就是真实 IP。
# 2026-10-27 实测踩过: 在 AdsPower 和 Terminal 都跑着 Claude 的情况下连着
# 切了好几次节点, 每次都开了这个窗口。
#
# 用法(在脚本里):
#     from _clients_guard import ensure_idle
#     ensure_idle(force=args.force)
#
# 或者命令行:
#     python3 scripts/_clients_guard.py          # 只检查
import os, subprocess, sys

# 真正会用代理出去的进程。注意写【真正发连接的那个】:
#   - AdsPower 的浏览器内核叫 SunBrowser, 不是 AdsPower 本身
#   - Claude Code 在终端里跑, 进程名是 claude, 不是 Terminal
WATCH = [
    # 只盯【会登录 Claude 的那两个客户端】—— 用户的用法是:
    #   AdsPower 指纹浏览器 说明: Claude 专用
    #   Terminal 里的 Claude Code
    #
    # 不要把 Chrome / Safari / 微信这类"一直都在跑"的进程放进来:
    # 它们常年存在, 会导致这道闸永远拦着, 最后只能被迫用 --force,
    # 那这道闸就等于没有。
    #
    # 注意 AdsPower 的浏览器内核叫 SunBrowser, 不是 AdsPower;
    # Claude Code 的进程名是 claude, 不是 Terminal。
    ("SunBrowser", "AdsPower 指纹浏览器 (Claude 专用)"),
    ("AdsPower",   "AdsPower 客户端"),
    ("claude",     "Claude Code (终端里跑的)"),
]


def running():
    """返回 [(进程名, 说明, pid列表)] —— 只看确实有进程在跑的"""
    found = []
    for pattern, label in WATCH:
        try:
            out = subprocess.run(["pgrep", "-f", pattern],
                                 capture_output=True, text=True, timeout=3).stdout.split()
        except (OSError, subprocess.SubprocessError):
            continue
        pids = [p for p in out if p.isdigit() and int(p) != os.getpid()]
        if pids:
            found.append((pattern, label, pids))
    return found


def ensure_idle(force=False):
    """有客户端在跑就抛异常；force=True 时只警告"""
    busy = running()
    if not busy:
        return True
    lines = [f"  {label} ({pattern})  pid={','.join(pids[:3])}"
             for pattern, label, pids in busy]
    msg = ("检测到这些客户端正在运行：\n" + "\n".join(lines) + "\n\n"
           "切换节点会重启 sing-box，期间 TUN 被撤掉约 1~3 秒，\n"
           "那段时间流量走【直连】—— 正在进行的请求会用真实 IP 出去。\n\n"
           "请先关闭上面的客户端（尤其是 AdsPower 里的 Claude、终端里的 claude），\n"
           "再执行本次操作。\n\n"
           "确实要先切，加 --force 跳过这道检查。")
    if force:
        print("⚠️ 已跳过客户端检查（--force）：", file=sys.stderr)
        for line in lines:
            print(line, file=sys.stderr)
        return True
    raise RuntimeError(msg)


if __name__ == "__main__":
    busy = running()
    if not busy:
        print("  ✓ 没有客户端在跑，可以安全切换节点")
        sys.exit(0)
    print("  ✗ 有客户端在跑：")
    for pattern, label, pids in busy:
        print(f"      {label:<14} ({pattern})  pid={','.join(pids[:3])}")
    print()
    print("  先关掉它们再切；否则切换瞬间的直连窗口会用真实 IP 发请求。")
    sys.exit(1)
