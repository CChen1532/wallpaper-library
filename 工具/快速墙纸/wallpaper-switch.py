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
from urllib.parse import urlparse, unquote

ROOT = Path(__file__).resolve().parents[2]
STORE = Path.home() / 'Library/Application Support/com.apple.wallpaper/Store/Index.plist'
STATE = ROOT / 'dist/WallpaperQuickSwitch'
SUPPORTED_MACOS = ('15.8', '24H23')
# Schema observed on the supported macOS build. UUIDs, Space counts, image
# choices and timestamps are excluded; structural keys and node types are not.
SUPPORTED_SCHEMA = '8c5d6761ee52272e7952fbfdd0ff3d2782d90cd051d0e78f0bdc983a3db2d53d'
SUPPORTED_SHARED_SCHEMA = '433decfbfbc5c4c064f764512dd89a19089fd7c52fd9be406185ed2b074b64c6'


class CompatibilityMismatch(ValueError):
    """The bundled app must disable automatic backdrop on this OS/schema."""


def macos_release():
    try:
        return tuple(subprocess.check_output(['/usr/bin/sw_vers', flag], text=True, timeout=5).strip()
                     for flag in ('-productVersion', '-buildVersion'))
    except (OSError, subprocess.SubprocessError) as error:
        raise CompatibilityMismatch('无法确认 macOS 版本，已停止自动过渡底图') from error


def schema_fingerprint(document):
    """Fingerprint only the private nodes edited by an all-Spaces lease."""
    try:
        spaces, displays = document['Spaces'], document['Displays']
        shared, system = document['AllSpacesAndDisplays'], document['SystemDefault']
        if not all(isinstance(node, dict) for node in (document, spaces, displays, shared, system)):
            raise ValueError('root')

        def fields(node):
            if not isinstance(node, dict):
                raise ValueError('node')
            return tuple((key, ('str:' + value) if key == 'Type' and isinstance(value, str)
                          else type(value).__name__) for key, value in sorted(node.items()))

        signature = {
            'root': fields(document), 'shared': fields(shared), 'system': fields(system),
            'spaces': sorted({fields(node) for node in spaces.values()}),
            'defaults': sorted({fields(node['Default']) for node in spaces.values()}),
            'displays': sorted({fields(node) for node in displays.values()}),
            'space_displays': sorted({fields(display) for node in spaces.values()
                                      for display in node['Displays'].values()}),
        }
        return digest(json.dumps(signature, sort_keys=True, separators=(',', ':')).encode())
    except (KeyError, TypeError, ValueError, AttributeError) as error:
        raise CompatibilityMismatch('系统墙纸配置结构未知，已停止自动过渡底图') from error


def check_compatibility(state, document, release=None, expected_schema=None):
    release = release or macos_release()
    fingerprint = schema_fingerprint(document)
    accepted = {expected_schema} if expected_schema else {SUPPORTED_SCHEMA, SUPPORTED_SHARED_SCHEMA}
    if release != SUPPORTED_MACOS or fingerprint not in accepted:
        raise CompatibilityMismatch('此 macOS 版本或墙纸配置结构未经验证，已停止自动过渡底图')
    # Diagnostic evidence only. The bundled constants, not this writable file,
    # authorize future writes. Restoration never depends on this check.
    atomic(state / 'compatibility.plist', encoded({
        'schema': 1, 'macOS': release[0], 'build': release[1],
        'wallpaperSchemaSHA256': fingerprint,
        'checkedAt': datetime.datetime.utcnow(),
    }))
    return fingerprint


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


def selected(node, field='Desktop'):
    return {'present': field in node, 'value': copy.deepcopy(node.get(field, {}))}


def put(node, selection, field='Desktop'):
    if selection['present']:
        node[field] = copy.deepcopy(selection['value'])
    else:
        node.pop(field, None)


def image_desktop(image):
    now = datetime.datetime.utcnow()
    # Matches the image provider's Files/placement form observed locally.
    return {'LastSet': now, 'LastUse': now, 'Content': {
        'Choices': [{'Provider': 'com.apple.wallpaper.choice.image',
                     'Configuration': encoded({'placement': 1}),
                     'Files': [{'relative': image.as_uri()}]}], 'Shuffle': '$null'}}


