import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var projectID: UUID?
    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            Form {
                Section("Agents") {
                    Stepper("Agents at once: \(model.settings.agentsAtOnce)", value: setting(\.agentsAtOnce), in: 1...32)
                        .help("Maximum simultaneous task and project-chat agents across all projects")
                    Stepper("Heavy steps at once: \(model.settings.heavyStepsAtOnce)", value: setting(\.heavyStepsAtOnce), in: 1...16)
                        .help("Limit simultaneous proof checks and local previews")
                    Stepper("Hold new work below \(model.settings.usageHoldThreshold)% usage remaining", value: setting(\.usageHoldThreshold), in: 0...100, step: 5)
                        .help("Zero disables automatic usage holds; running agents continue")
                }
                Section("Notifications") { NotificationSettings() }
                if !model.snapshot.projects.isEmpty {
                    Section("Project") {
                        projectPicker
                        if let project {
                            Picker("Open code in", selection: projectSetting(\.editor, fallback: nil)) {
                                Text("First installed editor").tag(Optional<String>.none)
                                ForEach(model.installedEditors) { Text($0.name).tag(Optional($0.id)) }
                            }.help("Default editor for this project")
                            Stepper("Turns per task: \(project.settings.maxTurnsPerTask)", value: projectSetting(\.maxTurnsPerTask, fallback: 20), in: 1...200)
                                .help("Maximum agent turns per task attempt")
                            Toggle("Ask me before starting to build", isOn: projectSetting(\.askBeforeBuild, fallback: false))
                                .help("Require plan approval unless a task overrides this preference")
                            Text("Pull requests are opened by you. Automatic merging is not available yet.").font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup("Advanced") {
                                number("Turn timeout (milliseconds)", \.turnTimeoutMs, fallback: 3_600_000)
                                number("Stall timeout (milliseconds, 0 disables)", \.stallTimeoutMs, fallback: 300_000)
                                number("Read timeout (milliseconds)", \.readTimeoutMs, fallback: 5_000)
                                number("Maximum retry backoff (milliseconds)", \.retryBackoffMaxMs, fallback: 300_000)
                                TextField("Branch prefix", text: projectSetting(\.branchPrefix, fallback: "")).help("Prefix for newly created task branches")
                                Toggle("Allow agent network access", isOn: projectSetting(\.network, fallback: true)).help("Allow network access from task agents; project chat remains read-only without network access")
                            }
                        }
                    }
                }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            VStack {
                if model.snapshot.projects.isEmpty { ContentUnavailableView("Add a project first", systemImage: "folder") }
                else { projectPicker.padding(.horizontal, 24).padding(.top, 16); if let project { HookSettings(projectID: project.id).id(project.id) } }
            }.tabItem { Label("Hooks", systemImage: "terminal") }.tag("hooks")
            InstructionsView().tabItem { Label("Instructions", systemImage: "doc.text") }.tag("instructions")
        }.padding(.top, 8).frame(width: 720, height: 620)
            .containerBackground(AppSurface.window, for: .window)
            .alert("Unable to save settings", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK", role: .cancel) { model.error = nil }.help("Dismiss the settings error")
            } message: { Text(model.error ?? "") }
            .onAppear { projectID = model.selectedProject?.id ?? model.snapshot.projects.first?.id }
    }
    private var project: Project? { model.snapshot.projects.first { $0.id == projectID } }
    private var projectPicker: some View {
        Picker("Project", selection: $projectID) { ForEach(model.snapshot.projects) { Text($0.name).tag(Optional($0.id)) } }
            .help("Choose the project whose settings you want to edit")
    }
    private func setting(_ key: WritableKeyPath<AppSettings, Int>) -> Binding<Int> {
        Binding(get: { model.settings[keyPath: key] }, set: { value in
            do { var settings = try model.store.settings(); settings[keyPath: key] = value; try model.store.saveSettings(settings); model.settings = settings; model.perform { await model.core.tick() } }
            catch { model.error = error.localizedDescription }
        })
    }
    private func projectSetting<T>(_ key: WritableKeyPath<ProjectSettings, T>, fallback: T) -> Binding<T> {
        Binding(get: { project?.settings[keyPath: key] ?? fallback }, set: { value in
            guard let projectID else { return }
            do {
                var project = try model.store.get(Project.self, projectID); project.settings[keyPath: key] = value
                try project.settings.validate(); try model.store.workflow(for: project); try model.store.save(project)
                if let index = model.snapshot.projects.firstIndex(where: { $0.id == projectID }) { model.snapshot.projects[index] = project }
            } catch { model.error = error.localizedDescription }
        })
    }
    private func number(_ title: String, _ key: WritableKeyPath<ProjectSettings, Int>, fallback: Int) -> some View {
        TextField(title, value: projectSetting(key, fallback: fallback), format: .number).help(title)
    }
}

