#!/usr/bin/env python3
"""Capture Solar System planets and moons in one hidden renderer session.

Requires Pillow and WindowServer access. Only a cloned package and isolated
script storage are modified. Inspect the labeled captures for visual quality;
focus delivery and a successful snapshot alone do not prove correct lighting.
"""
import argparse
import hashlib
import json
import mmap
import os
from pathlib import Path
import queue
import struct
import subprocess
import threading
import time

from PIL import Image, ImageDraw, ImageStat

TARGETS = ('s,p1,p2,p3,p4,dp1,p5,p6,p7,p8,dp2,dp3,dp4,dp5,'
           '3.1,4.1,4.2,6.1,6.2,6.3,6.4,7.1,7.2,7.3,7.4,7.5,7.6,7.8,'
           '8.1,8.2,8.3,8.4,8.5,9.1,9.8,10.1').split(',')
PARENTS = {3: 'p3', 4: 'p4', 6: 'p5', 7: 'p6', 8: 'p7', 9: 'p8', 10: 'dp2'}


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def make_fixture(source, folder):
    """Leave all resources intact; add a focus-control hook to a private clone."""
    folder.mkdir()
    package = folder / 'scene.pkg'
    subprocess.run(['cp', '-c', str(source), str(package)], check=True)
    with package.open('r+b') as file:
        with mmap.mmap(file.fileno(), 0) as data:
            cursor = 12
            count, = struct.unpack_from('<I', data, cursor)
            cursor += 4
            entry = None
            for _ in range(count):
                length, = struct.unpack_from('<I', data, cursor)
                cursor += 4
                name = data[cursor:cursor + length]
                cursor += length
                offset, size = struct.unpack_from('<II', data, cursor)
                cursor += 8
                if name == b'scene.json':
                    entry = (offset, size)
            if entry is None:
                raise RuntimeError('scene.json is missing')
            start, size = cursor + entry[0], entry[1]
            scene = json.loads(data[start:start + size])
            main = next(obj for obj in scene['objects'] if obj.get('name') == 'Main')
            props = main['visible']['scriptproperties']
            props.update(initialFocus=4, introAnimEnd=1, transitionDuration=0.25)
            script = main['visible']['script']
            anchor = 'currentMode = Math.round(scriptProperties.mode);'
            status = ("shared.currentFocus = isTransitioning ? currentFocus + '->' + "
                      'targetFocus : currentFocus;')
            if anchor not in script or status not in script:
                raise RuntimeError('Solar System script layout changed; hook was not applied')
            hook = '''
var probeRequest = engine.userProperties.solarProbeFocus;
if (probeRequest && probeRequest !== globalThis.lastSolarProbeFocus) {
    if (probeRequest !== currentFocus) shared.viewSwitchRequest = probeRequest;
    globalThis.lastSolarProbeFocus = probeRequest;
}
'''
            script = script.replace(anchor, anchor + hook, 1)
            script = script.replace(status, status + '''
localStorage.set('solarProbeFocus', currentFocus);
localStorage.set('solarProbeTransition', isTransitioning);
''', 1)
            main['visible']['script'] = script
            body = json.dumps(scene, ensure_ascii=False, separators=(',', ':')).encode()
            if len(body) > size:
                raise RuntimeError('diagnostic script exceeds the existing package entry')
            data[start:start + size] = body + b' ' * (size - len(body))
            data.flush()
    return package


class Renderer:
    def __init__(self, runtime, binary, assets, package, output, display_id):
        self.output = output
        self.lines = []
        self.events = queue.Queue()
        self.activated = False
        env = os.environ.copy()
        icd = str(runtime / 'Resources/Renderers/vulkan/icd.d/MoltenVK_icd.json')
        env.update(RSTD_LOG='info', VK_ICD_FILENAMES=icd, VK_DRIVER_FILES=icd,
                   DYLD_FALLBACK_LIBRARY_PATH=str(runtime / 'Frameworks'),
                   FONTCONFIG_FILE=str(runtime / 'Resources/fonts/fonts.conf'))
        arguments = [str(binary), '--display-id', str(display_id), '--fps', '12',
                     '--muted', '--no-spectrum', '--no-mouse', '--deferred-show',
                     '--control-stdin', '--run-seconds', '240', '--resolution', '640x400',
                     '--cache-path', str(output / 'cache'),
                     '--script-storage-dir', str(output / 'storage'),
                     str(assets), str(package)]
        (output / 'arguments.json').write_text(json.dumps(arguments, indent=2))
        self.process = subprocess.Popen(arguments, env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                        text=True, bufsize=1)
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.process.stdout:
            self.lines.append(line)
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if isinstance(event, dict):
                self.activated |= event.get('event') == 'activated'
                self.events.put(event)

    def send(self, command):
        self.process.stdin.write(json.dumps(command) + '\n')
        self.process.stdin.flush()

    def wait(self, name, token=None, timeout=40):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                event = self.events.get(timeout=0.2)
            except queue.Empty:
                if self.process.poll() is not None:
                    raise RuntimeError('renderer exited: ' + str(self.process.returncode))
                continue
            if event.get('event') == name and (token is None or event.get('token') == token):
                return event
        raise RuntimeError('timeout: ' + name)

    def focus(self, target):
        self.send(dict(cmd='setProperty', key='solarProbeFocus', value=target))
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline:
            time.sleep(0.4)
            token = 'focus-' + target
            self.send(dict(cmd='exportScriptStorage', token=token))
            state = self.wait('script-storage', token, 8)['values']
            current = json.loads(state.get('solarProbeFocus', 'null'))
            moving = json.loads(state.get('solarProbeTransition', 'true'))
            if current == target and not moving:
                return
        raise RuntimeError('focus did not settle: ' + target + ' ' + str(state))

    def snapshot(self, target):
        self.send(dict(cmd='power', state='pause', fps=12))
        time.sleep(0.2)
        file = self.output / (target.replace('.', '-') + '.heic')
        self.send(dict(cmd='snapshot', path=str(file), token=target))
        if not self.wait('snapshot-done', target, 10).get('ok'):
            raise RuntimeError('snapshot failed: ' + target)
        png = file.with_suffix('.png')
        subprocess.run(['sips', '-s', 'format', 'png', str(file), '--out', str(png)],
                       check=True, stdout=subprocess.DEVNULL)
        self.send(dict(cmd='power', state='run', fps=12))
        return png

    def close(self):
        try:
            self.send(dict(cmd='quit'))
        except (BrokenPipeError, OSError):
            pass
        try:
            self.process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=4)
        (self.output / 'renderer.log').write_text(''.join(self.lines))