def validate_all_spaces(document, display_uuid, space_uuids):
    """Validate recoverable scopes, including sparse historical display maps.

    A Space need not contain the active display: macOS keeps records from
    other monitors and can inherit its Default selection. The whole Spaces
    value is journalled, so preserve those missing entries on restoration.
    """
    shared = document.get('AllSpacesAndDisplays')
    # The native all-Spaces switch clears both maps. This is another known
    # baseline, not an incompatible OS upgrade. Preserve its shared selection.
    if (isinstance(shared, dict) and shared.get('Type') == 'individual' and
            isinstance(shared.get('Desktop'), dict) and
            document.get('Spaces') == {} and document.get('Displays') == {}):
        return
    if not isinstance(shared, dict) or shared.get('Type') != 'idle' or 'Desktop' in shared:
        raise CompatibilityMismatch('全空间墙纸配置不是已验证的 idle 形式，拒绝改动')
    spaces, displays = document.get('Spaces'), document.get('Displays')
    if not isinstance(spaces, dict) or not isinstance(displays, dict) or display_uuid not in displays:
        raise CompatibilityMismatch('当前显示器没有可恢复的墙纸记录')
    if not set(space_uuids).issubset(spaces):
        raise CompatibilityMismatch('目标 Space 已变化，拒绝改动')
    for space in spaces.values():
        if (not isinstance(space, dict) or not isinstance(space.get('Default'), dict) or
                not isinstance(space.get('Displays'), dict) or
                not set(space['Displays']).issubset(displays)):
            raise CompatibilityMismatch('全空间切换遇到未知 Space 显示器结构')
        if any(not isinstance(node, dict) for node in space['Displays'].values()):
            raise CompatibilityMismatch('全空间切换遇到未知显示器墙纸节点')


def prepare(document, display_uuid, space_uuids, image, all_spaces_visible=False):
    global_entry = document.get('AllSpacesAndDisplays', {})
    if not all_spaces_visible and isinstance(global_entry, dict) and 'Desktop' in global_entry:
        raise ValueError('当前启用了全空间壁纸，不能安全地只改选定桌面')
    after = {'present': True, 'value': image_desktop(image)}
    if all_spaces_visible:
        # The system's switch moves the selection to these shared scopes and
        # clears Spaces. Keeping per-Space records made Settings show "on" but
        # Mission Control still used the previous thumbnails on this Mac.
        validate_all_spaces(document, display_uuid, space_uuids)
        displays = document['Displays']
        system = entry(document, ['SystemDefault'])
        patches = [
            {'path': [], 'field': 'Spaces', 'before': selected(document, 'Spaces'),
             'after': {'present': True, 'value': {}}},
            {'path': ['SystemDefault'], 'before': selected(system), 'after': copy.deepcopy(after)},
        ]
        if not displays:
            patches.append({'path': [], 'field': 'Displays',
                            'before': selected(document, 'Displays'),
                            'after': selected(document, 'Displays')})
        # macOS can retain records for an inactive historical display even
        # when NSScreen reports one active screen. Preserve each known record.
        for uuid in sorted(displays):
            display = entry(document, ['Displays', uuid])
            patches.append({'path': ['Displays', uuid], 'before': selected(display),
                            'after': copy.deepcopy(after)})
        patches += [
            {'path': ['AllSpacesAndDisplays'], 'field': 'Type',
             'before': selected(global_entry, 'Type'), 'after': {'present': True, 'value': 'individual'}},
            {'path': ['AllSpacesAndDisplays'], 'before': selected(global_entry), 'after': copy.deepcopy(after)},
        ]
        return patches
    patches = []
    for space in space_uuids:
        path = ['Spaces', space, 'Displays', display_uuid]
        node = entry(document, path)
        if node.get('Type') != 'individual':
            raise ValueError('此桌面未使用独立壁纸/屏保配置，拒绝自动拆分')
        patches.append({'path': path, 'before': selected(node), 'after': copy.deepcopy(after)})
    if not patches:
        raise ValueError('没有目标桌面')
    return patches


