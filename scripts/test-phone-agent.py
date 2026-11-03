#!/usr/bin/env python3
"""Protocol checks, plus an opt-in end-to-end agent loop on one dedicated simulator.

No real-iPhone actions. --live creates/reuses only --phone in the supplied registry.
"""
import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / "dist/terminal-phone"
checks = []


def run(env, *arguments, failure=None):
    result = subprocess.run([str(BINARY), *map(str, arguments)], env=env, capture_output=True, text=True, timeout=450)
    data = json.loads(result.stdout or result.stderr)
    if failure:
        assert result.returncode != 0, (arguments, data)
        assert data.get("error", {}).get("code") == failure, (arguments, data)
    else:
        assert result.returncode == 0, (arguments, data)
    return data


class MCP:
    def __init__(self, env):
        self.process = subprocess.Popen([str(BINARY), "mcp"], env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.buffer = bytearray()
        self.sequence = 0
        reply = self.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                         "clientInfo": {"name": "phone-agent-validation", "version": "1"}})
        assert reply["result"]["protocolVersion"] == "2025-06-18", reply
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, message):
        self.process.stdin.write(json.dumps(message, separators=(",", ":")).encode() + b"\n")
        self.process.stdin.flush()

    def receive(self, timeout=120):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            assert remaining > 0, "MCP response timed out"
            ready, _, _ = select.select([self.process.stdout], [], [], remaining)
            assert ready, "MCP response timed out"
            chunk = os.read(self.process.stdout.fileno(), 65536)
            assert chunk, "MCP server ended before replying"
            self.buffer.extend(chunk)
        line, _, rest = self.buffer.partition(b"\n")
        self.buffer = bytearray(rest)
        return json.loads(line)

    def call(self, method, params=None):
        self.sequence += 1
        self.send({"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params or {}})
        reply = self.receive()
        assert reply["id"] == self.sequence, reply
        return reply

    def tool(self, name, arguments):
        reply = self.call("tools/call", {"name": name, "arguments": arguments})
        assert "result" in reply, reply
        return reply["result"]

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=3)


def protocol_checks():
    with tempfile.TemporaryDirectory(prefix="phone-agent-protocol-") as directory:
        home = Path(directory)
        registration = home / "phones/protocol"
        registration.mkdir(parents=True)
        (registration / "phone.json").write_text(json.dumps({"name": "protocol", "udid": str(uuid.uuid4()).upper(),
                                                            "deviceType": "test", "runtime": "test"}))
        env = dict(os.environ, TERMINAL_PHONE_HOME=str(home))
        mcp = MCP(env)
        try:
            schema = run(env, "schema")
            tools = mcp.call("tools/list")["result"]["tools"]
            assert tools == schema["tools"] and len(tools) == 7
            assert mcp.call("ping")["result"] == {}
            checks.append("MCP handshake, ping and all seven schemas match CLI discovery")
            unknown = mcp.call("tools/call", {"name": "unknown", "arguments": {}})
            assert unknown["error"]["code"] == -32602
            invalid = mcp.call("tools/call", {"name": "phone_observe", "arguments": {"includeImage": "no"}})
            assert invalid["error"]["code"] == -32602
            invalid = mcp.call("tools/call", {"name": "phone_act", "arguments": {"action": {"kind": "tap", "unexpected": True}}})
            assert invalid["error"]["code"] == -32602
            run(env, "observe", "protocol", "--direction", "down", failure="INVALID_REQUEST")
            checks.append("unknown tools, invalid argument types and ignored CLI flags are rejected")
            started = mcp.tool("phone_session", {"phone": "protocol", "operation": "start"})["structuredContent"]
            status = run(env, "session", "status", "protocol")
            assert started["ok"] and started["session"]["id"] == status["session"]["id"]
            caps = mcp.tool("phone_capabilities", {"phone": "protocol"})["structuredContent"]
            assert caps["session"]["id"] == status["session"]["id"]
            assert caps["capabilities"]["foregroundApp"] is False
            checks.append("CLI and MCP reuse one session and report backend-specific capabilities")
            stopped = run(env, "session", "stop", "protocol")
            assert stopped["stopped"] is True
            assert run(env, "session", "stop", "protocol")["stopped"] is False
            checks.append("Stop identifies the session peer and is repeatable")
        finally:
            mcp.close()
            subprocess.run([str(BINARY), "session", "stop", "protocol"], env=env, capture_output=True, timeout=5)


def live_checks(phone, home):
    env = dict(os.environ, TERMINAL_PHONE_HOME=str(home.resolve()))
    registration = run(env, "up", phone, "--no-view")
    try:
        run(env, "install", phone, ROOT / "dist/PhoneDemo.app")
        run(env, "launch", phone, "dev.terminal-phone.demo")
        observed = run(env, "wait", phone, "--id", "increment", "--timeout", "10")
        scene = observed["observation"]
        elements = {entry["element"].get("identifier"): entry for entry in scene["elements"]}
        initial = int(elements["counter"]["element"]["label"].split(": ")[1])
        ref = elements["increment"]["ref"]
        reply = run(env, "act", phone, "tap", "--ref", ref, "--wait-text", f"Count: {initial + 1}")
        assert reply["action"]["verified"] is True
        run(env, "act", phone, "tap", "--ref", ref, failure="STALE_REFERENCE")
        checks.append("fresh reference tap verifies the counter; old reference is rejected")
        request_id = "validation-" + str(uuid.uuid4())
        command = ["act", phone, "tap", "--id", "increment", "--request-id", request_id,
                   "--wait-text", f"Count: {initial + 2}"]
        first = run(env, *command)
        assert run(env, *command) == first
        current = run(env, "observe", phone)
        counter = next(e["element"] for e in current["observation"]["elements"] if e["element"].get("identifier") == "counter")
        assert counter["label"] == f"Count: {initial + 2}", counter
        checks.append("duplicate request ID returns its original result without a second tap")
        run(env, "act", phone, "fill", "--id", "message", "--text", "replace this", "--observe")
        run(env, "act", phone, "fill", "--id", "message", "--observe", "--", "--agent-literal")
        reply = run(env, "act", phone, "tap", "--id", "submit", "--wait-text", "Message: --agent-literal")
        assert reply["action"]["verified"] is True
        checks.append("fill replaces existing text and preserves a leading-dash literal")
        timeout = run(env, "wait", phone, "--text", "__missing_validation_state__", "--timeout", "0", failure="WAIT_TIMEOUT")
        assert Path(timeout["observation"]["screenshot"]).exists()
        run(env, "act", phone, "tap", "10000", "10", failure="INVALID_REQUEST")
        checks.append("wait timeout returns diagnostic state; out-of-display input is rejected")
        mcp = MCP(env)
        try:
            result = mcp.tool("phone_observe", {"phone": phone})
            assert result["structuredContent"]["session"]["id"] == reply["session"]["id"]
            images = [item for item in result["content"] if item["type"] == "image"]
            assert len(images) == 1 and base64.b64decode(images[0]["data"]).startswith(b"\x89PNG\r\n\x1a\n")
            result = mcp.tool("phone_act", {"phone": phone, "action": {"kind": "tap", "target": {"identifier": "increment"}},
                                           "condition": {"text": f"Count: {initial + 3}"}})
            assert result["structuredContent"]["action"]["verified"] is True, result
            checks.append("MCP returns a real PNG and verifies input through the same live session")
            mcp.send({"jsonrpc": "2.0", "id": "pending-wait", "method": "tools/call", "params": {
                "name": "phone_wait", "arguments": {"phone": phone, "condition": {"text": "__cancel_wait__"}, "timeout": 30}}})
            time.sleep(0.2)
            mcp.send({"jsonrpc": "2.0", "id": "queued-input", "method": "tools/call", "params": {
                "name": "phone_act", "arguments": {"phone": phone, "action": {"kind": "tap", "target": {"identifier": "increment"}}}}})
            mcp.send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": "queued-input"}})
            mcp.send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": "pending-wait"}})
            fresh = mcp.tool("phone_observe", {"phone": phone, "includeImage": False})["structuredContent"]
            counter = next(e["element"] for e in fresh["observation"]["elements"] if e["element"].get("identifier") == "counter")
            assert counter["label"] == f"Count: {initial + 3}", counter
            checks.append("MCP cancellation interrupts polling and prevents queued input from dispatching")
        finally:
            mcp.close()
        run(env, "session", "release", phone)
        lock = Path(f"/tmp/terminal-phone-agent-{os.getuid()}/{registration['udid'].lower()}.control.lock")
        with lock.open("a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            run(env, "act", phone, "press", "HOME", failure="CONTROLLER_BUSY")
            run(env, "observe", phone, "--no-image")
        checks.append("another controller blocks input while observation remains available")
        run(env, "action", phone, "button", "HOME")
        run(env, "launch", phone, "dev.terminal-phone.demo")
        run(env, "wait", phone, "--id", "increment")
        checks.append("legacy button and app launch commands share the session queue")
        pending = subprocess.Popen([str(BINARY), "wait", phone, "--text", "__never__", "--timeout", "60"],
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.5)
        started = time.monotonic()
        assert run(env, "session", "stop", phone)["stopped"] is True
        assert time.monotonic() - started < 3
        pending.communicate(timeout=5)
        assert pending.returncode != 0
        assert run(env, "status", phone)["state"] == "Booted"
        run(env, "act", phone, "press", "HOME", "--session", reply["session"]["id"], failure="STALE_REFERENCE")
        checks.append("Stop interrupts a pending wait, leaves the simulator running and rejects ended-session actions")
        return {"phone": phone, "udid": registration["udid"], "screenshot": timeout["observation"]["screenshot"]}
    finally:
        run(env, "stop", phone)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--phone", default="agent-validation")
    parser.add_argument("--home", type=Path, default=ROOT / ".build/phone-agent-validation")
    args = parser.parse_args()
    protocol_checks()
    result = live_checks(args.phone, args.home) if args.live else {}
    print(json.dumps({"ok": True, **result, "checks": checks}, indent=2))


if __name__ == "__main__":
    main()
