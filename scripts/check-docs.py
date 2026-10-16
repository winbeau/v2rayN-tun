#!/usr/bin/env python3
# 检查所有 markdown 里的相对链接是否有效。
#
# 注意: 必须先去掉 #锚点 再判断文件是否存在 —— 否则
#       [文字](doc.md#某节) 会被当成文件名 "doc.md#某节" 而误报失效。
#       中文锚点在不同渲染器下规则不一, 所以正文里尽量用不带锚点的链接。
import os, re, sys, glob

bad = n = 0
for f in glob.glob('**/*.md', recursive=True):
    base = os.path.dirname(f)
    for _, link in re.findall(r'\[([^\]]+)\]\(([^)]+)\)', open(f, encoding='utf-8').read()):
        if link.startswith(('http://', 'https://', 'mailto:')):
            continue
        path = link.split('#')[0]
        if not path:
            continue
        n += 1
        if not os.path.exists(os.path.normpath(os.path.join(base, path))):
            print(f"  ✗ {f}: {link}")
            bad += 1
print(f"  链接 {n} 条 {'✓ 全部有效' if bad == 0 else f'✗ {bad} 失效'}")
sys.exit(1 if bad else 0)
