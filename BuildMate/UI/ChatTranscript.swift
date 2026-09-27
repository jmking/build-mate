import SwiftUI

/// The pending row keeps its identity when the next agent message arrives, so its bubble can grow in place.
struct ChatTranscript<Content: View>: View {
    let messages: [Message]
    let responding: Bool
    var spacing: CGFloat = 20
    @ViewBuilder let content: (Message) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rows: [Row] = []
    @State private var loaded = false
    @State private var nextIndicator: Task<Void, Never>?

    private struct Row: Identifiable {
        var id: UUID
        var message: Message?
    }
    private var motion: Animation { reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.32) }
    private func isSpeech(_ message: Message) -> Bool { message.role == "agent" && message.kind == "text" }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(rows) { row in
                Group {
                    if row.message == nil || row.message.map(isSpeech) == true {
                        AgentResponseBubble(message: row.message)
                    } else if let message = row.message {
                        content(message)
                    }
                }
                .transition(reduceMotion ? .opacity : .scale(scale: 0.8, anchor: .bottomLeading).combined(with: .opacity))
            }
        }
        .onChange(of: messages, initial: true) { update() }
        .onChange(of: responding) { update() }
        .onDisappear { nextIndicator?.cancel(); nextIndicator = nil; loaded = false }
    }

    private func update() {
        guard loaded else {
            var initial = messages.map { Row(id: $0.id, message: $0) }
            if responding { initial.append(Row(id: UUID(), message: nil)) }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { rows = initial }
            loaded = true
            return
        }
        let existing = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.message.map { ($0.id, row) } })
        let pending = rows.first { $0.message == nil }
        let incoming = messages.first { isSpeech($0) && existing[$0.id] == nil }
        let changedSpeech = messages.contains { isSpeech($0) && existing[$0.id]?.message?.body != $0.body }
        var updated = messages.map { message in
            Row(id: existing[message.id]?.id ?? (message.id == incoming?.id ? pending?.id : nil) ?? message.id, message: message)
        }
        if !responding || changedSpeech { nextIndicator?.cancel(); nextIndicator = nil }
        if responding && !changedSpeech && nextIndicator == nil {
            updated.append(Row(id: pending?.id ?? UUID(), message: nil))
        }
        // Reduce Motion updates geometry immediately, without size or scale animation.
        withAnimation(reduceMotion ? nil : motion) { rows = updated }
        if responding && changedSpeech {
            // Wait for a pause in incoming text before showing that more work is underway.
            nextIndicator = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(motion) { rows.append(Row(id: UUID(), message: nil)) }
                nextIndicator = nil
            }
        }
    }
}

struct AgentResponseBubble: View {
    let message: Message?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message {
                HStack(alignment: .firstTextBaseline) {
                    Text("Agent").fontWeight(.medium)
                    Text(message.createdAt, style: .time)
                }.font(.caption).foregroundStyle(.secondary)
                MessageAttachments(messageID: message.id)
                Text(.init(message.body)).font(.system(size: 14)).lineSpacing(5)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else {
                AgentTypingIndicator(showsBackground: false).transition(.opacity)
            }
        }
        .padding(message == nil ? 0 : 14)
        .frame(maxWidth: message == nil ? 64 : 588, alignment: .leading)
        .background(AppSurface.agentBubble, in: RoundedRectangle(cornerRadius: message == nil ? 18 : 12))
        .clipped()
        .scaleEffect(!reduceMotion && !appeared && message == nil ? 0.8 : 1, anchor: .bottomLeading)
        .opacity(!appeared && message == nil ? 0 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.28)) { appeared = true }
        }
    }
}
