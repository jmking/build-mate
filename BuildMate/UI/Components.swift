import SwiftUI
import UniformTypeIdentifiers

extension TaskState {
    var title: String {
        switch self {
        case .todo: "Queue"; case .needsClarification: "Needs Clarification"
        case .building: "Building"; case .humanReview: "Awaiting human review"; case .inPR: "In PR"; case .done: "Merged"; case .canceled: "Canceled"
        }
    }
    var symbol: String {
        switch self {
        case .todo: "circle.dashed"; case .needsClarification: "questionmark.circle"
        case .building: "play.circle"; case .humanReview: "eye"; case .inPR: "arrow.triangle.pull"; case .done: "checkmark.circle"; case .canceled: "xmark.circle"
        }
    }
    var color: Color {
        switch self { case .needsClarification, .humanReview: .purple; case .building, .inPR: .accentColor; case .done: .green; default: .secondary }
    }
}

struct StateLabel: View {
    @Environment(AppModel.self) private var model
    var task: WorkTask
    var body: some View {
        Label(task.paused ? "Paused" : model.retryNeedsAttention(task) ? "Retry scheduled" : task.state.title,
              systemImage: task.paused ? "pause.circle" : model.retryNeedsAttention(task) ? "clock.arrow.circlepath" : task.state.symbol)
        .foregroundStyle(.secondary)
    }
}
struct RoadToMerge: View {
    var task: WorkTask
    private var completed: Int {
        switch task.state { case .building: 1; case .humanReview: 3; case .inPR: 4; case .done: 5; default: 0 }
    }
    private let names = ["Clarified", "Built", "Proof of work", "Human review", "Merged"]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                HStack(spacing: 8) {
                    Image(systemName: index < completed ? "checkmark.circle.fill" : index == completed ? "circle.inset.filled" : "circle")
                        .foregroundStyle(index < completed ? Color.green : index == completed ? .accentColor : .secondary)
                        .frame(width: 18)
                    Text(name).foregroundStyle(index <= completed ? .primary : .secondary)
                }.font(.callout)
                if index < names.count - 1 {
                    Rectangle().fill(.separator).frame(width: 1, height: 12).padding(.leading, 8.5)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(completed) of 5 complete, \(task.state.title)")
    }
}
struct TaskCard: View {
    @Environment(AppModel.self) private var model
    let task: WorkTask
    var body: some View {
        Button { model.destination = .task(task.id) } label: {
            VStack(alignment: .leading, spacing: 12) {
                Text(task.title).font(.body.weight(.medium)).foregroundStyle(.primary).multilineTextAlignment(.leading).lineLimit(3)
                if task.state == .todo && model.usageHeld {
                    Label("Waiting for usage", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
                }
                if task.paused || model.retryNeedsAttention(task) {
                    StateLabel(task: task).font(.caption).frame(maxWidth: .infinity, alignment: .trailing)
                }
                if let id = task.dependsOn.first, let dependency = model.snapshot.tasks.first(where: { $0.id == id }), dependency.state != .done {
                    Label("Waits on \(dependency.title)", systemImage: "link").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppSurface.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.35), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .help("Open \(task.title)")
        .accessibilityLabel("\(task.title), \(task.state.title)")
        .accessibilityIdentifier("task-\(task.number)")
        .contextMenu {
            Button("Open") { model.destination = .task(task.id) }.help("Open this task")
            Button("Edit Task…") { model.editingTask = task }.help("Edit this task’s title, brief and proof requirements")
            TaskPriorityActions(task: task)
            Button(task.paused ? "Resume" : "Pause") { model.perform { try await model.core.pause(task.id, paused: !task.paused) } }
                .help(task.paused ? "Resume work on this task" : "Pause work on this task")
            Divider()
            Button("Delete Task…", role: .destructive) { model.taskToDelete = task }
                .disabled(model.deletingTasks.contains(task.id)).help("Delete this task, including its conversation and worktree")
        }
        .modifier(TaskPriorityDrag(task: task))
    }
}

struct TaskPriorityActions: View {
    @Environment(AppModel.self) private var model
    let task: WorkTask
    var body: some View {
        if task.state == .todo {
            Button("Move Earlier") { model.perform { try model.movePriority(task, earlier: true) } }
                .help("Move this task one place earlier in priority")
                .disabled(model.priorityNeighbor(task, earlier: true) == nil)
            Button("Move Later") { model.perform { try model.movePriority(task, earlier: false) } }
                .help("Move this task one place later in priority")
                .disabled(model.priorityNeighbor(task, earlier: false) == nil)
        }
    }
}

struct TaskPriorityDrag: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var height: CGFloat = 1
    let task: WorkTask
    func body(content: Content) -> some View {
        if task.state == .todo {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .opacity(model.priorityDrag?.taskID == task.id ? 0.25 : 1)
                .draggable("build-mate-task:" + task.id.uuidString) {
                    content
                        .background(AppSurface.card, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                        .scaleEffect(reduceMotion ? 1 : 1.025)
                        .padding(16)
                }
                .dragConfiguration(DragConfiguration(operationsWithinApp: .init(allowCopy: false, allowMove: true), operationsOutsideApp: .init(allowCopy: false)))
                .onDragSessionUpdated { session in
                    switch session.phase {
                    case .initial: model.beginPriorityDrag(task)
                    case .ended: model.finishPriorityDrag(commit: false)
                    default: break
                    }
                }
                .onDrop(of: [UTType.text], delegate: TaskPriorityDrop(model: model, task: task, height: height, reduceMotion: reduceMotion))
                .accessibilityAction(named: "Move earlier") { model.perform { try model.movePriority(task, earlier: true) } }
                .accessibilityAction(named: "Move later") { model.perform { try model.movePriority(task, earlier: false) } }
                .help("Open \(task.title). Drag above or below another task to change priority.")
        } else { content }
    }
}

private struct TaskPriorityDrop: DropDelegate {
    let model: AppModel
    let task: WorkTask
    let height: CGFloat
    let reduceMotion: Bool
    func validateDrop(info: DropInfo) -> Bool { model.canDropPriority(on: task) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard model.canDropPriority(on: task), let sourceID = model.priorityDrag?.taskID else { return DropProposal(operation: .forbidden) }
        let group = model.tasks(task.projectId).filter { $0.state == task.state }
        if let source = group.firstIndex(where: { $0.id == sourceID }),
           let target = group.firstIndex(where: { $0.id == task.id }), source != target {
            // Cross the row midpoint before moving it, so the shifted row cannot
            // immediately move back under a stationary pointer.
            let after = source < target
            if after ? info.location.y > height / 2 : info.location.y < height / 2 {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0)) {
                    model.previewPriorityDrag(over: task, after: after)
                }
            }
        }
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        guard model.canDropPriority(on: task) else { return false }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0)) {
            model.finishPriorityDrag(commit: true)
        }
        return true
    }
}
