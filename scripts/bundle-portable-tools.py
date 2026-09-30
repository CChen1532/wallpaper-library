#!/usr/bin/env python3
"""Package an explicitly supplied standalone CPython and local media tools.
No downloads or installations occur during build. Missing inputs fail the build.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys

resources = Path(sys.argv[1])
python = Path(os.environ['PORTABLE_PYTHON_SOURCE']).resolve()
media = Path(os.environ.get('MEDIA_TOOLS_SOURCE', str(Path.home() / '.local/bin')))
for name in ('phonto', 'phonto-winwait', 'ffmpeg', 'ffprobe'):
    source = media / name
    if not os.access(source, os.X_OK):
        raise SystemExit(f'Missing build input: {source}')
    shutil.copy2(source, resources / 'Phonto' / name)
version = subprocess.check_output([str(python / 'bin/python3'), '-I', '-c', 'import sys; print("python%d.%d" % sys.version_info[:2])'], text=True).strip()
target = resources / 'Python'
(target / 'bin').mkdir(parents=True)
(target / 'lib').mkdir()
shutil.copy2((python / 'bin/python3').resolve(), target / 'bin/python3')
shutil.copytree(python / 'lib' / version, target / 'lib' / version,
    ignore=shutil.ignore_patterns('site-packages', '__pycache__', '*.pyc', 'test', 'tests', 'idlelib', 'tkinter', '_tkinter*'))
shutil.copy2(python / 'lib' / version / 'LICENSE.txt', resources / 'Licenses/CPython.txt')
subprocess.run([str(target / 'bin/python3'), '-I', '-c',
    'import argparse,fcntl,getpass,hashlib,json,plistlib,shutil,signal,subprocess,tempfile,uuid; print("Portable Python OK")'], check=True)
