<div align="center">
  <img src="ClaudeIsland/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="Logo" width="100" height="100">
  <h3 align="center">Claude Island</h3>
  <p align="center">
    一款 macOS 菜单栏应用，为编程 Agent 会话带来类似灵动岛（Dynamic Island）风格的通知体验。
    <br />
    <br />
    Fork 自 <a href="https://github.com/farouqaldori/claude-island" target="_blank" rel="noopener noreferrer">farouqaldori/claude-island</a>，并针对多 Agent 工作流进行了扩展。
  </p>
</div>

> 本仓库是 `farouqaldori/claude-island` 的 Fork 版本。
>
> 它保留了原版的 macOS 灵动岛风格体验，并扩展了多 Provider 支持、远程会话工作流、历史 Token 统计等一系列实用改进。

## 为什么有这个 Fork

上游项目最初是一个精致的 Dynamic Island 风格的 Claude Code 伴侣应用。

这个 Fork 保留了核心理念，但进一步面向那些需要在不同编程 Agent 之间切换、跨本地和远程机器工作、并且希望拥有更好日常工作流工具的用户。

## 功能特性

- **多 Agent 支持** — 通过共享的 Provider 架构，同时支持 `Claude Code` 和 `Coco` / `Trae` 风格的会话
- **灵动岛 UI** — 从 MacBook 刘海处展开的动画悬浮层，让活跃会话触手可及
- **实时会话监控** — 实时追踪多个本地会话，带有 Provider 标识和单会话 Token 统计
- **远程会话工作流** — 通过 SSH 反向隧道和远程 Hook 集成，监控远程 Agent 会话
- **权限审批** — 直接从灵动岛批准或拒绝工具执行请求，必要时支持回退到终端操作
- **聊天历史查看器** — 浏览对话历史，支持 Markdown 渲染、工具执行结果、Diff 和更丰富的消息解析
- **Token 用量统计** — 按 Agent 查看全局 Token 统计，包括从现有会话日志导入历史数据和手动重建
- **更智能的配置和路径** — 自动安装 Hook，支持 `~/.coding-island` 下的共享应用路径，处理常见的 Claude 配置位置
- **全方位的工作流优化** — 更好的完成提示、会话状态处理、设置界面优化等各种体验改进

## 系统要求

- macOS 15.6+
- `Claude Code` CLI 和/或 `Coco` / `Trae` CLI
- 可选：`ssh`、`tmux` 和 `yabai`（用于远程和终端工作流）

## 安装

从源码构建：

```bash
xcodebuild -scheme ClaudeIsland -configuration Release build
```

构建完成后，从 Xcode 的构建产物目录启动应用，或将其移动到 `/Applications` 以供日常使用。

## 工作原理

Claude Island 通过 Unix Socket 监听 Agent 事件，并在灵动岛悬浮层中渲染。

对于本地工作流，应用会为支持的 Provider 自动安装 Hook，并在 `~/.coding-island/` 下维护共享状态。

对于远程工作流，它可以通过 SSH 隧道接收从远程机器转发回来的事件。

当 Agent 需要运行工具的权限时，灵动岛会展开并显示批准和拒绝按钮，无需切换回终端即可完成操作。

## Fork 说明

- 这不是上游的官方仓库。如果你需要原版项目，请前往 `farouqaldori/claude-island`。
- 如果你需要支持多 Agent 和远程工作流的扩展版本，这个 Fork 正是为此定制的。

## 数据分析

Claude Island 使用 Mixpanel 收集匿名使用数据：

- **App Launched** — 应用版本、构建号、macOS 版本
- **Session Started** — 检测到新的编程会话时触发

不会收集任何个人数据或对话内容。

## 许可证

Apache 2.0
