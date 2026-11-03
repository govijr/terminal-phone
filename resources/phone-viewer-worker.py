#!/usr/bin/env python3
"""One local idb connection for streamed JPEG frames and ordered viewer input.

stdin: newline JSON requests. stdout: uint32-be length, type byte (1 JPEG,
2 JSON status/ack), payload. No shell commands or network listener.
"""
import argparse
import asyncio
import contextlib
import json
import logging
import signal
import struct
import sys
import time

from idb.common.types import DomainSocketAddress, HIDButtonType, VideoFormat
from idb.grpc.client import Client


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--scale", type=float, required=True)
    # Fraction of the native framebuffer to stream. The viewer picks this from the
    # pane's real pixel size, so frames arrive close to the size they're drawn at.
    parser.add_argument("--stream-scale", type=float, default=1.0)
    parser.add_argument("--fps", type=int, default=30)
    args = parser.parse_args()
    output_lock = asyncio.Lock()
    stopped = asyncio.Event()
    loop = asyncio.get_running_loop()
    for number in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(number, stopped.set)

    async def emit(kind, payload):
        if isinstance(payload, dict):
            payload = json.dumps(payload, separators=(",", ":")).encode()
        packet = struct.pack(">I", len(payload) + 1) + bytes([kind]) + payload
        def write():
            sys.stdout.buffer.write(packet)
            sys.stdout.buffer.flush()
        async with output_lock:
            await asyncio.to_thread(write)

    async with Client.build(address=DomainSocketAddress(path=args.socket), logger=logging.getLogger("phone-viewer")) as client:
        if client.companion.udid.upper() != args.udid.upper():
            raise RuntimeError("Companion UUID does not match the selected phone")
        await emit(2, {"event": "ready"})

        async def frames():
            pending = bytearray()
            async for chunk in client.stream_video(output_file=None, fps=args.fps, format=VideoFormat.MJPEG,
                                                    compression_quality=0.85,
                                                    scale_factor=min(1.0, max(0.1, args.stream_scale))):
                pending.extend(chunk)
                while True:
                    start = pending.find(b"\xff\xd8")
                    if start < 0:
                        if len(pending) > 1:
                            del pending[:-1]
                        break
                    end = pending.find(b"\xff\xd9", start + 2)
                    if end < 0:
                        if len(pending) > 16 * 1024 * 1024:
                            raise RuntimeError("Oversized video frame")
                        break
                    frame = bytes(pending[start:end + 2])
                    del pending[:end + 2]
                    await emit(1, frame)

        async def inputs():
            reader = asyncio.StreamReader(limit=256 * 1024)
            await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
            while line := await reader.readline():
                request = json.loads(line)
                started = time.monotonic()
                try:
                    action, values = request["action"], request.get("values", [])
                    if action == "tap":
                        await client.tap(float(values[0]), float(values[1]))
                    elif action == "swipe":
                        await client.swipe(tuple(map(int, values[:2])), tuple(map(int, values[2:4])),
                                           duration=float(request.get("duration", 0.2)))
                    elif action == "type":
                        await client.text(values[0])
                    elif action == "key":
                        await client.key(int(values[0]))
                    elif action == "button":
                        await client.button(HIDButtonType[values[0]])
                    else:
                        raise ValueError("Unsupported viewer input")
                    await emit(2, {"event": "ack", "id": request["id"], "milliseconds": (time.monotonic() - started) * 1000})
                except Exception as error:
                    # Never replay an input operation: it may already have reached iOS.
                    await emit(2, {"event": "input-error", "id": request.get("id"), "error": str(error)})

        tasks = [asyncio.create_task(frames()), asyncio.create_task(inputs()), asyncio.create_task(stopped.wait())]
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            if not task.cancelled() and task.exception():
                await emit(2, {"event": "fatal", "error": str(task.exception())})
        for task in tasks:
            task.cancel()
        for task in tasks:
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await task


if __name__ == "__main__":
    logging.basicConfig(level=logging.ERROR, stream=sys.stderr)
    asyncio.run(main())
