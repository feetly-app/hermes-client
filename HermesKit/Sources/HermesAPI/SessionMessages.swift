import Foundation

/// One page of `GET /api/sessions/{id}/messages`, in chronological order. Pages count back from the newest message.
public struct SessionMessagesPage: Sendable, Equatable {
    public let sessionID: String
    /// Messages as the instance sent them, compaction scaffolding included. Filtering is the caller's job.
    public let messages: [SessionMessage]
    /// Whether another page exists after this one.
    public let hasMore: Bool

    public init(sessionID: String, messages: [SessionMessage], hasMore: Bool) {
        self.sessionID = sessionID
        self.messages = messages
        self.hasMore = hasMore
    }
}

/// A message of a session stored on the Hermes instance. Only the fields a transcript needs are kept.
public struct SessionMessage: Sendable, Equatable, Identifiable, Decodable {
    public let id: String
    public let role: String
    /// `nil` or empty for rows that carry no text, such as tool calls or compaction markers. For a message
    /// stored as `text` and `image_url` parts, the text parts joined by new lines.
    public let content: String?
    /// The text to show instead of `content`, when the instance sets one: for a message sent while a reply
    /// was running, `content` wraps the user's words in a notice for the model and this holds the words.
    public let displayContent: String?
    public let timestamp: Date?
    /// `"hidden"` marks rows the instance wants clients not to display. Other kinds, such as
    /// `"async_delegation_complete"`, mark rows the instance wrote itself rather than the user.
    public let displayKind: String?
    /// What the instance says about the row, for the kinds that carry details.
    public let displayMetadata: DisplayMetadata?
    /// The tools an assistant row asks to run, in order. Empty for other rows.
    public let toolCalls: [SessionToolCall]
    /// For a `tool` row: the call it answers, and the name of the tool that ran.
    public let toolCallID: String?
    public let toolName: String?
    /// The reasoning the model wrote before an assistant row, when the instance kept it.
    public let reasoning: String?

    public init(
        id: String,
        role: String,
        content: String?,
        displayContent: String? = nil,
        timestamp: Date? = nil,
        displayKind: String? = nil,
        displayMetadata: DisplayMetadata? = nil,
        toolCalls: [SessionToolCall] = [],
        toolCallID: String? = nil,
        toolName: String? = nil,
        reasoning: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.displayContent = displayContent
        self.timestamp = timestamp
        self.displayKind = displayKind
        self.displayMetadata = displayMetadata
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.reasoning = reasoning
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp
        case displayContent = "display_content"
        case displayKind = "display_kind"
        case displayMetadata = "display_metadata"
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case toolName = "tool_name"
        case reasoning
        case reasoningContent = "reasoning_content"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The instance stores message ids as integers; a string is accepted too.
        if let text = try? container.decode(String.self, forKey: .id) {
            id = text
        } else {
            id = String(try container.decode(Int.self, forKey: .id))
        }
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        // A string, or an array of `text` and `image_url` parts (a multimodal message). Anything else
        // carries nothing to show.
        if let text = try? container.decodeIfPresent(String.self, forKey: .content) {
            content = text
        } else if let parts = try? container.decodeIfPresent([ContentPartBody].self, forKey: .content) {
            let texts = parts.compactMap { $0.type == "text" ? $0.text : nil }
            content = texts.isEmpty ? nil : texts.joined(separator: "\n")
        } else {
            content = nil
        }
        displayContent = try? container.decodeIfPresent(String.self, forKey: .displayContent)
        timestamp = try container.decodeIfPresent(Double.self, forKey: .timestamp).map(Date.init(timeIntervalSince1970:))
        displayKind = try container.decodeIfPresent(String.self, forKey: .displayKind)
        // Display details are optional: a shape this client does not know never fails the page.
        displayMetadata = try? container.decodeIfPresent(DisplayMetadata.self, forKey: .displayMetadata)
        // An array of OpenAI-style calls, or the same array encoded as a JSON string. Calls this client cannot
        // read are skipped rather than failing the page.
        if let calls = try? container.decodeIfPresent([LossyToolCall].self, forKey: .toolCalls) {
            toolCalls = calls.compactMap(\.call)
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .toolCalls),
                  let calls = try? JSONDecoder().decode([LossyToolCall].self, from: Data(text.utf8))
        {
            toolCalls = calls.compactMap(\.call)
        } else {
            toolCalls = []
        }
        toolCallID = try? container.decodeIfPresent(String.self, forKey: .toolCallID)
        toolName = try? container.decodeIfPresent(String.self, forKey: .toolName)
        let reasoningText = (try? container.decodeIfPresent(String.self, forKey: .reasoning))
            ?? (try? container.decodeIfPresent(String.self, forKey: .reasoningContent))
        reasoning = reasoningText.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }
}

