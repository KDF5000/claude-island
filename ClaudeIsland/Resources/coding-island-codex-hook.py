#!/usr/bin/env python3
"""Coding Island Hook (OpenAI Codex CLI)

- Sends Codex session/tool/permission events to CodingIsland.app via Unix socket
- For PermissionRequest: waits briefly for Coding Island approval and outputs
  Codex hookSpecificOutput JSON to stdout when a decision is received.

Codex hook input schema is documented here:
https://developers.openai.com/codex/hooks
"""

import json
import os
import socket
import sys


SOCKET_PATH = os.path.expanduser("~/.coding-island/coding-island.sock")
TIMEOUT_SECONDS = 300
DUAL_APPROVAL_TIMEOUT = 3  # seconds
PROVIDER_ID = "codex"


def send_event(state, wait_for_response=False):
    sock = None
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(2)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode())

        if not wait_for_response:
            try:
                sock.close()
            except Exception:
                pass
            return None

        # Wait briefly for an app decision; if no decision, Codex will show its own prompt.
        try:
            sock.settimeout(DUAL_APPROVAL_TIMEOUT)
            response = sock.recv(4096)
            if response:
                return json.loads(response.decode())
        except socket.timeout:
            return None
        except (json.JSONDecodeError, OSError):
            return None
        return None
    except Exception:
        return None
    finally:
        try:
            if sock is not None:
                sock.close()
        except Exception:
            pass


def codex_permission_output(decision, reason=None):
    if decision == "allow":
        return {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {"behavior": "allow"},
            }
        }
    if decision == "deny":
        return {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {
                    "behavior": "deny",
                    "message": reason or "Denied by user via CodingIsland",
                },
            }
        }
    return None


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    session_id = data.get("session_id", "unknown")
    cwd = data.get("cwd") or os.getcwd()
    event = data.get("hook_event_name", "")
    transcript_path = data.get("transcript_path")

    tool_name = data.get("tool_name")
    tool_input = data.get("tool_input")
    tool_use_id = data.get("tool_use_id")

    # Basic process info
    pid = os.getppid()
    tty = None
    try:
        tty = os.ttyname(sys.stdin.fileno())
    except Exception:
        pass

    state = {
        "provider_id": PROVIDER_ID,
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": pid,
        "tty": tty,
        "transcript_path": transcript_path,
    }

    # Map Codex hook events to Coding Island status model
    if event == "SessionStart":
        state["status"] = "starting"
        send_event(state)
        sys.exit(0)

    if event == "UserPromptSubmit":
        state["status"] = "processing"
        send_event(state)
        sys.exit(0)

    if event == "PreToolUse":
        state["status"] = "running_tool"
        state["tool"] = tool_name
        state["tool_input"] = tool_input if isinstance(tool_input, dict) else {}
        if tool_use_id:
            state["tool_use_id"] = tool_use_id
        send_event(state)
        sys.exit(0)

    if event == "PostToolUse":
        state["status"] = "processing"
        state["tool"] = tool_name
        state["tool_input"] = tool_input if isinstance(tool_input, dict) else {}
        if tool_use_id:
            state["tool_use_id"] = tool_use_id
        send_event(state)
        sys.exit(0)

    if event == "PermissionRequest":
        state["status"] = "waiting_for_approval"
        state["tool"] = tool_name
        state["tool_input"] = tool_input if isinstance(tool_input, dict) else {}
        state["dual_approval_mode"] = True

        response = send_event(state, wait_for_response=True)
        if response:
            decision = response.get("decision")
            reason = response.get("reason")
            out = codex_permission_output(decision, reason)
            if out is not None:
                print(json.dumps(out))
        # No output means: do not decide, let Codex show its normal prompt.
        sys.exit(0)

    if event == "Stop":
        state["status"] = "waiting_for_input"
        send_event(state)
        sys.exit(0)

    # Default: forward as notification/idle.
    state["status"] = "idle"
    send_event(state)
    sys.exit(0)


if __name__ == "__main__":
    main()

