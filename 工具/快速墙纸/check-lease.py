#!/usr/bin/env python3
"""Offline lease/crash checks. All wallpaper writes use temporary fixtures."""
import importlib.util
import copy
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time

source = Path(__file__).with_name('wallpaper-switch.py').resolve()
spec = importlib.util.spec_from_file_location('switcher', source)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def wait_for(predicate):
    deadline = time.monotonic() + 6
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError('fixture timed out')
        time.sleep(.025)


with tempfile.TemporaryDirectory() as folder:
    root = Path(folder)
    store = root / 'Index.plist'
    original = {'AllSpacesAndDisplays': {'Type': 'idle', 'Idle': {'untouched': True}},
                'SystemDefault': {'Type': 'individual', 'Idle': {}, 'Desktop': {'original': 'aerial'}},
                'Displays': {'display': {'Type': 'individual', 'Idle': {}, 'Desktop': {'original': 'aerial'}}},
                'Spaces': {'a': {'Default': {'Type': 'individual', 'Idle': {}, 'Desktop': {'original': 'aerial'}},
                                  'Displays': {'display': {
        'Type': 'individual', 'Desktop': {'original': 'aerial'}, 'Idle': {'unchanged': True}}}}}}
    image = root / 'image.png'; image.write_bytes(b'fixture')
    state = root / 'state'; state.mkdir()
    runner = root / 'lease.py'
    runner.write_text('''import importlib.util, pathlib, sys, signal, fcntl
spec = importlib.util.spec_from_file_location('switcher', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
root = pathlib.Path(sys.argv[2])
def refresh():
    if (root/'fail-once').exists():
        (root/'fail-once').unlink()
        raise RuntimeError('fixture refresh failure')
def interrupted(*_): raise KeyboardInterrupt
signal.signal(signal.SIGTERM, interrupted)
tool = m.Switcher(root/'Index.plist', root/'state', refresh)
inv = {'display_uuid':'display', 'screen_count':1, 'spaces':[{'uuid':'a','number':1}]}
with (root/'state/lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    m.lease(tool, root/'image.png', inv, inv['spaces'], lambda: sys.stdin.buffer.read())
''')
    command = [sys.executable, str(runner), str(source), str(root)]
    journal = state / 'session.plist'

    def applied():
        return journal.exists() and plistlib.loads(journal.read_bytes())['state'] == 'applied'

    def restored():
        return journal.exists() and plistlib.loads(journal.read_bytes())['state'] == 'restored'

    store.write_bytes(m.encoded(original))
    with (root / 'log').open('wb') as output:
        child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=output, stderr=output)
        try:
            wait_for(applied)
            # The live macOS switch removes the display node after the lease
            # begins. EOF must still restore the full original configuration.
            switched = plistlib.loads(store.read_bytes())
            switched['Displays'] = {}
            store.write_bytes(m.encoded(switched))
            child.stdin.close()
            assert child.wait(timeout=6) == 0
            assert restored() and plistlib.loads(store.read_bytes()) == original
        finally:
            if child.poll() is None: child.kill(); child.wait()
    print('PASS: pipe EOF restores after Settings removes the display node')

    # The fake UI owns the only stdin writer. Killing just this fixture process
    # exercises real parent death; the helper must restore without a UI callback.
    proxy = root / 'ui.py'
    proxy.write_text('''import pathlib, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
with (root/'crash.log').open('wb') as output:
    child = subprocess.Popen(sys.argv[2:], stdin=subprocess.PIPE, stdout=output, stderr=output)
    (root/'helper.pid').write_text(str(child.pid))
    while True: time.sleep(1)
''')
    ui = subprocess.Popen([sys.executable, str(proxy), str(root)] + command)
    helper_pid = None
    try:
        wait_for(applied)
        helper_pid = int((root/'helper.pid').read_text())
        ui.kill(); ui.wait(timeout=3)
        wait_for(restored)
        assert plistlib.loads(store.read_bytes()) == original
    finally:
        if ui.poll() is None: ui.kill(); ui.wait()
        if helper_pid and not restored():
            try: os.kill(helper_pid, signal.SIGTERM)
            except ProcessLookupError: pass
    print('PASS: killed UI fixture triggers independent helper restoration')

    (root/'fail-once').touch()
    failed = subprocess.run(command, input=b'', capture_output=True, timeout=6)
    assert failed.returncode != 0 and restored()
    assert plistlib.loads(store.read_bytes()) == original
    print('PASS: failed apply rolls back its pending journal')

    before = store.read_bytes()
    try:
        m.check_compatibility(state, original, release=('99.0', 'unknown'))
        raise AssertionError('unknown macOS accepted')
    except m.CompatibilityMismatch:
        assert store.read_bytes() == before and restored()
    changed = copy.deepcopy(original)
    changed['UnexpectedPrivateField'] = {}
    try:
        m.check_compatibility(state, changed, release=m.SUPPORTED_MACOS)
        raise AssertionError('unknown wallpaper schema accepted')
    except m.CompatibilityMismatch:
        assert store.read_bytes() == before and restored()
    print('PASS: unknown OS and private schema refuse automatic writes')

    tool = m.Switcher(store=store, state=state, refresh=lambda: None)
    inv = {'display_uuid': 'display', 'screen_count': 1,
           'spaces': [{'uuid': 'a', 'number': 1}]}
    tool.apply(image, inv, inv['spaces'], all_spaces_visible=True)
    evidence = plistlib.loads((state / 'compatibility.plist').read_bytes())
    assert evidence['macOS'] == m.SUPPORTED_MACOS[0]
    assert evidence['wallpaperSchemaSHA256'] == m.SUPPORTED_SCHEMA
    m.SUPPORTED_SCHEMA = 'unknown-after-system-upgrade'
    tool.restore()
    assert restored() and plistlib.loads(store.read_bytes()) == original
    print('PASS: restoration remains available after compatibility changes')

print('6 offline lease checks passed; no system wallpaper settings accessed.')
