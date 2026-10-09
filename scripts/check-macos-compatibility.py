#!/usr/bin/env python3
"""Offline upgrade checks. Never opens the real wallpaper store or private APIs."""
import importlib.util
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

sys.dont_write_bytecode = True
helper = Path(__file__).resolve().parent.parent / '工具/快速墙纸/wallpaper-switch.py'
spec = importlib.util.spec_from_file_location('upgrade_switcher', helper)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
count = 0


def check(condition, message):
    global count
    assert condition, message
    count += 1
    print('PASS:', message)


for release in [('15.8', '24H23'), ('15.8.1', '24H32')]:
    check(m.require_supported_release(release) == release,
          'previously verified OS builds retain their release gate')

with tempfile.TemporaryDirectory(prefix='WallpaperUpgrade-') as folder:
    state = Path(folder)
    journal = state / 'session.plist'
    journal.write_bytes(b'pending-upgrade-journal-fixture')
    original = journal.read_bytes()
    for release in [('27.0', 'fixture-build'), ('27.0.1', 'fixture-build'),
                    ('26.6', 'fixture-build'), ('28.0', 'fixture-build')]:
        with patch.object(m, 'schema_fingerprint', side_effect=AssertionError('old schema queried')):
            try:
                m.check_compatibility(state, {}, release=release,
                                      expected_schema=m.SUPPORTED_SCHEMA)
                raise AssertionError('unknown release accepted')
            except m.CompatibilityMismatch:
                check(journal.read_bytes() == original,
                      release[0] + ' cannot authorize writes by matching an older schema')

    for verb in ['check-compatibility', 'apply', 'lease', 'timed']:
        args = ['wallpaper-switch.py', '--state-dir', str(state), verb]
        if verb != 'check-compatibility':
            args.append(str(state / 'unused.png'))
        with patch.object(sys, 'argv', args), \
             patch.object(m, 'macos_release', return_value=('27.0', 'fixture-build')), \
             patch.object(m, 'inventory', side_effect=AssertionError('private API queried')), \
             patch.object(m, 'load_store', side_effect=AssertionError('wallpaper store opened')):
            try:
                m.main()
                raise AssertionError('unknown release reached the command body')
            except m.CompatibilityMismatch:
                check(journal.read_bytes() == original,
                      verb + ' rejects an unverified OS before reading private Space APIs or the store')

    for only_if_restored in [False, True]:
        args = ['wallpaper-switch.py', '--state-dir', str(state), 'restore']
        if only_if_restored:
            args.append('--only-if-already-restored')
        with patch.object(sys, 'argv', args), \
             patch.object(m, 'macos_release', side_effect=AssertionError('restore gated by OS')), \
             patch.object(m.Switcher, 'restore') as restore:
            m.main()
            restore.assert_called_once_with(only_if_already_restored=only_if_restored)
            check(True, 'upgrade does not gate existing recovery on the new OS allowlist')

    check(journal.read_bytes() == original and not (state / 'compatibility.plist').exists(),
          'rejected upgrade probes preserve the journal and create no compatibility approval')

print(count, 'macOS upgrade compatibility checks passed (fixture OS versions only)')
