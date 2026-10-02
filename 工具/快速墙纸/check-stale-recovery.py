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

# WallpaperAgent may add a known display to a historical Space while a lease
# is active. Restoring the whole Spaces snapshot must keep that new selector;
# an external edit to a selector that existed before the lease remains a
# conflict. Both cases operate on in-memory plists only.
historical = copy.deepcopy(original)
historical['Displays']['inactive'] = copy.deepcopy(node)
historical['Spaces']['history'] = {
    'Default': copy.deepcopy(node),
    'Displays': {'display': copy.deepcopy(node)},
}
scene = Path('/tmp/offline-scene.png')
patches = m.prepare(historical, 'display', ['a'], scene, all_spaces_visible=True)
registered = m.merge(historical, patches)
registered['Spaces'] = copy.deepcopy(historical['Spaces'])
registered['Spaces']['history']['Displays']['inactive'] = copy.deepcopy(historical['Displays']['inactive'])
restored = m.merge(registered, patches, restore=True, original=historical,
                   known_spaces={'a'}, display='display')
assert restored['Spaces']['history']['Displays']['inactive'] == historical['Displays']['inactive']
assert restored['Spaces']['a'] == historical['Spaces']['a']
print('PASS: restore preserves a known display materialized in a historical Space')

external = copy.deepcopy(registered)
external['Spaces']['a']['Displays']['display']['Desktop'] = {'external': 'wallpaper'}
try:
    m.merge(external, patches, restore=True, original=historical,
            known_spaces={'a'}, display='display')
    raise AssertionError('external wallpaper change accepted')
except ValueError:
    assert external['Spaces']['a']['Displays']['display']['Desktop'] == {'external': 'wallpaper'}
print('PASS: restore still refuses an external edit to a pre-existing selector')

foreign_added = copy.deepcopy(registered)
foreign_added['Spaces']['history']['Displays']['inactive']['Desktop'] = {'external': 'wallpaper'}
try:
    m.merge(foreign_added, patches, restore=True, original=historical,
            known_spaces={'a'}, display='display')
    raise AssertionError('foreign wallpaper in a new display node accepted')
except ValueError:
    assert foreign_added['Spaces']['history']['Displays']['inactive']['Desktop'] == {'external': 'wallpaper'}
print('PASS: restore refuses a new display node with an external wallpaper')

unknown_added = copy.deepcopy(registered)
unknown_added['Spaces']['history']['Displays']['unknown'] = copy.deepcopy(historical['Displays']['display'])
try:
    m.merge(unknown_added, patches, restore=True, original=historical,
            known_spaces={'a'}, display='display')
    raise AssertionError('unbacked display node accepted')
except ValueError:
    assert 'unknown' in unknown_added['Spaces']['history']['Displays']
print('PASS: restore refuses a display absent from the verified backup')

# When every affected selector is already back to its original choice, closing
# the pending journal must not write the live store or restart WallpaperAgent.
with tempfile.TemporaryDirectory() as folder:
    root = Path(folder)
    store = root / 'Index.plist'
    state = root / 'state'
    state.mkdir()
    backup = state / 'original.plist'
    backup.write_bytes(m.encoded(historical))
    already_restored = m.encoded(restored)
    still_active = m.encoded(m.merge(historical, patches))
    store.write_bytes(still_active)
    refreshes = []
    tool = m.Switcher(store, state, lambda: refreshes.append(True), verify=lambda *_: None)
    tool.save({'schema': 1, 'store': str(store.resolve()), 'state': 'pending_restore',
               'backup': str(backup), 'backup_sha256': m.digest(backup.read_bytes()),
               'patches': patches, 'spaces': inv['spaces'], 'display': 'display',
               'image': str(scene)})
    try:
        tool.restore(only_if_already_restored=True)
        raise AssertionError('journal-only restore wrote an active wallpaper')
    except ValueError:
        assert store.read_bytes() == still_active and not refreshes
        assert tool.read_session()['state'] == 'pending_restore'
    store.write_bytes(already_restored)
    tool.restore(only_if_already_restored=True)
    assert store.read_bytes() == already_restored and not refreshes
    assert tool.read_session()['state'] == 'restored'
