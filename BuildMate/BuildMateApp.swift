import SwiftUI

@main
struct BuildMateApp: App {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel?
    @State private var error: String?

    var body: some Scene {
        Window("Build Mate", id: "main") {
            Group {
                if let model { MainWindow().environment(model) }
                else if let error { ContentUnavailableView("Unable to open Build Mate", systemImage: "exclamationmark.triangle", description: Text(error)).frame(minWidth: 900, minHeight: 620) }
                else { ProgressView("Opening workspace…").frame(minWidth: 900, minHeight: 620) }
            }
            .containerBackground(AppSurface.window, for: .window)
            .preferredColorScheme(developmentAppearance)
            .task {
                guard model == nil, error == nil else { return }
                do {
                    let root = ProcessInfo.processInfo.environment["BUILD_MATE_DATA_ROOT"].map { URL(fileURLWithPath: $0) }
                    let store = try root.map { try Store(root: $0) } ?? Store()
                    let value = AppModel(store: store)
                    delegate.core = value.core; delegate.model = value; model = value
                    let notifications = AttentionNotifications(root: store.root)
                    notifications.open = { type, id in
                        value.destination = type == "task" ? .task(id) : .project(id, .chat)
                        openWindow(id: "main"); NSApp.activate()
                    }
                    delegate.notifications = notifications
                    value.onRefresh = { items in Task { await notifications.update(items) } }
                    delegate.observation = Task { await value.observe() }
                } catch { self.error = error.localizedDescription }
            }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Task…") { model?.showNewTask = true }.keyboardShortcut("n").disabled(model?.snapshot.projects.isEmpty != false)
                    .help("Create a new task (⌘N)")
                Button("New Project…") { model?.showAddProject = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                    .help("Add an existing repository or create a new project (⇧⌘N)")
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Open Code") { model?.openLocation(appID: model?.defaultEditor?.id) }
                    .keyboardShortcut("o").disabled(model?.selectedProject == nil || (model?.selectedTask != nil && model?.selectedTask?.worktreePath == nil))
                    .help("Open the selected task’s worktree, or the project folder, in your editor (⌘O)")
                Button("Open Terminal") { model?.openLocation(appID: "com.apple.Terminal") }
                    .keyboardShortcut("t", modifiers: [.command, .control]).disabled(model?.selectedProject == nil || (model?.selectedTask != nil && model?.selectedTask?.worktreePath == nil))
                    .help("Open a Terminal at this location (⌃⌘T)")
                Button("Open in Finder") { model?.openLocation() }
                    .keyboardShortcut("r", modifiers: [.command, .option]).disabled(model?.selectedProject == nil || (model?.selectedTask != nil && model?.selectedTask?.worktreePath == nil))
                    .help("Open this folder in Finder (⌥⌘R)")
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") { model?.toggleSidebar.toggle() }.keyboardShortcut("s", modifiers: [.command, .control])
                    .help("Show or hide the project sidebar (⌃⌘S)")
                Button("Needs You") { model?.destination = .needsYou }.keyboardShortcut("1")
                    .help("Show tasks that need your attention (⌘1)")
                Button("Chat") { model?.navigate(.chat) }.keyboardShortcut("2")
                    .help("Open project chat (⌘2)")
                Button("Tasks") { model?.navigate(.tasks) }.keyboardShortcut("3")
                    .help("Show queued, running and completed work (⌘3)")
                Divider()
                Button("Toggle List/Board") { model?.listMode.toggle() }.keyboardShortcut("l")
                    .disabled(!isTaskCollection).help("Switch between the task list and board (⌘L)")
                Button("Toggle Inspector") { model?.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
                    .disabled(!hasInspector).help("Show or hide task details (⌥⌘I)")
                Button("Back") { model?.goBack() }.keyboardShortcut("[").disabled(model?.canGoBack != true)
                    .help("Return to the previous view (⌘[)")
                Button("Forward") { model?.goForward() }.keyboardShortcut("]").disabled(model?.canGoForward != true)
                    .help("Go forward in navigation history (⌘])")
                Button("Find") { model?.findRequested.toggle() }.keyboardShortcut("f")
                    .disabled(model?.canSearch != true).help("Search tasks in the current view (⌘F)")
                Divider()
                Button("Pause / Resume All") { guard let model else { return }; model.perform { try model.pauseAll() } }.keyboardShortcut("p", modifiers: [.command, .option])
                    .help("Pause or resume agents across all projects (⌥⌘P)")
            }
            CommandMenu("Project") {
                Button("Instructions") { model?.navigate(.instructions) }.keyboardShortcut("4").disabled(model?.selectedProject == nil)
                    .help("Show this project’s instructions (⌘4)")
                Button("Project Settings…") {
                    model?.settingsProjectID = model?.selectedProject?.id
                    model?.settingsTab = "general"
                    openSettings()
                }
                    .disabled(model?.selectedProject == nil).help("Edit settings for the selected project")
                Button("Configure Local Preview…") { if let project = model?.selectedProject { model?.reviewSheet = .previewSetup(project.id) } }
                    .disabled(model?.selectedProject == nil).help("Set the project’s preview command, port variable and ready path")
                Divider()
                Button("Stop Project Response") { if let model, let project = model.selectedProject { model.perform { await model.core.stopProjectChat(project.id) } } }
                    .disabled(model?.snapshot.sessions.contains { $0.ownerType == "project" && $0.ownerId == model?.selectedProject?.id && ["queued", "running", "waiting"].contains($0.status) } != true)
                    .help("Stop the project agent’s current response")
                Button("Pause / Resume Project") {
                    guard let model, let project = model.selectedProject else { return }
                    model.perform { try model.pauseProject(project) }
                }.disabled(model?.selectedProject == nil)
                    .help("Pause or resume agent work in this project")
            }
            CommandMenu("Task") {
                Button("Refine Task in Chat") { if let task = model?.selectedTask { model?.refineInChat(task) } }
                    .disabled(model?.selectedTask?.state != .todo).help("Ask the project agent to refine the selected queued task")
                Button("Edit Task…") { model?.editingTask = model?.selectedTask }
                    .help("Edit the selected task (⇧⌘E)")
                    .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model?.selectedTask == nil)
                Divider()
                Button("Run / Open Local Preview") { if let task = model?.selectedTask { model?.runPreview(task) } }
                    .disabled(model?.selectedTask?.worktreePath == nil || model?.selectedTask?.state.terminal == true)
                    .help("Start or reopen the selected task’s preview in your browser")
                Button("Stop Local Preview") {
                    guard let model, let task = model.selectedTask else { return }
                    model.perform { await model.core.stopPreview(task.id) }
                }.disabled(model?.selectedTask.flatMap { model?.previews[$0.id] } == nil).help("Stop the selected task’s preview")
                Button("View Changes…") { if let task = model?.selectedTask { model?.reviewSheet = .changes(task.id) } }
                    .disabled(model?.snapshot.proofs.contains { $0.taskId == model?.selectedTask?.id } != true)
                    .help("Review the saved proof’s change summary and file list")
                Button(model?.selectedTask?.pr == nil ? "Open Pull Request" : "Update Pull Request") {
                    guard let model, let task = model.selectedTask else { return }
                    model.perform { try await model.core.openPullRequest(task.id) }
                }.disabled(model?.selectedTask?.state != .humanReview || model?.selectedProject?.host != .github || model?.selectedTask?.paused == true || model?.snapshot.proofs.contains { $0.taskId == model?.selectedTask?.id && $0.complete } != true)
                    .help(model?.selectedTask?.pr == nil ? "Publish the selected task’s reviewed changes as a GitHub pull request" : "Push the reviewed changes and update this pull request’s description")
                Button("Use Suggested Answers…") { if let task = model?.selectedTask { model?.reviewSheet = .defaults(task.id) } }
                    .disabled(model?.selectedTask?.state != .needsClarification || model?.selectedTask.map { model?.hasSuggestedAnswers(for: $0.id) == true } != true)
                    .help("Review and confirm the agent’s suggested answers")
                Button("Expand Recording") {
                    guard let model, let path = model.snapshot.proofs.first(where: { $0.taskId == model.selectedTask?.id })?.recordingPath else { return }
                    openWindow(id: "recording", value: path)
                }.disabled(model?.snapshot.proofs.first { $0.taskId == model?.selectedTask?.id }?.recordingPath == nil)
                    .help("Open the selected task’s proof recording in a larger player")
                Button("Approve Plan") {
                    guard let model, let approval = model.snapshot.approvals.first(where: { $0.taskId == model.selectedTask?.id && $0.status == "pending" && $0.kind == "plan" }) else { return }
                    model.perform { try await model.core.approvePlan(approval.id) }
                }.disabled(model?.snapshot.approvals.contains { $0.taskId == model?.selectedTask?.id && $0.status == "pending" && $0.kind == "plan" } != true)
                    .help("Approve the selected task’s plan")
                Divider()
                Button("Move Earlier") {
                    guard let model, let task = model.selectedTask else { return }
                    model.perform { try model.movePriority(task, earlier: true) }
                }.keyboardShortcut(.upArrow, modifiers: [.command, .control])
                    .help("Move the selected task one place earlier in priority (⌃⌘↑)")
                    .disabled(model?.selectedTask.flatMap { model?.priorityNeighbor($0, earlier: true) } == nil)
                Button("Move Later") {
                    guard let model, let task = model.selectedTask else { return }
                    model.perform { try model.movePriority(task, earlier: false) }
                }.keyboardShortcut(.downArrow, modifiers: [.command, .control])
                    .help("Move the selected task one place later in priority (⌃⌘↓)")
                    .disabled(model?.selectedTask.flatMap { model?.priorityNeighbor($0, earlier: false) } == nil)
                Button("Delete Task…", role: .destructive) {
                    guard let model, let task = model.selectedTask else { return }
                    model.taskToDelete = task
                }.keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model?.selectedTask == nil || model?.selectedTask.map { model?.deletingTasks.contains($0.id) == true } == true)
                    .help("Delete the selected task after confirmation (⌘Delete)")
                Button("Cancel Task") {
                    guard let model, let task = model.selectedTask else { return }
                    model.perform { try await model.core.transition(task.id, to: .canceled); await model.core.tick() }
                }.disabled(model?.selectedTask == nil || model?.selectedTask?.state.terminal == true)
                    .help("Stop this task and retain its history and worktree")
                Button("Pause / Resume Task") {
                    guard let model, let task = model.selectedTask else { return }
                    model.perform { try await model.core.pause(task.id, paused: !task.paused) }
                }.keyboardShortcut(".").disabled(model?.selectedTask == nil || model?.selectedTask?.state.terminal == true)
                    .help("Pause or resume work on the selected task (⌘.)")

            }
        }
        MenuBarExtra {
            if let model { AgentMenu().environment(model) }
        } label: {
            Image(systemName: "hammer")
                .overlay(alignment: .topTrailing) {
                    if (model?.needsCount ?? 0) > 0 { Circle().frame(width: 4, height: 4).offset(x: 3, y: -2) }
                }.accessibilityLabel("Build Mate, \(model?.needsCount ?? 0) need attention")
                .help("Build Mate agents and Needs You")
        }.menuBarExtraStyle(.window)
        Settings {
            if let model { SettingsView().environment(model) }
        }
        WindowGroup("Proof Recording", id: "recording", for: String.self) { $path in
            if let path { RecordingPlayer(path: path).frame(minWidth: 640, minHeight: 360) }
        }.defaultSize(width: 960, height: 540)
        WindowGroup("Screenshot", id: "screenshot", for: String.self) { $path in
            if let path { ScreenshotViewer(path: path) }
        }.defaultSize(width: 1100, height: 760)
            .restorationBehavior(.disabled)
    }
    private var isTaskCollection: Bool {
        if case .project(_, .tasks) = model?.destination { return true }
        return false
    }
    private var hasInspector: Bool {
        switch model?.destination {
        case .task, .project(_, .chat): true
        default: false
        }
    }
    private var developmentAppearance: ColorScheme? {
        switch ProcessInfo.processInfo.environment["BUILD_MATE_APPEARANCE"] {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var core: Orchestrator?
    var model: AppModel?
    var observation: Task<Void, Never>?
    var notifications: AttentionNotifications?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let core else { return .terminateNow }
        if let model, model.workers > 0 {
            let alert = NSAlert()
            alert.messageText = "\(model.workers) agents are working. Pause them and quit?"
            alert.informativeText = "Worktrees and conversation history are kept so work can resume when you reopen Build Mate."
            alert.addButton(withTitle: "Pause and Quit"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        observation?.cancel()
        Task { await core.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
