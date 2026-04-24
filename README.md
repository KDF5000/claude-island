<div align="center">
  <img src="ClaudeIsland/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="Logo" width="100" height="100">
  <h3 align="center">Claude Island</h3>
  <p align="center">
    A macOS menu bar app that brings Dynamic Island-style notifications to coding agent sessions.
    <br />
    <br />
    Forked from <a href="https://github.com/farouqaldori/claude-island" target="_blank" rel="noopener noreferrer">farouqaldori/claude-island</a>, then extended for multi-agent workflows.
  </p>
</div>

> This repository is a fork of `farouqaldori/claude-island`.
>
> It keeps the original notch-style macOS experience for Claude Code, and extends it with multi-provider support, remote session workflows, historical token stats, and a long list of quality-of-life improvements.

## Why This Fork

The upstream project started as a polished Dynamic Island-style companion for Claude Code.

This fork keeps that core idea, but pushes it further for people who switch between different coding agents, work across local and remote machines, and want better day-to-day workflow tooling instead of a thin session popup.

## Features

- **Multi-agent support** — Works with `Claude Code` and `Coco` / `Trae` style sessions through a shared provider architecture
- **Notch UI** — Animated overlay that expands from the MacBook notch and keeps active sessions one click away
- **Live session monitoring** — Track multiple local sessions in real time, with provider-aware badges and per-session token totals
- **Remote session workflows** — Monitor remote agent sessions over SSH with reverse tunnel support and remote hook integration
- **Permission approvals** — Approve or deny tool executions directly from the notch, with terminal fallback paths when needed
- **Chat history viewer** — Browse conversation history with markdown rendering, tool results, diffs, and richer message parsing
- **Token usage statistics** — See global token totals by agent, including historical import from existing session logs and manual rebuild
- **Smarter setup and paths** — Auto-installs hooks, supports shared app paths under `~/.coding-island`, and handles common Claude config locations
- **Small workflow upgrades everywhere** — Better completion prompts, session status handling, settings polish, and other quality-of-life improvements

## Requirements

- macOS 15.6+
- `Claude Code` CLI and/or `Coco` / `Trae` CLI
- Optional: `ssh`, `tmux`, and `yabai` for remote and terminal-focused workflows

## Install

Build from source:

```bash
xcodebuild -scheme ClaudeIsland -configuration Release build
```

Then launch the built app from Xcode's build products, or move it into `/Applications` if you are packaging it for daily use.

## How It Works

Claude Island listens for agent events over a Unix socket and renders them in the notch overlay.

For local workflows, the app installs hooks for supported providers and keeps its own shared state in `~/.coding-island/`.

For remote workflows, it can receive events forwarded back from remote machines over SSH tunnels.

When an agent needs permission to run a tool, the notch expands with approve and deny actions so you do not have to context switch back to the terminal unless you want to.

## Fork Notes

- This is not the canonical upstream repository. If you want the original project, go to `farouqaldori/claude-island`.
- If you want the extended version with multi-agent and remote-oriented workflow improvements, this fork is the one being customized here.

## Analytics

Claude Island uses Mixpanel to collect anonymous usage data:

- **App Launched** — App version, build number, macOS version
- **Session Started** — When a new supported coding session is detected

No personal data or conversation content is collected.

## License

Apache 2.0
