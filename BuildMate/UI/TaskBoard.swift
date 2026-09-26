import SwiftUI

struct TaskBoard: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID
    private let columns: [TaskState] = [.todo, .needsClarification, .building, .humanReview, .inPR]
    var body: some View {
        if model.listMode {
            TaskList(tasks: model.tasks(projectID), emptyTitle: "No tasks yet", emptyDescription: "Create a task to start building.")
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(columns, id: \.self) { state in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 6) {
                                Image(systemName: state.symbol).foregroundStyle(state.color).accessibilityHidden(true)
                                Text(state.title).font(.caption.weight(.semibold))
                                Spacer(minLength: 2)
                                Text("\(model.tasks(projectID).filter { $0.state == state }.count)").font(.caption).foregroundStyle(.secondary)
                                if state == .todo { Button { model.showNewTask = true } label: { Image(systemName: "plus") }.buttonStyle(.plain).accessibilityLabel("New Task") }
                            }.padding(.horizontal, 4).padding(.top, 6).accessibilityAddTraits(.isHeader)
                            ScrollView {
                                LazyVStack(spacing: 8) {
                                    if state == .todo {
                                        Button { model.destination = .project(projectID, .backlog) } label: {
                                            HStack { Label("Backlog", systemImage: "list.bullet.rectangle"); Spacer(); Text("\(model.tasks(projectID).filter { $0.state == .backlog }.count)") }
                                                .font(.caption).padding(10).frame(maxWidth: .infinity)
                                        }.buttonStyle(.plain)
                                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [4])))
                                    }
                                    ForEach(model.tasks(projectID).filter { $0.state == state }) { task in TaskCard(task: task) }
                                    if model.tasks(projectID).allSatisfy({ $0.state != state }) {
                                        Text("No tasks").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.top, 24)
                                    }
                                }.padding(1)
                            }
                        }
                        .padding(8).frame(width: 205)
                        .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 20))
                    }
                }.padding(20)
            }
            .toolbar {
                ToolbarItem {
                    if let project = model.selectedProject {
                        Button(project.paused ? "Resume Project" : "Pause Project", systemImage: project.paused ? "play" : "pause") { model.perform { try model.pauseProject(project) } }
                    }
                }
            }
        }
    }
}

struct TaskList: View {
    @Environment(AppModel.self) private var model
    let tasks: [WorkTask]
    let emptyTitle: String
    let emptyDescription: String
    var body: some View {
        if tasks.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: "list.bullet.rectangle", description: Text(emptyDescription))
        } else {
            List {
                ForEach(TaskState.allCases, id: \.self) { state in
                    let group = tasks.filter { $0.state == state }
                    if !group.isEmpty {
                        Section(state.title) {
                            ForEach(group) { task in
                                Button { model.destination = .task(task.id) } label: {
                                    HStack(spacing: 16) {
                                        Text("#\(task.number)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                        Text(task.title).foregroundStyle(.primary)
                                        Spacer()
                                        StateLabel(task: task).font(.caption)
                                    }.padding(.vertical, 8)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }
}
