import SwiftUI

struct TaskApprovalPicker: View {
    @Environment(AppModel.self) private var model
    let task: WorkTask
    @State private var saving = false
    private var inherited: AgentApprovalMode { model.project(for: task)?.settings.approvalMode ?? .ask }
    var body: some View {
        Menu {
            Picker("Approvals", selection: Binding(get: { task.approvalMode }, set: update)) {
                Text("Project default (\(inherited.title))").tag(Optional<AgentApprovalMode>.none)
                ForEach(AgentApprovalMode.allCases, id: \.self) { mode in Text(mode.title).tag(Optional(mode)) }
            }
            .pickerStyle(.inline)
        } label: {
            Label((task.approvalMode ?? inherited).title, systemImage: task.approvalMode == .fullAccess || task.approvalMode == nil && inherited == .fullAccess ? "lock.open" : "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
        }.menuStyle(.borderlessButton).fixedSize().disabled(saving)
            .accessibilityLabel("Task approval level").accessibilityIdentifier("task-approval-mode")
            .help((task.approvalMode ?? inherited).explanation + " Changing this restarts the active turn in the same conversation.")
    }
    private func update(_ mode: AgentApprovalMode?) {
        saving = true
        model.perform {
            defer { saving = false }
            try await model.core.setTaskApprovalMode(task.id, mode: mode)
        }
    }
}
