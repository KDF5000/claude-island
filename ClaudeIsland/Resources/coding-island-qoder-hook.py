#!/usr/bin/env python3
"""Coding Island Hook (Qoder IDE / JetBrains plugin)

Receives Qoder hook JSON on stdin and forwards a normalized event to CodingIsland.app
via Unix domain socket.

Qoder events supported by the IDE/JB plugin docs:
- UserPromptSubmit
- PreToolUse
- PostToolUse
- PostToolUseFailure
- Stop

This hook is intended to be used as a Qoder hook command configured in
~/.qoder/settings.json.
"""

import json
import os
import socket
import sys
import time


SOCKET_PATH = os.path.expanduser("~/.coding-island/coding-island.sock")
TIMEOUT_SECONDS = 30

# Optional debug logging to help diagnose payload shape differences.
# Enable via either:
# - `touch ~/.coding-island/qoder-hook-debug`
# - or env var `CODING_ISLAND_QODER_DEBUG=1` (if your Qoder hook runner supports env)
DEBUG_FLAG_PATH = os.path.expanduser("~/.coding-island/qoder-hook-debug")
DEBUG_LOG_PATH = os.path.expanduser("~/.coding-island/qoder-hook-debug.log")
HOOK_VERSION = "2026-04-28-title-v2"


def debug_enabled():
    try:
        if os.environ.get("CODING_ISLAND_QODER_DEBUG") == "1":
            return True
        return os.path.exists(DEBUG_FLAG_PATH)
    except Exception:
        return False


def append_debug(obj):
    if not debug_enabled():
        return
    try:
        # Ensure ~/.coding-island exists
        os.makedirs(os.path.dirname(DEBUG_LOG_PATH), exist_ok=True)
        with open(DEBUG_LOG_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(obj, ensure_ascii=False) + "\n")
    except Exception:
        # Never break the hook.
        return


def get_tty():
    """Best-effort TTY detection.

    Qoder hooks usually run from an IDE context without an attached TTY.
    """
    try:
        return os.ttyname(sys.stdin.fileno())
    except Exception:
        pass
    try:
        return os.ttyname(sys.stdout.fileno())
    except Exception:
        pass
    return None


def send_event(state):
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode("utf-8"))
        sock.close()
    except Exception:
        # Hooks must never break the agent execution.
        return


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    received_at = time.time()

    session_id = data.get("session_id", "unknown")
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd", "")

    tool_name = data.get("tool_name")
    tool_input = data.get("tool_input") or {}
    tool_use_id = data.get("tool_use_id")
    transcript_path = data.get("transcript_path")

    # Qoder docs may name the user prompt differently across IDE/JetBrains variants.
    # Best-effort extraction so Coding Island can show a stable title even when
    # no transcript file exists.
    prompt_value = (
        data.get("prompt")
        or data.get("user_prompt")
        or data.get("userPrompt")
        or data.get("input")
        or data.get("text")
        or data.get("content")
        or data.get("message")
    )
    prompt_key_used = None
    if "prompt" in data:
        prompt_key_used = "prompt"
    elif "user_prompt" in data:
        prompt_key_used = "user_prompt"
    elif "userPrompt" in data:
        prompt_key_used = "userPrompt"
    elif "input" in data:
        prompt_key_used = "input"
    elif "text" in data:
        prompt_key_used = "text"
    elif "content" in data:
        prompt_key_used = "content"
    elif "message" in data:
        prompt_key_used = "message"

    prompt_text = None
    if isinstance(prompt_value, str):
        prompt_text = prompt_value
    elif prompt_value is not None:
        try:
            prompt_text = json.dumps(prompt_value, ensure_ascii=False)
        except Exception:
            prompt_text = str(prompt_value)

    append_debug(
        {
            "hook_version": HOOK_VERSION,
            "received_at": received_at,
            "event": event,
            "session_id": session_id,
            "cwd": cwd,
            "keys": sorted(list(data.keys())),
            "prompt_key_used": prompt_key_used,
            "prompt_len": len(prompt_text) if isinstance(prompt_text, str) else None,
            "tool_name": tool_name,
            "tool_use_id": tool_use_id,
            "transcript_path": transcript_path,
        }
    )

    state = {
        "provider_id": "qoder",
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": os.getppid(),
        "tty": get_tty(),
        "transcript_path": transcript_path,
    }

    # Map event to Coding Island session status
    if event == "UserPromptSubmit":
        state["status"] = "processing"
        if prompt_text:
            state["message"] = prompt_text

    elif event == "PreToolUse":
        state["status"] = "running_tool"
        state["tool"] = tool_name
        state["tool_input"] = tool_input
        if tool_use_id:
            state["tool_use_id"] = tool_use_id

    elif event == "PostToolUse":
        state["status"] = "processing"
        state["tool"] = tool_name
        state["tool_input"] = tool_input
        if tool_use_id:
            state["tool_use_id"] = tool_use_id

    elif event == "PostToolUseFailure":
        state["status"] = "processing"
        state["tool"] = tool_name
        state["tool_input"] = tool_input
        state["tool_error"] = data.get("error")
        if tool_use_id:
            state["tool_use_id"] = tool_use_id

    elif event == "Stop":
        state["status"] = "waiting_for_input"

    else:
        state["status"] = "unknown"

    send_event(state)
    sys.exit(0)


if __name__ == "__main__":
    main()
