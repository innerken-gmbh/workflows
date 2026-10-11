#!/usr/bin/env python3
"""
把 AppCenter/<App> 整理成 appcenter-sync 通道用的产物（设备端见 aaden-cli AadenDeploy/appCenterSync.sh）。

  prune <dir>      就地剔除历次手工覆盖堆积下来的旧构建文件：
                     - 所有 *.map
                     - js/ css/ img/ fonts/ media/ 下文件名带 8 位 hash、但当前构建没引用的
                     - 根目录下 service-worker.js 没引用的 precache-manifest.*.js
                   "当前构建引用了什么"从 index.html 出发算闭包：index.html 的 src/href，
                   webpack runtime 里的 chunk→hash 表，以及 js/css 文本里出现的 hash 资源路径。
                   不带 hash 的文件（fonts.css、highlightjs/、android/、Images/ 等手工放的）一律保留。
  manifest <dir>   写 <dir>/.appcenter-manifest（sha256sum 格式，按路径排序），stdout 输出它的 sha256，
                   这就是 manifest.json 里的 treeSha256。设备端用 `sha256sum -c` 校验同一份清单。
"""
import hashlib
import os
import re
import sys

HASHED_DIRS = ('js', 'css', 'img', 'fonts', 'media')
HASHED_NAME = re.compile(r'\.[0-9a-f]{8}\.[A-Za-z0-9]+$')
# index.html 里的属性值，Vue CLI 产出的 html 属性不带引号
ATTR = re.compile(r'''(?:src|href)=["']?([^"'\s>]+)''')
# webpack 4 runtime 的 chunk 文件名：  js/"+({..名字..}[e]||e)+"."+{"chunk-xx":"hash",...}[e]+".js"
RUNTIME = re.compile(r'(js|css)/"\+\(\{([^}]*)\}\[\w+\]\|\|\w+\)\+"\."\+\{([^}]*)\}')
PAIR = re.compile(r'"?([\w\-]+)"?:"([\w\-]+)"')
# js/css 文本里的 hash 资源路径（url(../img/x.1234abcd.png)、n.p+"img/x.1234abcd.png" 等）
ASSET_REF = re.compile(r'(?<![\w\-])((?:js|css|img|fonts|media)/[\w\-.@]+\.[0-9a-f]{8}\.[A-Za-z0-9]+)')
PRECACHE = re.compile(r'precache-manifest\.[0-9a-f]+\.js')


def norm(ref):
    ref = ref.split('?')[0].split('#')[0]
    if re.match(r'^[a-z]+:|^//', ref):
        return None
    while ref.startswith('./'):
        ref = ref[2:]
    return ref.lstrip('/') or None


def read_text(path):
    with open(path, 'rb') as f:
        return f.read().decode('utf-8', 'replace')


def referenced(root):
    refs, missing = set(), set()
    html = read_text(os.path.join(root, 'index.html'))
    queue = [r for r in (norm(m) for m in ATTR.findall(html)) if r]
    sw = os.path.join(root, 'service-worker.js')
    if os.path.exists(sw):
        queue.append('service-worker.js')
        queue += PRECACHE.findall(read_text(sw))
    while queue:
        ref = queue.pop()
        if ref in refs:
            continue
        refs.add(ref)
        path = os.path.join(root, ref)
        if not os.path.isfile(path):
            missing.add(ref)
            continue
        if not ref.endswith(('.js', '.css')):
            continue
        text = read_text(path)
        for kind, names, hashes in RUNTIME.findall(text):
            name_of = dict(PAIR.findall(names))
            for chunk, h in PAIR.findall(hashes):
                queue.append('%s/%s.%s.%s' % (kind, name_of.get(chunk, chunk), h, kind))
        queue += ASSET_REF.findall(text)
    return refs, missing


def prune(root):
    refs, missing = referenced(root)
    removed = removed_bytes = 0
    for dirpath, _, files in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        top = rel_dir.split(os.sep)[0]
        for name in files:
            rel = os.path.normpath(os.path.join(rel_dir, name))
            stale = (
                name.endswith('.map')
                or (top in HASHED_DIRS and HASHED_NAME.search(name) and rel not in refs)
                or (rel_dir == '.' and PRECACHE.fullmatch(name) and rel not in refs)
            )
            if stale:
                path = os.path.join(dirpath, name)
                removed_bytes += os.path.getsize(path)
                os.remove(path)
                removed += 1
    # webpack 给没有样式的 chunk 也记了 css hash：31d6cfe0 是空串的 md5，runtime 不会去拉，不算缺
    empty_css = {r for r in missing if r.endswith('.31d6cfe0.css')}
    missing -= empty_css
    # 其余引用了但源目录里本来就没有的，只报告，不算错
    print('prune: 删除 %d 个文件 (%.1f MB)，引用 %d 个，源里本来就缺 %d 个'
          % (removed, removed_bytes / 1048576, len(refs) - len(empty_css), len(missing)), file=sys.stderr)
    for ref in sorted(missing):
        print('  缺: ' + ref, file=sys.stderr)
    if 'index.html' in missing or any(r.startswith('js/app.') for r in missing):
        sys.exit('入口文件缺失，产物不可用')


def manifest(root):
    lines = []
    for dirpath, _, files in os.walk(root):
        for name in files:
            rel = os.path.relpath(os.path.join(dirpath, name), root)
            if rel == '.appcenter-manifest':
                continue
            with open(os.path.join(dirpath, name), 'rb') as f:
                digest = hashlib.sha256(f.read()).hexdigest()
            lines.append('%s  %s\n' % (digest, rel))
    # 按路径排序（不按 hash），同一份内容任何机器上都得到同一个 treeSha256
    lines.sort(key=lambda line: line.split('  ', 1)[1])
    body = ''.join(lines).encode('utf-8')
    with open(os.path.join(root, '.appcenter-manifest'), 'wb') as f:
        f.write(body)
    print(hashlib.sha256(body).hexdigest())


if __name__ == '__main__':
    if len(sys.argv) != 3 or sys.argv[1] not in ('prune', 'manifest'):
        sys.exit(__doc__)
    {'prune': prune, 'manifest': manifest}[sys.argv[1]](sys.argv[2])
