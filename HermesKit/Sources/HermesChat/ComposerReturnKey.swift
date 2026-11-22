/// What Return does in the message composer on a hardware keyboard (macOS).
public enum ComposerReturnKey: Equatable, Sendable {
    /// Sends the message, or does nothing when there is nothing to send. The key is consumed either way.
    case send
    /// Inserts a line break at the cursor.
    case insertNewline
    /// Left to the text field: it confirms an input method composition, or runs a shortcut.
    case passThrough

    /// Return sends, Shift-Return and Option-Return insert a line break. With Command or Control, or while
    /// an input method is composing text (marked text), the key is left to the system.
    public static func action(
        shift: Bool,
        option: Bool,
        command: Bool,
        control: Bool,
        isComposing: Bool
    ) -> ComposerReturnKey {
        if isComposing || command || control {
            return .passThrough
        }
        if shift || option {
            return .insertNewline
        }
        return .send
    }
}
