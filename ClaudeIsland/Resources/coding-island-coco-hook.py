#!/usr/bin/env python3
"""
Coding Island Hook (Coco/Trae CLI)
- Sends Coco agent state to CodingIsland.app via Unix socket
- Supports PermissionRequest with user decision response
- Compatible with Coco (Trae CLI) hook system
"""

import json
import os
import socket
import sys
import subprocess
import time

SOCKET_PATH = os.path.expanduser("~/.coding-island/coding-island.sock")
# Overall budget for waiting on a permission decision from CodingIsland.
# Note: Coco's hook config must have a timeout >= this value.
TIMEOUT_SECONDS = 300  # 5 minutes (non-permission events)
DUAL_APPROVAL_TIMEOUT = 3  # Short wait for fast Coding Island approval;
                           # after timeout, CLI shows its own permission UI
PROVIDER_ID = "coco"


def get_tty():
    """Get the TTY of the Coco process (parent)"""
    ppid = os.getppid()

    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2
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
    except (OSError, AttributeError):
        pass

    try:
        return os.ttyname(sys.stdout.fileno())
    except (OSError, AttributeError):
        pass

    return None

def get_real_coco_process():
    """Find the actual Coco process ID by walking up the process tree"""
    pid = os.getppid()
    try:
        current_pid = str(pid)
        for _ in range(10):  # Safety limit
            result = subprocess.run(
                ["ps", "-p", current_pid, "-o", "comm=,ppid="],
                capture_output=True,
                text=True,
                timeout=1
            )
            output = result.stdout.strip().split()
            if len(output) >= 2:
                # comm might contain spaces (e.g. "Flux Island"), so we take all but last as comm
                # or simpler: just check if 'coco' or 'trae' is anywhere in the output
                if "coco" in result.stdout.lower() or "trae" in result.stdout.lower():
                    return int(current_pid)
                
                # Get PPID (last item)
                ppid = output[-1]
                current_pid = ppid
                if current_pid in ("0", "1", ""):
                    break
    except Exception:
        pass
        
    return pid

def get_cwd_for_pid(pid):
    try:
        result = subprocess.run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"], capture_output=True, text=True, timeout=2)
        for line in result.stdout.splitlines():
            if line.startswith("n"):
                return line[1:]
    except Exception:
        pass
    return None

def _try_get_mtime(path):
    if not path:
        return None
    try:
        return os.path.getmtime(path)
    except Exception:
        return None


def _resolve_transcript_path(session_id, transcript_path):
    # Prefer the path provided by Coco, if it exists.
    if transcript_path:
        try:
            if os.path.exists(transcript_path):
                return transcript_path
        except Exception:
            pass

    # Fallback to Coco cache locations used by CodingIsland's parser.
    home = os.path.expanduser("~")
    candidates = [
        f"{home}/Library/Caches/coco/sessions/{session_id}/traces.jsonl",
        f"{home}/Library/Caches/coco/sessions/{session_id}/events.jsonl",
    ]
    for p in candidates:
        try:
            if os.path.exists(p):
                return p
        except Exception:
            continue

    return transcript_path or None


def send_event(state, wait_for_response=False, transcript_path=None):
    """Send event to app, return response if any.

    For permission requests (wait_for_response=True), uses a short timeout
    (DUAL_APPROVAL_TIMEOUT) so the CLI can show its own permission UI
    concurrently. If the app responds within the timeout, the decision
    is returned; otherwise None is returned and the hook exits silently.
    """
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

        # Wait for response with short timeout (dual-approval mode)
        try:
            sock.settimeout(DUAL_APPROVAL_TIMEOUT)
            response = sock.recv(4096)
            if response:
                return json.loads(response.decode())
        except socket.timeout:
            # Dual-approval mode: timeout reached, CLI will show its own UI
            return None
        except (json.JSONDecodeError, OSError):
            pass

        return None
    except Exception as e:
        # Log error but don't fail the hook
        try:
            print(f"CocoIsland hook error: {e}", file=sys.stderr)
        except Exception:
            pass
        try:
            with open("/tmp/hook-error.log", "a") as f:
                f.write(f"Error: {e}\n")
        except Exception:
            pass
        return None
    finally:
        try:
            if sock is not None:
                sock.close()
        except Exception:
            pass

