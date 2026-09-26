import AppKit
import SwiftUI

struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let task: WorkTask
    @State private var message = ""
    @State private var messageStatus: String?
    @State private var sending = false
    private var openQuestion: Question? { questions.first { $0.answer == nil } }
    private var isPaused: Bool { task.paused || model.settings.paused || model.selectedProject?.paused == true }
    private var activeTurn: Bool { session?.status == "running" && session?.currentTurn != nil }
    private var composerTitle: String { openQuestion != nil ? "Answer the question" : activeTurn ? "Message the agent" : "Save a message for the next run" }
    private var actionTitle: String { openQuestion != nil ? "Send answer" : activeTurn ? "Send message" : "Save message" }
    private var composerExplanation: String {
        if let question = openQuestion { return question.allowsFreeText ? "Your answer resolves this question. Paused tasks stay paused." : "Choose one of the answer buttons above." }
        return activeTurn ? "Sent to the current agent turn." : "Messages are saved for when work resumes."
    }
    private var session: Session? { model.snapshot.sessions.first { $0.ownerId == task.id && $0.ownerType == "task" } }
    private var messages: [Message] { model.snapshot.messages.filter { $0.sessionId == session?.id } }
    private var questions: [Question] { model.snapshot.questions.filter { $0.taskId == task.id } }
    private var proof: Proof? { model.snapshot.proofs.first { $0.taskId == task.id } }
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
                    HStack(spacing: 8) {
                        Image(systemName: isPaused ? "pause.circle" : "circle.fill")
                            .font(.system(size: 8)).foregroundStyle(isPaused ? Color.secondary : .accentColor)
                            .symbolEffect(.pulse, options: .repeating, isActive: activeTurn && !isPaused && !reduceMotion)
                        Text(isPaused ? "Paused" : "Agent is working…").font(.caption).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine)
                }
                if let retry = task.retry, model.retryNeedsAttention(task) {
                    Label(retry.error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Text("Next retry: \(retry.dueAt.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28).frame(maxWidth: 776).frame(maxWidth: .infinity)
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if !task.state.terminal && task.state != .backlog {
                VStack(alignment: .leading, spacing: 8) {
                    Text(messageStatus ?? composerExplanation).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("message-status")
                    HStack(alignment: .bottom, spacing: 12) {
                        TextField(composerTitle, text: $message, axis: .vertical).lineLimit(1...5).textFieldStyle(.plain).font(.system(size: 14))
                            .padding(.vertical, 7).frame(minHeight: 32)
                            .accessibilityLabel(composerTitle).accessibilityIdentifier("task-message").onSubmit(send)
                            .disabled(sending || openQuestion?.allowsFreeText == false)
                        Button(action: send) { Label(actionTitle, systemImage: "arrow.up").labelStyle(.iconOnly).frame(width: 18, height: 18) }
                            .buttonStyle(.borderedProminent).buttonBorderShape(.circle).controlSize(.large)
                            .accessibilityLabel(actionTitle).help(actionTitle + " (⌘Return)")
                            .disabled(sending || openQuestion?.allowsFreeText == false || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                                Button("Open in Terminal", systemImage: "terminal") { openWorktree(path, inTerminal: true) }
                                    .help("Open a new Terminal at this worktree")
                                    .accessibilityIdentifier("open-worktree-terminal")
                                Button("Open in Finder", systemImage: "folder") { openWorktree(path, inTerminal: false) }
                                    .help("Open this worktree in Finder")
                                    .accessibilityIdentifier("open-worktree-finder")
                            }.labelStyle(.iconOnly).buttonStyle(.bordered).controlSize(.small)
                            Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    if let proof {
                        Divider()
                        Text("Proof of work").font(.headline)
                        if !proof.complete { Text("Proof incomplete — verification is required before review.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(Array(proof.checks.enumerated()), id: \.offset) { _, check in Label(check.name + " · " + check.status, systemImage: check.status == "passed" ? "checkmark.circle" : "xmark.circle") }
                        if let rationale = proof.rationale { Text(rationale).foregroundStyle(.secondary) }
                        Text(proof.recordingPath != nil ? "Recording captured" : proof.recordingRequired ? "Required recording not captured" : "Recording not required").foregroundStyle(.secondary)
                    }
                    if let pr = task.pr, let url = URL(string: pr.url) { Link("View Pull Request #\(pr.number)", destination: url) }
                    if task.state == .backlog {
                        Button("Move to Queue") { model.perform { try await model.moveToTodo(task) } }.buttonStyle(.borderedProminent)
                            .disabled(model.selectedProject?.runBlockReason != nil)
                        if let reason = model.selectedProject?.runBlockReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    }
                    ForEach(model.snapshot.approvals.filter { $0.taskId == task.id && $0.kind == "plan" && $0.status == "pending" }) { approval in
                        Button("Approve Plan") { model.perform { try await model.core.approvePlan(approval.id) } }.buttonStyle(.borderedProminent)
                    }
                    if task.state == .humanReview {
                        Text("Review playback and preview controls are coming soon.").font(.caption).foregroundStyle(.secondary)
                        if model.selectedProject?.host == .local {
                            Text("Changes are committed in the task worktree. Publishing and pull requests are not available for local projects yet.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.background(AppSurface.raised).inspectorColumnWidth(min: 280, ideal: 340, max: 380)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: model.showInspector)
        .toolbar {
            ToolbarItem {
                Button(task.paused ? "Resume" : "Pause", systemImage: task.paused ? "play" : "pause") { model.perform { try await model.core.pause(task.id, paused: !task.paused) } }.disabled(task.state.terminal).help("Pause or resume task (⌘.)")
            }
        }
    }
    private func openWorktree(_ path: String, inTerminal: Bool) {
        model.perform {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CoreError.invalid("This worktree folder is no longer available.")
            }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if inTerminal {
                guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                    throw CoreError.invalid("Terminal could not be found on this Mac.")
                }
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            } else if !NSWorkspace.shared.open(url) {
                throw CoreError.invalid("The worktree folder could not be opened in Finder.")
            }
        }
    }
    private func displayText(_ item: Message) -> String {
        if item.kind == "event", item.body.hasPrefix("Moved to "), let state = TaskState(rawValue: String(item.body.dropFirst(9))) { return "Moved to " + state.title }
        return item.body
    }
    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, openQuestion?.allowsFreeText != false else { return }
        let question = openQuestion
        sending = true
        model.perform {
            defer { sending = false }
            if let question {
                try await model.core.answer(question.id, text: text)
                messageStatus = "Answer saved."
            } else {
                let delivery = try await model.core.steer(task.id, text: text)
                messageStatus = delivery == .sent ? "Sent to the agent." : "Saved for the next run. The task has not been started or resumed."
            }
            message = ""
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
