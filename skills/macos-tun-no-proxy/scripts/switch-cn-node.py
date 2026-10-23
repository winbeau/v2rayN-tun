#!/usr/bin/env python3
"""仅替换现有国内出站；保留 DNS detour、路由、例外和国外出站。

python3 scripts/switch-cn-node.py plan --node selab-reality
sudo python3 scripts/switch-cn-node.py apply --node selab-reality
"""

import argparse
import copy
import datetime
import json
import os
from pathlib import Path
import pwd
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import time

BASE = Path('/usr/local/libexec/v2rayn-tun')
LIVE = BASE / 'config.json'
SINGBOX = BASE / 'sing-box'
CN_TAG = 'cn-via-jp'  # 保留历史标签，已有路由和 jp-dns 均引用它。


def user_home():
    return Path(pwd.getpwuid(int(os.environ.get('SUDO_UID', os.getuid()))).pw_dir)


def load_node(name, group=None):
    db = user_home() / 'Library/Application Support/v2rayN/guiConfigs/guiNDB.db'
    with sqlite3.connect(db.as_uri() + '?mode=ro', uri=True) as con:
        con.row_factory = sqlite3.Row
        query = ('SELECT p.* FROM ProfileItem p '
                 'LEFT JOIN SubItem s ON p.Subid = s.Id WHERE p.Remarks = ?')
        params = [name]
        if group is not None:
            query += ' AND s.Remarks = ?'
            params.append(group)
        rows = con.execute(query, params).fetchall()
    if len(rows) != 1:
        scope = f'（分组：{group}）' if group is not None else '（可用 --group 指定分组）'
        raise RuntimeError(f'需要唯一的同名节点，实际找到 {len(rows)} 个：{name}{scope}')
    p = dict(rows[0])
    if p.get('ConfigType') != 5 or p.get('StreamSecurity') != 'reality':
        raise RuntimeError('仅支持 VLESS REALITY 节点')
    if (p.get('Network') or 'tcp') not in ('tcp', 'raw'):
        raise RuntimeError('仅支持 TCP/raw 传输')
    if not all(p.get(k) for k in ('Address', 'Password', 'PublicKey', 'Sni')):
        raise RuntimeError('节点缺少必要的 REALITY 参数')
    ob = {
        'type': 'vless', 'tag': CN_TAG, 'server': p['Address'],
        'server_port': p['Port'] or 443, 'uuid': p['Password'],
        'packet_encoding': 'xudp',
        'tls': {
            'enabled': True, 'server_name': p['Sni'],
            'utls': {'enabled': True, 'fingerprint': p.get('Fingerprint') or 'chrome'},
            'reality': {'enabled': True, 'public_key': p['PublicKey'],
                        'short_id': p.get('ShortId') or ''},
        },
    }
    flow = json.loads(p.get('ProtoExtra') or '{}').get('Flow') or p.get('Flow')
    if flow:
        ob['flow'] = flow
    return ob


def write_json(path, cfg):
    with path.open('w', encoding='utf-8') as f:
        os.fchmod(f.fileno(), 0o600)
        json.dump(cfg, f, indent=2, ensure_ascii=False)
        f.write('\n')


def check(path):
    result = subprocess.run([str(SINGBOX), 'check', '-c', str(path)], capture_output=True)
    if result.returncode:
        raise RuntimeError('sing-box 配置校验失败；线上未改动')


