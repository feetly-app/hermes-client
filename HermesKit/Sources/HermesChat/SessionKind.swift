import HermesAPI

/// What a sidebar row stands for. It picks the icon of the row.
public enum SessionKind: Sendable, Equatable {
    /// A conversation with the agent.
    case chat
    /// A session run by a scheduled (cron) job of the instance.
    case scheduled
}

extension RemoteSession {
    public var kind: SessionKind {
        source == Self.cronSource ? .scheduled : .chat
    }

    /// The title shown on a row: the session's title, or `ConversationTitle.placeholder` when the instance
    /// has not named it.
    public var displayTitle: String {
        title ?? ConversationTitle.placeholder
    }
}
