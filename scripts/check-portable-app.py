#!/usr/bin/env python3
"""Read-only bundle audit plus relocated, isolated tool execution.
Does not start wallpaper engines or write system wallpaper settings.
"""
from pathlib import Path
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
app = Path(sys.argv[1]).resolve()
count = 0

def check(condition, message):
    global count
    if not condition:
        raise AssertionError(message)
    count += 1
    print('PASS:', message)

info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
minimum = tuple(map(int, info['LSMinimumSystemVersion'].split('.')))
check(minimum == (15, 0), 'minimum macOS matches packaged dependencies')
for path in app.rglob('*'):
    if not path.is_file() or path.is_symlink():
        continue
    with path.open('rb') as stream:
        magic = stream.read(4)
    if magic not in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
        continue
    load = subprocess.check_output(['/usr/bin/otool', '-l', str(path)], text=True)
    versions = re.findall(r'\bminos\s+([\d.]+)', load)
    check(all(tuple(map(int, v.split('.'))) <= minimum for v in versions), f'deployment version: {path.name}')
    deps = subprocess.check_output(['/usr/bin/otool', '-L', str(path)], text=True)
    external = [line.strip().split(' (')[0] for line in deps.splitlines()[1:]
                if line.strip().startswith('/') and not line.strip().startswith(('/usr/lib/', '/System/Library/'))]
    check(not external, f'no external dylibs: {path.relative_to(app)}')
    check('arm64' in subprocess.check_output(['/usr/bin/lipo', '-archs', str(path)], text=True), f'Apple Silicon slice: {path.name}')
with tempfile.TemporaryDirectory(prefix='Wallpaper Portable 中文 ') as folder:
    moved = Path(folder) / '移动后的应用.app'
    shutil.copytree(app, moved)
    resources = moved / 'Contents/Resources'
    env = {'PATH': '/usr/bin:/bin', 'TMPDIR': folder, 'LANG': 'en_US.UTF-8'}
    python = resources / 'Python/bin/python3'
    result = subprocess.check_output([str(python), '-I', '-B', '-c',
        'import sys,fcntl,hashlib,plistlib,subprocess,uuid; print(sys.prefix)'], env=env, text=True)
    check(str(resources / 'Python') in result, 'Python discovers relocated bundled stdlib without developer tools')
    for tool in ('ffmpeg', 'ffprobe'):
        check(subprocess.run([str(resources / 'Phonto' / tool), '-version'], env=env, capture_output=True).returncode == 0, f'relocated {tool} starts')
    check(subprocess.run([str(resources / 'Phonto/phonto'), 'displays'], env=env, capture_output=True).returncode == 0, 'relocated video engine enumerates displays')
    check(subprocess.run([str(resources / 'Phonto/phonto-wall'), 'status'], env=env, capture_output=True).returncode == 0, 'wrapper uses bundled Python')
    check(subprocess.run([str(python), '-I', '-B', str(resources / 'WallpaperSwitch/wallpaper-switch.py'), '--help'], env=env, capture_output=True).returncode == 0, 'wallpaper helper imports offline')
    check(not list((resources / 'Python').rglob('*.pyc')), 'runtime helper checks leave no bytecode inside the signed bundle')
    check(subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(moved)], capture_output=True).returncode == 0, 'relocated signed app stays valid after running its helpers')
print(count, 'portability checks passed (does not replace a physical clean-Mac trial)')
