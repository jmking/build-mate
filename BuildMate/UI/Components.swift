import SwiftUI

extension TaskState {
    var title: String {
        switch self {
        case .backlog: "Backlog"; case .todo: "Todo"; case .needsClarification: "Needs Clarification"
        case .building: "Building"; case .humanReview: "Human review"; case .inPR: "In PR"; case .done: "Merged"; case .canceled: "Canceled"
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
    var vertical = false
    private var completed: Int {
        switch task.state { case .building: 1; case .humanReview: 3; case .inPR: 4; case .done: 5; default: 0 }
    }
    private let names = ["Clarified", "Built", "Proof of work", "Human review", "Merged"]
    var body: some View {
        Group {
            if vertical {
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
            } else {
                HStack(spacing: 3) {
                    ForEach(0..<5) { index in Capsule().fill(index < completed ? Color.green : Color.secondary.opacity(0.2)).frame(height: 3) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Road to merge: \(completed) of 5 complete, \(task.state.title)")
    }
}
struct TaskCard: View {
    @Environment(\.colorScheme) private var colorScheme
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
                if task.state != .todo && task.state != .backlog { RoadToMerge(task: task) }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: colorScheme == .dark ? .underPageBackgroundColor : .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.35), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(task.title), task \(task.number), \(task.state.title)")
        .accessibilityIdentifier("task-\(task.number)")
        .contextMenu {
            Button("Open") { model.destination = .task(task.id) }
            Button("Edit Task…") { model.editingTask = task }
            Button(task.paused ? "Resume" : "Pause") { model.perform { try await model.core.pause(task.id, paused: !task.paused) } }
        }
    }
}
