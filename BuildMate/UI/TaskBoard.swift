import SwiftUI

struct TaskBoard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var cardMovement
    let projectID: UUID
    private let columns: [TaskState] = [.todo, .needsClarification, .building, .humanReview, .inPR, .done]
    private var tasks: [WorkTask] { model.tasks(projectID) }
    var body: some View {
        Group {
            if tasks.isEmpty {
                ContentUnavailableView(model.search.isEmpty ? "No work queued yet" : "No matches",
                                       systemImage: model.search.isEmpty ? "list.bullet.rectangle" : "magnifyingglass",
                                       description: Text(model.search.isEmpty ? "Create a task or ask the project agent to create one." : "Try a different task title."))
            } else if !model.listMode && tasks.allSatisfy({ !columns.contains($0.state) }) {
                ContentUnavailableView("No tasks on the board", systemImage: "rectangle.split.3x1",
                                       description: Text("Canceled tasks are available in the list."))
            } else if model.listMode {
                TaskList(tasks: tasks, emptyTitle: "No work queued yet", emptyDescription: "Create a task or ask the project agent to create one.")
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
                                        Text("\(tasks.filter { $0.state == state }.count)").font(.caption).foregroundStyle(.secondary)
                                    }.frame(height: 20).padding(.horizontal, 4).padding(.top, 6).accessibilityAddTraits(.isHeader)
                                    ScrollView {
                                        LazyVStack(spacing: 8) {
                                            ForEach(tasks.filter { $0.state == state }) { task in
                                                if reduceMotion {
                                                    TaskCard(task: task).transition(.opacity)
                                                } else {
                                                    TaskCard(task: task)
                                                        .matchedGeometryEffect(id: task.id, in: cardMovement)
                                                        .transition(.opacity)
                                                }
                                            }
                                        }.padding(1)
                                    }
                                }
                                .padding(8).frame(width: max(240, (geometry.size.width - 100) / 6))
                                .background(AppSurface.recessed, in: RoundedRectangle(cornerRadius: 20))
                            }
                        }.frame(height: max(0, geometry.size.height - 40)).padding(20)
                            .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0), value: columns.map { state in tasks.filter { $0.state == state }.map(\.id) })
                    }.scrollIndicators(.visible)
                }
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.18), value: model.listMode)
    }
}

struct TaskList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(task.title).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                        TaskNotices(task: task)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .tag(task.id)
                                    .help("Open \(task.title)")
                                    .accessibilityElement(children: .combine)
                                    .accessibilityValue(task.state.title)
                                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                                    .contextMenu { TaskContextActions(task: task) }
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
            }
            .scrollContentBackground(.hidden).background(AppSurface.window)
            .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0), value: tasks.map(\.id))
        }
    }
}
