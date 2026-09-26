import SwiftUI

struct ProjectChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let projectID: UUID
    @State private var sending = false
    @FocusState private var focused: Bool
    private var project: Project? { model.snapshot.projects.first { $0.id == projectID } }
    private var session: Session? { model.snapshot.sessions.first { $0.ownerType == "project" && $0.ownerId == projectID } }
    private var messages: [Message] { model.snapshot.messages.filter { $0.sessionId == session?.id } }
    private var busy: Bool { ["queued", "running", "waiting"].contains(session?.status ?? "") }
    private var question: Message? { messages.last { $0.kind == "question" && $0.payload["answer"] == .null } }
    private var fromChat: [WorkTask] { model.snapshot.tasks.filter { $0.projectId == projectID && $0.origin == "chat" } }
    private var files: [URL] { model.attachmentDrafts[projectID] ?? [] }
    private var fileBinding: Binding<[URL]> { Binding(get: { model.attachmentDrafts[projectID] ?? [] }, set: { model.attachmentDrafts[projectID] = $0 }) }
    var body: some View {
        @Bindable var model = model
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if messages.isEmpty {
                        ContentUnavailableView("What would you like to build?", systemImage: "bubble.left.and.bubble.right", description: Text("Discuss an idea, ask about your code, or shape the next tasks."))
                            .frame(maxWidth: .infinity).padding(.top, 70)
                    }
                    ForEach(messages) { message in
                        if message.kind == "proposal", let proposal = model.snapshot.proposals.first(where: { $0.messageId == message.id }) {
                            ProjectProposalCard(proposal: proposal)
                        } else if message.kind == "question" {
                            ProjectQuestionCard(message: message, projectID: projectID)
                        } else if message.kind == "activity" {
                            DisclosureGroup {
                                Text(message.payload["output"].string ?? "").font(.caption.monospaced()).textSelection(.enabled)
                            } label: { Label(message.body, systemImage: "terminal").font(.caption).lineLimit(2) }
                                .foregroundStyle(.secondary).help("Show the project inspection output")
                        } else if message.role == "system" {
                            Label(message.body, systemImage: message.kind == "error" ? "exclamationmark.triangle" : "arrow.right")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        } else { ProjectChatBubble(message: message) }
                    }
                    if busy {
                        HStack(spacing: 8) {
                            if session?.status == "running" { ProgressView().controlSize(.small) }
                            Text(session?.status == "waiting" ? "Waiting for your answer" : session?.status == "queued" ? (project?.paused == true || model.settings.paused ? "Chat queued · work is paused" : "Waiting for an agent slot") : "Agent is responding…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if ["failed", "interrupted"].contains(session?.status ?? "") {
                        Button("Retry Response", systemImage: "arrow.clockwise") { model.perform { try await model.core.retryProjectChat(projectID) } }
                            .help("Continue this project conversation using the same Codex thread")
                    }
                    Color.clear.frame(height: 1).id("latest")
                }.padding(28).frame(maxWidth: 776).frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onChange(of: messages.count) { if sending || busy { withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { proxy.scrollTo("latest", anchor: .bottom) } } }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                ChatAttachmentTray(files: fileBinding, root: model.store.root)
                if question != nil {
                    Text("Answer the question to continue.").font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    ChatAttachmentControls(files: fileBinding, root: model.store.root).disabled(sending)
                    TextField(question != nil ? "Your answer…" : "Describe what you want built…", text: Binding(get: { model.chatDrafts[projectID] ?? "" }, set: { model.chatDrafts[projectID] = $0 }), axis: .vertical)
                        .font(.system(size: 14)).lineLimit(1...5).textFieldStyle(.plain).padding(.vertical, 7).frame(minHeight: 32)
                        .focused($focused).accessibilityLabel("Project message").accessibilityIdentifier("project-message")
                        .disabled(sending || (busy && question == nil) || question?.payload["allowsFreeText"].bool == false).onSubmit(send)
                    if busy && question == nil {
                        Button { model.perform { await model.core.stopProjectChat(projectID) } } label: { Image(systemName: "stop.fill").frame(width: 18, height: 18) }
                            .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
                            .accessibilityLabel("Stop response").help("Stop this project response")
                    } else {
                        Button(action: send) { Image(systemName: "arrow.up").frame(width: 18, height: 18) }
                            .buttonStyle(.borderedProminent).buttonBorderShape(.circle).controlSize(.large)
                            .disabled(sending || (model.chatDrafts[projectID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty || question?.payload["allowsFreeText"].bool == false)
                            .keyboardShortcut(.return, modifiers: .command).accessibilityLabel("Send project message")
                            .accessibilityIdentifier("send-project-message").help("Send message (⌘Return)")
                    }
                }
            }.padding(14).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 16).frame(maxWidth: 776).frame(maxWidth: .infinity)
        }
        .modifier(ChatAttachmentDrop(files: fileBinding, root: model.store.root, enabled: !sending))
        .inspector(isPresented: $model.showInspector) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("From this chat").font(.headline).accessibilityAddTraits(.isHeader)
                    if fromChat.isEmpty { Text("Tasks you create here will appear here.").foregroundStyle(.secondary) }
                    ForEach(fromChat) { task in
                        Button { model.destination = .task(task.id) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: task.state.symbol).foregroundStyle(task.state.color).frame(width: 16)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.title).foregroundStyle(.primary)
                                    Text(task.state.title).font(.caption).foregroundStyle(.secondary)
                                    ForEach(task.dependsOn, id: \.self) { id in
                                        if let parent = model.snapshot.tasks.first(where: { $0.id == id }) { Text("Waits on \(parent.title)").font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Open \(task.title)")
                        Divider()
                    }
                    Text("Project").font(.headline).accessibilityAddTraits(.isHeader)
                    if let project {
                        Text(project.repoPath).font(.caption.monospaced()).textSelection(.enabled)
                        Text("\(project.defaultBranch) · Codex").foregroundStyle(.secondary)
                        Text(project.settings.model ?? "Default Codex model").font(.caption).foregroundStyle(.secondary)
                        Text(project.host == .local ? "Local Git repository" : project.remoteSlug).foregroundStyle(.secondary)
                    }
                    Text("The project agent reads code in its own checkout. Task agents build changes in separate worktrees.").font(.caption).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.background(AppSurface.raised)
                .safeAreaInset(edge: .bottom) {
                    Button("Open Tasks", systemImage: "rectangle.split.3x1") { model.destination = .project(projectID, .tasks) }
                        .help("Show this project’s task board (⌘4)").padding(16).frame(maxWidth: .infinity).background(AppSurface.raised)
                }.inspectorColumnWidth(min: 300, ideal: 340, max: 440)
        }
        .toolbar {
            ToolbarItem { Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }.help("Toggle Inspector (⌥⌘I)") }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: model.showInspector)
    }
    private func send() {
        guard !sending else { return }
        let text = (model.chatDrafts[projectID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !files.isEmpty else { return }
        let pending = question
        let attached = files
        sending = true
        model.perform {
            defer { sending = false }
            if let pending { try await model.core.answerProjectQuestion(pending.id, projectID: projectID, answer: text.isEmpty ? "See attached files." : text, files: attached) }
            else { try await model.core.sendProjectMessage(projectID, text: text, files: attached) }
            model.chatDrafts[projectID] = ""
            model.attachmentDrafts[projectID] = []
            for url in attached { removeDraftCapture(url, root: model.store.root) }
        }
    }
}

private struct ProjectChatBubble: View {
    let message: Message
    private var user: Bool { message.role == "user" }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(user ? "You" : "Agent").fontWeight(.medium)
                Text(message.createdAt, style: .time)
            }.font(.caption).foregroundStyle(user ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            MessageAttachments(messageID: message.id)
            Text(.init(message.body)).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.foregroundStyle(user ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary)).tint(user ? .white : .accentColor)
            .frame(maxWidth: 560, alignment: .leading).padding(14)
            .background(user ? AppSurface.userBubble : .agentBubble, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
    }
}

