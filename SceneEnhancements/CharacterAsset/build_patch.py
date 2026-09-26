#!/usr/bin/env python3
"""Build a separate CharacterAsset package, preserving all unrelated source bytes.

Requires the inspected original package. Never modifies the source directory;
output must be a new directory outside watched wallpaper libraries.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import struct

ORIGINAL_SHA256 = '574597953f56fc06627f95c79840856892d2c7eb973f0de1903f5291f890b4c0'
MATERIAL = 'materials/角色素材最终版！_cleaned.json'
SHADER = 'wallpaperui/character_hair'


def unpack(data):
    cursor = 0
    def integer():
        nonlocal cursor
        value, = struct.unpack_from('<I', data, cursor)
        cursor += 4
        return value
    def string():
        nonlocal cursor
        size = integer()
        assert size <= 4096 and cursor + size <= len(data), 'invalid package string'
        value = data[cursor:cursor + size].decode('utf-8')
        cursor += size
        return value
    version = string()
    assert version.startswith('PKGV'), 'not a PKGV package'
    count = integer()
    assert count < 100000, 'invalid file count'
    index = [(string(), integer(), integer()) for _ in range(count)]
    entries = {}
    for name, offset, size in index:
        path = PurePosixPath(name)
        assert not path.is_absolute() and '..' not in path.parts and '\\' not in name
        assert name not in entries and cursor + offset + size <= len(data)
        entries[name] = data[cursor + offset:cursor + offset + size]
    return version, entries


def pack(version, entries):
    def string(value):
        encoded = value.encode('utf-8')
        return struct.pack('<I', len(encoded)) + encoded
    header = bytearray(string(version) + struct.pack('<I', len(entries)))
    payload = bytearray()
    for name, data in entries.items():
        header += string(name) + struct.pack('<II', len(payload), len(data))
        payload += data
    return bytes(header + payload)


def encode(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8')


def build(source, output):
    data = (source / 'scene.pkg').read_bytes()
    assert hashlib.sha256(data).hexdigest() == ORIGINAL_SHA256, 'source differs from the inspected original; review before patching'
    assert not output.exists(), 'output must not exist'
    project = json.loads((source / 'project.json').read_text())
    assert str(project['workshopid']) == '1000000003' and project['type'].lower() == 'scene'
    version, original = unpack(data)
    entries = original.copy()
    material = json.loads(entries[MATERIAL])
    assert len(material['passes']) == 1 and material['passes'][0]['shader'] == 'genericimage4'
    material['passes'][0]['shader'] = SHADER
    entries[MATERIAL] = encode(material)
    for suffix in ['vert', 'frag']:
        entries[f'shaders/{SHADER}.{suffix}'] = Path(__file__).with_name(f'character_hair.{suffix}').read_bytes()
    properties = project['general']['properties']
    properties['character_hair_enabled'] = dict(type='bool', text='头发飘动', value=True, order=10)
    properties['character_hair_strength'] = dict(type='slider', text='飘动强度', value=65, min=0, max=100, step=1, order=11)
    properties['character_hair_speed'] = dict(type='slider', text='飘动速度', value=100, min=50, max=150, step=1, order=12)
    result = pack(version, entries)
    assert unpack(result) == (version, entries)
    assert all(entries[name] == value for name, value in original.items() if name != MATERIAL)
    output.mkdir(parents=True)
    (output / 'scene.pkg').write_bytes(result)
    (output / 'project.json').write_bytes(encode(project))
    shutil.copy2(source / 'preview.jpg', output / 'preview.jpg')
    manifest = dict(originalSHA256=ORIGINAL_SHA256, patchedSHA256=hashlib.sha256(result).hexdigest(),
                    preservedEntries=len(original)-1, changedEntries=[MATERIAL],
                    addedEntries=[name for name in entries if name not in original])
    (output / 'patch-manifest.json').write_bytes(encode(manifest))
    print(json.dumps(manifest, ensure_ascii=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    build(args.source.resolve(), args.output.resolve())
