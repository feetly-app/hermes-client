import Foundation
import HermesAPI
import Testing

@testable import HermesChat

@MainActor
@Suite("Rows the instance writes in the user's place")
struct TranscriptNoticeTests {
    private let batchResult = """
        [ASYNC DELEGATION BATCH COMPLETE — deleg_9a92f834]
        A background fan-out unit you dispatched earlier — 2 subagent(s) — has finished; its consolidated results are below.

        --- ✓ TASK 1/2: Finish api issues (status=completed, api_calls=82, 909.94s) ---
        All four PRs are open.
        """

    @Test("a finished delegation is a notice with the task count, not a user message")
    func delegationIsNotice() throws {
        let lines = RemoteTranscript.lines(from: [
            SessionMessage(id: "1", role: "user", content: batchResult, displayKind: "async_delegation_complete")
        ])

        let line = try #require(lines.first)
        #expect(line.notice == "2 background tasks finished")
        #expect(line.text == batchResult)
    }

    @Test("a delegation that ended with an error says so")
    func delegationWithError() {
        let content = """
            [ASYNC DELEGATION BATCH COMPLETE — deleg_faba53c0]
            A background fan-out unit you dispatched earlier — 5 subagent(s) — has finished.
            --- ERROR ---
            The batch did not complete successfully.
            """
        let message = SessionMessage(id: "1", role: "user", content: content, displayKind: "async_delegation_complete")

        #expect(RemoteTranscript.notice(for: message) == "5 background tasks finished with errors")
    }

    @Test("the label and counts of display_metadata win over the text")
    func metadataWins() {
        let counted = SessionMessage(
            id: "1", role: "user", content: batchResult, displayKind: "async_delegation_complete",
            displayMetadata: DisplayMetadata(taskCount: 3, failedCount: 1)
        )
        let labelled = SessionMessage(
            id: "2", role: "user", content: "[IMPORTANT: Background process proc_1 completed normally (exit code 0).]",
            displayKind: "process_complete",
            displayMetadata: DisplayMetadata(displayText: "Background Process Finished: swift test")
        )

        #expect(RemoteTranscript.notice(for: counted) == "3 background tasks finished, 1 failed")
        #expect(RemoteTranscript.notice(for: labelled) == "Background Process Finished: swift test")
    }

    @Test("untyped rows are recognised by their header")
    func untypedRows() {
        let delegation = SessionMessage(id: "1", role: "user", content: batchResult)
        let process = SessionMessage(
            id: "2", role: "user", content: "[IMPORTANT: Background process proc_1 completed normally (exit code 0).]"
        )

        #expect(RemoteTranscript.notice(for: delegation) == "2 background tasks finished")
        #expect(RemoteTranscript.notice(for: process) == "Background process finished")
    }

    @Test("the user's own messages stay messages, whatever their kind or text")
    func userMessagesStay() {
        let messages = [
            // The instance marks messages sent through the API as internal notifications.
            SessionMessage(id: "1", role: "user", content: "Yes go", displayKind: "internal_notification"),
            // A message quoting a delegation result is still the user's.
            SessionMessage(id: "2", role: "user", content: "The app shows this wrong:\n\n" + batchResult),
            SessionMessage(id: "3", role: "assistant", content: batchResult),
        ]

        #expect(RemoteTranscript.lines(from: messages).map(\.notice) == [nil, nil, nil])
    }

    @Test("display_content replaces the stored text, such as a message sent while a reply was running")
    func displayContent() {
        let message = SessionMessage(
            id: "1", role: "user",
            content: "[OUT-OF-BAND USER MESSAGE — a direct message from the user]\nHere is the JSON\n[/OUT-OF-BAND USER MESSAGE]",
            displayContent: "Here is the JSON", displayKind: "steer"
        )

        #expect(RemoteTranscript.lines(from: [message]).map(\.text) == ["Here is the JSON"])
    }
}
