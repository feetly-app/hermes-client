import Foundation
import HermesChat
import SwiftUI

/// What the agent did between two replies: the tools it ran and its reasoning, one compact row each, under
/// a header that folds the group. The group starts folded: the header alone says how many tools ran, and a
/// spinner shows while one is running. A tap on a row shows its arguments and what the tool returned.
struct ActivityView: View {
    let steps: [ActivityStep]

    @State private var isExpanded = false

    private var toolCount: Int { steps.count { $0.kind == .tool } }
    private var isRunning: Bool { steps.contains { $0.status == .running } }

    private var headerLabel: String {
        switch toolCount {
        case 0: "Thinking"
        case 1: "1 tool call"
        default: "\(toolCount) tool calls"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: toolCount == 0 ? "brain" : "wrench.and.screwdriver")
                    Text(headerLabel)
                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hides the tool calls" : "Shows the tool calls")

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(steps) { step in
                        ActivityStepRow(step: step)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One tool call or one piece of reasoning: status, name and a one-line summary. Agents started by a
/// delegation are listed under it. A tap shows the details.
private struct ActivityStepRow: View {
    let step: ActivityStep

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 6) {
                    StatusIndicator(step: step)
                    Text(step.title)
                        .fontWeight(.semibold)
                        .layoutPriority(1)
                    if let summary = step.summary {
                        // Commands and paths keep both ends; prose reads from its start.
                        Text(summary)
                            .font(step.kind == .thinking ? .footnote : .footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(step.kind == .thinking || step.name == "delegate_task" ? .tail : .middle)
                    }
                    if step.status == .background {
                        Text("Background")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.18), in: .capsule)
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                }
                .font(.footnote)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hides the details" : "Shows the details")

            let subtasks = step.subtasks
            if subtasks.count > 1 || (subtasks.count == 1 && isExpanded) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(subtasks.enumerated()), id: \.offset) { _, goal in
                        Label {
                            Text(goal)
                                .lineLimit(isExpanded ? nil : 1)
                        } icon: {
                            Image(systemName: "arrow.turn.down.right")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 18)
            }

            if isExpanded {
                ActivityStepDetails(step: step)
                    .padding(.leading, 18)
                    .transition(.opacity)
            }
        }
    }
}

private struct StatusIndicator: View {
    let step: ActivityStep

    var body: some View {
        Group {
            if step.kind == .thinking {
                Image(systemName: "brain")
                    .foregroundStyle(.secondary)
            } else {
                switch step.status {
                case .running:
                    ProgressView()
                        .controlSize(.mini)
                case .done:
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                case .background:
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.orange)
                }
            }
        }
        .font(.caption)
        .frame(width: 12)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch step.status {
        case .running: "Running"
        case .done: "Done"
        case .failed: "Failed"
        case .background: "Running in the background"
        }
    }
}

/// The arguments of a call and what it returned, or the full reasoning text.
private struct ActivityStepDetails: View {
    let step: ActivityStep

    /// Longest text shown for one block: tool outputs can be huge.
    private static let limit = 4000

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if step.kind == .thinking {
                Text(step.result ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                if let preview = step.preview, step.arguments.isEmpty {
                    block("Call", preview)
                }
                if !step.arguments.isEmpty {
                    block("Arguments", Self.readable(step.arguments))
                }
                if let result = step.result, !result.isEmpty {
                    block(step.status == .failed ? "Error" : "Result", Self.readable(result))
                } else if step.status == .running {
                    Text("Running…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(Self.clipped(text))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.primary.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
        }
    }

    private static func clipped(_ text: String) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n… (\(text.count - limit) more characters)" : text
    }

    /// A JSON object as `key: value` lines, with string values written out as they are so that command
    /// outputs and diffs keep their line breaks. Anything else is shown unchanged.
    static func readable(_ text: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              !object.isEmpty
        else { return text }
        return object.keys.sorted().compactMap { key in
            switch object[key] {
            case is NSNull, nil:
                return nil
            case let string as String:
                return string.contains("\n") ? "\(key):\n\(string)" : "\(key): \(string)"
            case let value:
                let data = try? JSONSerialization.data(
                    withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
                )
                return "\(key): \(data.map { String(decoding: $0, as: UTF8.self) } ?? "\(value)")"
            }
        }
        .joined(separator: "\n")
    }
}