def fetch(url, port=None):
    cmd = ['curl', '-4', '-sS', '--connect-timeout', '5', '--max-time', '15',
           '-o', '/dev/null', '-w', '%{http_code}']
    cmd += ['--noproxy', '', '--proxy', f'socks5h://127.0.0.1:{port}'] if port else ['--noproxy', '*']
    result = subprocess.run(cmd + [url], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else '000'


def probe(ob, directory):
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    path = directory / 'probe.json'
    write_json(path, {'log': {'level': 'error'}, 'inbounds': [
        {'type': 'mixed', 'listen': '127.0.0.1', 'listen_port': port}],
        'outbounds': [ob], 'route': {'final': CN_TAG}})
    check(path)
    proc = subprocess.Popen([str(SINGBOX), 'run', '-c', str(path)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 4
        while True:
            if proc.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError('临时节点测试未启动；线上未改动')
            try:
                socket.create_connection(('127.0.0.1', port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)
        for url, accepted in [
            ('https://www.baidu.com', {'200'}),
            ('https://api.deepseek.com/models', {'200', '401'}),
            ('https://cloudflare-dns.com/dns-query?dns=AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE', {'200'}),
        ]:
            code = fetch(url, port)
            print(f'  节点实测 {url.split("?")[0]}: HTTP {code}', flush=True)
            if code not in accepted:
                raise RuntimeError('新节点预检未通过；线上未改动')
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['plan', 'apply'])
    parser.add_argument('--node', default='selab-reality')
    parser.add_argument('--group', help='按 v2rayN 分组名称精确匹配，避免选中其他组的同名节点')
    args = parser.parse_args()
    if args.action == 'apply' and os.geteuid() != 0:
        raise RuntimeError('apply 需要 sudo；plan 不需要管理员权限')
    original = LIVE.read_bytes()
    cfg = json.loads(original)
    indices = [i for i, ob in enumerate(cfg['outbounds']) if ob.get('tag') == CN_TAG]
    if len(indices) != 1:
        raise RuntimeError('需要唯一的现有 cn-via-jp 出站；请先配置基础分流')
    ob = load_node(args.node, args.group)
    candidate = copy.deepcopy(cfg)
    old = candidate['outbounds'][indices[0]]
    candidate['outbounds'][indices[0]] = ob
    print(f'国内出站：{old["server"]}:{old["server_port"]} → '
          f'{args.node} ({ob["server"]}:{ob["server_port"]})', flush=True)
    if args.group is not None:
        print(f'节点分组：{args.group}', flush=True)
    print('仅替换该出站；已有 DNS detour 和路由继续引用同一标签。', flush=True)
    # 临时目录同目标目录仅在 apply 时使用，以便最后原子替换。
    with tempfile.TemporaryDirectory(prefix='cn-switch-',
                                     dir=BASE if args.action == 'apply' else None) as temp:
        directory = Path(temp)
        path = directory / 'candidate.json'
        write_json(path, candidate)
        check(path)
        probe(ob, directory)
        if LIVE.read_bytes() != original:
            raise RuntimeError('预检期间线上配置发生变化，请重试')
        if args.action == 'plan':
            print('完整配置校验及节点实测通过；尚未修改线上配置。')
            return
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
        backup = BASE / f'config.json.bak-cn-{stamp}'
        shutil.copy2(LIVE, backup)
        backup.chmod(0o600)
        os.chown(path, 0, 0)
        path.chmod(0o600)
        os.replace(path, LIVE)
        restart = ['launchctl', 'kickstart', '-k', 'system/com.local.v2rayn-tun']
        if subprocess.run(restart).returncode:
            shutil.copy2(backup, LIVE)
            subprocess.run(restart)
            raise RuntimeError('守护重启失败，已恢复原配置')
        for _ in range(15):
            try:
                running = json.loads((BASE / 'config.run.json').read_text())
                loaded = next(o for o in running['outbounds'] if o.get('tag') == CN_TAG)
                interfaces = subprocess.run(['ifconfig'], capture_output=True, text=True).stdout
                if loaded == ob and '172.19.0.1' in interfaces:
                    code = fetch('https://api.deepseek.com/models')
                    if code in ('200', '401'):
                        print(f'已生效：TUN → {args.node} → DeepSeek API，HTTP {code}')
                        print(f'备份：{backup}')
                        return
            except (OSError, ValueError, StopIteration):
                pass
            time.sleep(1)
        raise RuntimeError(f'已写入新配置，但 TUN 连通性尚未验证通过。备份：{backup}')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, sqlite3.Error) as error:
        raise SystemExit(str(error))
