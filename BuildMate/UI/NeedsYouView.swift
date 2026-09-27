import SwiftUI

struct NeedsYouView: View {
    @Environment(AppModel.self) private var model
    private var waiting: [WorkTask] { model.snapshot.tasks.filter(model.needsYou).filter { model.search.isEmpty || $0.title.localizedCaseInsensitiveContains(model.search) } }
    var body: some View {
        if model.snapshot.projects.isEmpty {
            ContentUnavailableView {
                Label("Build with a little help", systemImage: "hammer")
            } description: {
                Text("Add a local repository, describe a task, and keep track of your agents from one workspace.")
            } actions: {
                Button("Add Project…") { model.showAddProject = true }.buttonStyle(.borderedProminent)
                    .help("Add an existing repository or create a new project (⇧⌘N)")
            }
        } else if waiting.isEmpty && model.projectQuestions.isEmpty {
            ContentUnavailableView("Nothing needs you", systemImage: "checkmark.circle",
                                   description: Text(model.workers == 0 ? "Your projects are ready. Create a task with ⌘N." : "Agents are working on \(model.workers) tasks."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if !model.projectQuestions.isEmpty {
                        Text("Project questions").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                        ForEach(model.projectQuestions) { question in
                            if let session = model.snapshot.sessions.first(where: { $0.id == question.sessionId }) {
                                Button { model.destination = .project(session.ownerId, .chat) } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Image(systemName: "questionmark.circle").foregroundStyle(.purple).frame(width: 20)
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(model.projectName(session.ownerId)).fontWeight(.medium)
                                            Text(question.body).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).frame(width: 12)
                                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                        .background(AppSurface.raised, in: RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(.plain).help("Open project chat to answer this question")
                            }
                        }
                    }
                    rows("Fix", tasks: waiting.filter(model.retryNeedsAttention), symbol: "exclamationmark.triangle", color: .orange) { task in task.retry?.error ?? "" }
                    rows("Questions", tasks: waiting.filter { task in model.snapshot.questions.contains { $0.taskId == task.id && $0.answer == nil } }, symbol: "questionmark.circle", color: .purple) { task in
                        model.snapshot.questions.first { $0.taskId == task.id && $0.answer == nil }?.prompt ?? ""
                    }
                    rows("Approvals", tasks: waiting.filter { task in model.snapshot.approvals.contains { $0.taskId == task.id && $0.status == "pending" } }, symbol: "checkmark.seal", color: .purple) { task in
                        model.snapshot.approvals.first { $0.taskId == task.id && $0.status == "pending" }?.planText ?? "Waiting for your approval"
                    }
                    rows("Ready for human review", tasks: waiting.filter { $0.state == .humanReview }, symbol: "eye", color: .green) { task in
                        model.snapshot.proofs.first { $0.taskId == task.id }?.summary ?? "Proof is complete"
                    }
                }.padding(28).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    @ViewBuilder private func rows(_ title: String, tasks: [WorkTask], symbol: String, color: Color, detail: @escaping (WorkTask) -> String) -> some View {
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                ForEach(tasks) { task in
                    Button { model.destination = .task(task.id) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: symbol).foregroundStyle(color).frame(width: 20).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(task.title).fontWeight(.medium)
                                Text(model.projectName(task.projectId)).font(.caption).foregroundStyle(.secondary)
                                Text(detail(task)).foregroundStyle(.secondary).lineLimit(3)
                            }.multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 12).accessibilityHidden(true)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppSurface.raised, in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .help("Open \(task.title) to review what needs your attention")
                        .accessibilityLabel("\(task.title), \(model.projectName(task.projectId)). \(detail(task))")
                        .accessibilityHint("Opens the task")
                        .accessibilityIdentifier("needs-you-\(title)-\(task.number)")
                        .contextMenu {
                            Button("Delete Task…", role: .destructive) { model.taskToDelete = task }
                                .disabled(model.deletingTasks.contains(task.id)).help("Delete this task, including its conversation and worktree")
                        }
                }
            }
        }
    }
}
