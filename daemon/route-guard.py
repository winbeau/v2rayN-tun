#!/usr/bin/python3
"""Darwin default-route backstop. sing-box and the backstop own disjoint prefixes."""
import argparse
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys

network = ipaddress.ip_network
HALVES = tuple(net for default in ("0.0.0.0/0", "::/0")
               for net in network(default).subnets())
LOOP = {4: "127.0.0.1", 6: "::1"}
STATE = Path("/var/run/v2rayn-route-guard.json")
ROUTE = "/sbin/route"


def prefixes(value):
    if isinstance(value, str):
        value = [value]
    return [network(entry, strict=False) for entry in value]


def split_capture(tun):
    """Materialize exclusions before splitting: sing-tun coalesces explicit routes
    if route_exclude_address is present. Never let it install/delete a guard /1.
    """
    if not tun.get("auto_route") or tun.get("route_address_set") or tun.get("route_exclude_address_set"):
        raise ValueError("断流保护需要 auto_route 和静态 TUN 网段")
    included = prefixes(tun.get("route_address", []))
    # Private deployments with split includes require a matching split backstop.
    # Do not silently widen their policy to both default routes.
    if included:
        raise ValueError("此守护适用于全局 TUN；不支持自定义 route_address")
    excluded = prefixes(tun.pop("route_exclude_address", []))
    capture = []
    for version in sorted({n.version for n in prefixes(tun["address"])}):
        # Darwin sing-tun defaults exclude the leading zero octet.
        zero = network("0.0.0.0/8" if version == 4 else "::/8")
        family = list(zero.supernet(new_prefix=0).address_exclude(zero))
        for hole in [n for n in excluded if n.version == version]:
            remaining = []
            for n in family:
                if hole.subnet_of(n):
                    remaining.extend(n.address_exclude(hole))
                elif not n.subnet_of(hole):
                    remaining.append(n)
            family = remaining
        if not family:
            raise ValueError("空的 route_address 会让 sing-box 回退到默认路由")
        for n in ipaddress.collapse_addresses(family):
            capture.extend(n.subnets(new_prefix=2) if n.prefixlen < 2 else [n])
    tun["route_address"] = [str(n) for n in capture]


def run(*args):
    return subprocess.run(args, text=True, capture_output=True, env={
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"
    })


def routes():
    """Unscoped exact routes only. netstat abbreviates IPv4 network destinations."""
    table = {}
    for family, version in (("inet", 4), ("inet6", 6)):
        result = run("/usr/sbin/netstat", "-rn", "-f", family)
        result.check_returncode()
        for line in result.stdout.splitlines():
            cols = line.split()
            if len(cols) < 4 or not cols[2].startswith("U") or "I" in cols[2]:
                continue
            dest, gateway, flags, iface = cols[:4]
            if dest == "default":
                dest = "::/0" if version == 6 else "0.0.0.0/0"
            elif version == 4:
                address, _, bits = dest.partition("/")
                parts = address.split(".")
                dest = ".".join(parts + ["0"] * (4 - len(parts))) + "/" + (bits or str(8 * len(parts)))
            elif "%" in dest:
                continue
            table[network(dest, strict=False)] = (gateway, flags, iface)
    return table


def change(action, net, gateway, *flags):
    result = run(ROUTE, "-n", action, "-inet" if net.version == 4 else "-inet6",
                 "-host" if net.prefixlen == net.max_prefixlen else "-net",
                 str(net.network_address) if net.prefixlen == net.max_prefixlen else str(net),
                 gateway, *flags)
    # Darwin route can print a routing-socket error even with exit status zero.
    if result.returncode or result.stderr.strip():
        raise RuntimeError(f"{action} {net}: {result.stderr.strip() or result.stdout.strip()}")


def ours(row, gateway, guard):
    return row and row[0] == gateway and "1" in row[1] and ("B" in row[1]) == guard


def save(owned):
    tmp = STATE.with_suffix(".new")
    tmp.write_text(json.dumps(owned))
    tmp.replace(STATE)


def reconcile(mode, holes=()):
    table = routes()
    owned = json.loads(STATE.read_text()) if STATE.exists() else {}
    if mode != "off":
        # Detect a competing VPN before modifying either address family.
        for net in HALVES:
            row = table.get(net)
            if row and not ours(row, LOOP[net.version], True):
                raise RuntimeError(f"{net} 已有其他路由 ({row[2]})，拒绝覆盖")
        for net in HALVES:
            row = table.get(net)
            if not row:
                change("add", net, LOOP[net.version], "-blackhole", "-proto1")
        if mode == "arm":
            return

    # Only the deliberately excluded destinations need to cross the backstop.
    # An existing LAN/VPN route keeps priority. A narrower VPN route also wins
    # over an installed aggregate (e.g. campus /16 inside the configured /8).
    wanted = {}
    for net in holes:
        default = network("0.0.0.0/0" if net.version == 4 else "::/0")
        row = table.get(default)
        if net.prefixlen < 2:
            raise ValueError(f"排除网段 {net} 与断流保护冲突")
        if not row:
            continue  # offline: retry once the underlying default comes back
        if any(n.version == net.version and n.prefixlen > 1 and net.subnet_of(n)
               and str(n) not in owned and r[2] != "lo0" for n, r in table.items()):
            continue
        wanted[str(net)] = row[0]

    for cidr, gateway in list(owned.items()):
        net = network(cidr)
        if wanted.get(cidr) == gateway and ours(table.get(net), gateway, False):
            continue
        if ours(table.get(net), gateway, False):
            change("delete", net, gateway)
            table.pop(net)
        del owned[cidr]
        save(owned)
    for cidr, gateway in wanted.items():
        if cidr in owned or network(cidr) in table:
            continue
        owned[cidr] = gateway
        save(owned)  # journal before add so an interrupted run can recover
        change("add", network(cidr), gateway, "-proto1")
    if mode == "off":
        for net in HALVES:
            if ours(table.get(net), LOOP[net.version], True):
                change("delete", net, LOOP[net.version])
        STATE.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("prepare", "arm", "sync", "off", "status"))
    parser.add_argument("config", type=Path, nargs="?")
    args = parser.parse_args()
    if args.action == "status":
        table = routes()
        active = True
        for net in HALVES:
            present = bool(ours(table.get(net), LOOP[net.version], True))
            print(net, "已保护" if present else "未保护")
            active &= present
        sys.exit(0 if active else 1)
    if args.action in ("prepare", "sync"):
        cfg = json.loads(args.config.read_text())
        tun, = [i for i in cfg["inbounds"] if i["type"] == "tun"]
        if args.action == "prepare":
            split_capture(tun)
            args.config.write_text(json.dumps(cfg, ensure_ascii=False, indent=2))
            return
        holes = prefixes(tun.get("route_exclude_address", []))
    else:
        holes = []
    with open("/var/run/v2rayn-route-guard.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        reconcile(args.action, holes)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as exc:
        sys.exit(f"route-guard: {exc}")
