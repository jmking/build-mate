import SwiftUI

struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    let task: WorkTask
    @State private var message = ""
    private var session: Session? { model.snapshot.sessions.first { $0.ownerId == task.id && $0.ownerType == "task" } }
    private var messages: [Message] { model.snapshot.messages.filter { $0.sessionId == session?.id } }
    private var questions: [Question] { model.snapshot.questions.filter { $0.taskId == task.id } }
    private var proof: Proof? { model.snapshot.proofs.first { $0.taskId == task.id } }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Task brief").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            Text(task.title).font(.title3.weight(.semibold))
                            Text(task.description.isEmpty ? "No additional description." : task.description).textSelection(.enabled)
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                        ForEach(messages) { item in
                            if let question = questions.first(where: { $0.messageId == item.id }) { TaskQuestion(question: question) } else {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(item.role == "agent" ? "Agent" : item.role == "user" ? "You" : "Build Mate").fontWeight(.medium)
                                        Text(item.createdAt, style: .time)
                                    }.font(.caption).foregroundStyle(.secondary)
                                    Text(.init(displayText(item))).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(item.role == "user" ? 14 : 0)
                                .background(item.role == "user" ? Color.secondary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        if task.state == .building { Label(task.paused ? "Paused" : "Agent is working…", systemImage: task.paused ? "pause.circle" : "play.circle").foregroundStyle(.secondary) }
                        if let retry = task.retry {
                            Label(retry.error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                            Text("Next retry: \(retry.dueAt.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(28).frame(maxWidth: 776).frame(maxWidth: .infinity)
                }
                if !task.state.terminal && task.state != .backlog {
                    HStack(alignment: .bottom) {
                        TextField(questions.contains { $0.answer == nil } ? "Answer the question" : "Message the agent", text: $message, axis: .vertical).lineLimit(1...5).textFieldStyle(.plain).onSubmit(send)
                        Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                            .buttonStyle(.plain).disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("Send message").help("Send message (Return)")
                    }.padding(14).glassEffect(in: RoundedRectangle(cornerRadius: 22)).padding(20)
                }
            }
            if model.showInspector {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Road to merge").font(.headline).accessibilityAddTraits(.isHeader)
                        RoadToMerge(task: task, vertical: true)
                        Divider()
                        Text("Brief").font(.headline)
                        Text(task.description.isEmpty ? task.title : task.description).foregroundStyle(.secondary)
                        if let path = task.worktreePath {
                            Divider()
                            Text("Worktree").font(.headline)
                            Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let proof {
                            Divider()
                            Text("Proof of work").font(.headline)
                            ForEach(Array(proof.checks.enumerated()), id: \.offset) { _, check in Label(check.name + " · " + check.status, systemImage: check.status == "passed" ? "checkmark.circle" : "xmark.circle") }
                            Text(proof.recordingPath == nil ? "Recording not available" : "Recording captured").foregroundStyle(.secondary)
                        }
                        if let pr = task.pr, let url = URL(string: pr.url) { Link("View Pull Request #\(pr.number)", destination: url) }
                        if task.state == .backlog {
                            Button("Move to Todo") { model.perform { try await model.core.transition(task.id, to: .todo); await model.core.tick() } }.buttonStyle(.borderedProminent)
                                .disabled(model.selectedProject?.host != .github)
                        }
                        ForEach(model.snapshot.approvals.filter { $0.taskId == task.id && $0.kind == "plan" && $0.status == "pending" }) { approval in
                            Button("Approve Plan") { model.perform { try await model.core.approvePlan(approval.id) } }.buttonStyle(.borderedProminent)
                        }
                        if task.state == .humanReview {
                            Text("Review playback and preview controls are coming soon.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(width: 340).background(.background.secondary)
            }
        }
        .toolbar {
            ToolbarItem {
                Button(task.paused ? "Resume" : "Pause", systemImage: task.paused ? "play" : "pause") { model.perform { try await model.core.pause(task.id, paused: !task.paused) } }.disabled(task.state.terminal).help("Pause or resume task (⌘.)")
            }
        }
    }
    private func displayText(_ item: Message) -> String {
        if item.kind == "event", item.body.hasPrefix("Moved to "), let state = TaskState(rawValue: String(item.body.dropFirst(9))) { return "Moved to " + state.title }
        return item.body
    }
    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let question = questions.first { $0.answer == nil }
        model.perform {
            if let question { try await model.core.answer(question.id, text: text) }
            else { try await model.core.steer(task.id, text: text) }
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
