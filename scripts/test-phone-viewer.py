#!/usr/bin/env python3
"""Check real screenshot framing, resize, exit, and terminal restoration via a PTY.

Requires a booted terminal-phone simulator. This checks protocol output, not the
appearance of graphics in a real terminal emulator.
"""
import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import termios
import time

parser = argparse.ArgumentParser()
parser.add_argument("--phone", default="default")
parser.add_argument("--home", required=True)
args = parser.parse_args()
binary = Path(__file__).resolve().parent.parent / "dist/terminal-phone"
results = []

def graphics_frames(data, protocol):
    if protocol == "iterm":
        return [(header, base64.b64decode(payload)) for header, payload in
                re.findall(rb"\x1b\]1337;File=inline=1;([^:]+):([A-Za-z0-9+/=]+)\x07", data)]
    frames = []
    header = None
    payload = bytearray()
    for fields, chunk in re.findall(rb"\x1b_G([^;]+);([^\x1b]*)\x1b\\", data):
        if b"a=T,f=100" in fields:
            header = fields
            payload = bytearray()
        if header is not None and b"m=" in fields:
            payload.extend(chunk)
            if b"m=0" in fields:
                frames.append((header, base64.b64decode(payload)))
                header = None
    return frames

def image_size(image, protocol):
    if protocol == "kitty":
        assert image.startswith(b"\x89PNG\r\n\x1a\n")
        return struct.unpack(">II", image[16:24])
    assert image.startswith(b"\xff\xd8")
    position = 2
    while position + 8 < len(image):
        assert image[position] == 255, "invalid JPEG marker"
        marker = image[position + 1]
        position += 2
        if marker in (0xD8, 0xD9):
            continue
        length = struct.unpack(">H", image[position:position + 2])[0]
        if marker in (0xC0, 0xC1, 0xC2):
            height, width = struct.unpack(">HH", image[position + 3:position + 7])
            return width, height
        position += length
    raise AssertionError("JPEG dimensions not found")

for protocol, marker in [("kitty", b"\x1b_Ga=T,f=100"), ("iterm", b"\x1b]1337;File=inline=1;")]:
    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 0, 0))
    env = dict(os.environ, TERMINAL_PHONE_HOME=str(Path(args.home).resolve()))
    env.pop("TMUX", None)
    process = subprocess.Popen(
        [str(binary), "view", args.phone, "--read-only", "--protocol", protocol],
        stdin=slave, stdout=slave, stderr=subprocess.PIPE, env=env,
    )
    received = bytearray()
    resized = False
    resized_at = None
    sent_exit = False
    deadline = time.monotonic() + 30
    try:
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                chunk = os.read(master, 65536)
                received.extend(chunk)
                if b"\x1b[16t" in chunk:
                    os.write(master, b"\x1b[6;21;8t")
                # The viewer probes image support before selecting Kitty output.
                # This PTY stands in for the terminal, so answer its direct-image query.
                if b"\x1b_Gi=32" in chunk:
                    os.write(master, b"\x1b_Gi=32;OK\x1b\\")
                if b"\x1b[c" in chunk:
                    os.write(master, b"\x1b[?1;2;4c")
            # Wait for graphics, not a particular footer phrase: viewer chrome may change.
            if marker in received and not resized:
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 70, 0, 0))
                resized = True
                resized_at = time.monotonic()
                # Wait for the next complete frame at the new terminal size.
            if resized and received.count(marker) >= 2 and time.monotonic() - resized_at >= 0.4 and not sent_exit:
                os.write(master, b"\x1d")
                sent_exit = True
            if process.poll() is not None:
                break
        if process.poll() is None:
            process.kill()
            raise AssertionError("viewer failed to exit")
        error = process.stderr.read().decode(errors="replace")
        assert process.returncode == 0, error
        assert marker in received, "missing graphics protocol frame"
        assert resized and sent_exit, "resize/exit path was not reached"
        assert termios.tcgetattr(slave) == original, "terminal attributes were not restored"
        # The final cleanup may still be queued in the PTY after process exit.
        while select.select([master], [], [], 0.1)[0]:
            received.extend(os.read(master, 65536))
        frames = graphics_frames(received, protocol)
        assert len(frames) >= 2, "missing complete graphics frames after resize"
        header, image = frames[-1]
        # The renderer supplies a complete cell-sized canvas with the phone fitted
        # inside it. Verify its actual pixels, rather than a particular aspect flag.
        column_key, row_key = (b"c", b"r") if protocol == "kitty" else (b"width", b"height")
        columns = int(re.search(rb"(?:^|[;,])" + column_key + rb"=(\d+)", header)[1])
        rows = int(re.search(rb"(?:^|[;,])" + row_key + rb"=(\d+)", header)[1])
        assert image_size(image, protocol) == (columns * 8, rows * 21), "canvas pixels do not match terminal cell geometry"
        assert b"\x1b[?1049l" in received, "alternate screen was not restored"
        results.append({"protocol": protocol, "frames": received.count(marker), "resize": True, "exit": True, "terminalRestored": True})
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        process.stderr.close()
        os.close(master)
        os.close(slave)
print(json.dumps(results, indent=2))
