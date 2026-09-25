#!/usr/bin/env python3
"""Read-only CLI checks: print input policy and exit before creating a renderer/window."""
import json
from pathlib import Path
import subprocess
import sys

renderer = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("dist/MirageFocusFollowSource/SceneRenderer/build/macos-arm64-clang-release/Tools/SceneWallpaper/SceneWallpaper")
checks = [
    ([], dict(mouse_move=True, mouse_enter=True, mouse_buttons=True, input_hz=60)),
    (["--no-mouse"], dict(mouse_move=False, mouse_enter=False, mouse_buttons=False, input_hz=60)),
    (["--no-mouse-buttons"], dict(mouse_move=True, mouse_enter=True, mouse_buttons=False, input_hz=60)),
    (["--no-mouse", "--no-mouse-buttons"], dict(mouse_move=False, mouse_enter=False, mouse_buttons=False, input_hz=60)),
    (["--input-hz", "30"], dict(mouse_move=True, mouse_enter=True, mouse_buttons=True, input_hz=30)),
    (["--input-hz", "120", "--no-mouse"], dict(mouse_move=False, mouse_enter=False, mouse_buttons=False, input_hz=120)),
    (["--input-hz", "0", "--no-mouse"], dict(mouse_move=False, mouse_enter=False, mouse_buttons=False, input_hz=60)),
    (["--input-hz", "999"], dict(mouse_move=True, mouse_enter=True, mouse_buttons=True, input_hz=240)),
]
for flags, expected in checks:
    result = subprocess.run([str(renderer.resolve()), "--print-input-config", *flags, "fixture-assets", "fixture-scene.pkg"], capture_output=True, text=True, timeout=10, check=True)
    actual = json.loads(result.stdout)
    assert actual == expected, (flags, actual, expected)
invalid = subprocess.run([str(renderer.resolve()), "--print-input-config", "--input-hz", "bad", "fixture-assets", "fixture-scene.pkg"], capture_output=True, timeout=10)
assert invalid.returncode != 0, "invalid rate accepted"
print(f"{len(checks) + 1} renderer input policy checks passed (no desktop window)")
