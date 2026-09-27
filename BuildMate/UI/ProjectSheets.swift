import SwiftUI
import AppKit

struct AddProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var discovered: DiscoveredProject?
    @State private var checking = false
    @State private var creatingNew = false
    @State private var failure: String?
    @State private var inspection: Task<Void, Never>?
    @FocusState private var pathFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(creatingNew ? "Create Project" : "Add Project").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Picker("Project setup", selection: $creatingNew) {
                Text("Add Existing").tag(false)
                Text("Create New").tag(true)
            }.pickerStyle(.segmented).disabled(checking).accessibilityIdentifier("project-setup-mode")
                .help("Add a repository that already exists, or create a new local Git repository")
                .onChange(of: creatingNew) { discovered = nil; failure = nil }
            Text(creatingNew ? "Choose a new or empty folder for your Git repository." : "Choose a local Git repository on this Mac.").foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                TextField(creatingNew ? "Project folder" : "Repository folder", text: $path).textFieldStyle(.roundedBorder).focused($pathFocused).onSubmit {
                    if !path.isEmpty && !checking { if creatingNew { createProject() } else { inspect(addWhenReady: true) } }
                }.accessibilityIdentifier("repository-path")
                    .onChange(of: path) { discovered = nil; failure = nil }
                Button("Choose…") { chooseFolder() }
                    .help(creatingNew ? "Choose a new or empty folder for this project" : "Choose an existing Git repository")
            }.disabled(checking)
            if creatingNew {
                Text("Creates a local repository on main, ready for your first task.").font(.caption).foregroundStyle(.secondary)
                if checking { ProgressView("Creating project…").controlSize(.small) }
            } else if checking { ProgressView("Checking repository…").controlSize(.small) }
            if let discovered {
                GroupBox {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                        GridRow(alignment: .firstTextBaseline) { Text("Project").foregroundStyle(.secondary); Text(discovered.project.name) }
                        GridRow(alignment: .firstTextBaseline) { Text("Host").foregroundStyle(.secondary); Text(discovered.project.host.title) }
                        GridRow(alignment: .firstTextBaseline) { Text("Default branch").foregroundStyle(.secondary); Text(discovered.project.defaultBranch).font(.body.monospaced()) }
                        GridRow(alignment: .firstTextBaseline) { Text(discovered.project.host == .local ? "Repository" : "CLI status").foregroundStyle(.secondary); Label(discovered.status, systemImage: discovered.authenticated ? "checkmark.circle" : "exclamationmark.circle") }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                if let command = discovered.setupCommand {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Run in Terminal: \(command)").font(.caption.monospaced()).textSelection(.enabled)
                        Button("Copy Command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string) }
                            .help("Copy this setup command to the clipboard")
                        Button("Check Again") { inspect() }.disabled(checking)
                            .help("Check Git hosting sign-in again after running the setup command")
                    }
                }
            }
            if let failure { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline) {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(creatingNew && checking)
                    .help("Close project setup without adding a project (Esc)")
                Button(creatingNew ? "Create Project" : "Add Project") {
                    if creatingNew { createProject() }
                    else if let discovered { model.perform { try model.add(discovered) } }
                    else { inspect(addWhenReady: true) }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .help(creatingNew ? "Create a local Git repository in the selected folder (Return)" : "Check and add this repository to Build Mate (Return)")
                    .disabled(checking || path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("confirm-add-project")
            }
        }.padding(28).frame(width: 610).frame(minHeight: 370).accessibilityElement(children: .contain).interactiveDismissDisabled(creatingNew && checking).onAppear { pathFocused = true }
            .onDisappear { inspection?.cancel() }
    }
    private func createProject() {
        guard !checking else { return }
        let requested = path
        checking = true; failure = nil
        Task {
            defer { checking = false }
            do { try await model.createProject(path: requested) }
            catch { failure = error.localizedDescription }
        }
    }
    private func inspect(addWhenReady: Bool = false) {
        let requested = path
        checking = true; discovered = nil; failure = nil
        inspection = Task {
            defer { checking = false }
            do {
                let result = try await ProjectDiscovery().inspect(path: requested)
                try Task.checkCancellation()
                if path == requested {
                    discovered = result
                    if addWhenReady && result.authenticated { try model.add(result); await model.refresh() }
                }
            } catch is CancellationError {
            } catch { if path == requested { failure = error.localizedDescription } }
        }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = creatingNew
        panel.prompt = creatingNew ? "Choose Project Folder" : "Choose Repository"
        if panel.runModal() == .OK, let url = panel.url { path = url.path; if !creatingNew { inspect() } }
    }
}

