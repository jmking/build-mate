import SwiftUI

struct TaskBoard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var cardMovement
    let projectID: UUID
    private let columns: [TaskState] = [.todo, .needsClarification, .building, .humanReview, .inPR]
    var body: some View {
        Group {
        if model.listMode {
            TaskList(tasks: model.tasks(projectID).filter { $0.state != .backlog }, emptyTitle: "No work queued yet", emptyDescription: "Move a task to Queue when it is ready to start.")
        } else {
            GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(columns, id: \.self) { state in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 6) {
                                Image(systemName: state.symbol).font(.caption).foregroundStyle(state.color).frame(width: 16).accessibilityHidden(true)
                                Text(state.title).font(.caption.weight(.semibold))
                                Spacer(minLength: 2)
                                Text("\(model.tasks(projectID).filter { $0.state == state }.count)").font(.caption).foregroundStyle(.secondary)
                                if state == .todo { Button { model.showNewTask = true } label: { Image(systemName: "plus").font(.caption).frame(width: 20, height: 20) }.buttonStyle(.plain).accessibilityLabel("New Task").help("Create a new task (⌘N)") }
                            }.frame(height: 20).padding(.horizontal, 4).padding(.top, 6).accessibilityAddTraits(.isHeader)
                            ScrollView {
                                LazyVStack(spacing: 8) {
                                    ForEach(model.tasks(projectID).filter { $0.state == state }) { task in
                                        if reduceMotion {
                                            TaskCard(task: task).transition(.opacity)
                                        } else {
                                            TaskCard(task: task)
                                                .matchedGeometryEffect(id: task.id, in: cardMovement)
                                                .transition(.opacity)
                                        }
                                    }
                                    if model.tasks(projectID).allSatisfy({ $0.state != state }) {
                                        Text("No tasks").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 24)
                                    }
                                }.padding(1)
                            }
                        }
                        .padding(8).frame(width: max(205, (geometry.size.width - 88) / 5))
                        .background(AppSurface.recessed, in: RoundedRectangle(cornerRadius: 20))
                    }
                }.frame(height: max(0, geometry.size.height - 40)).padding(20)
                    .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0.1), value: columns.map { state in model.tasks(projectID).filter { $0.state == state }.map(\.id) })
            }
            }
            .toolbar {
                ToolbarItem {
                    if let project = model.selectedProject {
                        Button(project.paused ? "Resume Project" : "Pause Project", systemImage: project.paused ? "play" : "pause") { model.perform { try model.pauseProject(project) } }
                            .help(project.paused ? "Resume eligible tasks in this project" : "Pause all agent work in this project")
                    }
                }
            }
        }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.18), value: model.listMode)
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
                        Section {
                            ForEach(group) { task in
                                Button { model.destination = .task(task.id) } label: {
                                    Text(task.title).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 8).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .help("Open \(task.title)")
                                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                                    .contextMenu {
                                        Button("Edit Task…") { model.editingTask = task }.help("Edit this task’s title, brief and proof requirements")
                                        TaskPriorityActions(task: task)
                                    }
                                    .modifier(TaskPriorityDrag(task: task))
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: state.symbol)
                                    .foregroundStyle(state.color).frame(width: 16).accessibilityHidden(true)
                                Text(state.title)
                            }.font(.caption.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        }
                    }
                }
            }.scrollContentBackground(.hidden).background(AppSurface.window)
        }
    }
}
