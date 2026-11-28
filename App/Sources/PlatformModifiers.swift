import SwiftUI

extension View {
    /// Inline navigation title. `navigationBarTitleDisplayMode` exists only on iOS, so this is a no-op on macOS.
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
            navigationBarTitleDisplayMode(.inline)
        #else
            self
        #endif
    }

    /// Large navigation title on iOS, also in the sidebar of a split view, where the bar is too narrow for an
    /// inline title next to the toolbar buttons. A no-op on macOS.
    @ViewBuilder
    func largeNavigationTitle() -> some View {
        #if os(iOS)
            navigationBarTitleDisplayMode(.large)
        #else
            self
        #endif
    }

    /// Hides the keyboard of a conversation screen two ways: a tap anywhere in the messages, and the
    /// native interactive dismiss, where the keyboard follows a finger dragging down past its top edge.
    /// iOS only: macOS has no software keyboard.
    @ViewBuilder
    func dismissesKeyboard(_ focus: FocusState<Bool>.Binding) -> some View {
        #if os(iOS)
            scrollDismissesKeyboard(.interactively)
                // Simultaneous, so links and buttons in the messages still get their taps.
                .simultaneousGesture(
                    TapGesture().onEnded {
                        focus.wrappedValue = false
                    }
                )
        #else
            self
        #endif
    }
}

extension ToolbarItemPlacement {
    /// The leading edge of the navigation bar on iOS, the leading side of the window toolbar on macOS.
    static var leadingAction: ToolbarItemPlacement {
        #if os(iOS)
            .topBarLeading
        #else
            .navigation
        #endif
    }
}
