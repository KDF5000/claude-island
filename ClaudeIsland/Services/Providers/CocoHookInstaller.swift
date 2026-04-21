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

        // Remove existing Coco Island hooks first
        content = removeHooksFromContent(content)

        // Build the hook entry (without the "hooks:" prefix)
        let python = detectPython()
        let command = "\(python) \(CocoPaths.hookScriptShellPath)"
        let hookEntry = """
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

        // Check if hooks section exists
        if let hooksRange = content.range(of: "hooks:") {
            // Find the end of hooks section (next top-level key or end of file)
            let afterHooks = content[hooksRange.upperBound...]
            var insertIndex = content.endIndex

            // Find where to insert (after existing hooks, before next top-level key)
            let lines = content[content.index(after: hooksRange.lowerBound)...].components(separatedBy: "\n")
            var currentPos = hooksRange.upperBound
            for line in lines {
                // A new top-level key starts with a non-space character at the beginning of a line
                if !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.hasPrefix("#") && !line.hasPrefix("-") {
                    insertIndex = content.index(currentPos, offsetBy: -line.count - 1)
                    break
                }
                currentPos = content.index(currentPos, offsetBy: line.count + 1)
            }

            if insertIndex == content.endIndex {
                // Insert at the end
                content += "\n" + hookEntry
            } else {
                // Insert before the next top-level key
                content.insert(contentsOf: "\n" + hookEntry, at: insertIndex)
            }
        } else {
            // No hooks section, create one
            if !content.isEmpty && !content.hasSuffix("\n") {
                content += "\n"
            }
            content += "\nhooks:\n" + hookEntry
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

        // Default to ~/.config/coco/config.yaml
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
