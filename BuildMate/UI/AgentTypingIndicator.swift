import SwiftUI

/// One quiet, accessible status bubble shared by project and task conversations.
struct AgentTypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if reduceMotion {
                bubble(time: nil)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    bubble(time: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent is responding")
        .accessibilityIdentifier("agent-typing-indicator")
        .help("Agent is responding")
        .transition(.opacity)
    }

    private func bubble(time: TimeInterval?) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                // A short wave passes through the dots, followed by a quiet rest.
                let phase = time.map { ($0.truncatingRemainder(dividingBy: 1.6) - Double(index) * 0.18) / 0.65 }
                let lift = phase.map { $0 > 0 && $0 < 1 ? sin($0 * .pi) : 0 } ?? 0
                Circle().fill(.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(time == nil ? 0.7 : 0.4 + lift * 0.5)
                    .offset(y: -lift * 3)
            }
        }
        .frame(width: 64, height: 36)
        .background(AppSurface.agentBubble, in: Capsule())
    }
}
