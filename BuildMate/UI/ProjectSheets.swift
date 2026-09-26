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
            HStack {
                TextField("Repository folder", text: $path).textFieldStyle(.roundedBorder).focused($pathFocused).accessibilityIdentifier("repository-path")
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
                        GridRow { Text("Project").foregroundStyle(.secondary); Text(discovered.project.name) }
                        GridRow { Text("Host").foregroundStyle(.secondary); Text(discovered.project.host == .github ? "GitHub" : "Bitbucket Cloud") }
                        GridRow { Text("Default branch").foregroundStyle(.secondary); Text(discovered.project.defaultBranch).font(.body.monospaced()) }
                        GridRow { Text("CLI status").foregroundStyle(.secondary); Label(discovered.status, systemImage: discovered.authenticated ? "checkmark.circle" : "exclamationmark.circle") }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                if let command = discovered.setupCommand {
                    HStack {
                        Text("Run in Terminal: \(command)").font(.caption.monospaced()).textSelection(.enabled)
                        Button("Copy Command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string) }
                    }
                }
            }
            if let failure { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 8)
            HStack {
                Text("Nothing is written to the repository.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Project") {
                    guard let discovered else { return }
                    model.perform { try model.add(discovered) }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(discovered == nil || checking).accessibilityIdentifier("confirm-add-project")
            }
        }.padding(28).frame(width: 610).frame(minHeight: 370).onAppear { pathFocused = true }
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
    @FocusState private var titleFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("New Task").font(.title2.weight(.semibold))
                Spacer()
                Picker("Project", selection: $projectID) {
                    ForEach(model.snapshot.projects) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().frame(maxWidth: 230)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Title").font(.caption).foregroundStyle(.secondary)
                TextField("What needs building?", text: $title).textFieldStyle(.roundedBorder).focused($titleFocused).accessibilityIdentifier("task-title")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("What should be built").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $description).font(.body).frame(height: 165).padding(6)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Task description")
            }
            Text("Review requires proof checks and a recording command. Their setup controls are coming soon; save work to Backlog until your project is configured.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Agents only pick up tasks in Todo.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start Now") { create(start: true) }.disabled(!valid || selectedProject?.host != .github)
                Button("Add to Backlog") { create(start: false) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(28).frame(width: 670).onAppear { projectID = model.selectedProject?.id ?? model.snapshot.projects.first?.id; titleFocused = true }
    }
    private var selectedProject: Project? { model.snapshot.projects.first { $0.id == projectID } }
    private var valid: Bool { projectID != nil && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func create(start: Bool) {
        guard let projectID else { return }
        model.perform { try await model.createTask(projectID: projectID, title: title, description: description, start: start) }
    }
}