def contact_sheet(results, output):
    columns = 4
    canvas = Image.new('RGB', (320 * columns, 270 * ((len(results) + 3) // 4)), (20, 20, 20))
    draw = ImageDraw.Draw(canvas)
    for index, result in enumerate(results):
        frame = Image.open(result['frame']).convert('RGB')
        frame.thumbnail((320, 250))
        x, y = index % columns * 320, index // columns * 270
        canvas.paste(frame, (x, y))
        draw.text((x + 10, y + 252), result['target'], fill='white')
    canvas.save(output / 'comparison.jpg')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--scene', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--display-id', type=int, required=True)
    parser.add_argument('--targets', default=','.join(TARGETS))
    parser.add_argument('--assets', type=Path)
    parser.add_argument('--renderer', type=Path, help='Explicit source binary override; its hash is recorded')
    args = parser.parse_args()
    targets = args.targets.split(',')
    if args.display_id <= 0 or any(target not in TARGETS for target in targets):
        parser.error('Use a positive display ID and declared Solar System targets')
    output = args.output.resolve()
    if output.exists():
        parser.error('Use a new output directory to preserve evidence')
    scene = args.scene.resolve(strict=True)
    runtime = args.runtime.resolve(strict=True) / 'Contents'
    binary = (args.renderer or runtime / 'Resources/Renderers/SceneWallpaper').resolve(strict=True)
    assets = (args.assets or runtime / 'Resources/assets').resolve(strict=True)
    output.mkdir(parents=True)
    report = dict(binary=str(binary), binary_sha256=sha256(binary), assets=str(assets),
                  shader_sha256=sha256(assets / 'shaders/generic4.frag'),
                  original_scene_sha256=sha256(scene), results=[])
    print('renderer', binary, 'sha256', report['binary_sha256'], flush=True)
    package = make_fixture(scene, output / 'fixture')
    renderer = Renderer(runtime, binary, assets, package, output, args.display_id)
    started = time.monotonic()
    try:
        renderer.wait('first-frame-presented')
        print('first frame', round(time.monotonic() - started, 2), 's', flush=True)
        time.sleep(2)
        current = 'p4'
        for target in targets:
            if '.' in target:
                group = target.split('.')[0]
                parent = PARENTS[int(group)]
                if current != parent and not current.startswith(group + '.'):
                    renderer.focus(parent)
            renderer.focus(target)
            current = target
            png = renderer.snapshot(target)
            frame = Image.open(png).convert('RGB')
            crop = frame.crop((120, 80, 490, 350))
            pixels = list(crop.getdata())
            white = sum(min(rgb) > 235 for rgb in pixels) / len(pixels)
            report['results'].append(dict(target=target, frame=str(png), snapshot_size=list(frame.size),
                                          white_fraction=round(white, 4), mean=ImageStat.Stat(crop).mean))
            print(target, 'white_fraction', round(white, 4), flush=True)
    finally:
        renderer.close()
        report.update(exit_code=renderer.process.returncode, activated=renderer.activated,
                      duration_seconds=round(time.monotonic() - started, 2),
                      original_scene_unchanged=sha256(scene) == report['original_scene_sha256'])
        (output / 'report.json').write_text(json.dumps(report, indent=2))
        if report['results']:
            contact_sheet(report['results'], output)
        print('saved', output, flush=True)
        if not report['original_scene_unchanged'] or report['activated'] or report['exit_code'] != 0:
            raise RuntimeError('renderer cleanup or isolation check failed')


if __name__ == '__main__':
    main()
