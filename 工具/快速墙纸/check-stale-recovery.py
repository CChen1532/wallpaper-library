#!/usr/bin/env python3
"""Temporary files only: prove inherited-frame recovery and durable status."""
import copy
import importlib.util
from pathlib import Path
import plistlib
import tempfile

spec = importlib.util.spec_from_file_location('switcher', Path(__file__).with_name('wallpaper-switch.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
node = {'Type': 'individual', 'Desktop': {'original': 'aerial'}, 'Idle': {}}
original = {'AllSpacesAndDisplays': {'Type': 'idle', 'Idle': {}},
            'SystemDefault': copy.deepcopy(node), 'Displays': {'display': copy.deepcopy(node)},
            'Spaces': {'a': {'Default': copy.deepcopy(node), 'Displays': {'display': copy.deepcopy(node)}}}}
inv = {'display_uuid': 'display', 'screen_count': 1, 'spaces': [{'uuid': 'a', 'number': 1}]}

with tempfile.TemporaryDirectory() as folder:
    root = Path(folder)
    store = root / 'Index.plist'
    state = root / 'state'
    state.mkdir()
    image = root / 'input.png'
    image.write_bytes(b'fixture')
    store.write_bytes(m.encoded(original))
    tool = m.Switcher(store, state, lambda: None, verify=lambda *_: None)
    tool.apply(image, inv, inv['spaces'], all_spaces_visible=True)
    activated = plistlib.loads(store.read_bytes())
    activated['Displays'] = {}  # Native all-Spaces switch clears the map.
    stale = m.encoded(activated)
    ancestor = tool.read_session()
    tool.restore()
    # Simulate the agent restoring a cached temporary selection AFTER the old
    # implementation had incorrectly marked the lease restored.
    store.write_bytes(stale)
    tool.restore()
    assert plistlib.loads(store.read_bytes()) == original
    print('PASS: a restored legacy journal still repairs a lingering owned image')

    store.write_bytes(stale)
    tool.apply(image, inv, inv['spaces'], all_spaces_visible=True)
    assert plistlib.loads(Path(tool.read_session()['backup']).read_bytes()) == original
    tool.restore()
    assert plistlib.loads(store.read_bytes()) == original
    print('PASS: new playback cannot adopt a lingering frame as its original')

    # A legacy newer session had already accepted the stale baseline.
    store.write_bytes(stale)
    inherited = plistlib.loads(stale)
    new_image = state / 'legacy-new' / 'wallpaper.png'
    new_image.parent.mkdir()
    new_image.write_bytes(b'new')
    backup = new_image.parent / 'original.plist'
    backup.write_bytes(stale)
    record = dict(ancestor, image=str(new_image), backup=str(backup), backup_sha256=m.digest(stale),
                  patches=m.prepare(inherited, 'display', ['a'], new_image, all_spaces_visible=True), state='applied')
    store.write_bytes(m.encoded(m.merge(inherited, record['patches'])))
    tool.save(record)
    tool.restore()
    assert plistlib.loads(store.read_bytes()) == original
    print('PASS: inherited temporary originals unwind to the real system selection')

    store.write_bytes(stale)
    foreign = plistlib.loads(stale)
    foreign['SystemDefault']['Desktop'] = {'user': 'changed'}
    store.write_bytes(m.encoded(foreign))
    try:
        tool.restore()
        raise AssertionError('foreign selector overwritten')
    except ValueError:
        assert plistlib.loads(store.read_bytes()) == foreign
    print('PASS: ancestry recovery refuses an external wallpaper change')

    store.write_bytes(stale)
    Path(ancestor['backup']).write_bytes(b'corrupt')
    try:
        tool.restore()
        raise AssertionError('corrupt ancestor accepted')
    except ValueError:
        assert store.read_bytes() == stale
    print('PASS: corrupt ancestor blocks recovery and new baseline capture')

    # A late agent rewrite must leave pending_restore, not a false success.
    store.write_bytes(m.encoded(original))
    tool.apply(image, inv, inv['spaces'], all_spaces_visible=True)
    active = store.read_bytes()
    def revert():
        store.write_bytes(active)
    unstable = m.Switcher(store, state, revert)
    try:
        unstable.restore()
        raise AssertionError('late agent rewrite accepted')
    except ValueError:
        assert unstable.read_session()['state'] == 'pending_restore'
    tool.restore()
    assert tool.read_session()['state'] == 'restored'
    print('PASS: post-reload reversion preserves a retryable recovery record')

    ticks = [0.0]
    m.verify_restoration(store, original, tool.read_session()['patches'],
                         clock=lambda: ticks[0], sleep=lambda dt: ticks.__setitem__(0, ticks[0] + dt))
    assert ticks[0] >= 3
    print('PASS: success requires three seconds of matching post-reload observations')

print('7 stale-recovery checks passed; no system settings accessed')
