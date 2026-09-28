import SwiftUI

struct NeedsYouView: View {
    @Environment(AppModel.self) private var model
    private var query: String { model.search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var waiting: [WorkTask] {
        model.snapshot.tasks.filter(model.needsYou).filter { task in
            matches(task.title + " " + model.projectName(task.projectId) + " " + task.description)
        }
    }
    private var projectQuestions: [Message] {
        model.projectQuestions.filter { question in
            let owner = model.snapshot.sessions.first { $0.id == question.sessionId }?.ownerId
            return matches(question.body + " " + (owner.map(model.projectName) ?? ""))
        }
    }
    private var agentApprovals: [Message] { model.agentApprovals.filter { matches($0.body + " " + ($0.payload["reason"].string ?? "")) } }
    var body: some View {
        if model.snapshot.projects.isEmpty {
            ContentUnavailableView {
                Label("No projects", systemImage: "folder")
            } description: {
                Text("Add a repository to start creating tasks.")
            } actions: {
                Button("Add Project…") { model.showAddProject = true }.buttonStyle(.borderedProminent)
                    .help("Add an existing repository or create a new project (⇧⌘N)")
            }
        } else if waiting.isEmpty && projectQuestions.isEmpty && agentApprovals.isEmpty {
            if !query.isEmpty {
                ContentUnavailableView {
                    Label("No matches", systemImage: "magnifyingglass")
                } description: {
                    Text("Nothing needing attention matches “\(query)”.")
                } actions: {
                    Button("Clear Search") { model.search = "" }.help("Show everything that needs your attention")
                }
            } else {
                ContentUnavailableView("Nothing needs you", systemImage: "checkmark.circle")
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if !agentApprovals.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Actions to approve").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                            ForEach(agentApprovals) { message in
                                if let session = model.snapshot.sessions.first(where: { $0.id == message.sessionId }) {
                                    Button { model.destination = session.ownerType == "task" ? .task(session.ownerId) : .project(session.ownerId, .chat) } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "lock.shield").foregroundStyle(.purple).frame(width: 20).accessibilityHidden(true)
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(model.snapshot.tasks.first { $0.id == session.ownerId }?.title ?? model.projectName(session.ownerId)).fontWeight(.medium)
                                                Text(message.body).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                            .background(AppSurface.raised, in: RoundedRectangle(cornerRadius: 12))
                                    }.buttonStyle(.plain).help("Open the conversation to review this request")
                                }
                            }
                        }
                    }
                    if !projectQuestions.isEmpty {
                        Text("Project questions").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                        ForEach(projectQuestions) { question in
                            if let session = model.snapshot.sessions.first(where: { $0.id == question.sessionId }) {
                                Button { model.destination = .project(session.ownerId, .chat) } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Image(systemName: "questionmark.circle").foregroundStyle(.purple).frame(width: 20).accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(model.projectName(session.ownerId)).fontWeight(.medium)
                                            Text(excerpt(question.body)).foregroundStyle(.secondary).multilineTextAlignment(.leading).lineLimit(2)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).frame(width: 12).accessibilityHidden(true)
                                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                        .background(AppSurface.raised, in: RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(.plain).help("Open project chat to answer this question")
                                    .accessibilityLabel("\(model.projectName(session.ownerId)). \(excerpt(question.body))")
                                    .accessibilityHint("Opens project chat")
                            }
                        }
                    }
                    rows("Needs attention", tasks: waiting.filter(model.retryNeedsAttention), symbol: "exclamationmark.triangle", color: .orange) { task in task.retry?.error ?? "" }
                    rows("Questions to answer", tasks: waiting.filter { task in model.snapshot.questions.contains { $0.taskId == task.id && $0.answer == nil } }, symbol: "questionmark.circle", color: .purple) { task in
                        model.snapshot.questions.first { $0.taskId == task.id && $0.answer == nil }?.prompt ?? ""
                    }
                    rows("Plans to approve", tasks: waiting.filter { task in model.snapshot.approvals.contains { $0.taskId == task.id && $0.status == "pending" } }, symbol: "checkmark.seal", color: .purple) { task in
                        model.snapshot.approvals.first { $0.taskId == task.id && $0.status == "pending" }?.planText ?? "Waiting for your approval"
                    }
                    rows("Changes to review", tasks: waiting.filter { $0.state == .humanReview }, symbol: "eye", color: .purple) { task in
                        model.snapshot.proofs.first { $0.taskId == task.id }?.changeSummary ?? "Changes are ready for review"
                    }
                }.padding(28).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedCaseInsensitiveContains(query) }
    private func excerpt(_ source: String) -> String {
        let parsed = try? AttributedString(markdown: source)
        let plain = parsed.map { String($0.characters) } ?? source
        let compact = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return compact.count > 240 ? String(compact.prefix(240)) + "…" : compact
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
                                Text(excerpt(detail(task))).foregroundStyle(.secondary).lineLimit(2)
                            }.multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 12).accessibilityHidden(true)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppSurface.raised, in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .help("Open \(task.title) to review what needs your attention")
                        .accessibilityLabel("\(task.title), \(model.projectName(task.projectId)). \(excerpt(detail(task)))")
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
