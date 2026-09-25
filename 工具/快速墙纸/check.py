#!/usr/bin/env python3
"""Offline recovery checks; never reads or writes real wallpaper settings."""
import copy
import importlib.util
from pathlib import Path
import plistlib
import tempfile

spec = importlib.util.spec_from_file_location('switcher', Path(__file__).with_name('wallpaper-switch.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
original = {'Content': {'Choices': [{'Provider': 'com.apple.wallpaper.choice.aerials',
             'Configuration': m.encoded({'assetID': 'original-aerial'}), 'Files': []}], 'Shuffle': '$null'}}
node = {'Type': 'individual', 'Desktop': original, 'Idle': {'preserve': 'OtherWallpaper'}}
document = {'Spaces': {k: {'Displays': {'display': copy.deepcopy(node)}} for k in ('a','b','other')},
            'AllSpacesAndDisplays': {'Type': 'idle', 'Idle': {'preserve': True}},
            'unrelated': {'keep': 42}}
inv = {'display_uuid': 'display', 'display_id': 1,
       'spaces': [{'uuid': 'a', 'number': 1}, {'uuid': 'b', 'number': 2}]}
with tempfile.TemporaryDirectory() as folder:
    root = Path(folder)
    store = root / 'Index.plist'
    store.write_bytes(m.encoded(document))
    image = root / 'test.png'
    image.write_bytes(b'fixture-only')
    state = root / 'state'; state.mkdir()
    refreshed = []
    tool = m.Switcher(store, state, lambda: refreshed.append(True))
    tool.apply(image, inv, inv['spaces'])
    changed = plistlib.loads(store.read_bytes())
    assert changed['Spaces']['other'] == document['Spaces']['other']
    assert changed['AllSpacesAndDisplays'] == document['AllSpacesAndDisplays']
    assert changed['Spaces']['a']['Displays']['display']['Idle'] == node['Idle']
    assert plistlib.loads(Path(tool.read_session()['backup']).read_bytes()) == document
    try:
        tool.apply(image, inv, inv['spaces'])
        raise AssertionError('nested apply allowed')
    except ValueError:
        pass
    # Other settings changed during playback must survive restoration.
    changed['unrelated']['keep'] = 99
    store.write_bytes(m.encoded(changed))
    tool.restore()
    restored = plistlib.loads(store.read_bytes())
    expected = copy.deepcopy(document); expected['unrelated']['keep'] = 99
    assert restored == expected
    raw = store.read_bytes(); tool.restore(); assert store.read_bytes() == raw
    # User-selected third wallpaper is a conflict; never overwrite it.
    tool.apply(image, inv, inv['spaces'])
    edited = plistlib.loads(store.read_bytes())
    edited['Spaces']['a']['Displays']['display']['Desktop'] = {'Content': {'user': 'changed'}}
    store.write_bytes(m.encoded(edited))
    try:
        tool.restore()
        raise AssertionError('conflict overwritten')
    except ValueError:
        pass
    assert plistlib.loads(store.read_bytes()) == edited
    assert tool.read_session()['state'] == 'applied'
    # Observed concurrent Agent write must prevent the entire commit.
    try:
        m.commit_store(store, b'stale', document)
        raise AssertionError('stale write accepted')
    except ValueError:
        pass
    assert plistlib.loads(store.read_bytes()) == edited
    # If refresh fails after writing, original backup and pending state survive.
    state2 = root / 'state2'; state2.mkdir()
    store.write_bytes(m.encoded(document))
    def failed_refresh():
        raise RuntimeError('simulated reload failure')
    failed = m.Switcher(store, state2, failed_refresh)
    try:
        failed.apply(image, inv, inv['spaces'])
    except RuntimeError:
        pass
    assert failed.read_session()['state'] == 'pending_apply'
    failed.refresh = lambda: None
    failed.restore()
    assert plistlib.loads(store.read_bytes()) == document
print('Offline recovery checks passed: scoped writes, aerial restore, unrelated edits, idempotence, conflicts, concurrent writes, refresh failure.')
