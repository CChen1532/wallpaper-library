#!/usr/bin/env python3
"""Render original/off/on controls serially. Stop the desktop player first."""
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time
from build_patch import unpack, pack, encode

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--original', type=Path, required=True)
parser.add_argument('--candidate', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--only', choices=['original', 'off', 'zero', 'on', 'full'])
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
root = args.app / 'Contents/Resources/SceneRuntime/Contents'
env = os.environ.copy()
env.pop('SCENERENDERER_DIAGNOSTICS_DIR', None)
env['VK_ICD_FILENAMES'] = env['VK_DRIVER_FILES'] = str(root / 'Resources/Renderers/vulkan/icd.d/MoltenVK_icd.json')
env['DYLD_FALLBACK_LIBRARY_PATH'] = str(root / 'Frameworks')
env['FONTCONFIG_FILE'] = str(root / 'Resources/fonts/fonts.conf')
results = []
for label, source, properties, isolated in [
    ('original', args.original, {}, True),
    ('off', args.candidate, {'character_hair_enabled': False}, True),
    ('zero', args.candidate, {'character_hair_strength': 0}, True),
    ('on', args.candidate, {}, True),
    ('full', args.candidate, {}, False),
]:
    if args.only and label != args.only:
        continue
    folder = args.output / label
    folder.mkdir(exist_ok=True)
    version, entries = unpack(source.read_bytes())
    if isolated:
        scene = json.loads(entries['scene.json'])
        scene['objects'] = [o for o in scene['objects'] if o['id'] == 113]
        entries['scene.json'] = encode(scene)
    package = folder / 'scene.pkg'
    package.write_bytes(pack(version, entries))
    (folder / 'project.json').write_bytes(source.with_name('project.json').read_bytes())
    propfile = folder / 'properties.json'
    propfile.write_bytes(encode(properties))
    cmd = [str(root / 'Resources/Renderers/SceneWallpaper'), '--display-id', '3', '--fps', '30',
           '--resolution', '1920x1080', '--muted', '--no-spectrum', '--no-mouse', '--deferred-show',
           '--control-stdin', '--run-seconds', '40', '--user-properties', str(propfile),
           '--cache-path', str(args.output / 'cache'), str(root / 'Resources/assets'), str(package)]
    p = subprocess.Popen(cmd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True, bufsize=1)
    events, log = queue.Queue(), []
    def reader(proc=p, q=events, lines=log):
        for line in proc.stdout:
            lines.append(line)
            try:
                q.put(json.loads(line))
            except ValueError:
                pass
    threading.Thread(target=reader, daemon=True).start()
    def wait(name, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                v = events.get(timeout=.2)
            except queue.Empty:
                if p.poll() is not None:
                    raise RuntimeError('renderer exited: ' + str(p.returncode))
                continue
            if v.get('event') == 'renderer-error':
                raise RuntimeError(str(v))
            if v.get('event') == name:
                return v
        raise RuntimeError(name + ' timeout')
    try:
        first = wait('first-frame-presented')
        for i in range(6 if label in ('on', 'full') else 2):
            time.sleep(.9)
            dest = folder / f'frame{i}.png'
            p.stdin.write(json.dumps(dict(cmd='snapshot', path=str(dest), token=str(i))) + '\n')
            p.stdin.flush()
            assert wait('snapshot-done', 8).get('ok'), 'snapshot failed'
            subprocess.run(['/usr/bin/sips', '-s', 'format', 'png', str(dest), '--out', str(dest)],
                           stdout=subprocess.DEVNULL, check=True)
        if label == 'on':
            # Hold scene time after real animation, then compare live controls.
            def send(message):
                p.stdin.write(json.dumps(message) + '\n')
                p.stdin.flush()
            send(dict(cmd='speed', value=1e-8))
            for setting, values in [
                ('strength0', dict(character_hair_strength=0)),
                ('strength65', dict(character_hair_strength=65)),
                ('strength100', dict(character_hair_strength=100)),
                ('speed50', dict(character_hair_speed=50)),
                ('speed150', dict(character_hair_speed=150)),
                ('disabled', dict(character_hair_enabled=False)),
                ('restored', dict(character_hair_enabled=True, character_hair_strength=65, character_hair_speed=100)),
            ]:
                for key, value in values.items():
                    send(dict(cmd='setProperty', key=key, value=value))
                time.sleep(.2)
                dest = folder / (setting + '.png')
                send(dict(cmd='snapshot', path=str(dest), token=setting))
                assert wait('snapshot-done', 8).get('ok')
                subprocess.run(['/usr/bin/sips', '-s', 'format', 'png', str(dest), '--out', str(dest)],
                               stdout=subprocess.DEVNULL, check=True)
        results.append(dict(label=label, firstFrame=first))
        print(label, 'rendered', flush=True)
    finally:
        p.stdin.close()
        try:
            p.wait(timeout=6)
        except subprocess.TimeoutExpired:
            p.terminate()
            p.wait(timeout=3)
        (folder / 'renderer.log').write_text(''.join(log))
        assert p.returncode == 0, f'{label} renderer exit {p.returncode}'
(args.output / 'render-results.json').write_bytes(encode(results))
