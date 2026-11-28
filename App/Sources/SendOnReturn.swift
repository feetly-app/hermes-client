import HermesChat
import SwiftUI

#if os(macOS)
    import AppKit

    /// Watches the key presses of the app while the composer is focused, and applies `ComposerReturnKey`.
    ///
    /// A local event monitor sees the key before the text field: a multi-line `TextField` handles Return
    /// itself, so `onKeyPress` and `onSubmit` cannot take it over reliably.
    @MainActor
    private final class ReturnKeyMonitor {
        /// `true` while the composer text field is focused.
        var isActive = false
        /// `true` when there is something to send.
        var canSend = false
        var send: () -> Void = {}
        private var token: Any?

        func start() {
            guard token == nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return consumed ? nil : event
            }
        }

        func stop() {
            if let token {
                NSEvent.removeMonitor(token)
            }
            token = nil
        }

        /// Returns `true` when the event is consumed.
        private func handle(_ event: NSEvent) -> Bool {
            // 36: Return, 76: Enter on the numeric keypad.
            guard isActive, event.keyCode == 36 || event.keyCode == 76 else { return false }
            // The composer's focus can stay set behind a sheet (settings, rename): Return there is the sheet's.
            guard let window = event.window, window.sheetParent == nil, window.attachedSheet == nil else {
                return false
            }
            let textView = window.firstResponder as? NSTextView
            let flags = event.modifierFlags
            let action = ComposerReturnKey.action(
                shift: flags.contains(.shift),
                option: flags.contains(.option),
                command: flags.contains(.command),
                control: flags.contains(.control),
                isComposing: textView?.hasMarkedText() ?? false
            )
            switch action {
            case .passThrough:
                return false
            case .insertNewline:
                guard let textView else { return false }
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case .send:
                if canSend {
                    send()
                }
                return true
            }
        }
    }

    private struct SendOnReturn: ViewModifier {
        let isActive: Bool
        let canSend: Bool
        let action: () -> Void
        @State private var monitor = ReturnKeyMonitor()

        func body(content: Content) -> some View {
            content
                .onAppear {
                    monitor.send = action
                    monitor.start()
                }
                .onDisappear { monitor.stop() }
                .onChange(of: isActive, initial: true) {
                    monitor.isActive = isActive
                    monitor.send = action
                }
                .onChange(of: canSend, initial: true) {
                    monitor.canSend = canSend
                    monitor.send = action
                }
        }
    }
#endif

extension View {
    /// On macOS, Return sends the message while the composer is focused (`isActive`); Shift-Return and
    /// Option-Return insert a line break. See `ComposerReturnKey`. No-op on iOS, where Return inserts a
    /// line break and the Send button sends.
    @ViewBuilder
    func sendsOnReturn(isActive: Bool, canSend: Bool, action: @escaping () -> Void) -> some View {
        #if os(macOS)
            modifier(SendOnReturn(isActive: isActive, canSend: canSend, action: action))
        #else
            self
        #endif
    }
}
