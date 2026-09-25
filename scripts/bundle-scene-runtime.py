#!/usr/bin/env python3
"""Bundle the locally built, focus-follow Scene runtime without external dylib paths.

Reads local build products only. No downloading or upstream scripts are run.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def dependencies(binary):
    return [line.strip().split(' (compatibility version', 1)[0]
            for line in command('/usr/bin/otool', '-L', str(binary)).splitlines()[1:]]


def rpaths(binary):
    lines = command('/usr/bin/otool', '-l', str(binary)).splitlines()
    return [lines[index + 2].strip().split(' (offset ', 1)[0][5:]
            for index, line in enumerate(lines) if line.strip() == 'cmd LC_RPATH']


def is_system(path):
    return path.startswith('/System/Library/') or path.startswith('/usr/lib/')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    target = args.destination.absolute()
    if target.exists() or target.is_symlink():
        parser.error('destination already exists')
    source_resources = source / 'Contents/Resources'
    source_renderer = source_resources / 'Renderers/SceneWallpaper'
    resources = target / 'Contents/Resources'
    frameworks = target / 'Contents/Frameworks'
    renderer = resources / 'Renderers/SceneWallpaper'
    renderer.parent.mkdir(parents=True)
    frameworks.mkdir(parents=True)
    shutil.copy2(source_renderer, renderer)
    shutil.copytree(source_resources / 'assets', resources / 'assets', symlinks=False)
    copied = {}
    destinations = {}
    receipt = []

    def resolve(dependency, owner):
        if dependency.startswith('/'):
            candidate = Path(dependency)
        elif dependency.startswith('@loader_path/'):
            candidate = owner.parent / dependency[len('@loader_path/'):]
        elif dependency.startswith('@executable_path/'):
            candidate = source_renderer.parent / dependency[len('@executable_path/'):]
        elif dependency.startswith('@rpath/'):
            name = dependency[len('@rpath/'):]
            candidates = []
            for base in rpaths(owner) + rpaths(source_renderer):
                base = base.replace('@loader_path', str(owner.parent)).replace('@executable_path', str(source_renderer.parent))
                candidates.append(Path(base) / name)
            candidates.append(owner.parent / name)
            candidate = next((path for path in candidates if path.is_file()), None)
            if candidate is None:
                raise RuntimeError('unresolved dependency: ' + dependency)
        else:
            raise RuntimeError('unsupported dependency: ' + dependency)
        return candidate.resolve(strict=True)

    def visit(original, destination, is_library=False):
        original = original.resolve(strict=True)
        if original in copied:
            return copied[original]
        if destination in destinations and destinations[destination] != original:
            raise RuntimeError('dylib basename collision: ' + str(destination))
        copied[original] = destination
        destinations[destination] = original
        if destination != renderer:
            shutil.copy2(original, destination)
        destination.chmod(destination.stat().st_mode | 0o200)
        own_id = None
        if is_library:
            ids = command('/usr/bin/otool', '-D', str(original)).splitlines()
            own_id = ids[1] if len(ids) > 1 else None
        for dependency in dependencies(original):
            if dependency == own_id or is_system(dependency):
                continue
            resolved = resolve(dependency, original)
            child = visit(resolved, frameworks / Path(dependency).name, True)
            relative = '@loader_path/' + os.path.relpath(child, destination.parent)
            command('/usr/bin/install_name_tool', '-change', dependency, relative, str(destination))
        for path in rpaths(original):
            command('/usr/bin/install_name_tool', '-delete_rpath', path, str(destination))
        if is_library:
            command('/usr/bin/install_name_tool', '-id', '@rpath/' + destination.name, str(destination))
        command('/usr/bin/codesign', '--force', '--sign', '-', str(destination))
        receipt.append({'file': str(destination.relative_to(target)),
                        'source_sha256': hashlib.sha256(original.read_bytes()).hexdigest(),
                        'bundled_sha256': hashlib.sha256(destination.read_bytes()).hexdigest()})
        return destination

    # The loader is also dlopen'ed by name, so preserve this exact filename.
    visit(source / 'Contents/Frameworks/libvulkan.1.dylib', frameworks / 'libvulkan.1.dylib', True)
    molten = visit(source_resources / 'lib/libMoltenVK.dylib', frameworks / 'libMoltenVK.dylib', True)
    visit(source_renderer, renderer)
    icd = resources / 'Renderers/vulkan/icd.d/MoltenVK_icd.json'
    icd.parent.mkdir(parents=True)
    data = json.loads((source_resources / 'Renderers/vulkan/icd.d/MoltenVK_icd.json').read_text())
    data['ICD']['library_path'] = os.path.relpath(molten, icd.parent)
    icd.write_text(json.dumps(data, indent=2) + '\n')
    fonts = resources / 'fonts'
    fonts.mkdir()
    (fonts / 'fonts.conf').write_text('''<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir>/System/Library/Fonts</dir><dir>/Library/Fonts</dir><dir>~/Library/Fonts</dir>
  <cachedir>~/Library/Caches/WallpaperUI/fontconfig</cachedir>
</fontconfig>
''')
    project = Path(__file__).resolve().parent.parent
    licenses = resources / 'Licenses'
    licenses.mkdir()
    upstream = project / 'ThirdParty/MirageWallpaper'
    shutil.copy2(upstream / 'LICENSE', licenses / 'Mirage-GPL-3.0.txt')
    for original in copied:
        package_root = original.parent.parent
        for pattern in ('LICENSE*', 'COPYING*', 'OFL*'):
            for license_file in package_root.glob(pattern):
                if license_file.is_file():
                    name = original.name + '-' + license_file.name
                    shutil.copy2(license_file, licenses / name)
    (resources / 'runtime-manifest.json').write_text(json.dumps({
        'upstream_revision': 'd639939b925f08cfa0e5227ed9bea79529348fd6',
        'patch': 'patches/mirage-focus-follow.patch',
        'architecture': 'arm64', 'files': receipt,
    }, indent=2) + '\n')
    for binary in destinations:
        for dependency in dependencies(binary):
            if dependency.startswith('/') and not is_system(dependency):
                raise RuntimeError('external dependency remains: ' + dependency)
            if dependency.startswith('@loader_path/'):
                resolved = (binary.parent / dependency[len('@loader_path/'):]).resolve(strict=True)
                resolved.relative_to(target.resolve())
    print('Bundled Scene runtime:', len(destinations), 'native binaries; no external dylib paths')


if __name__ == '__main__':
    main()
