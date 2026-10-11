#!/usr/bin/env python3
"""
给一台 xray 服务器增加 VLESS + Reality + XTLS-Vision 入站, 并接入 v2rayN。

用法:
    python3 add-reality-inbound.py server <服务器IP> --port 8443 --target www.intel.com
    python3 add-reality-inbound.py client <本机>     --port 8443 --target www.intel.com \
            --address <服务器IP> --public-key <公钥> --short-id <id>

设计要点 (踩过的坑, 详见 docs/10-reality-setup.md):
  1. 字段名是 `target` 不是 `dest` —— 旧名会被静默忽略, -test 仍报 OK
  2. target 必须实测 —— 表面条件相同的站点不一定都能用作回落目标
  3. 客户端开 Vision 时不要开 mux
  4. 改 v2rayN 的 DB 前必须先退出 v2rayN, 否则会被覆盖
"""
import argparse, json, os, shutil, subprocess, sys, time

XRAY_CFG = "/usr/local/etc/xray/config.json"


# ---------------------------------------------------------------- 服务端
def server(args):
    cfg = json.load(open(XRAY_CFG))

    def field(text, name):
        return [l.split(": ", 1)[1] for l in text.splitlines() if l.startswith(name)][0]

    if args.private_key:
        priv = args.private_key
    else:
        priv = field(subprocess.run(["xray", "x25519"],
                                    capture_output=True, text=True).stdout, "PrivateKey")

    # 由私钥推导公钥 —— x25519 -i 的输出里 "Password" 就是公钥
    out = subprocess.run(["xray", "x25519", "-i", priv], capture_output=True, text=True).stdout
    pub = field(out, "Password")

    short_id = args.short_id or os.urandom(8).hex()
    uuid = args.uuid or subprocess.run(
        ["xray", "uuid"], capture_output=True, text=True
    ).stdout.strip()

    inbound = {
        "tag": "in-reality",
        "port": args.port,
        "listen": "0.0.0.0",
        "protocol": "vless",
        "settings": {
            "clients": [{"id": uuid, "flow": "xtls-rprx-vision", "email": "reality"}],
            "decryption": "none",
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                # ⚠️ 必须是 target, 不是 dest
                "target": f"{args.target}:443",
                "serverNames": [args.target],
                "privateKey": priv,
                "shortIds": [short_id],
                "show": False,
                "xver": 0,
            },
            "sockopt": {
                "tcpFastOpen": True,
                "tcpNoDelay": True,
                "tcpKeepAliveInterval": 30,
                "tcpCongestion": "bbr",
            },
        },
        "sniffing": {"enabled": True, "destOverride": ["http", "tls"]},
    }

    shutil.copy(XRAY_CFG, f"{XRAY_CFG}.bak.{int(time.time())}")
    cfg["inbounds"] = [i for i in cfg.get("inbounds", []) if i.get("tag") != "in-reality"]
    cfg["inbounds"].insert(0, inbound)
    json.dump(cfg, open(XRAY_CFG, "w"), indent=1, ensure_ascii=False)

    r = subprocess.run(["xray", "run", "-test", "-config", XRAY_CFG],
                       capture_output=True, text=True)
    if "Configuration OK" not in r.stdout + r.stderr:
        print(r.stdout + r.stderr)
        sys.exit("配置校验失败, 已中止 (备份仍在)")
    subprocess.run(["systemctl", "restart", "xray"], check=True)

    print("  ✓ Reality 入站已启用")
    print(f"    端口      : {args.port}")
    print(f"    target/SNI: {args.target}")
    print(f"    UUID      : {uuid}")
    print(f"    公钥      : {pub}")
    print(f"    shortId   : {short_id}")
    print()
    print("  客户端参数 (填入 v2rayN):")
    print(f"    地址={args.address or '<本机IP>'}  端口={args.port}  UUID={uuid}")
    print(f"    SNI={args.target}  公钥={pub}  shortId={short_id}  flow=xtls-rprx-vision")


# ---------------------------------------------------------------- 客户端
def client(args):
    db = os.path.expanduser("~/Library/Application Support/v2rayN/guiConfigs/guiNDB.db")
    if subprocess.run(["pgrep", "-x", "v2rayN"], capture_output=True).returncode == 0:
        sys.exit("v2rayN 正在运行 —— 请先从托盘菜单 Exit 退出, 否则修改会被覆盖")

    import sqlite3
    shutil.copy(db, f"{db}.bak.{int(time.time())}")
    con = sqlite3.connect(db)
    con.execute("delete from ProfileItem where Remarks=?", (args.remarks,))
    con.execute(
        """insert into ProfileItem
           (IndexId, ConfigType, ConfigVersion, IsSub, DisplayLog, Remarks, Address, Port,
            Password, Network, StreamSecurity, Sni, Fingerprint, PublicKey, ShortId,
            ProtoExtra, TransportExtra, AlterId)
           values (?,5,4,0,1,?,?,?,?,'raw','reality',?,'chrome',?,?,?,?,0)""",
        (str(int(time.time() * 1000)), args.remarks, args.address, args.port,
         args.uuid, args.target, args.public_key, args.short_id,
         json.dumps({"Flow": "xtls-rprx-vision", "VlessEncryption": "none"}, separators=(",", ":")),
         json.dumps({"RawHeaderType": "none", "Host": "", "Path": ""}, separators=(",", ":"))),
    )
    con.commit()
    con.close()
    print(f"  ✓ 已写入 v2rayN: {args.remarks} → {args.address}:{args.port}")
    print("    启动 v2rayN 后即可选用")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="mode", required=True)
    for name in ("server", "client"):
        s = sub.add_parser(name)
        s.add_argument("host")
        s.add_argument("--address")
        s.add_argument("--port", type=int, default=8443)
        s.add_argument("--target", default="www.intel.com",
                       help="Reality 回落目标; 必须实测可用")
        s.add_argument("--uuid")
        s.add_argument("--short-id")
        s.add_argument("--private-key")
        s.add_argument("--public-key")
        s.add_argument("--remarks", default="selab-reality")
    a = p.parse_args()
    {"server": server, "client": client}[a.mode](a)