private struct HookSettings: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID
    @State private var draft = ProjectSettings()
    @State private var unlocked = false
    @State private var confirming = false
    @State private var failure: String?
    var body: some View {
        Form {
            Section {
                Text("Hooks run as you on this Mac.").font(.headline)
                if !unlocked { Button("Edit Commands…") { confirming = true }.help("Review the permission to edit commands that run on this Mac") }
            }
            Group {
                Section("Workspace hooks") {
                    command("After create", text: $draft.hooks.afterCreate)
                    command("Before run", text: $draft.hooks.beforeRun)
                    command("After run", text: $draft.hooks.afterRun)
                    command("Before remove", text: $draft.hooks.beforeRemove)
                    TextField("Hook timeout (seconds)", value: $draft.hooks.timeoutSeconds, format: .number).help("Maximum runtime for each workspace hook")
                }
                Section("Local preview") {
                    command("Preview command", text: $draft.previewCommand)
                    TextField("Port variable", text: $draft.previewPortEnvVar).help("Environment variable containing the preview’s assigned port")
                    TextField("Ready path", text: $draft.previewReadyPath).help("HTTP path checked before opening the preview")
                }
                Section("Checks") {
                    ForEach(draft.checks.indices, id: \.self) { index in
                        VStack(alignment: .leading) {
                            TextField("Check name", text: $draft.checks[index].name).help("Name shown in proof results")
                            command("Command", text: $draft.checks[index].command)
                            HStack {
                                Toggle("Required", isOn: $draft.checks[index].required).help("Block review until this check passes")
                                Spacer()
                                Button("Remove", systemImage: "minus.circle") { draft.checks.remove(at: index) }.help("Remove this check")
                            }
                        }
                    }
                    if draft.checks.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                        Text("Complete each check’s name and command to save. Existing checks remain active.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Add Check", systemImage: "plus") { draft.checks.append(CheckDefinition(name: "", command: "")) }.help("Add a project proof check")
                }
                Section("Visual proof") {
                    command("Recording command", text: Binding(get: { draft.recordingCommand ?? "" }, set: { draft.recordingCommand = $0.isEmpty ? nil : $0 }))
                    Text("Leave blank to let the agent provide a recording command when the task needs one.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Request before/after screenshots for UI changes", isOn: $draft.screenshotsForUI).help("Ask for screenshots when visual proof is needed")
                }
            }.disabled(!unlocked)
            if let failure { Text(failure).foregroundStyle(.red) }
        }.formStyle(.grouped)
            .onAppear { draft = (try? model.store.get(Project.self, projectID).settings) ?? ProjectSettings() }
            .onChange(of: encodedDraft) { if unlocked { save() } }
            .confirmationDialog("Hooks run as you on this Mac", isPresented: $confirming) {
                Button("Edit Commands") { unlocked = true }.help("Enable command editing for this settings session")
            } message: { Text("These commands can read and change files with your account’s permissions.") }
    }
    private var encodedDraft: Data? { try? JSONEncoder().encode(draft) }
    private func command(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text, axis: .vertical).lineLimit(1...4).font(.system(.body, design: .monospaced)).help(title)
    }
    private func save() {
        do {
            try draft.validate()
            var project = try model.store.get(Project.self, projectID)
            project.settings.hooks = draft.hooks
            // Keep saved checks active while a row is being edited; only Remove deletes a check.
            if draft.checks.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                project.settings.checks = draft.checks
            }
            project.settings.previewCommand = draft.previewCommand; project.settings.previewPortEnvVar = draft.previewPortEnvVar; project.settings.previewReadyPath = draft.previewReadyPath
            project.settings.recordingCommand = draft.recordingCommand; project.settings.screenshotsForUI = draft.screenshotsForUI
            try model.store.workflow(for: project); try model.store.save(project); failure = nil
        } catch { failure = error.localizedDescription }
    }
}
