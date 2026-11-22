import Testing

@testable import HermesChat

@Suite("Composer Return key")
struct ComposerReturnKeyTests {
    private func action(
        shift: Bool = false, option: Bool = false, command: Bool = false, control: Bool = false,
        isComposing: Bool = false
    ) -> ComposerReturnKey {
        ComposerReturnKey.action(
            shift: shift, option: option, command: command, control: control, isComposing: isComposing)
    }

    @Test("Return alone sends")
    func plainReturnSends() {
        #expect(action() == .send)
    }

    @Test("Shift-Return and Option-Return insert a line break")
    func modifiedReturnInsertsNewline() {
        #expect(action(shift: true) == .insertNewline)
        #expect(action(option: true) == .insertNewline)
        #expect(action(shift: true, option: true) == .insertNewline)
    }

    @Test("Command and Control leave the key to the system")
    func shortcutsPassThrough() {
        #expect(action(command: true) == .passThrough)
        #expect(action(control: true) == .passThrough)
        #expect(action(shift: true, command: true) == .passThrough)
    }

    @Test("Return while an input method is composing confirms the composition instead of sending")
    func compositionPassesThrough() {
        #expect(action(isComposing: true) == .passThrough)
        #expect(action(shift: true, isComposing: true) == .passThrough)
    }
}
