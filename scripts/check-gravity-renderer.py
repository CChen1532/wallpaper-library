#!/usr/bin/env python3
"""Exercise the owned native renderer protocol, without activating its window.
Run on a macOS GUI session with Metal access. Never changes system wallpaper.
"""
import json
import os
import pathlib
import select
import subprocess
import sys
import tempfile
import time

renderer = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="gravity-protocol-") as directory:
    for preset in ("ultra", "efficient"):
        process = subprocess.Popen([str(renderer), "--preset", preset, "--control-stdin", "--deferred-show"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        buffer = b""
        def wait_event(name, timeout=20):
            global buffer
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    event = json.loads(line)
                    if event["event"] == "error":
                        raise RuntimeError(event)
                    if event["event"] == name:
                        return event
                if process.poll() is not None:
                    raise RuntimeError(process.stderr.read().decode())
                if select.select([process.stdout], [], [], max(0, deadline-time.monotonic()))[0]:
                    buffer += os.read(process.stdout.fileno(), 65536)
            raise TimeoutError(name)
        def send(command):
            process.stdin.write(json.dumps(command).encode() + b"\n")
            process.stdin.flush()
        try:
            wait_event("scene-ready")
            wait_event("first-frame-presented")
            snapshots=[]
            for index in range(2):
                path=pathlib.Path(directory) / f"{preset}-{index}.png"
                send({"cmd":"snapshot", "token":str(index), "path":str(path)})
                assert wait_event("snapshot-done")["ok"]
                data=path.read_bytes()
                assert data.startswith(b"\x89PNG\r\n\x1a\n") and len(data)>10000
                snapshots.append(data)
                if index==0:
                    time.sleep(0.6)
            assert snapshots[0] != snapshots[1], "Scene must actually animate while deferred"
            # EOF must stop the child if the parent quits unexpectedly.
            process.stdin.close()
            assert process.wait(timeout=5)==0
            print(f"PASS {preset}: ready, animated hidden frames, PNG snapshots, parent EOF cleanup")
        finally:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=3)
                except subprocess.TimeoutExpired: process.kill();process.wait()