private struct ProjectQuestionCard: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let projectID: UUID
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message.body, systemImage: "questionmark.circle").fontWeight(.medium)
            if let answer = message.payload["answer"].string { Text(answer).foregroundStyle(.secondary) }
            else {
                ForEach(message.payload["options"].array.compactMap(\.string), id: \.self) { option in
                    Button(option) { model.perform { try await model.core.answerProjectQuestion(message.id, projectID: projectID, answer: option) } }
                        .help("Answer: \(option)").accessibilityLabel("\(message.body): \(option)")
                }
                if message.payload["allowsFreeText"].bool != false { Text("Or answer in the message field below.").font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.purple.opacity(0.3)))
    }
}

private struct ProjectProposalCard: View {
    @Environment(AppModel.self) private var model
    let proposal: Proposal
    @State private var excluded: Set<Int> = []
    @State private var saving = false
    private var selected: Set<Int> { Set(proposal.tasks.indices).subtracting(excluded) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(proposal.status == "created" ? "Tasks created" : proposal.status == "dismissed" ? "Proposal dismissed" : "\(proposal.tasks.count) proposed tasks").font(.headline).accessibilityAddTraits(.isHeader)
            if proposal.status == "created" {
                ForEach(proposal.createdTaskIds, id: \.self) { id in
                    if let task = model.snapshot.tasks.first(where: { $0.id == id }) {
                        Button { model.destination = .task(id) } label: { Label(task.title, systemImage: task.state.symbol) }.help("Open \(task.title)")
                    }
                }
            } else {
                ForEach(proposal.tasks.indices, id: \.self) { index in
                    let item = proposal.tasks[index]
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(item.title, isOn: Binding(get: { !excluded.contains(index) }, set: { if $0 { excluded.remove(index) } else { excluded.insert(index) } }))
                            .toggleStyle(.checkbox).fontWeight(.medium).disabled(proposal.status != "open" || saving)
                            .help("Include \(item.title) when creating tasks")
                        Text(item.description).font(.callout).foregroundStyle(.secondary).padding(.leading, 20)
                        ForEach(item.dependsOnIndex, id: \.self) { dependency in
                            if proposal.tasks.indices.contains(dependency) { Label("After \(proposal.tasks[dependency].title)", systemImage: "link").font(.caption).foregroundStyle(.secondary).padding(.leading, 20) }
                        }
                    }
                    if index != proposal.tasks.indices.last { Divider() }
                }
                if proposal.status == "open" {
                    Divider()
                    ViewThatFits {
                        HStack { actions }
                        VStack(alignment: .leading, spacing: 12) { actions }
                    }.disabled(saving)
                }
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppSurface.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
    }
    @ViewBuilder private var actions: some View {
        Button("Dismiss") { model.perform { try await model.core.dismissProposal(proposal.id, projectID: proposal.projectId) } }.help("Dismiss this proposal without creating tasks")
        Spacer(minLength: 4)
        Button("Add to queue") { accept(queue: true) }.disabled(selected.isEmpty || model.selectedProject?.runBlockReason != nil)
            .help(model.selectedProject?.runBlockReason ?? "Create selected tasks in Queue; they start when an agent slot is available")
        Button("Add \(selected.count) to Backlog") { accept(queue: false) }.buttonStyle(.borderedProminent).disabled(selected.isEmpty)
            .help("Create selected tasks in Backlog without starting coding")
    }
    private func accept(queue: Bool) {
        let selection = selected
        saving = true
        model.perform {
            defer { saving = false }
            _ = try await model.core.acceptProposal(proposal.id, projectID: proposal.projectId, selected: selection, queue: queue ? selection : [])
        }
    }
}
