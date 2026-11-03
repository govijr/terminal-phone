#!/usr/bin/env python3
"""Exercise actual viewer mouse/keyboard input, calibrated from its rendered PNG.

Uses only the named test simulator and the included demo; never controls a real iPhone.
Requires Pillow for inspection, not for modifying product images.
"""
import argparse
import base64
import fcntl
import io
import json
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import termios
import threading
import time
from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument('--phone', default='agent-validation')
parser.add_argument('--home', default='.build/phone-agent-validation')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
binary = Path(os.environ.get('PHONE_TEST_BINARY', root / 'dist/terminal-phone'))
home = Path(args.home).resolve()
env = dict(os.environ, TERMINAL_PHONE_HOME=str(home))
env.pop('TMUX', None)
checks = []

def cli(*arguments, retry_busy=True):
    deadline = time.monotonic() + 8
    while True:
        result = subprocess.run([str(binary), *map(str, arguments)], env=env, capture_output=True, text=True, timeout=300)
        data = json.loads(result.stdout or result.stderr)
        if result.returncode == 0:
            return data
        if retry_busy and isinstance(data.get('error'), dict) and data['error']['code'] == 'CONTROLLER_BUSY' and time.monotonic() < deadline:
            time.sleep(.2)
            continue
        raise AssertionError((arguments, data))

def elements():
    return cli('action', args.phone, 'describe')['elements']

def wait_for(predicate, timeout=10):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        result = predicate()
        if result:
            return result
        time.sleep(.05)
    raise AssertionError('Expected viewer/UI state did not appear')

def element(identifier):
    return wait_for(lambda: next((e for e in elements() if e.get('AXUniqueId') == identifier), None))

def value(identifier, expected, key='AXLabel'):
    return wait_for(lambda: next((e for e in elements() if e.get('AXUniqueId') == identifier and e.get(key) == expected), None))

master = slave = viewer = None
received = bytearray()
lock = threading.Lock()

def screen_lines():
    with lock:
        text = bytes(received).decode('utf-8', errors='replace')
    text = re.sub(r'\x1b_G.*?\x1b\\', '', text, flags=re.S)
    text = re.sub(r'\x1b\].*?(?:\x07|\x1b\\)', '', text, flags=re.S)
    lines = [[' '] * 100 for _ in range(40)]
    row = column = 0
    token = re.compile(r'\x1b\[([?0-9;]*)([@-~])|([^\x1b]+)', re.S)
    for match in token.finditer(text):
        if match[3] is not None:
            for char in match[3]:
                if char == '\r': column = 0
                elif char == '\n': row = min(39, row + 1)
                elif char >= ' ':
                    if 0 <= row < 40 and 0 <= column < 100: lines[row][column] = char
                    column += 1
        else:
            params, command = match[1], match[2]
            if command in ('H', 'f'):
                numbers = params.split(';')
                row, column = int(numbers[0] or 1) - 1, int(numbers[1] or 1) - 1
            elif command == 'J' and params == '2': lines = [[' '] * 100 for _ in range(40)]
            elif command == 'K' and params == '2' and 0 <= row < 40: lines[row] = [' '] * 100
    return [''.join(line) for line in lines]

def toolbar_click(text):
    def locate():
        for row, line in enumerate(screen_lines()):
            if text in line and row >= 36:
                return row + 1, line.index(text) + 1 + len(text) // 2
    row, column = wait_for(locate)
    os.write(master, f'\x1b[<0;{column};{row}M\x1b[<0;{column};{row}m'.encode())

def calibration():
    with lock: data = bytes(received)
    header = payload = position = None
    frames = []
    for match in re.finditer(rb'\x1b_G([^;]+);([^\x1b]*)\x1b\\', data):
        fields, chunk = match[1], match[2]
        if b'a=T,f=100' in fields:
            header, payload = fields, bytearray()
            positions = re.findall(rb'\x1b\[(\d+);(\d+)H', data[max(0, match.start() - 100):match.start()])
            position = tuple(map(int, positions[-1])) if positions else None
        if header is not None and b'm=' in fields:
            payload.extend(chunk)
            if b'm=0' in fields:
                if position: frames.append((position, base64.b64decode(payload)))
                header = None
    for position, png in reversed(frames):
        image = Image.open(io.BytesIO(png)).convert('RGBA')
        mask = Image.new('1', image.size)
        pixels = image.get_flattened_data() if hasattr(image, 'get_flattened_data') else image.getdata()
        mask.putdata([r > 240 and g > 240 and b > 240 and a > 200 for r, g, b, a in pixels])
        bounds = mask.getbbox()
        if bounds and bounds[2] - bounds[0] > 120 and bounds[3] - bounds[1] > 300:
            return position, bounds

