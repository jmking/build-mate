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

/// Only exceptions belong on a card or row; the section already names its state.
struct TaskNotices: View {
    @Environment(AppModel.self) private var model
    let task: WorkTask
    private var activeTurn: Bool {
        model.snapshot.sessions.contains { $0.ownerId == task.id && $0.status == "running" && $0.currentTurn != nil }
    }
    private var retrying: Bool { task.retry != nil && !activeTurn }
    private var dependencyNotice: String? {
        guard !activeTurn else { return nil }
        for id in task.dependsOn + (task.stackOn.map { [$0] } ?? []) {
            guard let dependency = model.snapshot.tasks.first(where: { $0.id == id && $0.projectId == task.projectId }) else { return "A dependency is unavailable" }
            if dependency.state != .done && !(task.stackOn == id && dependency.state == .inPR && dependency.pr != nil) {
                return "Waits on \(dependency.title)"
            }
        }
        return nil
    }
    var body: some View {
        if !task.state.terminal && (task.paused || retrying || (task.state == .todo && model.usageHeld) || dependencyNotice != nil) {
            VStack(alignment: .leading, spacing: 4) {
                if model.retryNeedsAttention(task) {
                    Label("Needs attention", systemImage: "exclamationmark.triangle")
                } else if task.paused {
                    Label("Paused", systemImage: "pause.circle")
                } else if retrying {
                    Label("Retrying…", systemImage: "clock.arrow.circlepath")
                } else if task.state == .todo && model.usageHeld {
                    Label("Waiting for usage", systemImage: "hourglass")
                }
                if let dependencyNotice {
                    Label(dependencyNotice, systemImage: "link").lineLimit(2)
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct TaskContextActions: View {
    @Environment(AppModel.self) private var model
    let task: WorkTask
    var body: some View {
        Button("Open") { model.destination = .task(task.id) }.help("Open this task")
        Button("Edit Task…") { model.editingTask = task }.help("Edit this task’s title, brief and proof requirements")
        if task.state == .todo {
            Button("Refine with Agent") { model.refineInChat(task) }.help("Refine this task’s description in project chat")
        }
        TaskPriorityActions(task: task)
        if !task.state.terminal {
            Button(task.paused ? "Resume Task" : "Pause Task", systemImage: task.paused ? "play" : "pause") {
                model.perform { try await model.core.pause(task.id, paused: !task.paused) }
            }.help(task.paused ? "Resume work on this task" : "Pause work on this task")
        }
        Divider()
        Button("Delete Task…", role: .destructive) { model.taskToDelete = task }
            .disabled(model.deletingTasks.contains(task.id)).help("Delete this task, including its conversation and worktree")
    }
}

struct TaskCard: View {
    @Environment(AppModel.self) private var model
    let task: WorkTask
    var body: some View {
        Button { model.destination = .task(task.id) } label: {
            VStack(alignment: .leading, spacing: 12) {
                Text(task.title).font(.body.weight(.medium)).foregroundStyle(.primary).multilineTextAlignment(.leading).lineLimit(3)
                TaskNotices(task: task)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppSurface.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.35), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .help("Open \(task.title)")
        .accessibilityElement(children: .combine)
        .accessibilityValue(task.state.title)
        .accessibilityIdentifier("task-\(task.number)")
        .contextMenu { TaskContextActions(task: task) }
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
    @State private var size: CGSize = .zero
    let task: WorkTask
    func body(content: Content) -> some View {
        if task.state == .todo {
            content
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                .opacity(model.priorityDrag?.taskID == task.id ? 0 : 1)
                .overlay {
                    if model.priorityDrag?.taskID == task.id {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.accentColor.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .accessibilityHidden(true)
                    }
                }
                .draggable("build-mate-task:" + task.id.uuidString) {
                    content
                        .frame(width: size.width > 0 ? size.width : nil, height: size.height > 0 ? size.height : nil)
                        .background(AppSurface.card, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                        .scaleEffect(reduceMotion ? 1 : 1.025)
                }
                .dragConfiguration(DragConfiguration(operationsWithinApp: .init(allowCopy: false, allowMove: true), operationsOutsideApp: .init(allowCopy: false)))
                .onDragSessionUpdated { session in
                    switch session.phase {
                    case .initial: model.beginPriorityDrag(task)
                    case .ended: model.finishPriorityDrag(commit: false)
                    default: break
                    }
                }
                .onDrop(of: [UTType.text], delegate: TaskPriorityDrop(model: model, task: task, height: max(1, size.height), reduceMotion: reduceMotion))
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
