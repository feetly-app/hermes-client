import Foundation

/// One thing the agent did between two replies: a tool it ran, or a piece of its reasoning.
///
/// Steps are read from the stored messages (an assistant row's `tool_calls`, answered by `tool` rows) or
/// built live from the events of a reply being streamed.
public struct ActivityStep: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case tool
        case thinking
    }

    public enum Status: Equatable, Sendable {
        /// Still running: the reply is streaming and the tool has not answered yet.
        case running
        case done
        case failed
        /// Handed to the background: the tool returned at once and the work goes on without the agent,
        /// such as a `delegate_task` in background mode or a background terminal process.
        case background
    }

    public let id: String
    public let kind: Kind
    /// The tool name as the instance knows it, such as `terminal` or `delegate_task`. Empty for reasoning.
    public let name: String
    /// The arguments as a JSON object string, or empty when unknown.
    public var arguments: String
    /// A short description of the call written by the instance, sent with live events.
    public var preview: String?
    /// What the tool returned, or the reasoning text for a thinking step.
    public var result: String?
    public var status: Status

    public init(
        id: String,
        kind: Kind = .tool,
        name: String,
        arguments: String = "",
        preview: String? = nil,
        result: String? = nil,
        status: Status = .done
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.arguments = arguments
        self.preview = preview
        self.result = result
        self.status = status
    }

    /// A reasoning step.
    public static func thinking(id: String, text: String) -> ActivityStep {
        ActivityStep(id: id, kind: .thinking, name: "", result: text, status: .done)
    }

    /// The name to show: `skill_view` reads "Skill View".
    public var title: String {
        if kind == .thinking { return "Thinking" }
        let words = name.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." })
        guard !words.isEmpty else { return name }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The decoded arguments, or an empty dictionary.
    var argumentObject: [String: Any] {
        guard !arguments.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]
        else { return [:] }
        return object
    }

    /// One line saying what the call is about: a command, a path, a skill, a goal… `nil` when nothing fits.
    public var summary: String? {
        if kind == .thinking {
            return result.map { Self.firstLine(of: $0) }
        }
        let args = argumentObject
        if name == "delegate_task" {
            let goals = subtasks
            if goals.count > 1 { return "\(goals.count) tasks" }
            if let goal = goals.first { return Self.clip(Self.firstLine(of: goal)) }
        }
        if let command = args["command"] as? String, !command.isEmpty {
            return Self.commandSummary(command)
        }
        for key in Self.summaryKeys {
            if let value = args[key] as? String, !value.isEmpty {
                return Self.clip(Self.firstLine(of: value))
            }
        }
        if let preview, !preview.isEmpty {
            return Self.clip(Self.firstLine(of: preview))
        }
        // The first short string argument, if any.
        let strings = args.keys.sorted().compactMap { args[$0] as? String }.filter { !$0.isEmpty }
        return strings.first.map { Self.clip(Self.firstLine(of: $0)) }
    }

    /// The goals of the agents a `delegate_task` call started, one per agent.
    public var subtasks: [String] {
        guard name == "delegate_task" else { return [] }
        let args = argumentObject
        if let tasks = args["tasks"] as? [[String: Any]] {
            let goals = tasks.compactMap { $0["goal"] as? String }
            if !goals.isEmpty { return goals }
        }
        if let goal = args["goal"] as? String, !goal.isEmpty {
            return [goal]
        }
        if let result, let object = Self.jsonObject(result), let goals = object["goals"] as? [String] {
            return goals
        }
        return []
    }

    /// The status a stored call ended with, read from what the tool returned.
    static func status(forResult result: String?, arguments: [String: Any] = [:]) -> Status {
        guard let result, let object = jsonObject(result) else {
            return arguments["background"] as? Bool == true ? .background : .done
        }
        if object["success"] as? Bool == false {
            return .failed
        }
        if let error = object["error"] as? String, !error.isEmpty {
            return .failed
        }
        if let status = object["status"] as? String, ["failed", "error"].contains(status) {
            return .failed
        }
        if let code = object["exit_code"] as? Int, code != 0 {
            return .failed
        }
        if object["mode"] as? String == "background" || object["status"] as? String == "dispatched" {
            return .background
        }
        if arguments["background"] as? Bool == true {
            return .background
        }
        return .done
    }

    private static let summaryKeys = [
        "path", "file_path", "name", "skill", "url", "query", "pattern", "goal", "prompt", "action", "text",
    ]

    /// "First command + N commands", the way the dashboard shows a terminal call.
    static func commandSummary(_ command: String) -> String {
        let parts = command
            .replacingOccurrences(of: "&&", with: "\n")
            .replacingOccurrences(of: ";", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = parts.first else { return clip(command) }
        let rest = parts.count - 1
        let head = clip(first, limit: rest > 0 ? 60 : 80)
        return rest > 0 ? "\(head) + \(rest) command\(rest == 1 ? "" : "s")" : head
    }

    static func firstLine(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
    }

    static func clip(_ text: String, limit: Int = 80) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    static func jsonObject(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }
}
