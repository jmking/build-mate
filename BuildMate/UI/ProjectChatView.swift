import SwiftUI

struct ProjectChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let projectID: UUID
    @State private var sending = false
    @State private var textSelection: TextSelection?
    @FocusState private var focused: Bool
    private var project: Project? { model.snapshot.projects.first { $0.id == projectID } }
    private var session: Session? { model.snapshot.sessions.first { $0.ownerType == "project" && $0.ownerId == projectID } }
    private var messages: [Message] { model.snapshot.messages.filter { $0.sessionId == session?.id } }
    private var conversation: [Message] { messages.filter { $0.kind != "activity" && $0.kind != "event" } }
    private var busy: Bool { ["queued", "running", "waiting"].contains(session?.status ?? "") }
    private var responding: Bool { session?.status == "running" && project?.paused != true && !model.settings.paused }
    private var question: Message? { messages.last { $0.kind == "question" && $0.payload["answer"] == .null } }
    private var fromChat: [WorkTask] {
        model.snapshot.tasks.filter { $0.projectId == projectID && $0.origin == "chat" }
            .sorted { $0.createdAt == $1.createdAt ? $0.number > $1.number : $0.createdAt > $1.createdAt }
    }
    private var files: [URL] { model.attachmentDrafts[projectID] ?? [] }
    private var draft: Binding<String> { Binding(get: { model.chatDrafts[projectID] ?? "" }, set: { model.chatDrafts[projectID] = $0 }) }
    private var fileBinding: Binding<[URL]> { Binding(get: { model.attachmentDrafts[projectID] ?? [] }, set: { model.attachmentDrafts[projectID] = $0 }) }

    var body: some View {
        @Bindable var model = model
        ChatScrollView(messages: conversation, responding: responding) { _ in
            if messages.isEmpty {
                Text("What would you like to build?").font(.title2.weight(.medium))
                    .frame(maxWidth: .infinity).padding(.top, 70)
            }
            ChatTranscript(messages: conversation, responding: responding) { message in
                if message.kind == "proposal", let proposal = model.snapshot.proposals.first(where: { $0.messageId == message.id }) {
                    ProjectProposalCard(proposal: proposal)
                } else if message.kind == "question" {
                    ProjectQuestionCard(message: message, projectID: projectID)
                } else if message.role == "system" {
                    Label(message.body, systemImage: message.kind == "error" ? "exclamationmark.triangle" : "info.circle")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                } else { ChatMessageBubble(message: message) }
            }
            if !model.settings.paused && project?.paused != true && question == nil,
               let reason = model.projectChatWaitingReason(projectID) {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if ["failed", "interrupted"].contains(session?.status ?? "") {
                Button("Retry Response", systemImage: "arrow.clockwise") { model.perform { try await model.core.retryProjectChat(projectID) } }
                    .help("Continue this project conversation")
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) { composer }
        .modifier(ChatAttachmentDrop(files: fileBinding, root: model.store.root, enabled: !sending))
        .inspector(isPresented: $model.showInspector) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("From this chat").font(.headline).accessibilityAddTraits(.isHeader)
                    if fromChat.isEmpty { Text("No tasks created yet").font(.callout).foregroundStyle(.secondary) }
                    ForEach(Array(fromChat.prefix(5))) { task in
                        Button { model.destination = .task(task.id) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: task.state.symbol).foregroundStyle(task.state.color).frame(width: 16).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.title).foregroundStyle(.primary).lineLimit(2)
                                    Text(task.state.title).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Open \(task.title)")
                            .accessibilityLabel("\(task.title), \(task.state.title)")
                            .contextMenu {
                                Button("Delete Task…", role: .destructive) { model.taskToDelete = task }
                                    .disabled(model.deletingTasks.contains(task.id)).help("Delete this task, including its conversation and worktree")
                            }
                    }
                    if !fromChat.isEmpty {
                        Button("View All Tasks", systemImage: "arrow.right") { model.destination = .project(projectID, .tasks) }
                            .buttonStyle(.borderless).help("Show all tasks in this project (⌘3)")
                    }
                    if let session {
                        SubagentActivityView(agents: model.snapshot.subagents.filter { $0.sessionId == session.id })
                    }
                    let activity = messages.filter { $0.kind == "activity" || $0.kind == "event" }
                    if !activity.isEmpty {
                        DisclosureGroup("Activity") {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(activity) { item in
                                    if item.kind == "activity" {
                                        DisclosureGroup(item.body) {
                                            Text(item.payload["output"].string ?? "").font(.caption.monospaced()).textSelection(.enabled)
                                        }.help("Show this inspection’s output")
                                    } else { Text(item.body) }
                                }
                            }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                        }.help("Show project inspection history")
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    .background(OverlayScrollbars())
            }.background(AppSurface.raised)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let project {
                        VStack(alignment: .leading, spacing: 8) {
                            Divider()
                            VStack(alignment: .leading, spacing: 6) {
                                Text(project.name).font(.subheadline.weight(.medium))
                                let repositories = model.repositories(project.id)
                                Text("\(repositories.count) \(repositories.count == 1 ? "repository" : "repositories")")
                                    .font(.caption).foregroundStyle(.secondary)
                                DisclosureGroup("Project details") {
                                    VStack(alignment: .leading, spacing: 10) {
                                        ForEach(repositories) { repository in
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(repository.name).fontWeight(.medium)
                                                Text(repository.defaultBranch)
                                                Text(repository.repoPath).textSelection(.enabled)
                                            }
                                        }
                                    }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                                }.font(.caption).help("Show this project’s repositories, branches and paths")
                            }.padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 8)
                        }.frame(maxWidth: .infinity, alignment: .leading).background(AppSurface.raised)
                    }
                }.inspectorColumnWidth(min: 280, ideal: 320, max: 400)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: model.showInspector)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            ChatAttachmentTray(files: fileBinding, root: model.store.root)
            HStack(alignment: .bottom, spacing: 10) {
                ChatAttachmentControls(files: fileBinding, root: model.store.root).disabled(sending)
                TextField(question != nil ? "Your answer…" : "Message the agent…", text: draft, selection: $textSelection, axis: .vertical)
                    .chatLineBreaks(text: draft, selection: $textSelection)
                    .font(.system(size: 14)).lineLimit(1...5).textFieldStyle(.plain).padding(.vertical, 7).frame(minHeight: 32)
                    .focused($focused).accessibilityLabel("Project message").accessibilityIdentifier("project-message")
                    .disabled(sending || question?.payload["allowsFreeText"].bool == false).onSubmit(send)
                if busy && question == nil && draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty {
                    Button { model.perform { await model.core.stopProjectChat(projectID) } } label: {
                        Image(systemName: "stop.fill").frame(width: 18, height: 18)
                    }.buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
                        .accessibilityLabel("Stop response").help("Stop this response; keep your draft")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up").frame(width: 18, height: 18) }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.circle).controlSize(.large)
                        .disabled(sending || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty || question?.payload["allowsFreeText"].bool == false)
                        .keyboardShortcut(.return, modifiers: .command).accessibilityLabel("Send project message")
                        .accessibilityIdentifier("send-project-message").help("Send message (⌘Return)")
                }
            }
            ModelPicker(ownerID: projectID, projectChat: true).id(projectID).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 4)
        }.padding(12).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 16).frame(maxWidth: 776).frame(maxWidth: .infinity)
    }

    private func send() {
        guard !sending else { return }
        let text = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
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

private struct ProjectQuestionCard: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let projectID: UUID
    @State private var answering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message.body, systemImage: "questionmark.circle").fontWeight(.medium)
            if let answer = message.payload["answer"].string { MarkdownBrief(answer) }
            else {
                ForEach(message.payload["options"].array.compactMap(\.string), id: \.self) { option in
                    Button(option) {
                        answering = true
                        model.perform {
                            defer { answering = false }
                            try await model.core.answerProjectQuestion(message.id, projectID: projectID, answer: option)
                        }
                    }.disabled(answering)
                        .help("Answer: \(option)").accessibilityLabel("\(message.body): \(option)")
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppSurface.raised, in: RoundedRectangle(cornerRadius: 12))
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
            } else if proposal.status != "dismissed" {
                ForEach(proposal.tasks.indices, id: \.self) { index in
                    let item = proposal.tasks[index]
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(item.title, isOn: Binding(get: { !excluded.contains(index) }, set: { if $0 { excluded.remove(index) } else { excluded.insert(index) } }))
                            .toggleStyle(.checkbox).fontWeight(.medium).disabled(proposal.status != "open" || saving)
                            .help("Include \(item.title) when creating tasks")
                        if model.repositories(proposal.projectId).count > 1,
                           let repository = model.snapshot.repositories.first(where: { $0.id == item.repositoryID }) {
                            Text(repository.name).font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
                        }
                        DisclosureGroup("Brief") { MarkdownBrief(item.description).padding(.top, 6) }
                            .font(.callout).padding(.leading, 20).help("Read the proposed task’s brief")
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
            .background(AppSurface.raised, in: RoundedRectangle(cornerRadius: 12))
    }
    @ViewBuilder private var actions: some View {
        Button("Dismiss") { model.perform { try await model.core.dismissProposal(proposal.id, projectID: proposal.projectId) } }.help("Dismiss this proposal without creating tasks")
        Spacer(minLength: 4)
        Button("Add \(selected.count) to Queue") { accept() }.buttonStyle(.borderedProminent).disabled(selected.isEmpty)
            .help("Create selected tasks in Queue; they start when an agent slot is available")
    }
    private func accept() {
        let selection = selected
        saving = true
        model.perform {
            defer { saving = false }
            _ = try await model.core.acceptProposal(proposal.id, projectID: proposal.projectId, selected: selection)
        }
    }
}
