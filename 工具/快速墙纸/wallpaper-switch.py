#!/usr/bin/env python3
"""macOS 14+ scoped wallpaper swap with a durable, field-level undo journal.

Private WallpaperAgent schema: refuse unknown structures. No GUI automation,
Space switching, Dock restart, or screen-saver writes. See README.md.
"""
import argparse
import copy
import datetime
import fcntl
import getpass
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
STORE = Path.home() / 'Library/Application Support/com.apple.wallpaper/Store/Index.plist'
STATE = ROOT / 'dist/WallpaperQuickSwitch'


def encoded(value):
    return plistlib.dumps(value, fmt=plistlib.FMT_BINARY, sort_keys=True)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def atomic(path, data, mode=0o600):
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as handle:
            os.fchmod(handle.fileno(), mode)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def load_store(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError('壁纸配置缺失或为符号链接，拒绝改动')
    raw = path.read_bytes()
    value = plistlib.loads(raw)
    if not isinstance(value, dict) or not isinstance(value.get('Spaces'), dict):
        raise ValueError('不支持此 macOS 壁纸配置格式')
    return raw, value


def semantic(value):
    # WallpaperAgent updates usage timestamps without changing the selection.
    if isinstance(value, dict):
        return {k: semantic(v) for k, v in value.items() if k not in ('LastUse', 'LastSet')}
    if isinstance(value, list):
        return [semantic(v) for v in value]
    return value


def entry(document, path):
    node = document
    for key in path:
        if not isinstance(node, dict) or key not in node:
            raise ValueError('原 Space/显示器记录已消失，保留恢复记录：' + '/'.join(path))
        node = node[key]
    if not isinstance(node, dict):
        raise ValueError('壁纸节点格式变化，拒绝覆盖')
    return node


def selected(node):
    return {'present': 'Desktop' in node, 'value': copy.deepcopy(node.get('Desktop', {}))}


def put(node, selection):
    if selection['present']:
        node['Desktop'] = copy.deepcopy(selection['value'])
    else:
        node.pop('Desktop', None)


def image_desktop(image):
    now = datetime.datetime.utcnow()
    # Matches the image provider's Files/placement form observed locally.
    return {'LastSet': now, 'LastUse': now, 'Content': {
        'Choices': [{'Provider': 'com.apple.wallpaper.choice.image',
                     'Configuration': encoded({'placement': 1}),
                     'Files': [{'relative': image.as_uri()}]}], 'Shuffle': '$null'}}


def prepare(document, display_uuid, space_uuids, image):
    global_entry = document.get('AllSpacesAndDisplays', {})
    if isinstance(global_entry, dict) and 'Desktop' in global_entry:
        raise ValueError('当前启用了全空间壁纸，不能安全地只改选定桌面')
    patches = []
    after = {'present': True, 'value': image_desktop(image)}
    for space in space_uuids:
        path = ['Spaces', space, 'Displays', display_uuid]
        node = entry(document, path)
        if node.get('Type') != 'individual':
            raise ValueError('此桌面未使用独立壁纸/屏保配置，拒绝自动拆分')
        patches.append({'path': path, 'before': selected(node), 'after': copy.deepcopy(after)})
    if not patches:
        raise ValueError('没有目标桌面')
    return patches


def merge(document, patches, restore=False):
    result = copy.deepcopy(document)
    # Preflight EVERY field before changing any field.
    for patch in patches:
        current = selected(entry(document, patch['path']))
        expected = patch['after'] if restore else patch['before']
        target = patch['before'] if restore else patch['after']
        if semantic(current) != semantic(expected) and not (restore and semantic(current) == semantic(target)):
            raise ValueError('该桌面壁纸已被其他操作改变，拒绝覆盖；恢复记录保留：' + '/'.join(patch['path']))
    for patch in patches:
        put(entry(result, patch['path']), patch['before'] if restore else patch['after'])
    return result


def commit_store(path, original, document):
    # Agent does not cooperate with our lock; refuse an observed concurrent write.
    if path.read_bytes() != original:
        raise ValueError('WallpaperAgent 正在更新配置，本次未写入；稍后重试')
    atomic(path, encoded(document), path.stat().st_mode & 0o777)


def reload_agent():
    result = subprocess.run(['/usr/bin/killall', '-u', getpass.getuser(), '-TERM', 'WallpaperAgent'],
                            capture_output=True, text=True, timeout=5)
    if result.returncode:
        raise RuntimeError('配置已写入但 WallpaperAgent 刷新失败；请运行“恢复原壁纸”：' + result.stderr.strip())


def inventory(display_id=None, binary=None):
    binary = binary or STATE / 'space-inventory'
    if not binary.is_file():
        raise ValueError('请先运行 工具/快速墙纸/build.sh')
    args = [str(binary)] + ([str(display_id)] if display_id else [])
    return json.loads(subprocess.check_output(args, text=True, timeout=5))


def resolve_spaces(inv, spec):
    rows = inv['spaces']
    if spec == 'all':
        return rows
    try:
        numbers = [int(n) for n in spec.split(',')]
    except ValueError:
        raise ValueError('桌面参数应为 1,2 或 all')
    if not numbers or len(numbers) != len(set(numbers)):
        raise ValueError('桌面编号为空或重复')
    selected_rows = [r for n in numbers for r in rows if r['number'] == n]
    if len(selected_rows) != len(numbers):
        raise ValueError('指定的桌面编号不存在（不计全屏应用）')
    return selected_rows


class Switcher:
    def __init__(self, store=STORE, state=STATE, refresh=reload_agent):
        self.store, self.state, self.refresh = store, state, refresh
        self.session = state / 'session.plist'

    def read_session(self):
        if not self.session.exists():
            return None
        value = plistlib.loads(self.session.read_bytes())
        if value.get('schema') != 1 or value.get('store') != str(self.store.resolve()):
            raise ValueError('恢复记录版本或配置路径不匹配')
        return value

    def save(self, session):
        atomic(self.session, encoded(session))

    def apply(self, image, inv, rows):
        old = self.read_session()
        if old and old['state'] != 'restored':
            raise ValueError('已有待恢复壁纸；先执行 restore，避免覆盖原始备份')
        image = image.expanduser().resolve(strict=True)
        if not image.is_file() or image.suffix.lower() not in ('.png', '.jpg', '.jpeg', '.heic', '.heif'):
            raise ValueError('请选择 PNG、JPEG 或 HEIC 普通图片文件')
        raw, document = load_store(self.store)
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
        archive = self.state / stamp
        archive.mkdir(mode=0o700)
        cached = archive / ('wallpaper' + image.suffix.lower())
        shutil.copyfile(image, cached)
        patches = prepare(document, inv['display_uuid'], [r['uuid'] for r in rows], cached)
        atomic(archive / 'original.plist', raw)
        if old:
            atomic(archive / 'previous-session.plist', encoded(old))
        session = {'schema': 1, 'store': str(self.store.resolve()), 'state': 'pending_apply',
                   'display': inv['display_uuid'], 'spaces': rows, 'patches': patches,
                   'backup': str(archive / 'original.plist'), 'backup_sha256': digest(raw)}
        self.save(session)  # Durable recovery exists BEFORE the first system write.
        commit_store(self.store, raw, merge(document, patches))
        self.refresh()
        session['state'] = 'applied'
        self.save(session)
        print('已写入选定桌面的底图并请求刷新；恢复记录：' + str(self.session), flush=True)

    def restore(self):
        session = self.read_session()
        if not session:
            print('没有待恢复记录；未改动系统。')
            return
        if session['state'] == 'restored':
            print('此记录已复原；未重复改动系统。')
            return
        backup = Path(session['backup']).read_bytes()
        if digest(backup) != session['backup_sha256']:
            raise ValueError('原始备份校验失败，拒绝复原')
        raw, document = load_store(self.store)
        restored = merge(document, session['patches'], restore=True)
        session['state'] = 'pending_restore'
        self.save(session)
        commit_store(self.store, raw, restored)
        self.refresh()
        session['state'] = 'restored'
        self.save(session)
        print('原壁纸配置已复原并请求刷新（包括原航拍选择）；未改动屏保。', flush=True)


def lease(switcher, image, inv, rows, wait):
    """Caller holds the state lock for the whole lease, including rollback.

    EOF on the UI-owned pipe releases the lease even if the UI is killed.
    A failed apply is also rolled back if it created a recovery journal.
    """
    old = switcher.read_session()
    if old and old['state'] != 'restored':
        raise ValueError('已有待恢复任务，请先 restore')
    try:
        switcher.apply(image, inv, rows)
        print('BACKDROP_READY', flush=True)
        wait()
    finally:
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        current = switcher.read_session()
        if current and (not old or current['backup'] != old['backup']):
            switcher.restore()


def main():
    parser = argparse.ArgumentParser(description='选定 Space 的快速墙纸切换与复原；不需要手动切桌面')
    parser.add_argument('--state-dir', type=Path, default=STATE)
    parser.add_argument('--inventory', type=Path, default=STATE / 'space-inventory')
    subs = parser.add_subparsers(dest='command', required=True)
    for verb in ('apply', 'timed', 'lease'):
        p = subs.add_parser(verb)
        p.add_argument('image', type=Path)
        p.add_argument('--spaces', default='1,2', help='当前所选屏幕的桌面顺序，默认 1,2；可选 all')
        p.add_argument('--display', type=int, help='CGDirectDisplayID，默认主屏')
        if verb == 'timed':
            p.add_argument('--seconds', type=float, default=60)
    subs.add_parser('restore')
    subs.add_parser('status')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('仅支持 macOS')
    state = args.state_dir.expanduser().resolve()
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (state / 'lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('另一个切换任务正在执行，请等其结束')
        switcher = Switcher(state=state)
        if args.command == 'status':
            session = switcher.read_session()
            print(json.dumps({'session': session['state'] if session else 'none',
                              'recovery_file': str(switcher.session), 'current': inventory(binary=args.inventory)}, ensure_ascii=False, indent=2))
        elif args.command == 'restore':
            switcher.restore()
        else:
            if args.command == 'timed' and not 0 < args.seconds <= 86400:
                raise ValueError('自动复原时长必须在 0 到 86400 秒之间')
            if args.display is not None and args.display <= 0:
                raise ValueError('显示器 ID 必须为正整数')
            inv = inventory(args.display, args.inventory)
            rows = resolve_spaces(inv, args.spaces)
            print('目标显示器 %s，桌面 %s（按本次实时顺序；恢复使用 UUID）' %
                  (inv['display_id'], ','.join(str(r['number']) for r in rows)), flush=True)
            if args.command == 'apply':
                switcher.apply(args.image, inv, rows)
            elif args.command == 'lease':
                def interrupted_lease(_signal, _frame):
                    raise KeyboardInterrupt
                signal.signal(signal.SIGTERM, interrupted_lease)
                lease(switcher, args.image, inv, rows, lambda: sys.stdin.buffer.read())
            else:
                old = switcher.read_session()
                if old and old['state'] != 'restored':
                    raise ValueError('已有待恢复任务，请先 restore')
                def interrupted(_signal, _frame):
                    raise KeyboardInterrupt
                signal.signal(signal.SIGTERM, interrupted)
                owned_backup = None
                try:
                    switcher.apply(args.image, inv, rows)
                    owned_backup = switcher.read_session()['backup']
                    print('%.1f 秒后自动复原；Ctrl+C 或“恢复原壁纸”可提前复原。' % args.seconds, flush=True)
                    # Release only during the wait so an explicit restore works.
                    fcntl.flock(lock, fcntl.LOCK_UN)
                    try:
                        time.sleep(args.seconds)
                    finally:
                        signal.signal(signal.SIGINT, signal.SIG_IGN)
                        signal.signal(signal.SIGTERM, signal.SIG_IGN)
                        fcntl.flock(lock, fcntl.LOCK_EX)
                finally:
                    signal.signal(signal.SIGINT, signal.SIG_IGN)
                    signal.signal(signal.SIGTERM, signal.SIG_IGN)
                    fcntl.flock(lock, fcntl.LOCK_EX)
                    current = switcher.read_session()
                    # An apply failure may leave a new pending journal. Never
                    # restore a newer session created while this timer slept.
                    if owned_backup is None and current and (not old or current['backup'] != old['backup']):
                        owned_backup = current['backup']
                    if current and current['backup'] == owned_backup:
                        switcher.restore()


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('已中断定时等待。', file=sys.stderr)
        sys.exit(130)
    except Exception as error:
        print('错误：' + str(error), file=sys.stderr)
        print('如已有系统写入，恢复记录会保留；可再次运行 restore。', file=sys.stderr)
        sys.exit(2)
