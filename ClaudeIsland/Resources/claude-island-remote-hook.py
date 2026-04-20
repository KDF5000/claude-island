#!/usr/bin/env python3
"""
Claude Island Remote Hook
- For use on remote servers accessed via SSH
- Connects to local Claude Island via SSH tunnel (Unix socket or TCP)
- Install: Copy to remote server and configure in coco/claude settings
"""

import json
import os
import socket
import sys
import subprocess

# Unix socket path (forwarded via SSH -R)
SOCKET_PATH = "/tmp/claude-island.sock"

# TCP fallback (forwarded via SSH -R 19999:127.0.0.1:19999)
TCP_HOST = "127.0.0.1"
TCP_PORT = 19999

TIMEOUT_SECONDS = 300  # 5 minutes for permission decisions
PROVIDER_ID = "coco-remote"  # Will be overridden by actual provider

# Per-session JSONL byte offsets (tracks how much we've already sent)
_jsonl_offsets = {}


def read_new_jsonl_lines(jsonl_path, session_id):
    """Read new lines from a JSONL file since the last read offset.
    Returns list of raw line strings (not parsed)."""
    if not jsonl_path or not os.path.isfile(jsonl_path):
        return []
    offset = _jsonl_offsets.get(session_id, 0)
    try:
        with open(jsonl_path, "rb") as f:
            f.seek(0, 2)  # end
            file_size = f.tell()
            if file_size <= offset:
                return []
            f.seek(offset)
            new_bytes = f.read()
            _jsonl_offsets[session_id] = file_size
        lines = []
        for raw in new_bytes.decode("utf-8", errors="replace").splitlines():
            raw = raw.strip()
            if raw:
                lines.append(raw)
        return lines
    except OSError:
        return []


def get_tty():
    """Get the TTY of the process"""
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
    
    return None


def _try_get_mtime(path):
    if not path:
        return None
    try:
        return os.path.getmtime(path)
    except Exception:
        return None