def same_image(current, expected):
    if not current['present'] or not expected['present']:
        return False
    try:
        a = current['value']['Content']['Choices']
        b = expected['value']['Content']['Choices']
        return (len(a) == len(b) == 1 and
                a[0]['Provider'] == b[0]['Provider'] == 'com.apple.wallpaper.choice.image' and
                a[0]['Files'] == b[0]['Files'])
    except (KeyError, TypeError, IndexError):
        return False


def registered_spaces(current, original, scene):
    """Recover surviving Spaces after setDesktopImageURL normalizes the store.

    macOS can prune an old Space or inactive display while registering the
    scene. Restore only selectors on surviving, known nodes; never recreate a
    deleted Space or display, and never erase a newly created one.
    """
    if not current['present'] or not original['present']:
        return None
    now, before = current['value'], original['value']
    if not isinstance(now, dict) or not isinstance(before, dict) or not set(now).issubset(before):
        return None
    normalized = copy.deepcopy(now)
    target = {uuid: copy.deepcopy(before[uuid]) for uuid in now}
    for uuid, space in now.items():
        try:
            old_displays = before[uuid]['Displays']
            new_displays = space['Displays']
            if (not isinstance(old_displays, dict) or not isinstance(new_displays, dict) or
                    not set(new_displays).issubset(old_displays)):
                return None
            target[uuid]['Displays'] = {key: copy.deepcopy(old_displays[key]) for key in new_displays}
            paths = [['Default']] + [['Displays', display] for display in new_displays]
            for path in paths:
                old_node = entry(target[uuid], path)
                new_node = entry(normalized[uuid], path)
                value, previous = selected(new_node), selected(old_node)
                if semantic(value) != semantic(previous):
                    if not same_image(value, scene):
                        return None
                    put(new_node, previous)
        except (KeyError, TypeError, ValueError):
            return None
    if semantic(normalized) != semantic(target):
        return None
    return {'present': True, 'value': target}


def removed_display_from_all_spaces(document, original, patches):
    """Recreate known display nodes that Settings deletes in all-Space mode.

    This is only safe while the one-display global scene still matches our
    journal. The original node comes from the checksummed pre-apply backup.
    """
    display_patches = {p['path'][1]: p for p in patches
                       if len(p['path']) == 2 and p['path'][0] == 'Displays'}
    if not display_patches or original is None:
        return document
    displays = document.get('Displays')
    if not isinstance(displays, dict):
        raise ValueError('全空间显示器记录格式变化，保留恢复记录')
    if not set(displays).issubset(display_patches):
        raise ValueError('出现未备份的显示器记录，保留恢复记录')
    missing = set(display_patches) - set(displays)
    if not missing:
        return document
    scene = next((p['after'] for p in patches if p['path'] == ['AllSpacesAndDisplays']
                  and p.get('field', 'Desktop') == 'Desktop'), None)
    global_node = document.get('AllSpacesAndDisplays', {})
    before_displays = original.get('Displays', {})
    if (document.get('Spaces') != {} or scene is None or
            not isinstance(global_node, dict) or global_node.get('Type') != 'individual' or
            not same_image(selected(global_node), scene) or
            not isinstance(before_displays, dict) or set(before_displays) != set(display_patches) or
            not set(displays).issubset(before_displays) or
            any(selected(before_displays[uuid]) != display_patches[uuid]['before'] for uuid in missing)):
        raise ValueError('全空间开关之外的显示器记录变化，保留恢复记录')
    result = copy.deepcopy(document)
    for uuid in missing:
        result['Displays'][uuid] = copy.deepcopy(before_displays[uuid])
    return result


