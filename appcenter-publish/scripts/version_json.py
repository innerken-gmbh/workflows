#!/usr/bin/env python3
"""
写 AppCenter 应用的 version.json：{"app","version","commit","ref","repo","builtAt"}。
门店上 aaden-cli appcenter-usage 读它，上报每个前端目录装的是哪个版本（前端版本遥测 A 层）。
version 优先用参数，其次调用方仓库根目录 package.json 的 version，都没有就是 "unknown"。

用法: version_json.py <输出文件> <App> [version]
"""
import datetime
import json
import os
import sys

out, app = sys.argv[1], sys.argv[2]
version = (sys.argv[3] if len(sys.argv) > 3 else '').strip()
if not version:
    pkg = os.path.join(os.environ.get('GITHUB_WORKSPACE', '.'), 'package.json')
    try:
        with open(pkg, encoding='utf-8') as f:
            version = str(json.load(f).get('version') or '').strip()
    except (OSError, ValueError):
        version = ''
data = {
    'app': app,
    'version': version or 'unknown',
    'commit': (os.environ.get('GITHUB_SHA') or '')[:12] or 'unknown',
    'ref': os.environ.get('GITHUB_REF_NAME', ''),
    'repo': os.environ.get('GITHUB_REPOSITORY', ''),
    'builtAt': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
}
with open(out, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False)
    f.write('\n')
