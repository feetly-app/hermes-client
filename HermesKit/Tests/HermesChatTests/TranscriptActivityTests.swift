import Foundation
import HermesAPI
import Testing

@testable import HermesChat

@MainActor
@Suite("What the agent did between replies")
struct TranscriptActivityTests {
    private func call(_ id: String, _ name: String, _ arguments: String = "{}") -> SessionToolCall {
        SessionToolCall(id: id, name: name, arguments: arguments)
    }

    private func toolRow(_ id: String, answering callID: String, _ content: String) -> SessionMessage {
        SessionMessage(id: id, role: "tool", content: content, toolCallID: callID, toolName: "terminal")
    }

    @Test("tool-only rows join one activity line; text ends it, and the calls of a row with text follow it")
    func grouping() throws {
        let lines = RemoteTranscript.lines(from: [
            SessionMessage(id: "1", role: "user", content: "Yes go"),
            SessionMessage(id: "2", role: "assistant", content: "", toolCalls: [call("a", "skill_view", #"{"name":"agents"}"#)]),
            toolRow("3", answering: "a", #"{"success": true}"#),
            SessionMessage(id: "4", role: "assistant", content: nil, toolCalls: [call("b", "terminal", #"{"command":"ls"}"#)]),
            toolRow("5", answering: "b", #"{"output": "x", "exit_code": 0, "error": null}"#),
            SessionMessage(
                id: "6", role: "assistant", content: "Now update the guide.",
                toolCalls: [call("c", "patch", #"{"path":"/tmp/guide.md"}"#)]
            ),
            toolRow("7", answering: "c", #"{"success": false, "error": "no match"}"#),
            SessionMessage(id: "8", role: "assistant", content: "Done."),
        ])

        #expect(lines.map(\.id) == ["1", "activity-2", "6", "activity-6", "8"])
        let first = lines[1].steps
        #expect(first.map(\.title) == ["Skill View", "Terminal"])
        #expect(first.map(\.summary) == ["agents", "ls"])
        #expect(first.map(\.status) == [.done, .done])
        #expect(first[1].result == #"{"output": "x", "exit_code": 0, "error": null}"#)
        let second = try #require(lines[3].steps.first)
        #expect(second.summary == "/tmp/guide.md")
        #expect(second.status == .failed)
        #expect(lines[2].isActivity == false)
    }

    @Test("a background delegation lists the goal of each agent")
    func delegation() throws {
        let arguments = #"{"tasks":[{"goal":"Finish api issues #8","context":"…"},{"goal":"Finish auth"}]}"#
        let lines = RemoteTranscript.lines(from: [
            SessionMessage(id: "1", role: "assistant", content: "", toolCalls: [call("d", "delegate_task", arguments)]),
            toolRow("2", answering: "d", #"{"status": "dispatched", "mode": "background", "count": 2}"#),
        ])

        let step = try #require(lines.first?.steps.first)
        #expect(step.title == "Delegate Task")
        #expect(step.summary == "2 tasks")
        #expect(step.subtasks == ["Finish api issues #8", "Finish auth"])
        #expect(step.status == .background)
    }

    @Test("reasoning becomes a thinking step before the calls of its row")
    func reasoning() {
        let lines = RemoteTranscript.lines(from: [
            SessionMessage(
                id: "1", role: "assistant", content: "", toolCalls: [call("a", "terminal", #"{"command":"pwd"}"#)],
                reasoning: "I check where I am.\nThen I list."
            ),
        ])

        #expect(lines.first?.steps.map(\.kind) == [.thinking, .tool])
        #expect(lines.first?.steps.first?.summary == "I check where I am.")
    }

    @Test("a terminal summary shows the first command and how many follow")
    func commandSummary() {
        #expect(ActivityStep.commandSummary("cd /srv && make test; echo ok") == "cd /srv + 2 commands")
        #expect(ActivityStep.commandSummary("sleep 8") == "sleep 8")
    }

    @Test("a result for a call this page does not hold is ignored")
    func orphanResult() {
        let lines = RemoteTranscript.lines(from: [toolRow("1", answering: "missing", "{}")])
        #expect(lines.isEmpty)
    }

    @Test("tool_calls are read as an array or as a JSON string")
    func decodesToolCalls() throws {
        let json = #"""
            [{"id": 1, "role": "assistant", "content": "",
              "tool_calls": [{"id": "a", "type": "function", "function": {"name": "terminal", "arguments": "{\"command\": \"ls\"}"}}]},
             {"id": 2, "role": "assistant", "content": "",
              "tool_calls": "[{\"id\": \"b\", \"function\": {\"name\": \"patch\", \"arguments\": {\"path\": \"/a\"}}}]",
              "reasoning": "  "},
             {"id": 3, "role": "tool", "content": "{}", "tool_call_id": "b", "tool_name": "patch"}]
            """#
        let messages = try JSONDecoder().decode([SessionMessage].self, from: Data(json.utf8))

        #expect(messages[0].toolCalls == [SessionToolCall(id: "a", name: "terminal", arguments: #"{"command": "ls"}"#)])
        #expect(messages[1].toolCalls == [SessionToolCall(id: "b", name: "patch", arguments: #"{"path":"/a"}"#)])
        #expect(messages[1].reasoning == nil)
        #expect(messages[2].toolCallID == "b")
        #expect(messages[2].toolName == "patch")
    }
}

@MainActor
@Suite("Live steps of a reply being streamed")
struct LiveActivityTests {
    @Test("tool and reasoning events become steps above the reply text, finished in the order they started")
    func liveSteps() async throws {
        let source = FakeChatStreamSource(events: [
            .thinking("I check "), .thinking("the tests."),
            .toolStarted(name: "terminal", preview: "pnpm test", arguments: #"{"command":"pnpm test"}"#),
            .toolStarted(name: "terminal", preview: "ls", arguments: nil),
            .toolFinished(name: "terminal", preview: #"{"exit_code": 0}"#, failed: false),
            .toolStarted(name: "delegate_task", preview: nil, arguments: #"{"tasks":[{"goal":"A"},{"goal":"B"}]}"#),
            .toolFinished(name: "delegate_task", preview: #"{"status": "dispatched", "mode": "background"}"#, failed: false),
            .toolStarted(name: "read_file", preview: nil, arguments: #"{"path":"/a"}"#),
            .toolFinished(name: "read_file", preview: "not found", failed: true),
            .delta("Done."), .finished,
        ])
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: source)

        await transcript.send("Go")

        #expect(transcript.lines.map(\.role) == ["user", "assistant"])
        let reply = try #require(transcript.lines.last)
        #expect(reply.text == "Done.")
        #expect(reply.isActivity == false)
        #expect(reply.steps.map(\.kind) == [.thinking, .tool, .tool, .tool, .tool])
        #expect(reply.steps.first?.result == "I check the tests.")
        // The second terminal never reported back: it is no longer shown as running once the reply ended.
        #expect(reply.steps.dropFirst().map(\.status) == [.done, .done, .background, .failed])
        #expect(reply.steps[1].summary == "pnpm test")
        #expect(reply.steps[3].subtasks == ["A", "B"])
    }

    @Test("a reply that only ran tools keeps its line")
    func toolsWithoutText() async {
        let source = FakeChatStreamSource(events: [
            .toolStarted(name: "terminal", preview: "ls", arguments: nil), .finished,
        ])
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: source)

        await transcript.send("Go")

        #expect(transcript.lines.count == 2)
        #expect(transcript.lines.last?.isActivity == true)
    }
}