def main():
    try:
        raw_data = sys.stdin.read()
        with open("/tmp/coco-raw-event.log", "a") as f:
            f.write(raw_data + "\n")
        data = json.loads(raw_data)
    except json.JSONDecodeError:
        sys.exit(1)

    # Extract common fields
    session_id = data.get("session_id", "unknown")
    event = data.get("hook_event_name", "")
    
    pid = get_real_coco_process()
    tty = get_tty()
    
    # Try to get real cwd from parent process, otherwise fallback
    real_cwd = get_cwd_for_pid(pid)
    cwd = data.get("cwd") or real_cwd or os.getcwd()
    
    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input", {})
    permission_mode = data.get("permission_mode", "default")
    transcript_path = data.get("transcript_path", "")
    resolved_transcript_path = _resolve_transcript_path(session_id, transcript_path)

    # Build state object with unified format
    state = {
        "provider_id": PROVIDER_ID,
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": pid,
        "tty": tty,
        "tool": tool_name,
        "tool_input": tool_input,
        "permission_mode": permission_mode,
        "transcript_path": transcript_path,
    }

    # Normalize event name for comparisons to handle both CamelCase and snake_case
    normalized_event = event.lower().replace("_", "")

    # === Event-to-status mapping ===

    if normalized_event == "userpromptsubmit":
        prompt = data.get("prompt", "")
        state["status"] = "processing"
        state["message"] = prompt[:200] if prompt else None

    elif normalized_event == "pretooluse":
        state["status"] = "running_tool"
        # Coco may not have tool_use_id, create one from session + tool name
        state["tool_use_id"] = data.get("tool_use_id") or f"{session_id}:{tool_name}"

    elif normalized_event == "posttooluse":
        state["status"] = "processing"
        tool_response = data.get("tool_response", "")
        state["tool_result"] = tool_response[:500] if tool_response else None  # Truncate for display
        state["tool_use_id"] = data.get("tool_use_id") or f"{session_id}:{tool_name}"

    elif normalized_event == "posttoolusefailure":
        error = data.get("error", "Unknown error")
        state["status"] = "processing"  # Main session continues
        state["error"] = error
        state["tool_use_id"] = data.get("tool_use_id") or f"{session_id}:{tool_name}"

    elif normalized_event == "notification":
        notification_type = data.get("notification_type", "")
        title = data.get("title", "")
        message = data.get("message", "")

        # Skip permission_prompt - handled by permission_request event
        if notification_type == "permission_prompt":
            sys.exit(0)
        elif notification_type == "idle_prompt":
            state["status"] = "waiting_for_input"
        elif notification_type == "elicitation_dialog":
            state["status"] = "waiting_for_input"
        else:
            state["status"] = "notification"

        state["notification_type"] = notification_type
        state["message"] = f"{title}: {message}" if title else message

    elif normalized_event == "stop":
        state["status"] = "waiting_for_input"

    elif normalized_event == "subagentstart":
        agent_id = data.get("agent_id", "")
        agent_type = data.get("agent_type", "")
        state["status"] = "processing"
        state["agent_id"] = agent_id
        state["agent_type"] = agent_type

    elif normalized_event == "subagentstop":
        state["status"] = "processing"

    elif normalized_event == "sessionstart":
        source = data.get("source", "startup")  # startup/resume/clear
        state["status"] = "waiting_for_input"
        state["source"] = source

    elif normalized_event == "sessionend":
        reason = data.get("reason", "other")  # clear/resume/prompt_input_exit/other
        state["status"] = "ended"
        state["end_reason"] = reason

    elif normalized_event == "precompact":
        state["status"] = "compacting"

    elif normalized_event == "postcompact":
        compact_summary = data.get("compact_summary", "")
        state["status"] = "processing"
        state["compact_summary"] = compact_summary

    elif normalized_event == "permissionrequest":
        # === Critical: Permission request handling ===
        state["status"] = "waiting_for_approval"
        state["tool_use_id"] = data.get("tool_use_id") or f"{session_id}:{tool_name}"
        state["dual_approval_mode"] = True

        # Send to app and wait for decision (short timeout)
        response = send_event(state, wait_for_response=True, transcript_path=resolved_transcript_path)

        if response:
            decision = response.get("decision", "ask")
            reason = response.get("reason", "")

            if decision == "allow":
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": event,
                        "decision": {"behavior": "allow"}
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

            elif decision == "deny":
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": event,
                        "decision": {
                            "behavior": "deny",
                            "message": reason or "Denied by user via CodingIsland"
                        }
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

        # No response (timeout) — output "ask" so CLI shows its own permission UI
        output = {
            "hookSpecificOutput": {
                "hookEventName": event,
                "decision": {"behavior": "ask"}
            }
        }
        print(json.dumps(output))
        sys.exit(0)

    else:
        state["status"] = "unknown"

    # Send to socket (fire and forget for non-permission events)
    send_event(state, wait_for_response=False)

if __name__ == "__main__":
    main()
