#!/usr/bin/env python3
"""Live latency comparison and real PTY click/type/drag regression on the demo."""
import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import pty
import queue
import select
import statistics
import struct
import subprocess
import termios
import threading
import time

p = argparse.ArgumentParser()
p.add_argument('--phone', default='validation')
p.add_argument('--home', required=True)
a = p.parse_args()
root = Path(__file__).resolve().parent.parent
home = Path(a.home).resolve()
env = dict(os.environ, TERMINAL_PHONE_HOME=str(home))
binary = root / 'dist/terminal-phone'

def cli(*args):
    result = subprocess.run([str(binary), *map(str, args)], capture_output=True, text=True, env=env, timeout=90)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)

def elements():
    return cli('action', a.phone, 'describe')['elements']

def element(name):
    until = time.monotonic() + 10
    while True:
        found = next((e for e in elements() if e.get('AXUniqueId') == name), None)
        if found is not None:
            return found
        assert time.monotonic() < until, f'Element did not appear: {name}'
        time.sleep(.1)

phone = cli('status', a.phone)
udid = phone['udid']
assert phone['state'] == 'Booted'
cli('install', a.phone, root / 'dist/PhoneDemo.app')
subprocess.run(['xcrun', 'simctl', 'terminate', udid, 'dev.terminal-phone.demo'], capture_output=True)
cli('launch', a.phone, 'dev.terminal-phone.demo')
baseline = []
for _ in range(3):
    start = time.perf_counter()
    cli('action', a.phone, 'tap', '200', '262')
    baseline.append((time.perf_counter() - start) * 1000)

python = root / 'dist/dependencies/idb-venv/bin/python'
worker = subprocess.Popen([str(python), '-u', str(root / 'dist/resources/phone-viewer-worker.py'),
    '--socket', f'/tmp/terminal-phone-{os.getuid()}/{udid}.sock', '--udid', udid, '--scale', '3'],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
events = queue.Queue()
frame_times = []
def packets():
    try:
        def read(count):
            data = bytearray()
            while len(data) < count:
                chunk = worker.stdout.read(count - len(data))
                if not chunk:
                    raise EOFError()
                data.extend(chunk)
            return data
        while True:
            packet = read(struct.unpack('>I', read(4))[0])
            if packet[0] == 1:
                frame_times.append(time.perf_counter())
            else:
                events.put(json.loads(packet[1:]))
    except Exception as error:
        events.put({'event': 'reader-ended', 'error': str(error)})
threading.Thread(target=packets, daemon=True).start()
try:
    assert events.get(timeout=15)['event'] == 'ready'
    times = []
    for i in range(20):
        start = time.perf_counter()
        worker.stdin.write((json.dumps({'id': i, 'action': 'tap', 'values': ['200', '262']}) + '\n').encode())
        worker.stdin.flush()
        event = events.get(timeout=10)
        assert event['event'] == 'ack', event
        times.append((time.perf_counter() - start) * 1000)
        time.sleep(0.05)
    until = time.monotonic() + 2
    while time.monotonic() < until:
        time.sleep(0.05)
finally:
    worker.stdin.close()
    try:
        worker.wait(timeout=5)
    except subprocess.TimeoutExpired:
        worker.kill(); worker.wait()
    stderr = worker.stderr.read().decode()
    assert worker.returncode == 0, stderr
assert len(frame_times) >= 10, f'Insufficient streamed frames: {len(frame_times)}'
stream_fps = (len(frame_times) - 1) / (frame_times[-1] - frame_times[0])
print(json.dumps({'stage': 'connection benchmark', 'commandMedianMs': round(statistics.median(baseline), 1), 'persistentMedianMs': round(statistics.median(times[1:]), 1), 'streamFPS': round(stream_fps, 1)}), flush=True)

# A real viewer process, no pixel dimensions in ioctl, and tall 8x21 cells.
master, slave = pty.openpty()
original = termios.tcgetattr(slave)
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 100, 0, 0))
env.pop('TMUX', None)
viewer = subprocess.Popen([str(binary), 'view', a.phone, '--protocol', 'kitty'], stdin=slave, stdout=slave, stderr=subprocess.PIPE, env=env)
received = bytearray()
ready = threading.Event()
def terminal():
    try:
        while viewer.poll() is None:
            if select.select([master], [], [], .05)[0]:
                chunk = os.read(master, 65536)
                received.extend(chunk)
                if len(received) > 4_000_000:
                    del received[:1_000_000]
                if b'\x1b[16t' in chunk:
                    os.write(master, b'\x1b[6;21;8t')
                if b'phone keeps running' in received:
                    ready.set()
    except OSError:
        pass
