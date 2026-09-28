import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var projectID: UUID?
    @State private var renamingProject: Project?
    @State private var advancedExpanded = false
    @State private var diagnosticsExpanded = false
    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            Form {
                Section("Agents") {
                    Stepper("Agents at once: \(model.settings.agentsAtOnce)", value: setting(\.agentsAtOnce), in: 1...32)
                        .help("Maximum simultaneous task and project-chat agents across all projects")
                    Stepper("Hold new work below \(model.settings.usageHoldThreshold)% usage remaining", value: setting(\.usageHoldThreshold), in: 0...100, step: 5)
                        .help("Applies when no usable Codex credits are reported. Zero disables automatic usage holds; running agents continue")
                }
                Section("Notifications") { NotificationSettings() }
                if !model.snapshot.projects.isEmpty {
                    Section("Project") {
                        projectPicker
                        if let project {
                            LabeledContent("Name") {
                                Text(project.name).lineLimit(1).truncationMode(.middle).help(project.name)
                                Button("Rename…") { renamingProject = project }
                                    .help("Change the name shown for this project")
                            }
                            ProjectRepositoryPicker(projectID: project.id).id(project.id)
                            Picker("Open code in", selection: projectSetting(\.editor, fallback: nil)) {
                                Text("First installed editor").tag(Optional<String>.none)
                                ForEach(model.installedEditors) { Text($0.name).tag(Optional($0.id)) }
                            }.help("Default editor for this project")
                            Toggle("Ask me before starting to build", isOn: projectSetting(\.askBeforeBuild, fallback: false))
                                .help("Require plan approval unless a task overrides this preference")
                            Picker("Default task approvals", selection: Binding(get: { project.settings.approvalMode ?? .ask }, set: { projectSetting(\.approvalMode, fallback: nil).wrappedValue = $0 })) {
                                ForEach(AgentApprovalMode.allCases, id: \.self) { Text($0.title).tag($0) }
                            }.help("Default for task agents; each task can override it. Project chat keeps its read-only sandbox")
                            Text((project.settings.approvalMode ?? .ask).explanation).font(.caption).foregroundStyle(.secondary)
                            Picker("Merge pull requests with", selection: projectSetting(\.mergeStrategy, fallback: nil)) {
                                Text("Repository default").tag(Optional<MergeStrategy>.none)
                                ForEach(MergeStrategy.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                            }.help("Use the repository’s default merge method, or choose one for this project. The repository must allow it")
                            DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                                TextField("Branch prefix", text: projectSetting(\.branchPrefix, fallback: "")).help("Prefix for newly created task branches")
                                Toggle("Allow agent network access", isOn: projectSetting(\.network, fallback: true)).disabled(project.settings.approvalMode == .fullAccess).help("Allow sandboxed task agents network access without prompting. Full Access always includes network access; project chat remains read-only")
                                DisclosureGroup("Diagnostics", isExpanded: $diagnosticsExpanded) {
                                    duration("Turn timeout", \.turnTimeoutMs, fallback: 3_600_000, unit: "minutes", scale: 60_000)
                                    duration("Stall timeout", \.stallTimeoutMs, fallback: 300_000, unit: "minutes", scale: 60_000, allowsZero: true)
                                    duration("Response timeout", \.readTimeoutMs, fallback: 5_000, unit: "seconds", scale: 1_000)
                                        .help("How long to wait for Codex to answer a request. Starting a conversation always allows at least 30 seconds")
                                    duration("Maximum retry delay", \.retryBackoffMaxMs, fallback: 300_000, unit: "minutes", scale: 60_000)
                                }.disclosureGroupStyle(SettingsDisclosureStyle())
                                    .help("Adjust timeouts only when diagnosing agent connection or execution problems")
                            }.disclosureGroupStyle(SettingsDisclosureStyle())
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
            .sheet(item: $renamingProject) { RenameProjectSheet(project: $0).presentationBackground(AppSurface.sheet) }
            .alert("Unable to save settings", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK", role: .cancel) { model.error = nil }.help("Dismiss the settings error")
            } message: { Text(model.error ?? "") }
            .onAppear {
                projectID = model.settingsProjectID.flatMap { id in model.snapshot.projects.contains { $0.id == id } ? id : nil }
                    ?? model.selectedProject?.id ?? model.snapshot.projects.first?.id
            }
            .onChange(of: model.settingsProjectID) {
                if let id = model.settingsProjectID, model.snapshot.projects.contains(where: { $0.id == id }) { projectID = id }
            }
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
    private func duration(_ title: String, _ key: WritableKeyPath<ProjectSettings, Int>, fallback: Int, unit: String, scale: Double, allowsZero: Bool = false) -> some View {
        let milliseconds = projectSetting(key, fallback: fallback)
        let value = Binding(get: { Double(milliseconds.wrappedValue) / scale }, set: { milliseconds.wrappedValue = Int(($0 * scale).rounded()) })
        let minimum = allowsZero ? 0.0 : 1.0
        return Stepper(onIncrement: value.wrappedValue < 10_080 ? {
            value.wrappedValue = min(10_080, floor(value.wrappedValue) + 1)
        } : nil, onDecrement: value.wrappedValue > minimum ? {
            value.wrappedValue = max(minimum, ceil(value.wrappedValue) - 1)
        } : nil) {
            Text("\(title): \(value.wrappedValue, format: .number.precision(.fractionLength(0...2))) \(unit)")
        }.help(allowsZero ? "Time without an agent update before recovery; zero disables this timeout" : "\(title) in \(unit)")
    }
}

/// The whole row is a keyboard-accessible button, not just the small disclosure arrow.
private struct SettingsDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
                .help(configuration.isExpanded ? "Hide these settings" : "Show these settings")
            if configuration.isExpanded { configuration.content.padding(.leading, 20) }
        }
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
