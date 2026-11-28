import Foundation
import HermesAPI

/// The stream endpoints of the sidecar: it runs a turn in the background, so that a client can leave and attach
/// to it again. `SidecarClient` conforms; tests provide a fake.
public protocol TurnStreaming: Sendable {
    /// Whether a turn of the session runs.
    func activeStreamStatus(sessionID: String) async throws -> SidecarStreamStatus
    /// Sends one message and streams the reply events, as `SessionListing.streamSessionChat` does.
    func streamChat(
        sessionID: String, message: String, images: [ImageAttachment]
    ) async -> AsyncThrowingStream<SessionChatEvent, any Error>
    /// The events of the running turn: the ones buffered since it started, then the live ones until `done`.
    func attachStream(sessionID: String) async -> AsyncThrowingStream<SessionChatEvent, any Error>
}

extension SidecarClient: TurnStreaming {}