struct EditTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: WorkTask
    @State private var title: String
    @State private var description: String
    @State private var proofRequirement: ProofRequirement
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var titleFocused: Bool

    init(task: WorkTask) {
        self.task = task
        _title = State(initialValue: task.title)
        _description = State(initialValue: task.description)
        _proofRequirement = State(initialValue: task.proofRequirement)
    }
    private var scopeLocked: Bool { task.state.terminal || task.state == .inPR }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Edit Task").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 6) {
                Text("Title").font(.caption).foregroundStyle(.secondary)
                TextField("Task title", text: $title).textFieldStyle(.roundedBorder).focused($titleFocused)
                    .accessibilityLabel("Task title").accessibilityIdentifier("edit-task-title").disabled(saving)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("What should be built").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $description).font(.system(size: 14)).scrollContentBackground(.hidden)
                    .frame(height: 165).padding(10)
                    .background(AppSurface.card, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
                    .accessibilityLabel("Task description").accessibilityIdentifier("edit-task-description")
                    .disabled(saving || scopeLocked)
            }
            Picker("Proof", selection: $proofRequirement) {
                ForEach(ProofRequirement.allCases, id: \.self) { Text($0.title).tag($0) }
            }.fixedSize().disabled(saving || scopeLocked).accessibilityIdentifier("edit-task-proof")
                .help("Choose the evidence the agent must provide for this task")
            Text(scopeLocked ? "Only the title can be changed once a pull request is open or the task is finished."
                 : "Changes to the brief or proof pause work that has already started. Resume the task when you’re ready for a new plan and fresh proof.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let failure { Text(failure).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack(alignment: .firstTextBaseline) {
                if saving { ProgressView().controlSize(.small); Text("Saving changes…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                    .help("Discard these edits and close (Esc)")
                Button("Save Changes", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .help("Save your edits to this task (Return)")
                    .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 670).interactiveDismissDisabled(saving).onAppear { titleFocused = true }
    }
    private func save() {
        guard !saving else { return }
        saving = true; failure = nil
        Task {
            defer { saving = false }
            do {
                try await model.editTask(task.id, title: title, description: description, proofRequirement: proofRequirement)
                dismiss()
            } catch { failure = error.localizedDescription }
        }
    }
}

struct NewTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var projectID: UUID?
    @State private var repositoryID: UUID?
    @State private var files: [URL] = []
    @State private var title = ""
    @State private var description = ""
    @State private var proofRequirement: ProofRequirement = .automatic
    @State private var askBeforeBuild: Bool?
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
                    .help("Choose the project for this task")
            }
            if repositories.count > 1 {
                Picker("Repository", selection: $repositoryID) {
                    Text("Choose repository").tag(Optional<UUID>.none)
                    ForEach(repositories) { Text($0.name).tag(Optional($0.id)) }
                }.help("Repository where this task will build and open its PR").disabled(creation != nil)
                    .accessibilityIdentifier("task-repository")
            } else if repositories.isEmpty {
                Text("Add a repository in Project Settings first.").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("What should be built").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $description).font(.system(size: 14)).scrollContentBackground(.hidden).frame(height: 165).padding(10)
                    .background(AppSurface.card, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
                    .focused($descriptionFocused).disabled(creation != nil)
                    .accessibilityLabel("Task description").accessibilityIdentifier("task-description")
            }
            ChatAttachmentTray(files: $files, root: model.store.root)
            ChatAttachmentControls(files: $files, root: model.store.root).disabled(creation != nil)
            DisclosureGroup("Options") {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent("Title") {
                        TextField("Automatic", text: $title).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Task title (optional)").accessibilityIdentifier("task-title")
                            .help("Leave blank to generate a title from the brief")
                    }
                    Picker("Proof", selection: $proofRequirement) {
                        ForEach(ProofRequirement.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("task-proof")
                        .help("Automatic chooses relevant checks and records visual changes; choose an override when needed")
                    Picker("Plan approval", selection: $askBeforeBuild) {
                        Text("Project default (\(selectedProject?.settings.askBeforeBuild == true ? "ask first" : "build automatically"))").tag(Optional<Bool>.none)
                        Text("Ask me before building").tag(Optional(true))
                        Text("Build automatically").tag(Optional(false))
                    }.help("Choose whether to review the plan before this task starts building")
                }.padding(.top, 12)
            }.disabled(creation != nil).accessibilityIdentifier("task-options")
                .help("Set an optional title, proof requirements or plan approval")
            if creation != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Creating task…").foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
            }
            if let failure { Text(failure).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let blocker { Text(blocker).font(.caption).foregroundStyle(.secondary) }
            HStack(alignment: .firstTextBaseline) {
                Spacer()
                Button("Cancel") { creation?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                    .help("Cancel task creation and close (Esc)")
                Button("Add to queue") { create() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!valid)
                    .help(blocker ?? "Queue this task to run when an agent slot is available and the project is resumed")
            }
        }.padding(28).frame(width: 670)
            .modifier(ChatAttachmentDrop(files: $files, root: model.store.root, enabled: creation == nil))
            .onAppear { projectID = model.selectedProject?.id ?? model.snapshot.projects.first?.id; descriptionFocused = true }
            // A successful save closes the sheet before its final refresh finishes.
            .onChange(of: projectID) { repositoryID = nil }
            .onDisappear { if model.showNewTask { creation?.cancel() } }
    }
    private var repositories: [ProjectRepository] { projectID.map { model.repositories($0) } ?? [] }
    private var selectedProject: Project? { model.snapshot.projects.first { $0.id == projectID } }
    private var blocker: String? {
        if (repositories.count == 1 ? repositories.first : repositories.first(where: { $0.id == repositoryID }))?.host == .bitbucket { return "Bitbucket task runs are not available yet." }
        if model.settings.paused { return "All agents are paused. This task will wait in the queue." }
        if selectedProject?.paused == true { return "This project is paused. The task will wait in the queue." }
        if model.usageHeld { return "New work is on hold until Codex usage resets or you resume it." }
        return nil
    }
    private var valid: Bool { projectID != nil && !repositories.isEmpty && (repositories.count == 1 || repositories.contains { $0.id == repositoryID }) && creation == nil && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func create() {
        guard valid, let projectID else { return }
        failure = nil
        creation = Task {
            defer { creation = nil }
            do {
                try await model.createTask(projectID: projectID, title: title, description: description, proofRequirement: proofRequirement, askBeforeBuild: askBeforeBuild, files: files, repositoryID: repositoryID)
                await model.refresh()
            } catch is CancellationError { }
            catch { failure = error.localizedDescription }
        }
    }
}
