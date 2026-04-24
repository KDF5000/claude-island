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

        let python = detectPython()
        let command = "\(python) \(CocoPaths.hookScriptShellPath)"
        content = upsertCodingIslandHook(in: content, command: command)

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
        let markers = [
            "coding-island-coco-hook.py",
            "coco-island-state.py",
        ]

        return rewriteHooksSection(in: content, markers: markers, appendedHookBlock: nil)
    }

    private static func upsertCodingIslandHook(in content: String, command: String) -> String {
        let markers = [
            "coding-island-coco-hook.py",
            "coco-island-state.py",
        ]

        return rewriteHooksSection(
            in: content,
            markers: markers,
            appendedHookBlock: { itemIndent in
                buildHookBlock(command: command, itemIndent: itemIndent)
            }
        )
    }

    private static func rewriteHooksSection(
        in content: String,
        markers: [String],
        appendedHookBlock: ((String) -> String)?
    ) -> String {
        let lines = content.components(separatedBy: "\n")
        if let hooksIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "hooks:" }) {
            var endIndex = lines.count
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
            let hooksBody = hooksIndex + 1 < endIndex ? Array(lines[(hooksIndex + 1)..<endIndex]) : []
            let afterHooks = endIndex < lines.count ? Array(lines[endIndex...]) : []
            let itemIndent = detectHookItemIndent(in: hooksBody)

            var kept = filterHookBody(hooksBody, itemIndent: itemIndent, markers: markers)
            if let appendedHookBlock {
                if !kept.isEmpty, kept.last?.isEmpty == false {
                    kept.append("")
                }
                kept.append(contentsOf: appendedHookBlock(itemIndent).components(separatedBy: "\n"))
            }

            var rewritten = beforeHooks
            rewritten.append(contentsOf: kept)
            rewritten.append(contentsOf: afterHooks)
            return rewritten.joined(separator: "\n")
        }

        guard let appendedHookBlock else { return content }

        var result = content
        if !result.isEmpty && !result.hasSuffix("\n") {
            result += "\n"
        }
        let separator = result.isEmpty ? "" : "\n"
        return result + separator + "hooks:\n" + appendedHookBlock("  ")
    }

    private static func filterHookBody(_ hooksBody: [String], itemIndent: String, markers: [String]) -> [String] {
        let itemPrefix = itemIndent + "- "
        var kept: [String] = []
        var idx = 0

        while idx < hooksBody.count {
            let line = hooksBody[idx]
            if line.hasPrefix(itemPrefix) {
                var j = idx + 1
                while j < hooksBody.count {
                    let nextLine = hooksBody[j]
                    let trimmed = nextLine.trimmingCharacters(in: .whitespaces)
                    if nextLine.hasPrefix(itemPrefix) {
                        break
                    }
                    if !trimmed.isEmpty,
                       !nextLine.hasPrefix(itemIndent),
                       !trimmed.hasPrefix("#") {
                        break
                    }
                    j += 1
                }

                let blockLines = Array(hooksBody[idx..<j])
                let blockText = blockLines.joined(separator: "\n")
                if !markers.contains(where: { blockText.contains($0) }) {
                    kept.append(contentsOf: blockLines)
                }
                idx = j
            } else {
                kept.append(line)
                idx += 1
            }
        }

        return kept
    }

    private static func detectHookItemIndent(in hooksBody: [String]) -> String {
        for line in hooksBody {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                return leadingWhitespace(of: line)
            }
        }
        return "  "
    }

    private static func leadingWhitespace(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    private static func buildHookBlock(command: String, itemIndent: String) -> String {
        let propertyIndent = itemIndent + "  "
        let matcherIndent = propertyIndent + "  "

        return """
\(itemIndent)# Coding Island hook for Coco/Trae CLI (all events)
\(itemIndent)- type: command
\(propertyIndent)command: \(command)
\(propertyIndent)# Allow enough time for Island-driven permission decisions.
\(propertyIndent)# The hook script will stop waiting early if the CLI proceeds.
\(propertyIndent)timeout: 310s
\(propertyIndent)matchers:
\(matcherIndent)- event: user_prompt_submit
\(matcherIndent)- event: pre_tool_use
\(matcherIndent)- event: post_tool_use
\(matcherIndent)- event: post_tool_use_failure
\(matcherIndent)- event: permission_request
\(matcherIndent)- event: notification
\(matcherIndent)- event: stop
\(matcherIndent)- event: subagent_start
\(matcherIndent)- event: subagent_stop
\(matcherIndent)- event: session_start
\(matcherIndent)- event: session_end
\(matcherIndent)- event: pre_compact
\(matcherIndent)- event: post_compact
"""
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
