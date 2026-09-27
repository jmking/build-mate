import SwiftUI

/// The pending row keeps its identity when the next agent message arrives, so its bubble can grow in place.
struct ChatTranscript<Content: View>: View {
    let messages: [Message]
    let responding: Bool
    var spacing: CGFloat = 20
    @ViewBuilder let content: (Message) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var model
    @State private var rows: [Row] = []
    @State private var observedMessages: [Message] = []
    @State private var loaded = false
    @State private var nextIndicator: Task<Void, Never>?

    private struct Row: Identifiable {
        var id: UUID
        var message: Message?
        var reactions: [Message] = []
    }
    private var attachmentMessageIDs: Set<UUID> { Set(model.snapshot.attachments.filter { $0.ownerType == "message" }.map(\.ownerId)) }
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
                .overlay(alignment: .bottomTrailing) {
                    if !row.reactions.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(row.reactions) { reaction in
                                Text(reaction.body.trimmingCharacters(in: .whitespacesAndNewlines))
                                    .font(.system(size: 16)).padding(6)
                                    .background(AppSurface.agentBubble, in: Capsule())
                                    .overlay { Capsule().strokeBorder(AppSurface.window, lineWidth: 2) }
                                    .accessibilityLabel("Agent reacted \(reaction.body) to your message")
                                    .help("Agent reacted \(reaction.body)")
                            }
                        }.offset(x: -10, y: 14)
                    }
                }
                .padding(.bottom, row.reactions.isEmpty ? 0 : 14)
                .accessibilityElement(children: .contain)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.8, anchor: .bottomLeading).combined(with: .opacity))
            }
        }
        .onChange(of: messages, initial: true) { update() }
        .onChange(of: responding) { update() }
        .onChange(of: attachmentMessageIDs) { update() }
        .onDisappear { nextIndicator?.cancel(); nextIndicator = nil; loaded = false }
    }

    private func update() {
        let reactions = ChatReactions.targets(in: messages, attachmentMessageIDs: attachmentMessageIDs)
        let reactionIDs = Set(reactions.values.flatMap { $0.map(\.id) })
        let visible = messages.filter { !reactionIDs.contains($0.id) }
        let previous = Dictionary(uniqueKeysWithValues: observedMessages.map { ($0.id, $0) })
        observedMessages = messages
        guard loaded else {
            var initial = visible.map { Row(id: $0.id, message: $0, reactions: reactions[$0.id] ?? []) }
            if responding { initial.append(Row(id: UUID(), message: nil)) }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { rows = initial }
            loaded = true
            return
        }
        let existing = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.message.map { ($0.id, row) } })
        let pending = rows.first { $0.message == nil }
        let incoming = visible.first { isSpeech($0) && existing[$0.id] == nil }
        let changedSpeech = messages.contains { isSpeech($0) && previous[$0.id] != $0 }
        var updated = visible.map { message in
            Row(id: existing[message.id]?.id ?? (message.id == incoming?.id ? pending?.id : nil) ?? message.id, message: message, reactions: reactions[message.id] ?? [])
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