/// The part of a message's `display_metadata` a transcript reads. Every field is optional.
public struct DisplayMetadata: Sendable, Equatable, Decodable {
    /// A short label the instance chose for the row.
    public let displayText: String?
    /// For a finished background delegation: how many tasks it ran, and how many of them failed.
    public let taskCount: Int?
    public let failedCount: Int?

    public init(displayText: String? = nil, taskCount: Int? = nil, failedCount: Int? = nil) {
        self.displayText = displayText
        self.taskCount = taskCount
        self.failedCount = failedCount
    }

    private enum CodingKeys: String, CodingKey {
        case displayText = "display_text"
        case taskCount = "task_count"
        case failedCount = "failed_count"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayText = try? container.decodeIfPresent(String.self, forKey: .displayText)
        taskCount = try? container.decodeIfPresent(Int.self, forKey: .taskCount)
        failedCount = try? container.decodeIfPresent(Int.self, forKey: .failedCount)
    }
}

/// A tool an assistant row asks to run: an OpenAI-style `tool_calls` entry.
public struct SessionToolCall: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// The arguments as the model wrote them: a JSON object encoded as a string.
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// Decodes one `tool_calls` entry, `{"id", "function": {"name", "arguments"}}`, or nothing.
private struct LossyToolCall: Decodable {
    let call: SessionToolCall?

    private enum CodingKeys: String, CodingKey {
        case id, function
    }

    private enum FunctionKeys: String, CodingKey {
        case name, arguments
    }

    init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self),
              let function = try? container.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function),
              let name = try? function.decode(String.self, forKey: .name)
        else {
            call = nil
            return
        }
        let id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
        let arguments: String
        if let text = try? function.decode(String.self, forKey: .arguments) {
            arguments = text
        } else if let object = try? function.decode(JSONValue.self, forKey: .arguments) {
            arguments = object.jsonString
        } else {
            arguments = ""
        }
        call = SessionToolCall(id: id, name: name, arguments: arguments)
    }
}

/// Any JSON value, kept to re-encode arguments sent as an object rather than a string.
private enum JSONValue: Decodable {
    case string(String), number(Double), bool(Bool), null, array([JSONValue]), object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    var foundation: Any {
        switch self {
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .null: NSNull()
        case .array(let values): values.map(\.foundation)
        case .object(let values): values.mapValues(\.foundation)
        }
    }

    var jsonString: String {
        guard let data = try? JSONSerialization.data(withJSONObject: foundation, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// One part of a multimodal message content. Unknown part types keep only their `type`.
private struct ContentPartBody: Decodable {
    let type: String
    let text: String?

    private enum CodingKeys: String, CodingKey {
        case type, text
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? container.decode(String.self, forKey: .type)) ?? ""
        text = try? container.decodeIfPresent(String.self, forKey: .text)
    }
}

/// Body of `GET /api/sessions/{id}/messages`. Only `data` and the returned count are read.
struct SessionMessagesBody: Decodable, Sendable {
    var data: [SessionMessage]
    var returned: Int

    private enum CodingKeys: String, CodingKey {
        case data, pagination
    }

    private enum PaginationKeys: String, CodingKey {
        case returned
    }

    init(data: [SessionMessage], returned: Int) {
        self.data = data
        self.returned = returned
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode([SessionMessage].self, forKey: .data)
        let pagination = try container.nestedContainer(keyedBy: PaginationKeys.self, forKey: .pagination)
        returned = try pagination.decode(Int.self, forKey: .returned)
    }
}
