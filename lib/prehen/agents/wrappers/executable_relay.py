#!/usr/bin/env python3

import base64
import json
import os
import selectors
import signal
import struct
import subprocess
import sys

PROCESS = None
CHUNK_SIZE = 4096


def emit(event):
    payload = json.dumps(event, separators=(",", ":")).encode("utf-8")

    try:
        sys.stdout.buffer.write(struct.pack(">I", len(payload)))
        sys.stdout.buffer.write(payload)
        sys.stdout.buffer.flush()
    except BrokenPipeError:
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, sys.stdout.fileno())
        raise SystemExit(0)


def terminate_child(_signum, _frame):
    global PROCESS

    if PROCESS is not None and PROCESS.poll() is None:
        PROCESS.terminate()

    raise SystemExit(0)


def read_exact(fd, size):
    chunks = []
    remaining = size

    while remaining > 0:
        chunk = os.read(fd, remaining)
        if not chunk:
            return None
        chunks.append(chunk)
        remaining -= len(chunk)

    return b"".join(chunks)


def read_bootstrap(fd):
    header = read_exact(fd, 4)
    if header is None:
        raise SystemExit(1)

    length = struct.unpack(">I", header)[0]
    payload = read_exact(fd, length)
    if payload is None:
        raise SystemExit(1)

    message = json.loads(payload.decode("utf-8"))
    if message.get("type") != "bootstrap":
        raise SystemExit(1)

    return message["config"]


def main():
    global PROCESS

    signal.signal(signal.SIGTERM, terminate_child)
    signal.signal(signal.SIGINT, terminate_child)

    stdin_fd = sys.stdin.fileno()
    config = read_bootstrap(stdin_fd)

    env = {key: str(value) for key, value in config.get("env", {}).items()}
    child_env = os.environ.copy()
    child_env.update(env)

    try:
        PROCESS = subprocess.Popen(
            [config["command"], *config.get("args", [])],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=child_env,
        )
    except FileNotFoundError as exc:
        emit({"type": "stderr", "data": base64.b64encode(str(exc).encode("utf-8")).decode("ascii")})
        emit({"type": "exit_status", "status": 127})
        return

    selector = selectors.DefaultSelector()
    selector.register(stdin_fd, selectors.EVENT_READ, "stdin")
    selector.register(PROCESS.stdout, selectors.EVENT_READ, "stdout")
    selector.register(PROCESS.stderr, selectors.EVENT_READ, "stderr")
    open_streams = {"stdout", "stderr"}

    while True:
        if PROCESS.poll() is not None and not open_streams:
            break

        for key, _mask in selector.select(timeout=0.1):
            stream_type = key.data
            fd = key.fd if key.fd is not None else key.fileobj.fileno()
            chunk = os.read(fd, CHUNK_SIZE)

            if stream_type == "stdin":
                if not chunk:
                    selector.unregister(key.fileobj)

                    try:
                        PROCESS.stdin.close()
                    except OSError:
                        pass

                    continue

                try:
                    PROCESS.stdin.write(chunk)
                    PROCESS.stdin.flush()
                except BrokenPipeError:
                    selector.unregister(key.fileobj)

                continue

            if not chunk:
                selector.unregister(key.fileobj)
                open_streams.discard(stream_type)
                if hasattr(key.fileobj, "close"):
                    key.fileobj.close()
                continue

            emit({"type": stream_type, "data": base64.b64encode(chunk).decode("ascii")})

    status = PROCESS.wait()
    emit({"type": "exit_status", "status": status})


if __name__ == "__main__":
    main()
