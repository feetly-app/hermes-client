import SwiftUI

/// A subtle animated indicator shown for conversations currently streaming an agent turn.
struct StreamingPulseIndicator: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 7, height: 7)
            .opacity(isPulsing ? 0.35 : 1.0)
            .scaleEffect(isPulsing ? 0.85 : 1.15)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear {
                isPulsing = true
            }
            .accessibilityLabel("Streaming active")
    }
}
