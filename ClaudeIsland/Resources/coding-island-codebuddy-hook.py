#!/usr/bin/env python3
"""Coding Island Hook (CodeBuddy)

Forwards CodeBuddy hook events to Coding Island via Unix socket.
Implements PreToolUse permission control using CodeBuddy's hook stdout protocol.
"""

import fcntl
import json
import os
import socket
import subprocess
import sys
import tempfile
import uuid


SOCKET_PATH = os.path.expanduser("~/.coding-island/coding-island.sock")
TIMEOUT_SECONDS = 300
STATE_DIR = os.path.expanduser("~/.coding-island")
STATE_PATH = os.path.join(STATE_DIR, "codebuddy-hook-state.json")
LOCK_PATH = os.path.join(STATE_DIR, "codebuddy-hook-state.lock")
PROVIDER_ID = "codebuddy"
DEBUG_LOG_PATH = "/tmp/codebuddy-hook.log"


def ensure_state_dir():
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
    except Exception:
        pass


def get_tty():
    """Best-effort TTY detection for the parent CodeBuddy process."""
    ppid = os.getppid()

    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2,
        )
        tty = result.stdout.strip()
        if tty and tty not in ("??", "-"):
            if not tty.startswith("/dev/"):
                tty = "/dev/" + tty
            return tty
    except Exception:
        pass

    try:
        return os.ttyname(sys.stdin.fileno())
    except Exception:
        pass

    try:
        return os.ttyname(sys.stdout.fileno())
    except Exception:
        pass

    return None


def tool_cache_key(session_id, tool_name, tool_input):
    try:
        input_json = json.dumps(tool_input or {}, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    except Exception:
        input_json = "{}"
    return f"{session_id}:{tool_name or 'unknown'}:{input_json}"


def with_locked_state(mutator):
    ensure_state_dir()
    with open(LOCK_PATH, "a+", encoding="utf-8") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)

        state = {"tool_ids": {}}
        try:
            if os.path.exists(STATE_PATH):
                with open(STATE_PATH, "r", encoding="utf-8") as f:
                    loaded = json.load(f)
                    if isinstance(loaded, dict):
                        state = loaded
        except Exception:
            state = {"tool_ids": {}}

        state.setdefault("tool_ids", {})
        result = mutator(state)

        tmp_fd, tmp_path = tempfile.mkstemp(prefix="codebuddy-hook-state-", dir=STATE_DIR)
        try:
            with os.fdopen(tmp_fd, "w", encoding="utf-8") as tmp_file:
                json.dump(state, tmp_file, ensure_ascii=False, sort_keys=True)
            os.replace(tmp_path, STATE_PATH)
        finally:
            if os.path.exists(tmp_path):
                try:
                    os.remove(tmp_path)
                except Exception:
                    pass

        return result


def enqueue_tool_use_id(session_id, tool_name, tool_input):
    tool_use_id = f"codebuddy-{uuid.uuid4()}"
    key = tool_cache_key(session_id, tool_name, tool_input)

    def mutate(state):
        queue = state["tool_ids"].setdefault(key, [])
        queue.append(tool_use_id)
        return tool_use_id

    return with_locked_state(mutate)


def dequeue_tool_use_id(session_id, tool_name, tool_input):
    key = tool_cache_key(session_id, tool_name, tool_input)

    def mutate(state):
        queue = state["tool_ids"].get(key) or []
        tool_use_id = queue.pop(0) if queue else None
        if queue:
            state["tool_ids"][key] = queue
        else:
            state["tool_ids"].pop(key, None)
        return tool_use_id

    return with_locked_state(mutate)


def clear_session_state(session_id):
    prefix = f"{session_id}:"

    def mutate(state):
        for key in list(state["tool_ids"].keys()):
            if key.startswith(prefix):
                state["tool_ids"].pop(key, None)
        return None

    with_locked_state(mutate)


def send_event(state, wait_for_response=False):
    sock = None
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode("utf-8"))

        if not wait_for_response:
            return None

        response = sock.recv(4096)
        if response:
            return json.loads(response.decode("utf-8"))
    except Exception:
        return None
    finally:
        try:
            if sock is not None:
                sock.close()
        except Exception:
            pass

    return None


def append_debug_log(message):
    try:
        with open(DEBUG_LOG_PATH, "a", encoding="utf-8") as f:
            f.write(message + "\n")
    except Exception:
        pass


def build_permission_output(decision, reason=None):
    decision = decision if decision in ("allow", "deny", "ask") else "ask"
    hook_output = {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
    }

    if reason:
        hook_output["permissionDecisionReason"] = reason

    return {
        "continue": decision != "deny",
        "hookSpecificOutput": hook_output,
    }


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    session_id = data.get("session_id", "unknown")
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd") or os.getcwd()
    transcript_path = data.get("transcript_path")
    tool_name = data.get("tool_name")
    tool_input = data.get("tool_input") or {}

    append_debug_log(f"event={event} session_id={session_id} transcript_path={transcript_path}")

    state = {
        "provider_id": PROVIDER_ID,
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": os.getppid(),
        "tty": get_tty(),
        "transcript_path": transcript_path,
    }

    if event == "SessionStart":
        state["status"] = "waiting_for_input"

    elif event == "SessionEnd":
        state["status"] = "ended"
        clear_session_state(session_id)

    elif event == "UserPromptSubmit":
        state["status"] = "processing"
        prompt = data.get("prompt")
        if isinstance(prompt, str) and prompt.strip():
            state["message"] = prompt.strip()

    elif event == "PreToolUse":
        tool_use_id = enqueue_tool_use_id(session_id, tool_name, tool_input)
        state["status"] = "waiting_for_approval"
        state["tool"] = tool_name
        state["tool_input"] = tool_input
        state["tool_use_id"] = tool_use_id

        response = send_event(state, wait_for_response=True) or {}
        decision = response.get("decision", "ask")
        reason = response.get("reason")
        print(json.dumps(build_permission_output(decision, reason), ensure_ascii=False))
        sys.exit(0)

    elif event == "PostToolUse":
        tool_use_id = dequeue_tool_use_id(session_id, tool_name, tool_input)
        state["status"] = "processing"
        state["tool"] = tool_name
        state["tool_input"] = tool_input
        if tool_use_id:
            state["tool_use_id"] = tool_use_id

    elif event == "Stop":
        state["status"] = "waiting_for_input"

    else:
        state["status"] = "unknown"

    send_event(state, wait_for_response=False)
    sys.exit(0)


if __name__ == "__main__":
    main()
