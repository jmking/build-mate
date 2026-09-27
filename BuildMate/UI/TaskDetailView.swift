import AppKit
import SwiftUI

struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let task: WorkTask
    @State private var message = ""
    @State private var messageStatus: String?
    @State private var sending = false
    @State private var openingPR = false
    private var openQuestion: Question? { questions.first { $0.answer == nil } }
    private var isPaused: Bool { task.paused || model.settings.paused || model.selectedProject?.paused == true }
    private var activeTurn: Bool { session?.status == "running" && session?.currentTurn != nil }
    private var composerTitle: String { openQuestion != nil ? "Answer the question" : (activeTurn || task.state == .humanReview) ? "Message the agent" : "Save a message for the next run" }
    private var actionTitle: String { openQuestion != nil ? "Send answer" : (activeTurn || task.state == .humanReview) ? "Send message" : "Save message" }
    private var composerExplanation: String {
        if let question = openQuestion { return question.allowsFreeText ? "Your answer resolves this question. Paused tasks stay paused." : "Choose one of the answer buttons above." }
        if task.state == .humanReview { return isPaused ? "Tell the agent what to change. Work will resume when unpaused." : "Tell the agent what to change. It will continue working." }
        return activeTurn ? "Sent to the current agent turn." : "Messages are saved for when work resumes."
    }
    private var session: Session? { model.snapshot.sessions.first { $0.ownerId == task.id && $0.ownerType == "task" } }
    private var messages: [Message] { model.snapshot.messages.filter { $0.sessionId == session?.id } }
    private var questions: [Question] { model.snapshot.questions.filter { $0.taskId == task.id } }
    private var proof: Proof? { model.snapshot.proofs.first { $0.taskId == task.id } }
    private var files: [URL] { model.attachmentDrafts[task.id] ?? [] }
    private var fileBinding: Binding<[URL]> { Binding(get: { model.attachmentDrafts[task.id] ?? [] }, set: { model.attachmentDrafts[task.id] = $0 }) }
    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Task brief").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline) {
                        Text(task.title).font(.title3.weight(.semibold))
                        Spacer(minLength: 12)
                        Button("Edit", systemImage: "pencil") { model.editingTask = task }
                            .buttonStyle(.borderless).help("Edit task (⇧⌘E)")
                            .accessibilityLabel("Edit task").accessibilityIdentifier("edit-task")
                    }
                    MessageAttachments(messageID: task.id, ownerType: "task")
                    Text(task.description.isEmpty ? "No additional description." : task.description).textSelection(.enabled).font(.system(size: 14)).lineSpacing(5)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                ForEach(messages) { item in
                    if let question = questions.first(where: { $0.messageId == item.id }) { TaskQuestion(question: question) }
                    else if item.kind == "event" {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "arrow.right").accessibilityHidden(true)
                            Text(displayText(item))
                            Text(item.createdAt, style: .time).foregroundStyle(.secondary).fixedSize()
                        }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        let conversation = item.role == "user" || item.role == "agent"
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.role == "agent" ? "Agent" : item.role == "user" ? "You" : "Build Mate").fontWeight(.medium)
                                Text(item.createdAt, style: .time)
                            }.font(.caption).foregroundStyle(item.role == "user" ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                            MessageAttachments(messageID: item.id)
                            Text(.init(displayText(item))).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .foregroundStyle(item.role == "user" ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                        .tint(item.role == "user" ? .white : .accentColor)
                        .frame(maxWidth: conversation ? 560 : .infinity, alignment: .leading)
                        .padding(conversation ? 14 : 0)
                        .background((item.role == "user" ? AppSurface.userBubble : .agentBubble).opacity(conversation ? 1 : 0), in: RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: .infinity, alignment: item.role == "user" ? .trailing : .leading)
                    }
                }
                if task.state == .building {
                    if isPaused {
                        Label("Paused", systemImage: "pause.circle").font(.caption).foregroundStyle(.secondary)
                    } else if activeTurn {
                        AgentTypingIndicator()
                    } else if !model.retryNeedsAttention(task) {
                        Text("Waiting for an agent…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let retry = task.retry, model.retryNeedsAttention(task) {
                    Label(retry.error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Text(task.paused ? "Resume when you’re ready to try again." : "Next retry: \(retry.dueAt.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28).frame(maxWidth: 776).frame(maxWidth: .infinity)
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if !task.state.terminal && task.state != .backlog {
                VStack(alignment: .leading, spacing: 8) {
                    ChatAttachmentTray(files: fileBinding, root: model.store.root)
                    Text(messageStatus ?? composerExplanation).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("message-status")
                    HStack(alignment: .bottom, spacing: 12) {
                    ChatAttachmentControls(files: fileBinding, root: model.store.root).disabled(sending)
                        TextField(composerTitle, text: $message, axis: .vertical).lineLimit(1...5).textFieldStyle(.plain).font(.system(size: 14))
                            .padding(.vertical, 7).frame(minHeight: 32)
                            .accessibilityLabel(composerTitle).accessibilityIdentifier("task-message").onSubmit(send)
                            .disabled(sending || openQuestion?.allowsFreeText == false)
                        Button(action: send) { Label(actionTitle, systemImage: "arrow.up").labelStyle(.iconOnly).frame(width: 18, height: 18) }
                            .buttonStyle(.borderedProminent).buttonBorderShape(.circle).controlSize(.large)
                            .accessibilityLabel(actionTitle).help(actionTitle + " (⌘Return)")
                            .disabled(sending || openQuestion?.allowsFreeText == false || (message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty))
                            .keyboardShortcut(.return, modifiers: .command)
                            .accessibilityIdentifier("send-task-message")
                    }
                }.padding(14).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
                    .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 16)
                    .frame(maxWidth: 776)
                    .frame(maxWidth: .infinity)
                .onChange(of: message) { if !message.isEmpty { messageStatus = nil } }

            }
        }
        .modifier(ChatAttachmentDrop(files: fileBinding, root: model.store.root, enabled: !sending && !task.state.terminal && task.state != .backlog))
        .inspector(isPresented: $model.showInspector) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Status").font(.headline).accessibilityAddTraits(.isHeader)
                    RoadToMerge(task: task)
                    Divider()
                    Text("Brief").font(.headline)
                    Text(task.description.isEmpty ? task.title : task.description).foregroundStyle(.secondary)
                    LabeledContent("Proof", value: task.proofRequirement.title)
                    if let path = task.worktreePath {
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Worktree").font(.headline).accessibilityAddTraits(.isHeader)
                                Spacer()
                                Button("Open in Terminal", systemImage: "terminal") { model.openLocation(task: task, appID: "com.apple.Terminal") }
                                    .help("Open a new Terminal at this worktree")
                                    .accessibilityIdentifier("open-worktree-terminal")
                                Button("Open in Finder", systemImage: "folder") { model.openLocation(task: task) }
                                    .help("Open this worktree in Finder")
                                    .accessibilityIdentifier("open-worktree-finder")
                            }.labelStyle(.iconOnly).buttonStyle(.bordered).controlSize(.small)
                            Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    if let proof {
                        Divider()
                        ReviewEvidence(task: task, proof: proof)
                    }
                    if let pr = task.pr, let url = URL(string: pr.url) {
                        Link("View Pull Request #\(pr.number)", destination: url).help("Open this pull request in your browser")
                    }
                    if task.state == .backlog {
                        Button("Refine with Agent", systemImage: "sparkles") { model.refineInChat(task) }.help("Discuss and refine this task in project chat without starting coding")
                        Button("Move to Queue") { model.perform { try await model.moveToTodo(task) } }.buttonStyle(.borderedProminent)
                            .help(model.selectedProject?.runBlockReason ?? "Queue this task to run when an agent slot is available and the project is resumed")
                            .disabled(model.selectedProject?.runBlockReason != nil)
                        if let reason = model.selectedProject?.runBlockReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    }
                    if task.state == .needsClarification {
                        Button("Let the Agent Decide…") { model.reviewSheet = .defaults(task.id) }
                            .disabled(questions.filter { $0.answer == nil && $0.blocking }.contains { $0.suggestedAnswer == nil })
                            .help("Review the agent’s suggested answers before accepting them; unavailable when a question has no suggestion")
                    }
                    ForEach(model.snapshot.approvals.filter { $0.taskId == task.id && $0.kind == "plan" && $0.status == "pending" }) { approval in
                        if let plan = approval.planText { Text("Proposed plan").font(.headline); Text(plan).textSelection(.enabled) }
                        Button("Approve Plan") { model.perform { try await model.core.approvePlan(approval.id) } }.buttonStyle(.borderedProminent)
                            .help("Approve this plan so the agent can continue when work is resumed")
                    }
                    if task.state == .humanReview {
                        Divider()
                        PreviewControls(task: task)
                        if model.selectedProject?.host == .local {
                            Text("Changes are committed in the task worktree. Publishing and pull requests are not available for local projects yet.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if task.state == .humanReview && model.selectedProject?.host == .github {
                    VStack(spacing: 10) {
                        Divider()
                        HStack {
                            Spacer(minLength: 4)
                            if model.selectedProject?.host == .github {
                                Button(openingPR ? "Opening…" : "Open Pull Request") {
                                    openingPR = true
                                    model.perform {
                                        defer { openingPR = false }
                                        try await model.core.openPullRequest(task.id)
                                    }
                                }.buttonStyle(.borderedProminent).disabled(openingPR || proof?.complete != true || task.paused)
                                    .help("Publish the reviewed changes as a GitHub pull request")
                            }
                        }.padding(.horizontal, 16).padding(.bottom, 16)
                    }.background(AppSurface.raised)
                }
            }
            .background(AppSurface.raised).inspectorColumnWidth(min: 320, ideal: 380, max: 440)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: model.showInspector)
        .toolbar {
            ToolbarItem { ModelPicker(ownerID: task.id).id(task.id) }
            ToolbarItem { OpenInMenu().disabled(task.worktreePath == nil) }
            ToolbarItem {
                Button(task.paused ? "Resume" : "Pause", systemImage: task.paused ? "play" : "pause") { model.perform { try await model.core.pause(task.id, paused: !task.paused) } }.disabled(task.state.terminal)
                    .help(task.paused ? "Resume work on this task (⌘.)" : "Pause work on this task (⌘.)")
            }
        }
    }
    private func displayText(_ item: Message) -> String {
        if item.kind == "event", item.body.hasPrefix("Moved to "), let state = TaskState(rawValue: String(item.body.dropFirst(9))) { return "Moved to " + state.title }
        return item.body
    }
    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !files.isEmpty), !sending, openQuestion?.allowsFreeText != false else { return }
        let question = openQuestion
        let attached = files
        sending = true
        model.perform {
            defer { sending = false }
            if let question {
                try await model.core.answer(question.id, text: text.isEmpty ? "See attached files." : text, files: attached)
                messageStatus = "Answer saved."
            } else {
                let delivery = try await model.core.steer(task.id, text: text, files: attached)
                switch delivery {
                case .sent: messageStatus = "Sent to the agent."
                case .saved: messageStatus = "Saved. The agent will read this when work resumes."
                case .queued: messageStatus = isPaused ? "Feedback saved. Work will resume when unpaused." : "Feedback sent. The agent will continue working."
                }
            }
            message = ""
            model.attachmentDrafts[task.id] = []
            for url in attached { removeDraftCapture(url, root: model.store.root) }
        }
    }
}
private struct FlowOptions: View {
    @Environment(AppModel.self) private var model
    let question: Question
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { options }
            VStack(alignment: .leading) { options }
        }
    }
    private var options: some View {
        ForEach(question.options, id: \.self) { option in
            Button(option) { model.perform { try await model.core.answer(question.id, text: option) } }
                .help("Answer this question with “\(option)”")
                .buttonStyle(.bordered).accessibilityLabel("\(question.prompt): \(option)")
        }
    }
}

private struct TaskQuestion: View {
    let question: Question
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(question.prompt, systemImage: "questionmark.circle").fontWeight(.medium)
            if let answer = question.answer { Text(answer).foregroundStyle(.secondary) }
            else {
                FlowOptions(question: question)
                if question.allowsFreeText { Text("Or type your answer below.").font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.purple.opacity(0.25)))
    }
}
