#!/usr/bin/python3
"""Local protocol simulator: never connects to Steam, credentials are test strings."""
import json
import os
import pathlib
import sys
import time

args = sys.argv[1:]
stage = pathlib.Path(args[args.index('+force_install_dir') + 1])
item = args[args.index('+workshop_download_item') + 2]
(stage / 'child.pid').write_text(str(os.getpid()))
if item in ('108', '109'):
    marker = stage / 'updated'
    attempts = int(marker.read_text()) if marker.exists() else 0
    marker.write_text(str(attempts + 1))
    if item == '109' or attempts < 2:
        print('Update complete, launching...', flush=True)
        sys.exit(42)
assert 'fixture; $(never-run) "password"' not in args
if item == '106':
    print('Password:', end='', flush=True)
    sys.stdin.readline()
    print('FAILED (Invalid Password)', flush=True)
    sys.exit(5)
if item == '107':
    print('ERROR! Download item failed (No Connection).', flush=True)
    sys.exit(0)
if item in ('104', '105'):
    print('Downloading item', flush=True)
    while True:
        time.sleep(1)
print('Pass', end='', flush=True)
time.sleep(0.05)
print('word:', end='', flush=True)
assert sys.stdin.readline().rstrip('\n') == 'fixture; $(never-run) "password"'
if item == '102':
    print('Steam Guard code:', end='', flush=True)
    assert sys.stdin.readline().strip() == 'ABCDE'
if item == '103':
    print('Please confirm login in the Steam mobile app', flush=True)
    time.sleep(0.2)
print('Downloading item', flush=True)
print('Update state (0x61) downloading, progress: 37.5', flush=True)
out = stage / 'steamapps' / 'workshop' / 'content' / '431960' / item
out.mkdir(parents=True)
(out / 'project.json').write_text(json.dumps({'type': 'video', 'file': 'movie.mp4'}))
(out / 'movie.mp4').write_bytes(b'fixture-media-not-for-playback')
print('Success. Downloaded item ' + item + ' to "' + str(out) + '"', flush=True)
# Interactive mode: one authenticated process serves subsequent commands.
if '+quit' not in args:
    while True:
        print('Steam', end='', flush=True)
        time.sleep(0.02)
        print('>', end='', flush=True)
        command = sys.stdin.readline().strip().split()
        if not command or command == ['quit']:
            break
        assert command[:2] == ['workshop_download_item', '431960']
        item = command[2]
        if item == '107':
            print('ERROR! Download item failed (No Connection).', flush=True)
            continue
        if item in ('104', '105'):
            print('Downloading item', flush=True)
            while True:
                time.sleep(1)
        if item == '111':
            # A prompt without the current success marker must never finish a download.
            continue
        out = stage / 'steamapps' / 'workshop' / 'content' / '431960' / item
        out.mkdir(parents=True, exist_ok=True)
        (out / 'project.json').write_text(json.dumps({'type': 'video', 'file': 'movie.mp4'}))
        (out / 'movie.mp4').write_bytes(b'fixture-media-not-for-playback')
        print('Success. Downloaded item ' + item + ' to "' + str(out) + '"', flush=True)
