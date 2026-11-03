#!/usr/bin/env python3
"""Persistent, ordered idb connection for the phone session host.

stdin: JSON lines; stdout: uint32-be length + JSON. No video, shell, or listener.
Reads may be retried when idb explicitly requests it. Input is never replayed.
"""
import argparse
import asyncio
import base64
import inspect
import json
import logging
import struct
import sys

from idb.common.types import DomainSocketAddress, HIDButtonType, HIDDirection, HIDKey, HIDPress
from idb.grpc.client import Client


async def dispatch(client, request):
    action = request["action"]
    values = request.get("values", [])
    if action == "capture":
        for attempt in range(3):
            try:
                if "options" in inspect.signature(client.accessibility_info).parameters:
                    from idb.common.types import AccessibilityInfoOptions
                    info = await client.accessibility_info(target=None, options=AccessibilityInfoOptions(nested=False))
                else:
                    info = await client.accessibility_info(point=None, nested=False)
                break
            except Exception as error:
                if attempt == 2 or "retry the read" not in str(error):
                    raise
                await asyncio.sleep(0.2)
        raw = getattr(info, "json", info)
        tree = json.loads(raw) if isinstance(raw, str) else raw
        png = bytes(await client.screenshot())
        return {"tree": tree, "png": base64.b64encode(png).decode("ascii")}
    if action == "tap":
        await client.tap(float(values[0]), float(values[1]))
    elif action == "fill":
        await client.tap(float(values[0]), float(values[1]))
        # Replace rather than append, using iOS's own keyboard editing behavior.
        async def select_all():
            for keycode, direction in [(227, HIDDirection.DOWN), (4, HIDDirection.DOWN),
                                       (4, HIDDirection.UP), (227, HIDDirection.UP)]:
                yield HIDPress(action=HIDKey(keycode=keycode), direction=direction)
        await client.hid(select_all())
        await client.key(42)
        if request["text"]:
            await client.text(request["text"])
    elif action == "type":
        await client.text(values[0])
    elif action == "key":
        await client.key(int(values[0]))
    elif action == "button":
        await client.button(HIDButtonType[values[0]])
    elif action == "swipe":
        await client.swipe(tuple(map(int, values[:2])), tuple(map(int, values[2:4])),
                           duration=float(request.get("duration", 0.3)))
    else:
        raise ValueError("Unsupported agent worker action")
    return {}


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--udid", required=True)
    args = parser.parse_args()
    reader = asyncio.StreamReader(limit=256 * 1024)
    loop = asyncio.get_running_loop()
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
    async with Client.build(address=DomainSocketAddress(path=args.socket), logger=logging.getLogger("phone-agent")) as client:
        if client.companion.udid.upper() != args.udid.upper():
            raise RuntimeError("Companion UUID does not match the selected phone")
        while line := await reader.readline():
            request = json.loads(line)
            try:
                result = await asyncio.wait_for(dispatch(client, request), timeout=60)
                reply = {"id": request["id"], "ok": True, "result": result}
            except Exception as error:
                reply = {"id": request.get("id"), "ok": False, "error": str(error)}
            payload = json.dumps(reply, separators=(",", ":"), allow_nan=False).encode()
            if len(payload) > 16 * 1024 * 1024:
                raise RuntimeError("Agent reply exceeds 16 MiB")
            sys.stdout.buffer.write(struct.pack(">I", len(payload)) + payload)
            sys.stdout.buffer.flush()


if __name__ == "__main__":
    logging.basicConfig(level=logging.ERROR, stream=sys.stderr)
    asyncio.run(main())
