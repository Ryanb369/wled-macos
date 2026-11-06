import AppKit
import Foundation

struct CodexConnectionStatus {
    let hooksConnected: Bool
    let notificationsConnected: Bool

    var isConnected: Bool { hooksConnected && notificationsConnected }
    var summary: String {
        if isConnected { return "Codex is connected" }
        if hooksConnected { return "Completion notifications need repair" }
        if notificationsConnected { return "Codex hooks need repair" }
        return "Codex is not connected"
    }
}

enum CodexHookManager {
    private static let fileManager = FileManager.default
    private static let codexDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    static let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
    static let configURL = codexDirectory.appendingPathComponent("config.toml")
    private static let notificationBackupURL = CodexEventBridge.supportDirectory
        .appendingPathComponent("codex-notify-command.json")

    private static var executablePath: String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    }

    static func status() -> CodexConnectionStatus {
        let hookText = (try? String(contentsOf: hooksURL, encoding: .utf8)) ?? ""
        let configText = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        return CodexConnectionStatus(
            hooksConnected: hookText.contains("--wled-hook") && hookText.contains("WLEDControl"),
            notificationsConnected: (configText.contains("--wled-notify") || configText.contains("codex-notify.sh"))
        )
    }

    static func installOrRepair() throws -> String {
        try fileManager.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: CodexEventBridge.supportDirectory, withIntermediateDirectories: true)
        try installHooks()
        let notificationResult = try installNotificationIfNeeded()
        return notificationResult ? "Codex hooks and completion notifications are connected." : "Codex hooks were repaired. Your existing completion notification connection was preserved."
    }

    static func remove() throws -> String {
        try removeHooks()
        let restored = try restoreManagedNotification()
        return restored
            ? "This app’s Codex hooks and notification connection were removed."
            : "This app’s Codex hooks were removed. The existing notification chain was left unchanged."
    }

    static func openCodexSettings() {
        NSWorkspace.shared.open(configURL)
    }

    static func openHooksFile() {
        NSWorkspace.shared.open(hooksURL)
    }

    static func runPreviousNotification(payload: String) {
        guard let data = try? Data(contentsOf: notificationBackupURL),
              let command = try? JSONDecoder().decode([String].self, from: data),
              let executable = command.first, !executable.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst()) + [payload]
        do {
            try process.run()
            process.waitUntilExit()
        } catch { }
    }

    private static func installHooks() throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: hooksURL) {
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "WLEDControl", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Codex hooks.json is not a JSON object, so it was not changed."])
            }
            root = existing
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in Array(hooks.keys) { hooks[event] = removingOwnedHooks(from: hooks[event]) }
        hooks = hooks.filter { !isEmptyArray($0.value) }

        addHook(event: "PermissionRequest", action: "permission", matcher: nil, to: &hooks)
        addHook(event: "PreToolUse", action: "question", matcher: "^.*request_user_input.*$", to: &hooks)
        addHook(event: "PostToolUse", action: "tool-complete", matcher: nil, to: &hooks)
        addHook(event: "SubagentStop", action: "subagent-complete", matcher: nil, to: &hooks)
        addHook(event: "UserPromptSubmit", action: "user-reply", matcher: nil, to: &hooks)
        root["hooks"] = hooks
        if root["description"] == nil {
            root["description"] = "Codex hooks, including WLED Control fixture alerts."
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: hooksURL, options: .atomic)
    }

    private static func removeHooks() throws {
        guard let data = try? Data(contentsOf: hooksURL),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in Array(hooks.keys) { hooks[event] = removingOwnedHooks(from: hooks[event]) }
        hooks = hooks.filter { !isEmptyArray($0.value) }
        root["hooks"] = hooks
        let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: hooksURL, options: .atomic)
    }

    private static func removingOwnedHooks(from value: Any?) -> Any {
        guard let groups = value as? [[String: Any]] else { return value ?? [] }
        return groups.compactMap { group -> [String: Any]? in
            var copy = group
            let commands = (group["hooks"] as? [[String: Any]] ?? []).filter { item in
                let command = item["command"] as? String ?? ""
                return !command.contains("--wled-hook")
            }
            guard !commands.isEmpty else { return nil }
            copy["hooks"] = commands
            return copy
        }
    }

    private static func addHook(event: String, action: String, matcher: String?, to hooks: inout [String: Any]) {
        let quoted = shellQuote(executablePath)
        var group: [String: Any] = ["hooks": [[
            "type": "command", "command": "\(quoted) --wled-hook \(action)", "timeout": 10, "async": true
        ]]]
        if let matcher { group["matcher"] = matcher }
        var groups = hooks[event] as? [[String: Any]] ?? []
        groups.append(group)
        hooks[event] = groups
    }

    private static func installNotificationIfNeeded() throws -> Bool {
        var config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        if config.contains("--wled-notify") || config.contains("codex-notify.sh") { return false }

        let pattern = #"(?m)^notify[ \t]*=[ \t]*(\[[^\r\n]*\])[ \t]*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(config.startIndex..<config.endIndex, in: config)
        var previous: [String] = []
        if let match = regex.firstMatch(in: config, range: range),
           let arrayRange = Range(match.range(at: 1), in: config),
           let data = String(config[arrayRange]).data(using: .utf8),
           let parsed = try? JSONDecoder().decode([String].self, from: data) {
            previous = parsed
        } else if config.range(of: #"(?m)^notify[ \t]*="#,
                               options: .regularExpression) != nil {
            throw NSError(domain: "WLEDControl", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The existing Codex notification setting uses a format this app can’t safely edit."])
        }

        if !previous.isEmpty {
            let backup = try JSONEncoder().encode(previous)
            try backup.write(to: notificationBackupURL, options: .atomic)
        } else {
            try? fileManager.removeItem(at: notificationBackupURL)
        }
        let managed = try tomlArray([executablePath, "--wled-notify-chain"])
        let line = "notify = \(managed)"
        if let match = regex.firstMatch(in: config, range: range), let fullRange = Range(match.range, in: config) {
            config.replaceSubrange(fullRange, with: line)
        } else {
            config = line + "\n" + config
        }
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        return true
    }

    private static func restoreManagedNotification() throws -> Bool {
        var config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        guard config.contains("--wled-notify-chain") else { return false }
        let pattern = #"(?m)^notify[ \t]*=[ \t]*\[[^\r\n]*--wled-notify-chain[^\r\n]*\][ \t]*\r?\n?"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(config.startIndex..<config.endIndex, in: config)
        guard let match = regex.firstMatch(in: config, range: range),
              let fullRange = Range(match.range, in: config) else { return false }
        var replacement = ""
        if let data = try? Data(contentsOf: notificationBackupURL),
           let previous = try? JSONDecoder().decode([String].self, from: data), !previous.isEmpty {
            replacement = "notify = \(try tomlArray(previous))\n"
        }
        config.replaceSubrange(fullRange, with: replacement)
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        try? fileManager.removeItem(at: notificationBackupURL)
        return true
    }

    private static func tomlArray(_ values: [String]) throws -> String {
        let data = try JSONEncoder().encode(values)
        return String(decoding: data, as: UTF8.self)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isEmptyArray(_ value: Any) -> Bool {
        (value as? [Any])?.isEmpty == true
    }
}