threading.Thread(target=terminal, daemon=True).start()

def mouse(x, y, button=0, release=False):
    image_width = 38 * 21 * 402 / 874
    origin = (100 - math.ceil(image_width / 8)) // 2 + 1
    col = origin + math.floor(x * image_width / 402 / 8)
    row = math.floor(y * 38 / 874) + 1
    os.write(master, f'\x1b[<{button};{col};{row}{"m" if release else "M"}'.encode())

def click(x, y):
    mouse(x, y); mouse(x, y, release=True)

def wait_value(name, key, expected):
    until = time.monotonic() + 10
    actual = None
    while time.monotonic() < until:
        actual = element(name).get(key)
        if actual == expected:
            return
        time.sleep(.05)
    raise AssertionError(f'{name}: expected {expected!r}, got {actual!r}')

try:
    assert ready.wait(15), 'No terminal frame'
    before = int(element('counter')['AXLabel'].split(': ')[1])
    click(200, 262)
    wait_value('counter', 'AXLabel', f'Count: {before + 1}')
    click(200, 319)
    for char in 'viewer-fast':
        os.write(master, char.encode()); time.sleep(.03)
    wait_value('message', 'AXValue', 'viewer-fast')
    click(200, 376)
    wait_value('echo', 'AXLabel', 'Message: viewer-fast')
    # Drag the demo's paging scroll view; this must be a swipe, not a tap.
    mouse(330, 500)
    mouse(200, 500, button=32)
    mouse(70, 500, button=32)
    mouse(70, 500, release=True)
    wait_value('page', 'AXLabel', 'Page: 2')
    # Continuous wheel input must start scrolling before the event burst becomes
    # a backlog of separately launched commands. Scroll only; don't change settings.
    cli('launch', a.phone, 'com.apple.Preferences')
    time.sleep(.5)
    before_tree = elements()
    def positions(tree):
        return {(e.get('AXUniqueId') or e.get('AXLabel')): e.get('frame', {}).get('y')
                for e in tree if (e.get('AXUniqueId') or e.get('AXLabel'))}
    initial = positions(before_tree)
    for _ in range(20):
        mouse(200, 450, button=65); time.sleep(.01)
    until = time.monotonic() + 5
    while True:
        current = positions(elements())
        moved = [key for key in initial.keys() & current.keys()
                 if initial[key] is not None and current[key] is not None and abs(initial[key] - current[key]) > 30]
        if len(moved) >= 2 or len(current.keys() - initial.keys()) >= 3:
            break
        assert time.monotonic() < until, 'Continuous wheel events did not scroll Settings'
        time.sleep(.05)
    os.write(master, b'\x1d')
    viewer.wait(timeout=3)
    assert viewer.returncode == 0, viewer.stderr.read().decode()
    assert termios.tcgetattr(slave) == original, 'Terminal not restored'
finally:
    if viewer.poll() is None:
        viewer.kill(); viewer.wait()
    os.close(master); os.close(slave)

result = {
    'ok': True, 'udid': udid,
    'commandPerTapMedianMilliseconds': round(statistics.median(baseline), 1),
    'persistentTapRoundTripMedianMilliseconds': round(statistics.median(times[1:]), 1),
    'streamFramesPerSecond': round(stream_fps, 1),
    'streamFrames': len(frame_times),
    'pty': ['click target with 8x21 cells', 'increment confirmed', 'incremental typing and submission confirmed', 'drag to page 2 confirmed', 'continuous wheel scroll changes Settings', 'terminal restored'],
}
(home / 'responsiveness.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
