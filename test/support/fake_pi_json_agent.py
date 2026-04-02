#!/usr/bin/env python3

import json
import os
import sys
import time


def emit(event):
    sys.stdout.write(json.dumps(event, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def turn_text():
    args = sys.argv[1:]

    if len(args) >= 2 and args[0] == "--mode":
        args = args[2:]

    return " ".join(args) or os.environ.get("FAKE_PI_TURN_TEXT", "")


def main():
    mode = os.environ.get("FAKE_PI_MODE", "happy")
    assistant_text = f"echo:{turn_text()}"

    if mode == "invalid_header":
        emit({"type": "not_session", "version": 3, "id": "fake_pi_session"})
        return

    emit({"type": "session", "version": 3, "id": "fake_pi_session", "cwd": os.getcwd()})
    emit({"type": "agent_start"})
    emit({"type": "turn_start"})

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


if __name__ == "__main__":
    main()