def normalize_shared_registration(document, original, patches, known_spaces, display):
    """Undo only native materialization of an originally shared selection.

    Registration can create per-Space nodes before the all-Spaces switch is
    pressed. Accept only inventoried scopes containing our exact image and
    unchanged screen-saver selectors; foreign edits remain recovery conflicts.
    """
    if not original or original.get('Spaces') != {} or original.get('Displays') != {}:
        return document
    shared = original.get('AllSpacesAndDisplays', {})
    current = document.get('AllSpacesAndDisplays', {})
    if shared.get('Type') != 'individual' or current.get('Type') != 'idle':
        return document
    idle = copy.deepcopy(shared)
    idle.pop('Desktop', None)
    idle['Type'] = 'idle'
    if semantic(current) != semantic(idle):
        return document
    scene = next((p['after'] for p in patches if p['path'] == ['AllSpacesAndDisplays']
                  and p.get('field', 'Desktop') == 'Desktop'), None)
    spaces, displays = document.get('Spaces'), document.get('Displays')
    if (scene is None or not isinstance(spaces, dict) or not spaces or
            not set(spaces).issubset(known_spaces) or not isinstance(displays, dict) or
            not set(displays).issubset({display})):
        return document
    idle_options = [selected(shared, 'Idle'), selected(original.get('SystemDefault', {}), 'Idle')]
    def owned(node):
        return (isinstance(node, dict) and set(node) == {'Type', 'Desktop', 'Idle'} and
                node['Type'] == 'individual' and same_image(selected(node), scene) and
                any(semantic(selected(node, 'Idle')) == semantic(value) for value in idle_options))
    for space in spaces.values():
        if (not isinstance(space, dict) or set(space) != {'Default', 'Displays'} or
                not owned(space['Default']) or not isinstance(space['Displays'], dict) or
                not set(space['Displays']).issubset({display}) or
                not all(owned(node) for node in space['Displays'].values())):
            return document
    if not all(owned(node) for node in displays.values()):
        return document
    result = copy.deepcopy(document)
    result['Spaces'] = {}
    result['Displays'] = {}
    result['AllSpacesAndDisplays'] = copy.deepcopy(shared)
    put(result['AllSpacesAndDisplays'], scene)
    return result


def merge(document, patches, restore=False, original=None, known_spaces=(), display=None):
    if restore:
        document = normalize_shared_registration(document, original, patches, known_spaces, display)
        document = removed_display_from_all_spaces(document, original, patches)
    result = copy.deepcopy(document)
    targets = []
    # Preflight EVERY field before changing any field.
    for patch in patches:
        field = patch.get('field', 'Desktop')
        current = selected(entry(document, patch['path']), field)
        expected = patch['after'] if restore else patch['before']
        target = patch['before'] if restore else patch['after']
        allowed = semantic(current) == semantic(expected)
        if restore and not allowed:
            allowed = semantic(current) == semantic(target) or (field == 'Desktop' and same_image(current, expected))
            if field == 'Spaces' and patch['path'] == []:
                scene = next((p['after'] for p in patches if
                              p['path'] == ['AllSpacesAndDisplays'] and p.get('field', 'Desktop') == 'Desktop'), None)
                recovered = registered_spaces(current, target, scene) if scene is not None else None
                if recovered is not None:
                    allowed = True
                    target = recovered
        if not allowed:
            raise ValueError('该桌面壁纸已被其他操作改变，拒绝覆盖；恢复记录保留：' + '/'.join(patch['path']))
        targets.append(target)
    for patch, target in zip(patches, targets):
        put(entry(result, patch['path']), target,
            patch.get('field', 'Desktop'))
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


def verify_restoration(store, expected, patches, clock=time.monotonic, sleep=time.sleep):
    """Observe the affected fields after the agent reload, not just our write."""
    started = clock()
    while True:
        _, current = load_store(store)
        for patch in patches:
            field = patch.get('field', 'Desktop')
            if semantic(selected(entry(current, patch['path']), field)) != semantic(
                    selected(entry(expected, patch['path']), field)):
                raise ValueError('系统在恢复后再次改变墙纸配置，恢复记录仍保留')
        if clock() - started >= 3:
            return
        sleep(.2)


