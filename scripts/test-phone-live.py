#!/usr/bin/env python3
"""Exercise the included demo through terminal-phone on a dedicated phone.

Requires built dist/terminal-phone, dist/PhoneDemo.app, and idb automation.
Creates/reuses only the named terminal-phone registration and stops it on exit.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--phone", default="validation")
parser.add_argument("--home", required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
env = dict(os.environ, TERMINAL_PHONE_HOME=str(Path(args.home).resolve()))
binary = root / "dist/terminal-phone"

def run(*arguments):
    result = subprocess.run([str(binary), *map(str, arguments)], env=env, capture_output=True, text=True, timeout=270)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)

def action(*arguments):
    return run("action", args.phone, *arguments)

def element(identifier):
    deadline = time.monotonic() + 20
    while True:
        match = next((e for e in action("describe")["elements"] if e.get("AXUniqueId") == identifier), None)
        if match is not None:
            return match
        assert time.monotonic() < deadline, f"Element did not appear: {identifier}"
        time.sleep(0.3)

def tap(identifier):
    frame = element(identifier)["frame"]
    action("tap", round(frame["x"] + frame["width"] / 2), round(frame["y"] + frame["height"] / 2))

phone = run("up", args.phone, "--no-view")
checks = []
try:
    assert run("up", args.phone, "--no-view")["udid"] == phone["udid"]
    checks.append("reconnect reuses the same simulator")
    run("install", args.phone, root / "dist/PhoneDemo.app")
    run("launch", args.phone, "dev.terminal-phone.demo")
    checks.append("install and launch simulator-built app")
    initial_count = int(element("counter")["AXLabel"].split(": ")[1])
    tap("increment")
    assert element("counter")["AXLabel"] == f"Count: {initial_count + 1}"
    checks.append("tap updates the counter, confirmed through accessibility")
    tap("message")
    # Leading '-' must remain literal text, rather than an idb command option.
    action("type", "--", "--agent-test")
    action("key", "backspace")
    action("type", "--", "t")
    tap("submit")
    echoed = element("echo")["AXLabel"]
    assert echoed == "Message: --agent-test", f"Unexpected submitted text: {echoed!r}"
    checks.append("typing and Backspace update the field, confirmed after submission")
    output = Path(args.home).resolve() / "demo-after.png"
    screenshot = action("screenshot", "--output", output)
    assert screenshot["width"] * screenshot["scale"] == screenshot["nativeWidth"]
    assert screenshot["height"] * screenshot["scale"] == screenshot["nativeHeight"]
    checks.append("screenshot coordinates match display points")
    action("button", "HOME")
    home = action("describe")
    assert "Phone Demo" in json.dumps(home)
    action("swipe", 330, 450, 70, 450, "--duration", "0.3")
    checks.append("Home and swipe commands complete on the selected simulator")
    run("launch", args.phone, "dev.terminal-phone.demo")
except Exception:
    diagnostics = Path(args.home).resolve()
    diagnostics.mkdir(parents=True, exist_ok=True)
    try:
        (diagnostics / "failure-tree.json").write_text(json.dumps(action("describe"), indent=2))
        action("screenshot", "--output", diagnostics / "failure.png")
    except Exception as error:
        (diagnostics / "diagnostics-error.txt").write_text(str(error))
    raise
finally:
    stopped = run("stop", args.phone)
    assert stopped["state"] == "Shutdown"
    checks.append("shutdown preserves registration")
print(json.dumps({"ok": True, "phone": args.phone, "udid": phone["udid"], "checks": checks, "screenshot": str(output)}, indent=2))
