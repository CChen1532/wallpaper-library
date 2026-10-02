#!/usr/bin/python3
"""Offline authentication failure fixture; no credentials or network are used."""
import os
import pathlib
import signal
import sys
import time

args = sys.argv[1:]
stage = pathlib.Path(args[args.index("+force_install_dir") + 1])
item = args[args.index("+workshop_download_item") + 2]
assert item in ("701", "702")
root = stage.parent.parent
(root / "child.pid").write_text(str(os.getpid()))


def terminating(_signal, _frame):
    # Keep the old authentication error suspended inside Session.deinit until
    # its bounded SIGKILL. The test cancels only after this exact marker exists.
    (root / ("auth-cleanup-" + item)).write_text("termination requested")


signal.signal(signal.SIGTERM, terminating)
print("Password:" if item == "701" else "FAILED (Invalid Password)", flush=True)
while True:
    time.sleep(0.02)
