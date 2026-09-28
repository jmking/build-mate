import AppKit
import SwiftUI

struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let task: WorkTask
    @State private var sending = false
    @State private var openingPR = false
    @State private var approving: Set<UUID> = []
    private var project: Project? { model.project(for: task) }
    private var openQuestion: Question? { questions.first { $0.answer == nil } }
    private var isPaused: Bool { task.paused || model.settings.paused || project?.paused == true }
    private var activeTurn: Bool { session?.status == "running" && session?.currentTurn != nil }
    private var responding: Bool { model.isWorking(task) && activeTurn }
    private var acceptsFeedback: Bool { task.state == .humanReview || task.state == .inPR }
    private var actionTitle: String { openQuestion != nil ? "Send answer" : (activeTurn || acceptsFeedback) ? "Send message" : "Save message" }
    private var session: Session? { model.snapshot.sessions.first { $0.ownerId == task.id && $0.ownerType == "task" } }
    private var messages: [Message] { model.snapshot.messages.filter { $0.sessionId == session?.id } }
    private var conversation: [Message] {
        let pendingQuestions = Set(questions.filter { $0.answer == nil }.map(\.messageId))
        let pendingPlanMessages = Set(pendingPlans.compactMap { approval in
            messages.last { $0.kind == "plan" && $0.body == approval.planText }?.id
        })
        return messages.filter { $0.kind != "event" && !pendingQuestions.contains($0.id) && !pendingPlanMessages.contains($0.id) }
    }
    private var questions: [Question] { model.snapshot.questions.filter { $0.taskId == task.id } }
    private var pendingPlans: [Approval] { model.snapshot.approvals.filter { $0.taskId == task.id && ["plan", "merge"].contains($0.kind) && $0.status == "pending" } }
    private var proof: Proof? { model.snapshot.proofs.first { $0.taskId == task.id } }
    private var files: [URL] { model.attachmentDrafts[task.id] ?? [] }
    private var message: Binding<String> { Binding(get: { model.chatDrafts[task.id] ?? "" }, set: { model.chatDrafts[task.id] = $0 }) }
    private var fileBinding: Binding<[URL]> { Binding(get: { model.attachmentDrafts[task.id] ?? [] }, set: { model.attachmentDrafts[task.id] = $0 }) }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            taskHeader
            if model.repositories(task.projectId).count > 1 {
                Text(model.repositoryName(for: task)).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 8)
            }
            ChatScrollView(messages: messages.filter { $0.kind != "event" }, responding: responding) { stopFollowing in
                DisclosureGroup(isExpanded: Binding(get: { model.isBriefExpanded(task) }, set: { expanded in
                    if expanded { stopFollowing() }
                    model.setBriefExpanded(task.id, expanded: expanded)
                })) {
                    VStack(alignment: .leading, spacing: 12) {
                        MessageAttachments(messageID: task.id, ownerType: "task")
                        MarkdownBrief(task.description.isEmpty ? task.title : task.description)
                        Button("Edit Brief", systemImage: "pencil") { model.editingTask = task }
                            .buttonStyle(.borderless).help("Edit this task’s brief (⇧⌘E)")
                            .accessibilityIdentifier("edit-task-brief")
                    }.padding(.top, 10)
                } label: { Text("Brief").font(.subheadline.weight(.medium)) }
                    .help("Show or hide the task brief")
                ChatTranscript(messages: conversation, responding: responding, reactionContext: messages) { item in
                    if let question = questions.first(where: { $0.messageId == item.id }) {
                        TaskQuestion(question: question)
                    } else if item.role == "system" {
                        Label(item.body, systemImage: item.kind == "error" ? "exclamationmark.triangle" : "info.circle")
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        ChatMessageBubble(message: item)
                    }
                }
                ForEach(questions.filter { $0.answer == nil }) { question in
                    TaskQuestion(question: question)
                        .modifier(ChatMessageMetadata(message: messages.first { $0.id == question.messageId }))
                }
                ForEach(pendingPlans) { approval in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(approval.kind == "merge" ? "Ready to merge" : "Review plan").font(.headline).accessibilityAddTraits(.isHeader)
                        if approval.kind == "merge" { Text("Approve merging the current reviewed commit. GitHub’s repository rules still apply.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        else if let plan = approval.planText { MarkdownBrief(plan) }
                        Button(approving.contains(approval.id) ? "Approving…" : (approval.kind == "merge" ? "Approve Merge" : "Approve Plan")) {
                            approving.insert(approval.id)
                            model.perform {
                                defer { approving.remove(approval.id) }
                                if approval.kind == "merge" { try await model.core.approveMerge(approval.id) }
                                else { try await model.core.approvePlan(approval.id) }
                            }
                        }.buttonStyle(.borderedProminent).disabled(approving.contains(approval.id))
                            .help(approval.kind == "merge" ? "Approve this reviewed commit for merge" : "Approve this plan so work can continue")
                            .accessibilityIdentifier("approve-task-plan")
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppSurface.raised, in: RoundedRectangle(cornerRadius: 12))
                        .modifier(ChatMessageMetadata(message: messages.last { $0.kind == "plan" && $0.body == approval.planText }))
                }
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if !task.state.terminal { composer }
        }
        .modifier(ChatAttachmentDrop(files: fileBinding, root: model.store.root, enabled: !sending && !task.state.terminal))
        .inspector(isPresented: $model.showInspector) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let proof { ReviewEvidence(task: task, proof: proof) }
                    if task.state == .humanReview {
                        PreviewControls(task: task)
                        if let reason = project?.publicationBlockReason {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                                Button("Open in Terminal", systemImage: "terminal") { model.openLocation(task: task, appID: "com.apple.Terminal") }
                                    .help("Open the reviewed worktree to publish the branch")
                            }
                        }
                    }
                    if let pr = task.pr, let url = URL(string: pr.url) {
                        Link("View Pull Request #\(pr.number)", destination: url).help("Open this pull request in your browser")
                    }
                    if let session {
                        SubagentActivityView(agents: model.snapshot.subagents.filter { $0.sessionId == session.id })
                    }
                    DisclosureGroup("Task details") {
                        VStack(alignment: .leading, spacing: 16) {
                            LabeledContent("QA approach", value: task.proofRequirement.title)
                            if task.state.terminal { ModelPicker(ownerID: task.id).id(task.id) }
                            if let path = task.worktreePath {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Worktree").font(.subheadline.weight(.medium))
                                        Spacer()
                                        Button("Open in Terminal", systemImage: "terminal") { model.openLocation(task: task, appID: "com.apple.Terminal") }
                                            .help("Open a new Terminal at this worktree").accessibilityIdentifier("open-worktree-terminal")
                                        Button("Open in Finder", systemImage: "folder") { model.openLocation(task: task) }
                                            .help("Open this worktree in Finder").accessibilityIdentifier("open-worktree-finder")
                                    }.labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
                                    Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }.padding(.top, 10)
                    }.help("Show QA preferences and worktree details")
                    let events = messages.filter { $0.kind == "event" }
                    if !events.isEmpty {
                        DisclosureGroup("History") {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(events) { event in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(displayText(event))
                                        Text(event.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute()).foregroundStyle(.secondary)
                                    }.font(.caption).textSelection(.enabled)
                                }
                            }.padding(.top, 10)
                        }.help("Show this task’s state changes")
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    .background(OverlayScrollbars())
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if task.state == .humanReview && project?.host == .github {
                    VStack(spacing: 12) {
                        Divider()
                        Button(openingPR ? (task.pr == nil ? "Opening…" : "Updating…") : (task.pr == nil ? "Open Pull Request" : "Update Pull Request")) {
                            openingPR = true
                            model.perform {
                                defer { openingPR = false }
                                try await model.core.openPullRequest(task.id)
                            }
                        }.buttonStyle(.borderedProminent).disabled(openingPR || proof?.complete != true || task.paused)
                            .help(task.pr == nil ? "Publish the reviewed changes as a GitHub pull request" : "Push the reviewed changes and update this pull request’s description")
                            .padding(.horizontal, 16).padding(.bottom, 16)
                    }.frame(maxWidth: .infinity).background(AppSurface.raised)
                }
            }
            .background(AppSurface.raised).inspectorColumnWidth(min: 280, ideal: 340, max: 440)
            .accessibilityIdentifier("task-details")
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: model.showInspector)
    }

    private var taskHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    stateLabel
                    if model.isWorking(task) { WorkingIndicator() }
                    pauseButton
                    Spacer(minLength: 8)
                    reviewButton
                    taskMenu
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        stateLabel
                        pauseButton
                        Spacer(minLength: 8)
                        taskMenu
                    }
                    if model.isWorking(task) { WorkingIndicator() }
                    reviewButton
                }
            }
            if !model.settings.paused && project?.paused != true, let reason = model.waitingReason(for: task) {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if let retry = task.retry, model.retryNeedsAttention(task) {
                DisclosureGroup("Error details") { Text(retry.error).font(.caption).textSelection(.enabled) }
                    .font(.caption).foregroundStyle(.secondary).help("Show the error preventing this task from continuing")
            }
        }.padding(.horizontal, 24).padding(.vertical, 12).frame(maxWidth: 776).frame(maxWidth: .infinity)
    }
    private var stateLabel: some View {
        Label { Text(task.state.title).foregroundStyle(.primary) } icon: {
            Image(systemName: task.state.symbol).foregroundStyle(task.state.color)
        }.font(.subheadline.weight(.medium)).fixedSize()
            .accessibilityLabel("Task status: \(task.state.title)")
    }
    @ViewBuilder private var pauseButton: some View {
        if !task.state.terminal {
            Button(task.paused ? "Resume" : "Pause", systemImage: task.paused ? "play" : "pause") {
                model.perform { try await model.core.pause(task.id, paused: !task.paused) }
            }.buttonStyle(.borderless).labelStyle(.iconOnly).frame(width: 28, height: 28)
                .help(task.paused ? "Resume this task (⌘.)" : "Pause this task (⌘.)")
                .accessibilityLabel(task.paused ? "Resume task" : "Pause task")
        }
    }
    @ViewBuilder private var reviewButton: some View {
        if task.state == .humanReview && !model.showInspector {
            Button("Review", systemImage: "eye") { model.showInspector = true }
                .buttonStyle(.bordered).fixedSize().help("Review changes, checks and visual evidence")
                .accessibilityIdentifier("review-task")
        }
    }
    private var taskMenu: some View {
        Menu {
            Button("Edit Task…", systemImage: "pencil") { model.editingTask = task }
                .help("Edit this task (⇧⌘E)").accessibilityIdentifier("edit-task")
            if task.state == .needsClarification {
                Button("Use Suggested Answers…") { model.reviewSheet = .defaults(task.id) }
                    .disabled(!model.hasSuggestedAnswers(for: task.id))
                    .help("Review the agent’s suggested answers")
            }
            Divider()
            Button("Delete Task…", systemImage: "trash", role: .destructive) { model.taskToDelete = task }
                .disabled(model.deletingTasks.contains(task.id))
                .help("Delete this task, its conversation and worktree (⌘Delete)")
        } label: { Label("Task actions", systemImage: "ellipsis") }
            .menuIndicator(.hidden).menuStyle(.borderlessButton).frame(width: 28, height: 28)
            .labelStyle(.iconOnly).help("Task actions").accessibilityIdentifier("task-actions")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            ChatAttachmentTray(files: fileBinding, root: model.store.root)
            HStack(alignment: .bottom, spacing: 10) {
                ChatAttachmentControls(files: fileBinding, root: model.store.root).disabled(sending)
                TextField(openQuestion != nil ? "Your answer…" : "Message the agent…", text: message, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.plain).font(.system(size: 14))
                    .padding(.vertical, 7).frame(minHeight: 32)
                    .accessibilityLabel(openQuestion != nil ? "Your answer" : "Task message").accessibilityIdentifier("task-message")
                    .onSubmit(send).disabled(sending || openQuestion?.allowsFreeText == false)
                Button(action: send) { Image(systemName: "arrow.up").frame(width: 18, height: 18) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.circle).controlSize(.large)
                    .accessibilityLabel(actionTitle).help(actionTitle + " (⌘Return)")
                    .disabled(sending || openQuestion?.allowsFreeText == false || (message.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty))
                    .keyboardShortcut(.return, modifiers: .command).accessibilityIdentifier("send-task-message")
            }
            ModelPicker(ownerID: task.id).id(task.id).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 4)
        }.padding(12).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 16)
            .frame(maxWidth: 776).frame(maxWidth: .infinity)
    }

    private func displayText(_ item: Message) -> String {
        if item.kind == "event", item.body.hasPrefix("Moved to "), let state = TaskState(rawValue: String(item.body.dropFirst(9))) { return "Moved to " + state.title }
        return item.body
    }
    private func send() {
        let text = message.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !files.isEmpty), !sending, openQuestion?.allowsFreeText != false else { return }
        let question = openQuestion
        let attached = files
        sending = true
        model.perform {
            defer { sending = false }
            if let question {
                try await model.core.answer(question.id, text: text.isEmpty ? "See attached files." : text, files: attached)
            } else {
                _ = try await model.core.steer(task.id, text: text, files: attached)
            }
            model.chatDrafts[task.id] = ""
            model.attachmentDrafts[task.id] = []
            for url in attached { removeDraftCapture(url, root: model.store.root) }
        }
    }
}

private struct TaskQuestion: View {
    @Environment(AppModel.self) private var model
    let question: Question
    @State private var answering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(question.prompt, systemImage: "questionmark.circle").fontWeight(.medium)
            if let answer = question.answer {
                MarkdownBrief(answer)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack { options }
                    VStack(alignment: .leading) { options }
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppSurface.raised, in: RoundedRectangle(cornerRadius: 12))
    }
    private var options: some View {
        ForEach(question.options, id: \.self) { option in
            Button(option) {
                answering = true
                model.perform {
                    defer { answering = false }
                    try await model.core.answer(question.id, text: option)
                }
            }.disabled(answering)
                .help("Answer this question with “\(option)”")
                .buttonStyle(.bordered).accessibilityLabel("\(question.prompt): \(option)")
        }
    }
}
