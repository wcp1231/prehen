#!/usr/bin/env python3

import json
import os
import sys
import time


def emit(event):
    sys.stdout.write(json.dumps(event, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def encode(event):
    return json.dumps(event, separators=(",", ":"))


def emit_raw(line):
    sys.stdout.write(line)
    sys.stdout.flush()


def turn_text():
    args = sys.argv[1:]
    filtered = []
    skip_next = False

    for arg in args:
        if skip_next:
            skip_next = False
            continue

        if arg in {"--mode", "--provider", "--model"}:
            skip_next = True
            continue

        if arg.startswith("--mode=") or arg.startswith("--provider=") or arg.startswith("--model="):
            continue

        filtered.append(arg)

    return " ".join(filtered) or os.environ.get("FAKE_PI_TURN_TEXT", "")


def write_exit_marker():
    marker = os.environ.get("FAKE_PI_EXIT_MARKER")

    if marker:
        with open(marker, "w", encoding="utf-8") as handle:
            handle.write("exited\n")


def write_launch_marker():
    marker = os.environ.get("FAKE_PI_LAUNCH_MARKER")

    if marker:
        with open(marker, "w", encoding="utf-8") as handle:
            handle.write("launched\n")


def main():
    mode = os.environ.get("FAKE_PI_MODE", "happy")
    assistant_text = f"echo:{turn_text()}"

    write_launch_marker()

    if mode == "wait_for_eof_before_header":
        sys.stdin.read()

    if mode == "invalid_header":
        emit({"type": "not_session", "version": 3, "id": "fake_pi_session"})
        return

    if mode == "delayed_nonzero":
        emit({"type": "session", "version": 3, "id": "fake_pi_session", "cwd": os.getcwd()})
        time.sleep(0.35)
        sys.exit(17)

    emit({"type": "session", "version": 3, "id": "fake_pi_session", "cwd": os.getcwd()})

    if mode == "nonzero_exit":
        sys.exit(17)

    if mode == "event_then_nonzero":
        emit({"type": "agent_start"})
        sys.exit(17)

    if mode == "unknown_event_then_nonzero":
        emit({"foo": "bar"})
        sys.exit(17)

    if mode == "malformed_after_header":
        emit_raw("{not-json}\n")
        return

    if mode == "same_chunk_after_agent_end":
        emit_raw(
            "\n".join(
                [
                    encode({"type": "agent_start"}),
                    encode({"type": "turn_start"}),
                    encode(
                        {
                            "type": "message_update",
                            "message": {"role": "assistant", "content": []},
                            "assistantMessageEvent": {
                                "type": "text_delta",
                                "delta": assistant_text,
                            },
                        }
                    ),
                    encode(
                        {
                            "type": "message_end",
                            "message": {
                                "role": "assistant",
                                "content": [{"type": "text", "text": assistant_text}],
                            },
                        }
                    ),
                    encode(
                        {
                            "type": "turn_end",
                            "message": {
                                "role": "assistant",
                                "content": [{"type": "text", "text": assistant_text}],
                            },
                            "toolResults": [],
                        }
                    ),
                    encode(
                        {
                            "type": "agent_end",
                            "messages": [
                                {
                                    "role": "assistant",
                                    "content": [{"type": "text", "text": assistant_text}],
                                }
                            ],
                        }
                    ),
                    encode({"type": "post_agent_end_ping"}),
                    "",
                ]
            )
        )
        return

    emit({"type": "agent_start"})
    emit({"type": "turn_start"})

    if mode == "message_lifecycle":
        emit(
            {
                "type": "message_start",
                "message": {
                    "role": "user",
                    "content": [{"type": "text", "text": turn_text()}],
                },
            }
        )
        emit(
            {
                "type": "message_end",
                "message": {
                    "role": "user",
                    "content": [{"type": "text", "text": turn_text()}],
                },
            }
        )

    if mode == "busy":
        time.sleep(1.5)

    emit(
        {
            "type": "message_update",
            "message": {"role": "assistant", "content": []},
            "assistantMessageEvent": {
                "type": "text_delta",
                "delta": assistant_text,
            },
        }
    )
    emit(
        {
            "type": "message_end",
            "message": {
                "role": "assistant",
                "content": [{"type": "text", "text": assistant_text}],
            },
        }
    )
    emit(
        {
            "type": "turn_end",
            "message": {
                "role": "assistant",
                "content": [{"type": "text", "text": assistant_text}],
            },
            "toolResults": [],
        }
    )
    emit(
        {
            "type": "agent_end",
            "messages": [
                {
                    "role": "assistant",
                    "content": [{"type": "text", "text": assistant_text}],
                }
            ],
        }
    )

    if mode == "linger_after_end":
        time.sleep(1.0)
        emit({"type": "post_agent_end_ping"})
        write_exit_marker()


if __name__ == "__main__":
    main()
