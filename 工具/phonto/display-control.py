#!/usr/bin/python3
"""Display-scoped phonto-wall API; only this wrapper owns video processes.

Persistent launchd labels and atomic per-display records avoid the upstream
single-current-path cache. Global legacy playback is retired by label only.
"""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

HOME = Path.home()
ROOT = HOME / 'Library/Application Support/WallpaperUI/DisplayPlayback'
TOOLS = Path(__file__).resolve().parent
PHONTO = TOOLS / 'phonto'
WINWAIT = TOOLS / 'phonto-winwait'


def command(args, timeout=8):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def pid(label):
    result = command(['/bin/launchctl', 'print', f'gui/{os.getuid()}/{label}'])
    if result.returncode:
        if 'Could not find' in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip() or '无法读取视频播放任务')
    for line in result.stdout.splitlines():
        fields = line.strip().split(' = ')
        if len(fields) == 2 and fields[0] == 'pid':
            return int(fields[1])
    return None


def remove(label):
    result = command(['/bin/launchctl', 'remove', label])
    if result.returncode and pid(label) is not None:
        raise RuntimeError('停止视频任务失败：' + label)
    deadline = time.monotonic() + 4
    while pid(label) is not None:
        if time.monotonic() >= deadline:
            raise RuntimeError('视频任务尚未退出：' + label)
        time.sleep(.05)


def labels(key):
    return [f'local.wallpaper.phonto.{key.lower()}.{slot}' for slot in ('a', 'b')]


def record(key):
    try:
        return json.loads((ROOT / (key + '.json')).read_text())
    except FileNotFoundError:
        return {}


def state(key):
    value = record(key)
    live = [label for label in labels(key) if pid(label) is not None]
    # Never infer a path from another monitor's global cache.
    if live and (len(live) != 1 or value.get('label') != live[0]):
        raise RuntimeError('此显示器的播放记录不一致，请停止此屏幕后重试')
    return {'running': bool(live), 'lastPath': value.get('path')}


def retire_legacy():
    # No pkill: other displays are owned by different labels.
    for label in ['com.local.phonto-rotate', 'com.local.phonto-wall', 'com.local.phonto-wall.b']:
        remove(label)
    for path in [HOME / '.config/phonto/rotate.conf', HOME / 'Library/LaunchAgents/com.local.phonto-rotate.plist']:
        path.unlink(missing_ok=True)


def stop(key):
    for label in labels(key):
        remove(label)


def start(key, display, path):
    source = Path(path)
    if not source.is_absolute() or not source.is_file() or source.suffix.lower() != '.mp4':
        raise RuntimeError('请选择有效的 MP4 文件')
    helper = TOOLS / 'display-name'
    if helper.is_file():
        resolved = command([str(helper), key])
        if resolved.returncode:
            raise RuntimeError('目标显示器已断开或无法区分同名显示器')
        display = resolved.stdout.strip()
    # phonto currently addresses macOS screens by localized name, not CG ID.
    listing = command([str(PHONTO), 'displays'])
    if listing.returncode or sum(line.startswith(display + '  ') for line in listing.stdout.splitlines()) != 1:
        raise RuntimeError('目标显示器已断开，请重新选择显示器')
    retire_legacy()
    pair = labels(key)
    existing = [label for label in pair if pid(label) is not None]
    if len(existing) > 1:
        raise RuntimeError('此显示器有未完成的切换，请停止此屏幕后重试')
    new = pair[1] if existing == [pair[0]] else pair[0]
    remove(new)
    try:
        result = command(['/bin/launchctl', 'submit', '-l', new, '--', str(PHONTO), '--display', display, path])
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or '视频启动失败')
        deadline = time.monotonic() + 5
        child = pid(new)
        while child is None and time.monotonic() < deadline:
            time.sleep(.05)
            child = pid(new)
        if child is None:
            raise RuntimeError('视频进程未启动')
        if not WINWAIT.is_file():
            raise RuntimeError('缺少视频窗口确认工具 phonto-winwait')
        ready = command([str(WINWAIT), str(child), '6'], timeout=8)
        if ready.returncode:
            raise RuntimeError('未确认视频窗口，已保留此屏幕原播放')
        time.sleep(.35)
        if pid(new) != child:
            raise RuntimeError('视频进程提前退出')
        for old in existing:
            remove(old)
        temporary = ROOT / (key + '.tmp')
        temporary.write_text(json.dumps({'path': path, 'label': new, 'display': display}, ensure_ascii=False))
        temporary.replace(ROOT / (key + '.json'))
    except BaseException:
        remove(new)
        raise


def main(args):
    if args == ['off']:
        ROOT.mkdir(parents=True, exist_ok=True)
        with (ROOT / 'control.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            retire_legacy()
            for path in ROOT.glob('*.json'):
                stop(str(uuid.UUID(path.stem)).upper())
        return
    if args == ['status']:
        print('Display-scoped playback control')
        return
    if len(args) < 3 or args[0] != 'display':
        raise ValueError('用法: phonto-wall display UUID state|start|off|stop-rotation')
    key = str(uuid.UUID(args[1])).upper()
    action = args[2]
    ROOT.mkdir(parents=True, exist_ok=True)
    # Global short transaction lock also serializes retiring legacy labels.
    with (ROOT / 'control.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if action == 'state' and len(args) == 3:
            print(json.dumps(state(key), ensure_ascii=False))
        elif action == 'start' and len(args) == 5:
            start(key, args[3], args[4])
        elif action == 'off' and len(args) == 3:
            retire_legacy()
            stop(key)
        elif action == 'stop-rotation' and len(args) == 3:
            remove('com.local.phonto-rotate')
        else:
            raise ValueError('不支持的显示器控制操作')


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
