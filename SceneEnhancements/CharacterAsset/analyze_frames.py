#!/usr/bin/env python3
"""Check actual render captures. Requires Pillow; never modifies image files."""
import argparse
import json
from pathlib import Path
from PIL import Image, ImageChops, ImageStat

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', type=Path, required=True)
parser.add_argument('--controls', type=Path, required=True)
args = parser.parse_args()

def load(path):
    with Image.open(path) as image:
        return image.convert('RGB')

def difference(a, b):
    return sum(ImageStat.Stat(ImageChops.difference(a, b)).mean) / 3

original = load(args.baseline / 'original/frame0.png')
for mode in ('original', 'off', 'zero'):
    for i in (0, 1):
        assert difference(original, load(args.baseline / mode / f'frame{i}.png')) == 0, mode

frames = [load(args.baseline / 'on' / f'frame{i}.png') for i in range(6)]
changes = [difference(a, b) for a, b in zip(frames, frames[1:])]
assert all(value > .05 for value in changes), 'head hair animation is static'

p = args.controls / 'on'
zero = load(p / 'strength0.png')
values = {name: difference(zero, load(p / (name + '.png'))) for name in
          ('strength65', 'strength100', 'speed50', 'speed150', 'disabled', 'restored')}
assert values['disabled'] == 0
assert values['strength100'] > values['strength65'] > .1
speed_difference = difference(load(p / 'speed50.png'), load(p / 'speed150.png'))
assert speed_difference > .1
restored_difference = difference(load(p / 'restored.png'), load(p / 'strength65.png'))
# Time scale is near-zero, not a synchronized time lock; tiny elapsed-time
# and HEIC encoding differences are expected after the asynchronous command.
assert restored_difference < .01

# Coordinates for the 1920 x 1080 fixture. Captures are HEIC converted to PNG;
# block compression causes small deltas even outside the mathematical mask.
assert original.size == (1920, 1080)
regions = {'hat': (600,90,1050,160), 'eyes': (800,245,930,288),
           'face': (860,300,932,375), 'body': (850,495,1030,750),
           'leftHair': (675,477,730,673), 'rightHair': (1179,484,1258,585),
           'bottomHair': (1215,650,1260,837), 'background': (1450,350,1800,880)}
regional = {key: max(difference(original.crop(box), frame.crop(box)) for frame in frames)
            for key, box in regions.items()}
for key in ('leftHair', 'rightHair', 'bottomHair'):
    assert regional[key] > 1.5, (key, regional[key])
assert regional['hat'] == 0
for key in ('eyes', 'face', 'body'):
    assert regional[key] < 1.2, (key, regional[key])
for key in ('background',):
    assert regional[key] < .3, (key, regional[key])
# Integer patch matching distinguishes geometric movement from HEIC tile noise.
shifts = {}
for key, box in regions.items():
    reference = original.crop(box)
    shifts[key] = []
    for frame in frames:
        scores = [(difference(reference, frame.crop((box[0]+x, box[1]+y, box[2]+x, box[3]+y))), x, y)
                  for x in range(-5, 6) for y in range(-2, 3)]
        shifts[key].append(min(scores)[1:])
for key in ('hat', 'eyes', 'face', 'body', 'background'):
    assert all(shift == (0, 0) for shift in shifts[key]), (key, shifts[key])
for key in ('leftHair', 'rightHair', 'bottomHair'):
    assert len(set(shifts[key])) >= 3, (key, shifts[key])
result = dict(adjacentFrameMeanAbsoluteDifferences=changes, controls=values, shifts=shifts,
              speedDifference=speed_difference, restoredDifference=restored_difference,
              regionMaxMeanAbsoluteDifference=regional)
(args.controls / 'pixel-results.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
print('PASS original/off/zero equality, real motion, local regions, live controls and restore')
