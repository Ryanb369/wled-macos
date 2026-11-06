import Foundation
import Darwin

struct CodexEventSnapshot {
    let done: [String: TimeInterval]
    let attentionCount: Int
    let latestCompletion: TimeInterval?
    let hasAttention: Bool
}

enum CodexEventBridge {
    static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WLED Display Sync")
    static let eventsURL = supportDirectory.appendingPathComponent("indicator-events.json")
    private static let lockURL = supportDirectory.appendingPathComponent("indicator-events.lock")

    static func handleCommandLine() -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else { return false }

        switch arguments[1] {
        case "--wled-hook":
            guard arguments.count >= 3 else { return true }
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
            handleHook(arguments[2], event: event)
            return true
        case "--wled-notify":
            guard arguments.count >= 3,
                  let data = arguments[2].data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
            handleNotification(event)
            return true
        case "--wled-notify-chain":
            guard arguments.count >= 3 else { return true }
            let payload = arguments.last ?? "{}"
            if let data = payload.data(using: .utf8),
               let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                handleNotification(event)
            }
            CodexHookManager.runPreviousNotification(payload: payload)
            return true
        case "--ack-attention":
            mutate(action: "ack-attention", thread: "", kind: "")
            return true
        case "--codex-connection-status":
            let status = CodexHookManager.status()
            print(status.isConnected ? "connected" : status.summary)
            return true
        case "--install-codex-connection":
            do { print(try CodexHookManager.installOrRepair()) }
            catch { fputs("\(error.localizedDescription)\n", stderr) }
            return true
        default:
            return false
        }
    }

    static func snapshot() -> CodexEventSnapshot {
        let values = readEvents()
        let rawDone = values["done"] as? [String: Any] ?? [:]
        let done = rawDone.reduce(into: [String: TimeInterval]()) { result, item in
            if let value = item.value as? TimeInterval { result[item.key] = value }
            else if let number = item.value as? NSNumber { result[item.key] = number.doubleValue }
        }
        let attention = values["attention"] as? [String: Any] ?? [:]
        return CodexEventSnapshot(done: done, attentionCount: attention.count,
                                  latestCompletion: done.values.max(), hasAttention: !attention.isEmpty)
    }

    static func acknowledgeAttention() {
        mutate(action: "ack-attention", thread: "", kind: "")
    }

    static func testCompletion() {
        mutate(action: "done", thread: "wled-control-test", kind: "")
    }

    static func testAttention() {
        mutate(action: "attention", thread: "wled-control-test", kind: "question")
    }

    static func purgeCompletions(olderThan seconds: TimeInterval) {
        withLockedEvents { values in
            let now = Date().timeIntervalSince1970
            var done = values["done"] as? [String: Any] ?? [:]
            done = done.filter { _, value in
                let timestamp = (value as? NSNumber)?.doubleValue ?? value as? Double ?? 0
                return now - timestamp < seconds
            }
            values["done"] = done
        }
    }

    private static func handleNotification(_ event: [String: Any]) {
        let type = event["type"] as? String ?? event["event"] as? String ?? event["event_type"] as? String
        guard type == "agent-turn-complete" else { return }
        let thread = string(event, keys: ["thread-id", "thread_id", "conversation-id", "conversation_id"]) ?? "unknown"
        let message = string(event, keys: ["last-assistant-message", "last_assistant_message"]) ?? ""
        if message.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") {
            mutate(action: "attention", thread: thread, kind: "question")
        } else {
            mutate(action: "done", thread: thread, kind: "")
        }
    }

    private static func handleHook(_ action: String, event: [String: Any]) {
        let thread = event["session_id"] as? String ?? "unknown"
        switch action {
        case "permission": mutate(action: "attention", thread: thread, kind: "approval")
        case "question":
            if (event["tool_name"] as? String ?? "").contains("request_user_input") {
                mutate(action: "attention", thread: thread, kind: "question")
            }
        case "user-reply": mutate(action: "clear-attention", thread: thread, kind: "")
        case "tool-complete": mutate(action: "clear-approval", thread: thread, kind: "")
        case "subagent-complete": mutate(action: "done", thread: thread, kind: "")
        default: break
        }
    }

    private static func string(_ values: [String: Any], keys: [String]) -> String? {
        for key in keys where values[key] is String { return values[key] as? String }
        return nil
    }

    private static func mutate(action: String, thread: String, kind: String) {
        withLockedEvents { values in
            var done = values["done"] as? [String: Any] ?? [:]
            var attention = values["attention"] as? [String: Any] ?? [:]
            let now = Date().timeIntervalSince1970
            switch action {
            case "done": done[thread] = now
            case "attention": attention[thread] = ["kind": kind, "at": now]
            case "clear-attention": attention.removeValue(forKey: thread)
            case "clear-approval":
                if (attention[thread] as? [String: Any])?["kind"] as? String == "approval" {
                    attention.removeValue(forKey: thread)
                }
            case "ack-attention": attention.removeAll()
            default: break
            }
            values["done"] = done
            values["attention"] = attention
        }
    }

    private static func readEvents() -> [String: Any] {
        guard let data = try? Data(contentsOf: eventsURL),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["done": [:], "attention": [:]]
        }
        return values
    }

    private static func withLockedEvents(_ change: (inout [String: Any]) -> Void) {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return }
        defer { flock(descriptor, LOCK_UN) }

        var values = readEvents()
        change(&values)
        guard let data = try? JSONSerialization.data(withJSONObject: values) else { return }
        try? data.write(to: eventsURL, options: .atomic)
    }
}