print('PASS: journal-only restore refuses system writes, then closes already-restored selectors')
# A new Space can inherit the original system/display choices after a failed
# lease. Preserve it instead of treating its UUID alone as a wallpaper edit.
new_spaces = copy.deepcopy(restored)
new_spaces['Spaces']['new-default-only'] = {
    'Default': copy.deepcopy(historical['SystemDefault']), 'Displays': {}}
new_spaces['Spaces']['new-with-displays'] = {
    'Default': copy.deepcopy(historical['SystemDefault']),
    'Displays': copy.deepcopy(historical['Displays'])}
new_spaces['Spaces']['new-with-displays']['Default']['Desktop']['LastUse'] = 'later'
new_restored = m.merge(new_spaces, patches, restore=True, original=historical,
                       known_spaces={'a'}, display='display')
assert new_restored['Spaces'] == new_spaces['Spaces']
assert m.semantic(new_restored) == m.semantic(new_spaces)
print('PASS: newly registered Spaces and original inherited choices survive restoration')

def refuses_new_space(candidate, title):
    unchanged = m.encoded(candidate)
    try:
        m.merge(candidate, patches, restore=True, original=historical,
                known_spaces={'a'}, display='display')
        raise AssertionError(title + ' accepted')
    except ValueError:
        assert m.encoded(candidate) == unchanged
    print('PASS: ' + title)

foreign_default = copy.deepcopy(new_spaces)
foreign_default['Spaces']['new-default-only']['Default']['Desktop'] = {'user': 'new wallpaper'}
refuses_new_space(foreign_default, 'a new Space with a user-changed wallpaper is left untouched')
foreign_display = copy.deepcopy(new_spaces)
foreign_display['Spaces']['new-with-displays']['Displays']['display']['Desktop'] = {'user': 'new wallpaper'}
refuses_new_space(foreign_display, 'a new Space display with a user-changed wallpaper is left untouched')
foreign_idle = copy.deepcopy(new_spaces)
foreign_idle['Spaces']['new-default-only']['Default']['Idle'] = {'user': 'new screen saver'}
refuses_new_space(foreign_idle, 'a new Space with changed screen-saver settings remains a conflict')
unknown_display = copy.deepcopy(new_spaces)
unknown_display['Spaces']['new-with-displays']['Displays']['unknown'] = copy.deepcopy(node)
refuses_new_space(unknown_display, 'a new Space cannot adopt an unbacked display')
unknown_schema = copy.deepcopy(new_spaces)
unknown_schema['Spaces']['new-default-only']['foreign-field'] = True
refuses_new_space(unknown_schema, 'unknown new Space structure remains a conflict')
owned_new_image = copy.deepcopy(new_spaces)
owned_new_image['Spaces']['new-default-only']['Default']['Desktop'] = m.image_desktop(scene)
refuses_new_space(owned_new_image, 'a new Space still showing the temporary image cannot be falsely settled')

# The journal can close without any store write or WallpaperAgent restart.
with tempfile.TemporaryDirectory() as folder:
    state = Path(folder) / 'state'; state.mkdir()
    store = Path(folder) / 'Index.plist'; store.write_bytes(m.encoded(new_spaces))
    backup = state / 'original.plist'; backup.write_bytes(m.encoded(historical))
    original_store_bytes = store.read_bytes()
    refreshes = []
    tool = m.Switcher(store, state, lambda: refreshes.append(True), verify=lambda *_: None)
    tool.save({'schema': 1, 'store': str(store.resolve()), 'state': 'pending_restore',
               'backup': str(backup), 'backup_sha256': m.digest(backup.read_bytes()),
               'patches': patches, 'spaces': inv['spaces'], 'display': 'display',
               'image': str(scene)})
    tool.restore(only_if_already_restored=True)
    assert tool.read_session()['state'] == 'restored'
    assert store.read_bytes() == original_store_bytes and not refreshes
print('PASS: newly registered original Spaces allow journal-only settlement without system writes')
print('20 stale-recovery checks passed; no system settings accessed')