class Switcher:
    def __init__(self, store=STORE, state=STATE, refresh=reload_agent, verify=verify_restoration):
        self.store, self.state, self.refresh = store, state, refresh
        self.session = state / 'session.plist'
        self.verify = verify

    def read_session(self):
        if not self.session.exists():
            return None
        value = plistlib.loads(self.session.read_bytes())
        if value.get('schema') != 1 or value.get('store') != str(self.store.resolve()):
            raise ValueError('恢复记录版本或配置路径不匹配')
        return value

    def save(self, session):
        atomic(self.session, encoded(session))
        # Keep each lease's own journal, independently of the next lease.
        backup = Path(session['backup'])
        if backup.parent.parent.resolve() == self.state.resolve() and backup.is_file():
            atomic(backup.parent / 'session.plist', encoded(session))

    def stale_shared_image(self, document):
        shared = document.get('AllSpacesAndDisplays', {})
        if not isinstance(shared, dict) or 'Desktop' not in shared:
            return None
        try:
            choices = shared['Desktop']['Content']['Choices']
            if len(choices) != 1 or choices[0]['Provider'] != 'com.apple.wallpaper.choice.image':
                return None
            files = choices[0]['Files']
            if len(files) != 1:
                return None
            url = urlparse(files[0]['relative'])
            image = Path(unquote(url.path))
            if url.scheme == 'file' and not url.netloc and image.parent.parent.resolve() == self.state.resolve():
                return image
        except (KeyError, TypeError, IndexError):
            pass
        return None

    def ancestor(self, image):
        candidates = {}
        paths = [self.session] + list(self.state.glob('*/session.plist')) + list(self.state.glob('*/previous-session.plist'))
        for path in paths:
            try:
                record = plistlib.loads(path.read_bytes())
                if record.get('image') != str(image):
                    continue
                if record.get('schema') != 1 or record.get('store') != str(self.store.resolve()):
                    continue
                backup = Path(record['backup'])
                if backup != image.parent / 'original.plist' or backup.is_symlink() or image.parent.is_symlink():
                    continue
                raw = backup.read_bytes()
                if digest(raw) != record['backup_sha256']:
                    continue
                original = plistlib.loads(raw)
                # Regenerate the allowed patch set: checksums alone do not
                # authorize arbitrary fields from an old journal.
                expected = prepare(original, record['display'], [r['uuid'] for r in record['spaces']],
                                   image, all_spaces_visible=True)
                if semantic(expected) != semantic(record['patches']):
                    continue
                key = digest(encoded({'backup': record['backup_sha256'], 'patches': semantic(expected)}))
                candidates[key] = record
            except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException):
                continue
        if len(candidates) != 1:
            raise ValueError('遗留临时底图的原始备份缺失或不唯一，未将它当作原壁纸；恢复记录保留')
        return next(iter(candidates.values()))

    def apply(self, image, inv, rows, all_spaces_visible=False):
        old = self.read_session()
        if old and old['state'] != 'restored':
            raise ValueError('已有待恢复壁纸；先执行 restore，避免覆盖原始备份')
        # Resolve inherited temporary pictures BEFORE accepting a new baseline.
        self.restore()
        old = self.read_session()
        image = image.expanduser().resolve(strict=True)
        if not image.is_file() or image.suffix.lower() not in ('.png', '.jpg', '.jpeg', '.heic', '.heif'):
            raise ValueError('请选择 PNG、JPEG 或 HEIC 普通图片文件')
        if all_spaces_visible and (inv.get('screen_count') != 1 or
                                   {row['uuid'] for row in rows} != {row['uuid'] for row in inv['spaces']}):
            raise ValueError('自动全空间底图需要单屏并覆盖全部普通桌面')
        raw, document = load_store(self.store)
        if all_spaces_visible:
            check_compatibility(self.state, document)
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
        archive = self.state / stamp
        archive.mkdir(mode=0o700)
        cached = archive / ('wallpaper' + image.suffix.lower())
        shutil.copyfile(image, cached)
        patches = prepare(document, inv['display_uuid'], [r['uuid'] for r in rows], cached,
                          all_spaces_visible=all_spaces_visible)
        atomic(archive / 'original.plist', raw)
        if old:
            atomic(archive / 'previous-session.plist', encoded(old))
        session = {'schema': 1, 'store': str(self.store.resolve()), 'state': 'pending_apply',
                   'display': inv['display_uuid'], 'spaces': rows, 'patches': patches,
                   'image': str(cached),
                   'backup': str(archive / 'original.plist'), 'backup_sha256': digest(raw)}
        self.save(session)  # Durable recovery exists BEFORE the first system write.
        commit_store(self.store, raw, merge(document, patches))
        self.refresh()
        session['state'] = 'applied'
        self.save(session)
        print('已写入选定桌面的底图并请求刷新；恢复记录：' + str(self.session), flush=True)

    def restore(self):
        session = self.read_session()
        if session and session['state'] != 'restored':
            self.restore_record(session)
        seen = set()
        for _ in range(16):
            _, document = load_store(self.store)
            image = self.stale_shared_image(document)
            if image is None:
                return
            if str(image) in seen:
                raise ValueError('临时底图恢复链存在循环，未接受它作为原壁纸')
            seen.add(str(image))
            ancestor = self.ancestor(image)
            # Preflight the merge before replacing the current recovery pointer.
            raw = Path(ancestor['backup']).read_bytes()
            merge(document, ancestor['patches'], restore=True, original=plistlib.loads(raw),
                  known_spaces={r['uuid'] for r in ancestor['spaces']}, display=ancestor['display'])
            current = self.read_session()
            if current:
                atomic(self.state / ('recovery-before-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f') + '.plist'), encoded(current))
            ancestor['state'] = 'pending_restore'
            self.save(ancestor)
            self.restore_record(ancestor)
        raise ValueError('临时底图恢复链过长，恢复记录保留')

    def restore_record(self, session):
        backup = Path(session['backup']).read_bytes()
        if digest(backup) != session['backup_sha256']:
            raise ValueError('原始备份校验失败，拒绝复原')
        raw, document = load_store(self.store)
        restored = merge(document, session['patches'], restore=True,
                         original=plistlib.loads(backup),
                         known_spaces={row['uuid'] for row in session['spaces']},
                         display=session['display'])
        session['state'] = 'pending_restore'
        self.save(session)
        commit_store(self.store, raw, restored)
        self.refresh()
        self.verify(self.store, restored, session['patches'])
        session['state'] = 'restored'
        self.save(session)
        print('原壁纸配置已复原并稳定确认（包括原航拍选择）；未改动屏保。', flush=True)


