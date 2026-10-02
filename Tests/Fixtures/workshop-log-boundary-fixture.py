#!/usr/bin/python3
"""Offline Steam protocol fixture for Unicode and long success-to-prompt logs."""
import json
import os
import pathlib
import sys
import time

args = sys.argv[1:]
stage = pathlib.Path(args[args.index("+force_install_dir") + 1])
account = args[args.index("+login") + 1]
item = args[args.index("+workshop_download_item") + 2] if "+workshop_download_item" in args else None
(stage / "child.pid").write_text(str(os.getpid()))
with (stage / "launches").open("a") as counter:
    counter.write(str(os.getpid()) + "\n")


def success(number):
    folder = stage / "steamapps" / "workshop" / "content" / "431960" / number
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "project.json").write_text(json.dumps({"type": "video", "file": "movie.mp4"}))
    (folder / "movie.mp4").write_bytes(b"offline-log-boundary-fixture")
    print("Success. Downloaded item " + number + ' to "' + str(folder) + '"', flush=True)


def prompt():
    # A command prompt may arrive across reads.
    print("Steam", end="", flush=True)
    time.sleep(0.03)
    print(">", end="", flush=True)


if item == "720":
    print("İ" * 32 + "Downloading item", flush=True)
    time.sleep(0.2)
    print("Update state downloading, progress: 37.5", flush=True)
    time.sleep(0.05)
    success(item)
elif item == "721":
    print("Steam>", flush=True)  # A stale prompt before the current success.
    success(item)
    time.sleep(0.1)
    print("x" * 10000, flush=True)
    time.sleep(0.1)
elif item == "722":
    print("Steam>", flush=True)
    success(item)
    # There is no prompt AFTER this item's success.
    while True:
        time.sleep(0.1)
elif item is None and account == "long_login_user":
    print("Steam>\nLogged in OK\nWaiting for user info...OK", flush=True)
    time.sleep(0.1)
    print("x" * 10000, flush=True)
    time.sleep(0.1)
else:
    raise AssertionError("unexpected fixture request")

prompt()
while "+quit" not in args:
    try:
        line = sys.stdin.readline()
    except OSError:
        break
    if not line:
        break
    command = line.strip().split()
    if command == ["quit"]:
        break
    assert command == ["workshop_download_item", "431960", "724"]
    success("724")
    prompt()
