//
//  CocoHookInstaller.swift
//  ClaudeIsland
//
//  Installs hooks for Coco (Trae CLI) agent
//  Manages YAML config file updates
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.codingisland", category: "CocoHooks")

struct CocoHookInstaller {

    // MARK: - Installation

    /// Install Coco hooks
    static func install() {
        // 1. Ensure shared hooks directory exists
        IslandPaths.ensureDirectoriesExist()

        // 2. Copy Python hook script
        let hookScript = IslandPaths.cocoHookScriptPath
        if let bundled = Bundle.main.url(forResource: "coding-island-coco-hook", withExtension: "py") {
            // Remove existing and copy new
            try? FileManager.default.removeItem(at: hookScript)
            try? FileManager.default.copyItem(at: bundled, to: hookScript)

            // Make executable
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: hookScript.path
            )

            logger.info("Installed Coco hook script")
        } else {
            logger.warning("Could not find bundled coding-island-coco-hook.py")
        }

        // 3. Update Coco config file
        updateConfigFile()
    }

    /// Uninstall Coco hooks
    static func uninstall() {
        // Remove hook script
        try? FileManager.default.removeItem(at: IslandPaths.cocoHookScriptPath)

        // Remove hooks from config
        removeHooksFromConfig()

        logger.info("Uninstalled Coco hooks")
    }

    /// Check if hooks are installed
    static func isInstalled() -> Bool {
        // Check if hook script exists
        guard FileManager.default.fileExists(atPath: IslandPaths.cocoHookScriptPath.path) else {
            return false
        }

        // Check if config has our hooks
        let configContent = readConfigFile()
        return configContent.contains("coding-island-coco-hook.py")
    }

    // MARK: - Config File Management

    private static func updateConfigFile() {
        let configPath = resolveConfigPath()
        var content = readConfigFile(at: configPath)

        // 先删掉旧的 Coding Island hook，避免重复条目
        content = removeHooksFromContent(content)

        // 构造新的 hook 块（不包含 "hooks:" 前缀）
        let python = detectPython()
        let command = "\(python) \(CocoPaths.hookScriptShellPath)"
        let hookBlock = """
  # Coding Island hook for Coco/Trae CLI (all events)
  - type: command
    command: \(command)
    # Allow enough time for Island-driven permission decisions.
    # The hook script will stop waiting early if the CLI proceeds.
    timeout: 310s
    matchers:
      - event: user_prompt_submit
      - event: pre_tool_use
      - event: post_tool_use
      - event: post_tool_use_failure
      - event: permission_request
      - event: notification
      - event: stop
      - event: subagent_start
      - event: subagent_stop
      - event: session_start
      - event: session_end
      - event: pre_compact
      - event: post_compact
"""

        // 如果已有 hooks: 段，直接整体替换该段，避免字符串定位出错导致 YAML 损坏
        var lines = content.components(separatedBy: "\n")
        if let hooksIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "hooks:" }) {
            var endIndex = lines.count

            // 找到 hooks 段结束位置（下一个顶级 key，或者文件结束）
            for i in (hooksIndex + 1)..<lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty,
                   !lines[i].hasPrefix(" "),
                   !lines[i].hasPrefix("\t"),
                   !trimmed.hasPrefix("#") {
                    endIndex = i
                    break
                }
            }

            let beforeHooks = Array(lines[0...hooksIndex])
            let afterHooks = endIndex < lines.count ? Array(lines[endIndex...]) : []

            var newLines = beforeHooks
            newLines.append(contentsOf: hookBlock.components(separatedBy: "\n"))
            newLines.append(contentsOf: afterHooks)
            content = newLines.joined(separator: "\n")
        } else {
            // 没有 hooks:，在文件末尾新增一个 hooks 段
            if !content.isEmpty && !content.hasSuffix("\n") {
                content += "\n"
            }
            content += "\n" + "hooks:\n" + hookBlock
        }

        // Ensure directory exists
        try? FileManager.default.createDirectory(
            at: configPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Write updated config
        do {
            try content.write(to: configPath, atomically: true, encoding: .utf8)
            logger.info("Updated Coco config at \(configPath.path, privacy: .public)")
        } catch {
            logger.error("Failed to write Coco config: \(error, privacy: .public)")
        }
    }

    private static func removeHooksFromConfig() {
        let configPath = resolveConfigPath()
        var content = readConfigFile(at: configPath)

        content = removeHooksFromContent(content)

        do {
            try content.write(to: configPath, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to remove hooks from Coco config: \(error, privacy: .public)")
        }
    }

    private static func resolveConfigPath() -> URL {
        // Prefer existing config file
        if FileManager.default.fileExists(atPath: CocoPaths.configFile.path) {
            return CocoPaths.configFile
        }
        if FileManager.default.fileExists(atPath: CocoPaths.altConfigFile.path) {
            return CocoPaths.altConfigFile
        }

        // Default to Trae CLI 路径（~/.trae/traecli.yaml）
        return CocoPaths.configFile
    }

    private static func readConfigFile(at path: URL? = nil) -> String {
        let configPath = path ?? resolveConfigPath()
        guard let data = try? Data(contentsOf: configPath),
              let content = String(data: data, encoding: .utf8) else {
            return ""
        }
        return content
    }

    private static func removeHooksFromContent(_ content: String) -> String {
        // Simple approach: remove hook entries that reference coco-island-state.py
        // This is a basic implementation; a proper YAML parser would be more robust

        var lines = content.components(separatedBy: "\n")
        var result: [String] = []
        var skipUntilNextTopLevel = false
        var inHooksSection = false
        var currentHookIndent = 0

        for (index, line) in lines.enumerated() {
            // Detect hooks section start
            if line.trimmingCharacters(in: .whitespaces) == "hooks:" {
                inHooksSection = true
                result.append(line)
                continue
            }

            // Detect end of hooks section (new top-level key)
            if inHooksSection && !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.hasPrefix("#") {
                inHooksSection = false
            }

            if inHooksSection {
                // Check if this is a new hook entry
                if line.hasPrefix("  - type:") {
                    // Look ahead to see if this hook references our script
                    let hookBlockStart = index
                    var hookBlock: [String] = [line]

                    // Collect the full hook block
                    for j in (index + 1)..<lines.count {
                        let nextLine = lines[j]
                        // Check if we've reached the next hook or end of hooks section
                        if nextLine.hasPrefix("  - ") || (!nextLine.hasPrefix("    ") && !nextLine.isEmpty && !nextLine.hasPrefix("#")) {
                            break
                        }
                        hookBlock.append(nextLine)
                    }

                    // Check if this hook contains our script reference
                    let blockContent = hookBlock.joined(separator: "\n")
                    if blockContent.contains("coding-island-coco-hook.py") || blockContent.contains("coco-island-state.py") {
                        // Skip this hook block
                        skipUntilNextTopLevel = true
                        currentHookIndent = 2
                        continue
                    } else {
                        skipUntilNextTopLevel = false
                    }
                }

                if skipUntilNextTopLevel {
                    // Check if we've reached the next hook
                    if line.hasPrefix("  - ") {
                        skipUntilNextTopLevel = false
                        // Re-check this line
                        if !line.contains("coding-island-coco-hook.py") && !line.contains("coco-island-state.py") {
                            result.append(line)
                        }
                    }
                    continue
                }
            }

            result.append(line)
        }

        return result.joined(separator: "\n")
    }

    // MARK: - YAML Generation

    private static func buildHooksYaml() -> String {
        let python = detectPython()
        let command = "\(python) \(CocoPaths.hookScriptShellPath)"

        // Generate a single hook entry with all matchers (cleaner than multiple entries)
        return """
# === Coding Island Hooks for Coco ===
hooks:
  # Coding Island hook for Coco/Trae CLI (all events)
  - type: command
    command: \(command)
    # Allow enough time for Island-driven permission decisions.
    # The hook script will stop waiting early if the CLI proceeds.
    timeout: 310s
    matchers:
      - event: user_prompt_submit
      - event: pre_tool_use
      - event: post_tool_use
      - event: post_tool_use_failure
      - event: permission_request
      - event: notification
      - event: stop
      - event: subagent_start
      - event: subagent_stop
      - event: session_start
      - event: session_end
      - event: pre_compact
      - event: post_compact
# === End Coding Island Hooks ===
"""
    }

    // MARK: - Helpers

    private static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "python3"
            }
        } catch {}

        return "python"
    }
}
