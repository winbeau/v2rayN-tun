import importlib.util
import ipaddress
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


guard = load("guard", "daemon/route-guard.py")
perapp = load("perapp", "scripts/per-app-routing.py")
net = ipaddress.ip_network


class Routes(unittest.TestCase):
    def test_last_network_change_survives_debounce_and_failed_restart(self):
        source = (ROOT/"daemon/dnsguard.sh").read_text()
        logic = source[source.index("BOUND=$("):source.index("# ================= 问题 1: DNS 回落到 on-link =================")]
        logic = logic.replace("/bin/launchctl kickstart -k system/com.local.v2rayn-tun", 'echo restart >> "$calls"; false')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root/"bound").write_text("en0 A")
            args = {"BOUND_STATE": str(root/"bound"), "RESTART_STAMP": str(root/"stamp"),
                    "PRIMARY_IF": "en0", "calls": str(root/"calls")}
            def poll(address):
                subprocess.run(["/bin/bash", "-uc", "log() { :; }\n"+logic], check=True,
                               env={**args, "CUR_ADDR": address})
            poll("B")
            poll("C")
            self.assertEqual((root/"calls").read_text().splitlines(), ["restart"])
            (root/"stamp").write_text("0")
            poll("C")
            self.assertEqual((root/"calls").read_text().splitlines(), ["restart"]*2)
            (root/"bound").write_text("en0 C")
            (root/"stamp").write_text("0")
            poll("C")
            self.assertEqual((root/"calls").read_text().splitlines(), ["restart"]*2)

    def test_no_catchall(self):
        config = {"route": {"rules": [{"process_name": [], "outbound": perapp.NODE_TAG},
                                      {"ip_is_private": True, "outbound": "direct"}]}}
        out, _ = perapp.patch(config, None)
        self.assertEqual(out["route"]["rules"], config["route"]["rules"][1:])
        self.assertEqual(perapp.patch(out, None)[0], out)

    def test_capture_preserves_coverage(self):
        tun = {"address": ["172.19.0.1/30", "fdfe::1/126"], "auto_route": True,
               "route_exclude_address": ["10.0.0.0/8", "198.51.100.42/32", "2001:db8::2/128"]}
        excluded = guard.prefixes(tun["route_exclude_address"])
        guard.split_capture(tun)
        ranges = guard.prefixes(tun["route_address"])
        self.assertTrue(all(n.prefixlen > 1 for n in ranges))
        for version, zero in ((4, "0.0.0.0/8"), (6, "::/8")):
            original_holes = [net(zero)] + [n for n in excluded if n.version == version]
            family = [n for n in ranges if n.version == version]
            self.assertFalse(any(n.overlaps(h) for n in family for h in original_holes))
            total = sum(n.num_addresses for n in ipaddress.collapse_addresses(family + original_holes))
            self.assertEqual(total, 1 << net(zero).max_prefixlen)

    def test_guard_lifecycle(self):
        table = {net("0.0.0.0/0"): ("192.168.1.1", "UG", "en0"),
                 net("192.168.99.0/24"): ("link#10", "U", "utun2")}
        scoped = {(6, "utun3"): ("fe80::1%utun3", "UGI", "utun3")}
        def snapshot(defaults):
            defaults.update(scoped)
            return table.copy()

        def change(action, dest, gw, *flags):
            if "-ifscope" in flags:
                iface = flags[flags.index("-ifscope") + 1]
                key = (dest.version, iface)
                if action == "delete":
                    del scoped[key]
                else:
                    self.assertNotIn(key, scoped)
                    scoped[key] = (gw, "UG1I", iface)
                return
            if action == "delete":
                del table[dest]
            else:
                self.assertNotIn(dest, table)
                table[dest] = (gw, "U1B" if "-blackhole" in flags else "U1", "lo0" if "-blackhole" in flags else "en0")
        holes = [net("198.51.100.42"), net("192.168.99.0/24")]
        with tempfile.TemporaryDirectory() as tmp, patch.object(guard, "STATE", Path(tmp)/"owned"), \
                patch.object(guard, "routes", snapshot), patch.object(guard, "change", change):
            guard.reconcile("arm")
            guard.reconcile("sync", holes)
            guard.reconcile("sync", holes)
            self.assertEqual(scoped[4, "en0"][0], "192.168.1.1")
            del table[net("0.0.0.0/0")]
            guard.reconcile("sync", holes)
            self.assertNotIn((4, "en0"), scoped)
            self.assertTrue(all(n in table for n in guard.HALVES))
            self.assertNotIn(holes[0], table)
            table[net("0.0.0.0/0")] = ("192.168.2.1", "UG", "en1")
            guard.reconcile("sync", holes)
            self.assertEqual(table[holes[0]][0], "192.168.2.1")
            self.assertEqual(scoped[4, "en1"][0], "192.168.2.1")
            table[net("::/0")] = ("fe80::1%utun3", "UG", "utun3")
            guard.reconcile("sync", holes)
            del table[net("::/0")]
            guard.reconcile("off")
            guard.reconcile("off")
            self.assertEqual(set(table), {net("0.0.0.0/0"), holes[1]})
            self.assertEqual(scoped, {(6, "utun3"): ("fe80::1%utun3", "UGI", "utun3")})
            table[guard.HALVES[-1]] = ("fe80::1", "UG", "utun3")
            before = table.copy()
            with self.assertRaises(RuntimeError):
                guard.reconcile("arm")
            self.assertEqual(table, before)
