import AppKit
import SwiftUI

/// Both conversations follow output only while the reader is already at the end.
/// Content can suspend following when the reader expands earlier material.
struct ChatScrollView<Content: View>: View {
    let messages: [Message]
    let responding: Bool
    @ViewBuilder let content: (@escaping () -> Void) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followsLatest = true
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var hasUnread = false
    @State private var scrolling = false
    @State private var nearBottom = true
    @State private var contentHeight: CGFloat = 0
    @State private var followTask: Task<Void, Never>?

    private struct Position: Equatable {
        let viewport: CGFloat
        let contentHeight: CGFloat
        let nearBottom: Bool
    }

    var body: some View {
        Group {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content { followsLatest = false }
                    Color.clear.frame(height: 1)
                }
                .padding(24).frame(maxWidth: 776).frame(maxWidth: .infinity)
                .background(OverlayScrollbars())
            }
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(messages.isEmpty || !followsLatest ? .top : .bottom, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(followsLatest && !scrolling ? .bottom : nil, for: .sizeChanges)
            .onScrollGeometryChange(for: Position.self) { geometry in
                Position(viewport: geometry.containerSize.height, contentHeight: geometry.contentSize.height,
                         nearBottom: geometry.contentSize.height - geometry.visibleRect.maxY < 80)
            } action: { old, new in
                contentHeight = new.contentHeight
                nearBottom = new.nearBottom
                // Only a reader's scroll changes follow mode, never layout or a programmatic scroll.
                if scrolling {
                    followsLatest = new.nearBottom
                    if followsLatest { hasUnread = false }
                }
                if old.viewport != new.viewport || old.contentHeight != new.contentHeight {
                    followLatest()
                }
            }
            .onScrollPhaseChange { _, phase in
                let moving = phase == .interacting || phase == .decelerating
                if moving {
                    followTask?.cancel()
                    scrolling = true
                    followsLatest = false
                } else if phase == .idle && scrolling {
                    scrolling = false
                    followsLatest = nearBottom
                    if nearBottom { hasUnread = false }
                }
            }
            .onChange(of: messages) {
                if followsLatest && !scrolling { followLatest() }
                else { hasUnread = true }
            }
            .onChange(of: responding) {
                if followsLatest && !scrolling { followLatest() }
                else if responding { hasUnread = true }
            }
            .onDisappear { followTask?.cancel() }
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest && hasUnread {
                    Button("Latest", systemImage: "arrow.down") {
                        followsLatest = true
                        hasUnread = false
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
                            scrollPosition.scrollTo(y: contentHeight)
                        }
                    }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .help("Go to the latest message").accessibilityIdentifier("chat-latest-message")
                        .padding(12)
                }
            }
        }
    }
    private func followLatest() {
        guard followsLatest && !scrolling else { return }
        followTask?.cancel()
        followTask = Task { @MainActor in
            // Wait for transcript rows (including the delayed typing bubble) to lay out.
            await Task.yield()
            guard !Task.isCancelled, followsLatest, !scrolling else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                scrollPosition.scrollTo(y: contentHeight)
            }
        }
    }
}

/// The pending row keeps its identity when the next agent message arrives, so its bubble can grow in place.
struct ChatTranscript<Content: View>: View {
    let messages: [Message]
    let responding: Bool
    var spacing: CGFloat = 20
    var reactionContext: [Message]? = nil
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
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let previous = index > 0 ? rows[index - 1].message : nil
                let timestamp = row.message.map { showsTimestamp($0, after: previous) } ?? false
                if timestamp, let message = row.message {
                    Text(message.createdAt, format: Calendar.current.isDateInToday(message.createdAt) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, index == 0 ? 0 : 16).padding(.bottom, 12)
                }
                Group {
                    if let message = row.message, message.kind == "agentApproval" {
                        AgentApprovalCard(message: message)
                    } else if row.message == nil || row.message.map(isSpeech) == true {
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
                        }.offset(x: -10, y: 24)
                    }
                }
                .padding(.bottom, row.reactions.isEmpty ? 0 : 24)
                .modifier(ChatMessageMetadata(message: row.message))
                .padding(.top, index == 0 || timestamp ? 0 : previous?.role == row.message?.role ? 8 : spacing)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.8, anchor: .bottomLeading).combined(with: .opacity))
            }
        }
        .onChange(of: messages, initial: true) { update() }
        .onChange(of: reactionContext) { update() }
        .onChange(of: responding) { update() }
        .onChange(of: attachmentMessageIDs) { update() }
        .onDisappear { nextIndicator?.cancel(); nextIndicator = nil; loaded = false }
    }

    private func showsTimestamp(_ message: Message, after previous: Message?) -> Bool {
        guard let previous else { return true }
        return message.createdAt.timeIntervalSince(previous.createdAt) >= 300
            || !Calendar.current.isDate(message.createdAt, inSameDayAs: previous.createdAt)
    }

    private func update() {
        let reactions = ChatReactions.targets(in: reactionContext ?? messages, attachmentMessageIDs: attachmentMessageIDs)
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
        withAnimation(reduceMotion ? nil : motion) { rows = updated }
        if responding && changedSpeech {
            nextIndicator = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(motion) { rows.append(Row(id: UUID(), message: nil)) }
                nextIndicator = nil
            }
        }
    }
}

struct ChatMessageMetadata: ViewModifier {
    let message: Message?
    func body(content: Content) -> some View {
        if let message {
            let sender = message.role == "user" ? "You" : message.role == "agent" ? "Agent" : "Build Mate"
            let timestamp = message.createdAt.formatted(date: .complete, time: .standard)
            content
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(sender), \(timestamp)")
                .help("\(sender) · \(timestamp)")
                .contextMenu {
                    Text("\(sender) · \(timestamp)")
                    Button("Copy Message", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.body, forType: .string)
                    }.help("Copy this message’s text")
                    Button("Copy Timestamp", systemImage: "clock") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(timestamp, forType: .string)
                    }.help("Copy the exact time this message was sent")
                }
        } else { content }
    }
}

struct ChatMessageBubble: View {
    let message: Message
    private var user: Bool { message.role == "user" }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MessageAttachments(messageID: message.id)
            if !message.body.isEmpty { MarkdownBrief(message.body, fillsWidth: false) }
        }
        .padding(14)
        .foregroundStyle(user ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
        .tint(user ? .white : .accentColor)
        .background(user ? AppSurface.userBubble : .agentBubble, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 588, alignment: user ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
    }
}

struct AgentResponseBubble: View {
    let message: Message?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message {
                MessageAttachments(messageID: message.id)
                if !message.body.isEmpty { MarkdownBrief(message.body, fillsWidth: false).transition(.opacity) }
            } else {
                AgentTypingIndicator(showsBackground: false).transition(.opacity)
            }
        }
        .padding(message == nil ? 0 : 14)
        .background(AppSurface.agentBubble, in: RoundedRectangle(cornerRadius: message == nil ? 18 : 14))
        .clipShape(RoundedRectangle(cornerRadius: message == nil ? 18 : 14))
        .scaleEffect(!reduceMotion && !appeared && message == nil ? 0.8 : 1, anchor: .bottomLeading)
        .opacity(!appeared && message == nil ? 0 : 1)
        .frame(maxWidth: 588, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.28)) { appeared = true }
        }
    }
}
