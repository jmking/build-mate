import SwiftUI
import AppKit

struct AddProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var discovered: DiscoveredProject?
    @State private var checking = false
    @State private var failure: String?
    @FocusState private var pathFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Project").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text("Choose a local clone on this Mac.").foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                TextField("Repository folder", text: $path).textFieldStyle(.roundedBorder).focused($pathFocused).onSubmit { if !path.isEmpty && !checking { inspect() } }.accessibilityIdentifier("repository-path")
                    .onChange(of: path) { discovered = nil; failure = nil }
                Button("Choose…") { chooseFolder() }
            }
            HStack {
                Button("Check Repository") { inspect() }.disabled(path.isEmpty || checking).accessibilityIdentifier("check-repository")
                if checking { ProgressView().controlSize(.small); Text("Checking repository and CLI…").foregroundStyle(.secondary) }
            }
            if let discovered {
                GroupBox {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                        GridRow(alignment: .firstTextBaseline) { Text("Project").foregroundStyle(.secondary); Text(discovered.project.name) }
                        GridRow(alignment: .firstTextBaseline) { Text("Host").foregroundStyle(.secondary); Text(discovered.project.host == .github ? "GitHub" : "Bitbucket Cloud") }
                        GridRow(alignment: .firstTextBaseline) { Text("Default branch").foregroundStyle(.secondary); Text(discovered.project.defaultBranch).font(.body.monospaced()) }
                        GridRow(alignment: .firstTextBaseline) { Text("CLI status").foregroundStyle(.secondary); Label(discovered.status, systemImage: discovered.authenticated ? "checkmark.circle" : "exclamationmark.circle") }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                if let command = discovered.setupCommand {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Run in Terminal: \(command)").font(.caption.monospaced()).textSelection(.enabled)
                        Button("Copy Command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string) }
                    }
                }
            }
            if let failure { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline) {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Project") {
                    guard let discovered else { return }
                    model.perform { try model.add(discovered) }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(discovered == nil || checking).accessibilityIdentifier("confirm-add-project")
            }
        }.padding(28).frame(width: 610).frame(minHeight: 370).accessibilityElement(children: .contain).onAppear { pathFocused = true }
    }
    private func inspect() {
        let requested = path
        checking = true; discovered = nil; failure = nil
        Task {
            do {
                let result = try await ProjectDiscovery().inspect(path: requested)
                if path == requested { discovered = result }
            } catch { if path == requested { failure = error.localizedDescription } }
            checking = false
        }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Choose Repository"
        if panel.runModal() == .OK, let url = panel.url { path = url.path; inspect() }
    }
}

struct NewTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var projectID: UUID?
    @State private var title = ""
    @State private var description = ""
    @State private var proofRequirement: ProofRequirement = .automatic
    @State private var creation: Task<Void, Never>?
    @State private var failure: String?
    @FocusState private var descriptionFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("New Task").font(.title2.weight(.semibold))
                Spacer()
                Picker("Project", selection: $projectID) {
                    ForEach(model.snapshot.projects) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().frame(maxWidth: 230).disabled(creation != nil)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("What should be built").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $description).font(.system(size: 14)).scrollContentBackground(.hidden).frame(height: 165).padding(10)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
                    .focused($descriptionFocused).disabled(creation != nil)
                    .accessibilityLabel("Task description").accessibilityIdentifier("task-description")
                Text("A descriptive title will be generated from your brief. You can rename it anytime.").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Set a title yourself") {
                TextField("Task title (optional)", text: $title).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Task title (optional)").accessibilityIdentifier("task-title").padding(.top, 6)
            }.disabled(creation != nil)
            VStack(alignment: .leading, spacing: 6) {
                Picker("Proof", selection: $proofRequirement) {
                    ForEach(ProofRequirement.allCases, id: \.self) { Text($0.title).tag($0) }
                }.fixedSize().disabled(creation != nil).accessibilityIdentifier("task-proof")
                Text("Automatic lets the agent choose relevant checks and a recording for visual changes. You can also describe the evidence you want in the brief.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if creation != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Generating a title…" : "Creating task…").foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
            }
            if let failure { Text(failure).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Text(selectedProject?.runBlockReason ?? "Start Now adds the task to Todo. It runs when the project is resumed and an agent slot is available.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text("Agents only pick up tasks in Todo.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { creation?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start Now") { create(start: true) }.disabled(!valid || selectedProject?.runBlockReason != nil)
                    .help(selectedProject?.runBlockReason ?? "Add to Todo")
                Button("Add to Backlog") { create(start: false) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(28).frame(width: 670)
            .onAppear { projectID = model.selectedProject?.id ?? model.snapshot.projects.first?.id; descriptionFocused = true }
            // A successful save closes the sheet before its final refresh finishes.
            .onDisappear { if model.showNewTask { creation?.cancel() } }
    }
    private var selectedProject: Project? { model.snapshot.projects.first { $0.id == projectID } }
    private var valid: Bool { projectID != nil && creation == nil && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func create(start: Bool) {
        guard valid, let projectID else { return }
        failure = nil
        creation = Task {
            defer { creation = nil }
            do {
                try await model.createTask(projectID: projectID, title: title, description: description, start: start, proofRequirement: proofRequirement)
                await model.refresh()
            } catch is CancellationError { }
            catch { failure = error.localizedDescription }
        }
    }
}