def send_event(state, wait_for_response=False, transcript_path=None):
    """Send event to app via SSH tunnel, return response if any"""
    
    sock = None
    # Try Unix socket first (if forwarded via SSH -R)
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
            
        start_mtime = _try_get_mtime(transcript_path)
        deadline = time.time() + TIMEOUT_SECONDS
        
        while time.time() < deadline:
            # For Coco, any transcript change means the user interacted with the terminal
            # so we should stop waiting and let the terminal take over
            current_mtime = _try_get_mtime(transcript_path)
            if start_mtime is not None and current_mtime is not None and current_mtime > start_mtime:
                # The user likely answered the prompt in the terminal
                return {"decision": "ask"}
                
            try:
                sock.settimeout(0.25)
                response = sock.recv(4096)
                if not response:
                    break
                return json.loads(response.decode())
            except socket.timeout:
                continue
            except json.JSONDecodeError:
                break
            except Exception:
                break
                
        return None
    except (socket.error, OSError, FileNotFoundError):
        if sock:
            try:
                sock.close()
            except Exception:
                pass
        sock = None
        pass

    # Fall back to TCP (if forwarded via SSH -R port:port)
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(2)
        sock.connect((TCP_HOST, TCP_PORT))
        sock.sendall(json.dumps(state).encode())

        if not wait_for_response:
            try:
                sock.close()
            except Exception:
                pass
            return None
            
        start_mtime = _try_get_mtime(transcript_path)
        deadline = time.time() + TIMEOUT_SECONDS
        
        while time.time() < deadline:
            # For Coco, any transcript change means the user interacted with the terminal
            # so we should stop waiting and let the terminal take over
            current_mtime = _try_get_mtime(transcript_path)
            if start_mtime is not None and current_mtime is not None and current_mtime > start_mtime:
                # The user likely answered the prompt in the terminal
                return {"decision": "ask"}
                
            try:
                sock.settimeout(0.25)
                response = sock.recv(4096)
                if not response:
                    break
                return json.loads(response.decode())
            except socket.timeout:
                continue
            except json.JSONDecodeError:
                break
            except Exception:
                break
                
        return None
    except (socket.error, OSError, json.JSONDecodeError) as e:
        print(f"ClaudeIsland remote hook error: {e}", file=sys.stderr)
        return None
    finally:
        try:
            if sock is not None:
                sock.close()
        except Exception:
            pass


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    # Detect provider from hook event name format
    event = data.get("hook_event_name", "")
    
    # Extract common fields
    session_id = data.get("session_id", "unknown")
    cwd = data.get("cwd") or os.getcwd()
    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input", {})
    
    # Check if this is a Coco agent_end or other top-level message that might not have a proper hook event name
    if not event:
        if "agent_end" in data:
            event = "agent_end"
        elif "message" in data and isinstance(data["message"], dict):
            event = "userpromptsubmit" # Default fallback for messages that don't specify an event
            
    # Try to extract the actual tool_call_id from Coco payloads
    actual_tool_use_id = data.get("tool_call_id") or data.get("tool_use_id")
    
    # Determine provider
    # Claude Code provides transcript_path in hook events.
    # Coco does not, so if it's empty, we assume it's Coco.
    transcript_path = data.get("transcript_path", "")
    if transcript_path:
        provider_id = "claude-code"
    else:
        provider_id = "coco"

    # Get process info
    pid = os.getppid()
    tty = get_tty()

    # Get JSONL transcript path.
    # Claude Code provides transcript_path in hook events.
    # Coco does not, so we derive the path from the well-known cache location.
    # Note: traces.jsonl contains OpenTelemetry spans (not messages); events.jsonl
    # has the actual conversation in agent_start/message/tool_call format.
    _path_debug = []
    if not transcript_path and provider_id == "coco":
        import platform
        home = os.path.expanduser("~")
        _path_debug.append(f"home={home} platform={platform.system()}")
        if platform.system() == "Darwin":
            coco_cache_base = os.path.join(home, "Library", "Caches", "coco", "sessions", session_id)
        else:
            # Linux / other: try XDG_CACHE_HOME first, then ~/.cache
            xdg_cache = os.environ.get("XDG_CACHE_HOME", os.path.join(home, ".cache"))
            coco_cache_base = os.path.join(xdg_cache, "coco", "sessions", session_id)
        # events.jsonl has conversation messages; traces.jsonl is OpenTelemetry spans only
        coco_events = os.path.join(coco_cache_base, "events.jsonl")
        _path_debug.append(f"coco_events={coco_events} exists={os.path.isfile(coco_events)}")
        if os.path.isfile(coco_events):
            transcript_path = coco_events
        else:
            # Also try ~/.config/coco and other common locations
            for alt_base in [
                os.path.join(home, ".config", "coco", "sessions", session_id),
                os.path.join(home, ".local", "share", "coco", "sessions", session_id),
            ]:
                alt_events = os.path.join(alt_base, "events.jsonl")
                _path_debug.append(f"alt={alt_events} exists={os.path.isfile(alt_events)}")
                if os.path.isfile(alt_events):
                    transcript_path = alt_events
                    break

    # Build state object
    state = {
        "provider_id": provider_id,
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": pid,
        "tty": tty,
        "tool": tool_name,
        "tool_input": tool_input,
        "transcript_path": transcript_path,
        "remote_path_debug": _path_debug,
    }

    # === Event-to-status mapping ===
    
    normalized_event = event.lower().replace("_", "")
    
    if normalized_event == "userpromptsubmit":
        prompt = data.get("prompt", "")
        state["status"] = "processing"
        state["message"] = prompt[:200] if prompt else None
        
    elif normalized_event == "pretooluse":
        state["status"] = "running_tool"
        state["tool_use_id"] = actual_tool_use_id or f"{session_id}:{tool_name}"
        
    elif normalized_event == "posttooluse":
        state["status"] = "processing"
        tool_response = data.get("tool_response", "")
        state["tool_result"] = tool_response[:500] if tool_response else None
        state["tool_use_id"] = actual_tool_use_id or f"{session_id}:{tool_name}"
        
    elif normalized_event == "posttoolusefailure":
        error = data.get("error", "Unknown error")
        state["status"] = "processing"
        state["error"] = error
        state["tool_use_id"] = actual_tool_use_id or f"{session_id}:{tool_name}"
        
    elif normalized_event == "notification":
        notification_type = data.get("notification_type", "")
        title = data.get("title", "")
        message = data.get("message", "")
        
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
        source = data.get("source", "startup")
        state["status"] = "waiting_for_input"
        state["source"] = source
        
    elif normalized_event == "sessionend":
        reason = data.get("reason", "other")
        state["status"] = "ended"
        state["end_reason"] = reason
        
    elif normalized_event == "agent_end" or normalized_event == "agentend":
        state["status"] = "waiting_for_input"
        state["event"] = "agent_end"  # Ensure event is explicitly set so it determines the phase
        
    elif normalized_event == "precompact":
        state["status"] = "compacting"
        
    elif normalized_event == "postcompact":
        compact_summary = data.get("compact_summary", "")
        state["status"] = "processing"
        state["compact_summary"] = compact_summary
        
    elif normalized_event == "permissionrequest":
        # === Critical: Permission request handling ===
        state["status"] = "waiting_for_approval"
        state["tool_use_id"] = actual_tool_use_id or f"{session_id}:{tool_name}"
        
        # Send to app and wait for decision
        response = send_event(state, wait_for_response=True, transcript_path=transcript_path)
        
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
                            "message": reason or "Denied by user via ClaudeIsland"
                        }
                    }
                }
                print(json.dumps(output))
                sys.exit(0)
        
        # We MUST print empty output so Coco doesn't block waiting for hook output
        print("{}")
        sys.exit(0)
        
    else:
        state["status"] = "unknown"

    # Send to socket (fire and forget for non-permission events)
    # Attach any new JSONL lines so the Mac app can build message history
    if transcript_path:
        new_lines = read_new_jsonl_lines(transcript_path, session_id)
        if new_lines:
            state["remote_jsonl_lines"] = new_lines
    elif provider_id == "coco":
        # Check standard Coco events location
        home_dir = os.path.expanduser("~")
        events_path = os.path.join(home_dir, "Library/Caches/coco/sessions", session_id, "events.jsonl")
        if os.path.exists(events_path):
            new_lines = read_new_jsonl_lines(events_path, session_id)
            if new_lines:
                state["remote_jsonl_lines"] = new_lines
            
    send_event(state)


if __name__ == "__main__":
    main()
