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

        if arg in {
            "--mode",
            "--provider",
            "--model",
            "--append-system-prompt",
            "--mcp-url",
            "--mcp-bearer-token",
        }:
            skip_next = True
            continue

        if (
            arg.startswith("--mode=")
            or arg.startswith("--provider=")
            or arg.startswith("--model=")
            or arg.startswith("--append-system-prompt=")
            or arg.startswith("--mcp-url=")
            or arg.startswith("--mcp-bearer-token=")
        ):
            continue

        filtered.append(arg)

    return " ".join(filtered) or os.environ.get("FAKE_PI_TURN_TEXT", "")


def option_value(name):
    args = sys.argv[1:]

    for index, arg in enumerate(args):
        if arg == name and index + 1 < len(args):
            return args[index + 1]

        prefix = f"{name}="

        if arg.startswith(prefix):
            return arg[len(prefix) :]

    return None


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


def write_launch_capture():
    capture_path = os.environ.get("FAKE_PI_CAPTURE_PATH")

    if not capture_path:
        return

    payload = {
        "cwd": os.getcwd(),
        "argv": sys.argv[1:],
        "system_prompt": option_value("--append-system-prompt"),
        "mcp_url_arg": option_value("--mcp-url"),
        "mcp_token_arg": option_value("--mcp-bearer-token"),
        "mcp_url_env": os.environ.get("PREHEN_MCP_URL"),
        "mcp_token_env": os.environ.get("PREHEN_MCP_TOKEN"),
    }

    with open(capture_path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle)


def emit_help_contract():
    contract = os.environ.get("FAKE_PI_HELP_CONTRACT", "none")

    if contract == "http_flags":
        sys.stdout.write("--mcp-url <url>\n--mcp-bearer-token <token>\n")
        sys.stdout.flush()
        return True

    if contract == "http_env":
        sys.stdout.write("PREHEN_MCP_URL\nPREHEN_MCP_TOKEN\n")
        sys.stdout.flush()
        return True

    if contract == "none":
        sys.stdout.write("--provider <provider>\n--model <model>\n")
        sys.stdout.flush()
        return True

    return False


def main():
    mode = os.environ.get("FAKE_PI_MODE", "happy")
    assistant_text = f"echo:{turn_text()}"

    if "--help" in sys.argv[1:]:
        emit_help_contract()
        return

    write_launch_marker()
    write_launch_capture()

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
