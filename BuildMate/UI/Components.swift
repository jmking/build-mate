import SwiftUI
import UniformTypeIdentifiers

extension TaskState {
    var title: String {
        switch self {
        case .backlog: "Backlog"; case .todo: "Queue"; case .needsClarification: "Needs Clarification"
        case .building: "Building"; case .humanReview: "Awaiting human review"; case .inPR: "In PR"; case .done: "Merged"; case .canceled: "Canceled"
        }
    }
    var symbol: String {
        switch self {
        case .backlog: "list.bullet.rectangle"; case .todo: "circle.dashed"; case .needsClarification: "questionmark.circle"
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
        .accessibilityLabel("Road to merge: \(completed) of 5 complete, \(task.state.title)")
    }
}
struct TaskCard: View {
    @Environment(AppModel.self) private var model
    let task: WorkTask
    var body: some View {
        Button { model.destination = .task(task.id) } label: {
            VStack(alignment: .leading, spacing: 12) {
                Text(task.title).font(.body.weight(.medium)).foregroundStyle(.primary).multilineTextAlignment(.leading).lineLimit(3)
                HStack(alignment: .firstTextBaseline) { Text("#\(task.number)").monospacedDigit(); Spacer(); StateLabel(task: task) }.font(.caption)
                if let id = task.dependsOn.first, let dependency = model.snapshot.tasks.first(where: { $0.id == id }), dependency.state != .done {
                    Label("Waits on #\(dependency.number)", systemImage: "link").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppSurface.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.35), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(task.title), task \(task.number), \(task.state.title)")
        .accessibilityIdentifier("task-\(task.number)")
        .contextMenu {
            Button("Open") { model.destination = .task(task.id) }
            Button("Edit Task…") { model.editingTask = task }
            TaskPriorityActions(task: task)
            Button(task.paused ? "Resume" : "Pause") { model.perform { try await model.core.pause(task.id, paused: !task.paused) } }
        }
        .modifier(TaskPriorityDrag(task: task))
    }
}

struct TaskPriorityActions: View {
    @Environment(AppModel.self) private var model
    let task: WorkTask
    var body: some View {
        if [.backlog, .todo].contains(task.state) {
            Button("Move Earlier") { model.perform { try model.movePriority(task, earlier: true) } }
                .disabled(model.priorityNeighbor(task, earlier: true) == nil)
            Button("Move Later") { model.perform { try model.movePriority(task, earlier: false) } }
                .disabled(model.priorityNeighbor(task, earlier: false) == nil)
        }
    }
}

struct TaskPriorityDrag: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var height: CGFloat = 1
    @State private var targeted = false
    let task: WorkTask
    func body(content: Content) -> some View {
        if [.backlog, .todo].contains(task.state) {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .onDrag { NSItemProvider(object: ("build-mate-task:" + task.id.uuidString) as NSString) }
                .onDrop(of: [UTType.text], delegate: TaskPriorityDrop(model: model, task: task, height: height, targeted: $targeted))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(targeted ? Color.accentColor : .clear, lineWidth: 2).allowsHitTesting(false))
                .accessibilityAction(named: "Move earlier") { model.perform { try model.movePriority(task, earlier: true) } }
                .accessibilityAction(named: "Move later") { model.perform { try model.movePriority(task, earlier: false) } }
                .help("Drag above or below another task to change priority")
        } else { content }
    }
}

private struct TaskPriorityDrop: DropDelegate {
    let model: AppModel
    let task: WorkTask
    let height: CGFloat
    @Binding var targeted: Bool
    func dropEntered(info: DropInfo) { targeted = true }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        let after = info.location.y > height / 2
        provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let text = value as? String, text.hasPrefix("build-mate-task:"),
                  let id = UUID(uuidString: String(text.dropFirst(16))) else { return }
            Task { @MainActor in
                guard let source = model.snapshot.tasks.first(where: { $0.id == id }),
                      source.projectId == task.projectId, source.state == task.state else { return }
                model.perform { try model.reorderTask(id, relativeTo: task.id, after: after) }
            }
        }
        return true
    }
}