def lease(switcher, image, inv, rows, wait):
    """Caller holds the state lock for the whole lease, including rollback.

    EOF on the UI-owned pipe releases the lease even if the UI is killed.
    A failed apply is also rolled back if it created a recovery journal.
    """
    old = switcher.read_session()
    if old and old['state'] != 'restored':
        raise ValueError('已有待恢复任务，请先 restore')
    try:
        switcher.apply(image, inv, rows, all_spaces_visible=True)
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
    subs.add_parser('check-compatibility').add_argument('--display', type=int)
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
        elif args.command == 'check-compatibility':
            inv = inventory(args.display, args.inventory)
            _, document = load_store(switcher.store)
            check_compatibility(state, document)
            if inv.get('screen_count') != 1:
                raise CompatibilityMismatch('自动全空间底图需要单屏并覆盖全部普通桌面')
            validate_all_spaces(document, inv['display_uuid'], [row['uuid'] for row in inv['spaces']])
            print('WALLPAPER_COMPATIBILITY_OK', flush=True)
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
    except CompatibilityMismatch as error:
        print('WALLPAPER_COMPATIBILITY_FAILED：' + str(error), file=sys.stderr)
        sys.exit(3)
    except KeyboardInterrupt:
        print('已中断定时等待。', file=sys.stderr)
        sys.exit(130)
    except Exception as error:
        print('错误：' + str(error), file=sys.stderr)
        print('如已有系统写入，恢复记录会保留；可再次运行 restore。', file=sys.stderr)
        sys.exit(2)
