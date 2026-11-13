#!/usr/bin/env python3
"""Replace domestic UDP DNS with AliDNS HTTPS; keep routing and proxy nodes.

python3 scripts/fix-easyconnect-dns.py plan
sudo python3 scripts/fix-easyconnect-dns.py apply
Close Claude/AdsPower before apply: restarting TUN temporarily removes its routes.
"""

import argparse
import copy
import datetime
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time

BASE = Path('/usr/local/libexec/v2rayn-tun')
LIVE = BASE / 'config.json'
TAGS = {'local-local', 'direct-dns-1'}


def candidate(original):
    config = copy.deepcopy(original)
    servers = config['dns']['servers']
    if any(sum(s.get('tag') == tag for s in servers) != 1 for tag in TAGS):
        raise RuntimeError('Expected one local-local and one direct-dns-1 DNS server')
    if not any(s.get('tag') == 'hosts-dns' and s.get('type') == 'hosts'
               and s.get('predefined', {}).get('dns.alidns.com') for s in servers):
        raise RuntimeError('Missing static AliDNS bootstrap in hosts-dns')
    if not any(o.get('tag') == 'direct' and o.get('type') == 'direct'
               for o in config.get('outbounds', [])):
        raise RuntimeError('Expected the existing direct outbound')
    for server in servers:
        if server.get('tag') in TAGS:
            tag = server['tag']
            server.clear()
            server.update(type='https', tag=tag, server='dns.alidns.com',
                          path='/dns-query', domain_resolver='hosts-dns', detour='direct')
    return config


def ensure_idle():
    rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines()
    pattern = r'/(?:AdsPower[^/]*|SunBrowser[^/]*|Claude)\.app/|(?:^|/)claude$'
    busy = [row.strip() for row in rows if re.search(pattern, row)
            and '/ShipIt' not in row and 'crashpad_handler' not in row]
    if busy:
        raise RuntimeError('Close Claude, Claude Code and AdsPower before restarting TUN:\n'
                           + '\n'.join(busy[:8]))


def validate(config, directory, name):
    path = Path(directory) / name
    path.write_text(json.dumps(config, indent=2, ensure_ascii=False) + '\n')
    path.chmod(0o600)
    subprocess.run([str(BASE / 'sing-box'), 'check', '-c', str(path)], check=True)


def probe(config, directory):
    """Test the proposed DNS with an isolated loopback listener, without TUN."""
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    test = copy.deepcopy(config)
    test['log'] = {'level': 'warn'}
    test.pop('experimental', None)
    test['inbounds'] = [{'type': 'direct', 'listen': '127.0.0.1', 'listen_port': port}]
    test['route'] = {'auto_detect_interface': True,
                     'default_domain_resolver': {'server': 'direct-dns-1'},
                     'rules': [{'action': 'hijack-dns'}],
                     'rule_set': config['route']['rule_set']}
    validate(test, directory, 'probe.json')
    with (Path(directory) / 'probe.log').open('w') as log:
        process = subprocess.Popen([str(BASE / 'sing-box'), 'run', '-c',
                                    str(Path(directory) / 'probe.json')],
                                   stdout=log, stderr=log)
        try:
            for _ in range(30):
                if process.poll() is not None:
                    raise RuntimeError('Independent DNS probe did not start')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=0.2):
                        break
                except OSError:
                    time.sleep(0.1)
            else:
                raise RuntimeError('Independent DNS probe did not become ready')
            for host in ('api.deepseek.com', 'www.baidu.com', 'www.google.com'):
                dns_check(host, ['@127.0.0.1', '-p', str(port)])
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


def dns_check(host, extra=()):
    result = subprocess.run(['dig', *extra, host, 'A', '+time=8', '+tries=1'],
                            capture_output=True, text=True, timeout=12)
    if result.returncode or 'status: NOERROR' not in result.stdout or not re.search(
            r'\sIN\s+A\s+\d', result.stdout):
        raise RuntimeError('DNS verification failed: ' + host)
    print('DNS OK:', host, flush=True)


def singbox_pids():
    rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines()
    return {row.split(None, 1)[0] for row in rows
            if row.strip().endswith(str(BASE / 'sing-box'))}


def verify(old_pids=()):
    # Check an actual TUN address, not merely a running process or open socket.
    for _ in range(30):
        interfaces = subprocess.check_output(['/sbin/ifconfig', '-a'], text=True)
        if 'inet 172.19.0.1 ' in interfaces and singbox_pids() - set(old_pids):
            break
        time.sleep(1)
    else:
        raise RuntimeError('TUN address did not reappear; inspect the daemon log')
    for host in ('api.deepseek.com', 'www.baidu.com', 'www.google.com'):
        dns_check(host)
    result = subprocess.run(['curl', '-sS', '--noproxy', '*', '--max-time', '15',
                             '-o', '/dev/null', '-w', '%{http_code}',
                             'https://api.deepseek.com/anthropic/v1/messages'],
                            capture_output=True, text=True, timeout=20)
    if result.returncode or result.stdout.strip() not in ('200', '400', '401', '404', '405'):
        raise RuntimeError('DeepSeek HTTPS verification failed: ' + result.stdout)
    print('DeepSeek HTTPS:', result.stdout, '(no credentials sent; this is a transport check)')
    print('Retry the failed turn in DeepSeek to verify an authenticated model response.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('plan', 'apply'))
    args = parser.parse_args()
    if args.mode == 'apply':
        if os.geteuid() != 0:
            raise RuntimeError('Run apply with sudo in your terminal; no changes made')
        ensure_idle()
    before = LIVE.read_bytes()
    original = json.loads(before)
    patched = candidate(original)
    # Validate the installed config and the effective config with merged exclusions.
    with tempfile.TemporaryDirectory(prefix='easyconnect-dns-') as directory:
        validate(patched, directory, 'candidate.json')
        validate(candidate(json.loads((BASE / 'config.run.json').read_text())),
                 directory, 'runtime-candidate.json')
        probe(patched, directory)
    print('Validated: local-local/direct-dns-1 -> AliDNS HTTPS (443).', flush=True)
    print('Routing, foreign DNS and all proxy outbounds are preserved.', flush=True)
    if args.mode == 'plan':
        print('Plan only; no live changes.')
        return
    ensure_idle()
    if before != LIVE.read_bytes():
        raise RuntimeError('Config changed concurrently; run again')
    if patched == original:
        print('Already configured; skipping restart.')
        verify()
        return
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    backup = BASE / ('config.json.bak-easyconnect-dns-' + stamp)
    with backup.open('xb') as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(before)
    print('Backup:', backup, flush=True)
    old_pids = singbox_pids()
    fd, temporary = tempfile.mkstemp(prefix='.dns-fix-', dir=BASE)
    try:
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), LIVE.stat().st_mode & 0o777)
            os.fchown(stream.fileno(), LIVE.stat().st_uid, LIVE.stat().st_gid)
            json.dump(patched, stream, indent=2, ensure_ascii=False)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, LIVE)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    subprocess.run(['/bin/launchctl', 'kickstart', '-k',
                    'system/com.local.v2rayn-tun'], check=True)
    verify(old_pids)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
