import Foundation

/// An event of `POST /api/sessions/{id}/chat/stream`, reduced to what a transcript needs.
public enum SessionChatEvent: Sendable, Equatable {
    /// A piece of the assistant reply (`assistant.delta`).
    case delta(String)
    /// The full assistant reply, sent once the turn is complete (`assistant.completed`).
    case completed(String)
    /// The turn failed, with a message for the user (`error`, `run.failed`).
    case failed(String)
    /// A tool started running (`tool.started`): its name, a short preview the instance wrote, and its
    /// arguments as a JSON object string when the instance sent them.
    case toolStarted(name: String, preview: String?, arguments: String?)
    /// A tool finished (`tool.completed`), or failed (`tool.failed`), with a preview of its result.
    case toolFinished(name: String, preview: String?, failed: Bool)
    /// A piece of the model's reasoning (`tool.progress` on the `_thinking` pseudo tool).
    case thinking(String)
    /// The end of the turn (`done`), or the end of the response.
    case finished
}

/// Body of `POST /api/sessions/{id}/chat/stream`: the user message, with its images when it has any.
struct SessionChatRequest: Encodable, Sendable {
    let message: MessageContent
}

/// One named SSE event: the `event:` field (`message` when absent) and the joined `data:` lines.
struct SessionEventFrame: Equatable, Sendable {
    let name: String
    let data: String
}

/// SSE parser for the named events of a session chat stream. Keeps the `event:` field, which the
/// generic `SSEParser` drops. Comments (`: keepalive`) and unknown fields are ignored.
struct SessionEventParser: Sendable {
    private var buffer: [UInt8] = []
    private var eventName: String?
    private var dataLines: [String] = []

    /// Consumes bytes and returns the frames they complete. A frame ends at a blank line.
    mutating func feed(_ bytes: some Sequence<UInt8>) -> [SessionEventFrame] {
        var frames: [SessionEventFrame] = []
        for byte in bytes {
            if byte == UInt8(ascii: "\n") {
                handle(takeLine(), into: &frames)
            } else {
                buffer.append(byte)
            }
        }
        return frames
    }

    /// Ends the input: a last unterminated line and a pending frame are emitted.
    mutating func finish() -> [SessionEventFrame] {
        var frames: [SessionEventFrame] = []
        if !buffer.isEmpty {
            handle(takeLine(), into: &frames)
        }
        dispatch(into: &frames)
        return frames
    }

    private mutating func takeLine() -> String {
        var bytes = buffer
        buffer.removeAll(keepingCapacity: true)
        if bytes.last == UInt8(ascii: "\r") {
            bytes.removeLast()
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private mutating func handle(_ line: String, into frames: inout [SessionEventFrame]) {
        if line.isEmpty {
            dispatch(into: &frames)
        } else if line.hasPrefix(":") {
            return
        } else if line.hasPrefix("event:") {
            eventName = Self.value(of: line, field: "event:")
        } else if line.hasPrefix("data:") {
            dataLines.append(Self.value(of: line, field: "data:"))
        }
    }

    private mutating func dispatch(into frames: inout [SessionEventFrame]) {
        guard !dataLines.isEmpty else {
            eventName = nil
            return
        }
        frames.append(SessionEventFrame(name: eventName ?? "message", data: dataLines.joined(separator: "\n")))
        eventName = nil
        dataLines = []
    }

    /// The text after `field`, without one leading space.
    private static func value(of line: String, field: String) -> String {
        var value = line.dropFirst(field.count)
        if value.first == " " {
            value = value.dropFirst()
        }
        return String(value)
    }
}

extension SessionChatEvent {
    /// Maps a named frame to an event, or `nil` for events a transcript does not show.
    init?(_ frame: SessionEventFrame) {
        switch frame.name {
        case "done":
            self = .finished
        case "assistant.delta":
            guard let delta = Self.field("delta", in: frame.data), !delta.isEmpty else { return nil }
            self = .delta(delta)
        case "assistant.completed":
            self = .completed(Self.field("content", in: frame.data) ?? "")
        case "error":
            self = .failed(Self.field("message", in: frame.data) ?? "The agent failed to reply.")
        case "run.failed":
            self = .failed(Self.field("error", in: frame.data) ?? "The agent failed to reply.")
        case "tool.started":
            guard let object = Self.object(frame.data), let name = object["tool_name"] as? String else { return nil }
            let arguments = (object["args"] as? [String: Any]).flatMap { args in
                (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys, .withoutEscapingSlashes]))
                    .map { String(decoding: $0, as: UTF8.self) }
            }
            self = .toolStarted(name: name, preview: Self.text(object["preview"]), arguments: arguments)
        case "tool.completed", "tool.failed":
            guard let object = Self.object(frame.data), let name = object["tool_name"] as? String else { return nil }
            self = .toolFinished(name: name, preview: Self.text(object["preview"]), failed: frame.name == "tool.failed")
        case "tool.progress":
            guard let object = Self.object(frame.data), object["tool_name"] as? String == "_thinking",
                  let delta = object["delta"] as? String, !delta.isEmpty
            else { return nil }
            self = .thinking(delta)
        default:
            return nil
        }
    }

    private static func field(_ key: String, in json: String) -> String? {
        object(json)?[key] as? String
    }

    private static func object(_ json: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    }

    /// A non-empty string value, or `nil`.
    private static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