try:
    registration = cli('up', args.phone, '--no-view')
    cli('install', args.phone, root / 'dist/PhoneDemo.app')
    subprocess.run(['xcrun', 'simctl', 'terminate', registration['udid'], 'dev.terminal-phone.demo'], capture_output=True)
    subprocess.run(['xcrun', 'simctl', 'ui', registration['udid'], 'appearance', 'light'], capture_output=True, check=True)
    cli('launch', args.phone, 'dev.terminal-phone.demo')
    element('increment')
    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 100, 0, 0))
    viewer = subprocess.Popen([str(binary), 'view', args.phone, '--read-only', '--protocol', 'kitty'],
                              env=env, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
    def read_terminal():
        while viewer.poll() is None:
            try:
                if not select.select([master], [], [], .05)[0]: continue
                chunk = os.read(master, 65536)
            except OSError: return
            with lock:
                received.extend(chunk)
            if b'\x1b[16t' in chunk: os.write(master, b'\x1b[6;21;8t')
    threading.Thread(target=read_terminal, daemon=True).start()
    (origin_row, origin_col), (left, top, right, bottom) = wait_for(calibration, timeout=20)
    assert any('Home' in line for line in screen_lines()), 'Home must remain visible in view-only mode'
    checks.append('Home remains visible in view-only mode')
    def mouse(x, y, button=0, release=False):
        column = origin_col + int((left + x * (right - left) / 402) / 8)
        row = origin_row + int((top + y * (bottom - top) / 874) / 21)
        os.write(master, f'\x1b[<{button};{column};{row}{"m" if release else "M"}'.encode())
    def tap(identifier):
        bounds = element(identifier)['frame']
        x, y = bounds['x'] + bounds['width'] / 2, bounds['y'] + bounds['height'] / 2
        mouse(x, y); mouse(x, y, release=True)
    before = int(element('counter')['AXLabel'].split(': ')[1])
    tap('increment'); time.sleep(.2)
    assert element('counter')['AXLabel'] == f'Count: {before}', 'View-only input was delivered'
    toolbar_click('Enable control')
    wait_for(lambda: any('Interactive' in line for line in screen_lines()))
    tap('increment'); value('counter', f'Count: {before + 1}')
    checks.append('Enable control restores clicks without restarting or releasing an agent session')
    tap('message')
    os.write(master, b'viewer-active')
    value('message', 'viewer-active', 'AXValue')
    tap('submit'); value('echo', 'Message: viewer-active')
    checks.append('Typing and submission work through the shared input service')
    frame = wait_for(lambda: next((e['frame'] for e in elements() if e.get('AXLabel') == 'Drag left →'), None))
    y = frame['y'] + frame['height'] / 2
    mouse(frame['x'] + frame['width'] * .85, y)
    mouse(frame['x'] + frame['width'] * .5, y, button=32)
    mouse(frame['x'] + frame['width'] * .15, y, button=32)
    mouse(frame['x'] + frame['width'] * .15, y, release=True)
    value('page', 'Page: 2')
    checks.append('Mouse drag performs a horizontal swipe, confirmed by page 2')
    time.sleep(.8)
    waiting = subprocess.Popen([str(binary), 'wait', args.phone, '--text', '__human_preempts_agent__', '--timeout', '30'],
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(.5)
    started = time.monotonic()
    tap('increment'); value('counter', f'Count: {before + 2}')
    latency = (time.monotonic() - started) * 1000
    stdout, stderr = waiting.communicate(timeout=5)
    reply = json.loads(stdout or stderr)
    assert reply['error']['code'] == 'REQUEST_CANCELLED', reply
    checks.append('A human tap interrupts a pending agent wait and still updates the UI')
    cli('launch', args.phone, 'com.apple.Preferences')
    time.sleep(.4)
    def positions():
        return {(e.get('AXUniqueId') or e.get('AXLabel')): e.get('frame', {}).get('y') for e in elements() if e.get('AXUniqueId') or e.get('AXLabel')}
    initial = positions()
    for _ in range(20): mouse(200, 450, button=65); time.sleep(.01)
    def moved():
        current = positions()
        delta = [key for key in initial.keys() & current.keys() if initial[key] is not None and current[key] is not None and abs(initial[key] - current[key]) > 30]
        return len(delta) >= 2 or len(current.keys() - initial.keys()) >= 3
    wait_for(moved)
    checks.append('Mouse-wheel events scroll Settings while the viewer and agent session coexist')
    toolbar_click('Home')
    wait_for(lambda: any(e.get('AXLabel') == 'Settings' for e in elements()))
    checks.append('The visible Home button navigates back to the Home Screen')
    os.write(master, b'\x1d')
    viewer.wait(timeout=5)
    assert viewer.returncode == 0, viewer.stderr.read().decode()
    assert termios.tcgetattr(slave) == original
    report = {'ok': True, 'phone': args.phone, 'udid': registration['udid'], 'checks': checks,
              'tapToAccessibilityConfirmationMs': round(latency, 1), 'geometry': 'calibrated from actual rendered PNG'}
    (home / 'interactive-validation.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
except Exception:
    home.mkdir(parents=True, exist_ok=True)
    (home / 'interactive-failure.json').write_text(json.dumps({'completed': checks, 'elements': elements()}, indent=2))
    with lock: (home / 'interactive-terminal.txt').write_bytes(bytes(received))
    raise
finally:
    if viewer and viewer.poll() is None: viewer.terminate(); viewer.wait(timeout=5)
    if master is not None: os.close(master)
    if slave is not None: os.close(slave)
    cli('stop', args.phone)
