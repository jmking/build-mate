import SwiftUI

@main
struct BuildMateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel?
    @State private var error: String?

    var body: some Scene {
        WindowGroup("Build Mate") {
            Group {
                if let model { MainWindow().environment(model) }
                else if let error { ContentUnavailableView("Unable to open Build Mate", systemImage: "exclamationmark.triangle", description: Text(error)).frame(minWidth: 1100, minHeight: 700) }
                else { ProgressView("Opening workspace…").frame(minWidth: 1100, minHeight: 700) }
            }
            .containerBackground(AppSurface.window, for: .window)
            .preferredColorScheme(developmentAppearance)
            .task {
                guard model == nil, error == nil else { return }
                do {
                    let root = ProcessInfo.processInfo.environment["BUILD_MATE_DATA_ROOT"].map { URL(fileURLWithPath: $0) }
                    let store = try root.map { try Store(root: $0) } ?? Store()
                    let value = AppModel(store: store)
                    delegate.core = value.core; model = value
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
            CommandGroup(after: .sidebar) {
                Button("Needs You") { model?.destination = .needsYou }.keyboardShortcut("1")
                    .help("Show tasks that need your attention (⌘1)")
                Button("Chat") { model?.navigate(.chat) }.keyboardShortcut("2")
                    .help("Open project chat (⌘2)")
                Button("Backlog") { model?.navigate(.backlog) }.keyboardShortcut("3")
                    .help("Show tasks that are not queued to run (⌘3)")
                Button("Tasks") { model?.navigate(.tasks) }.keyboardShortcut("4")
                    .help("Show queued, running and completed work (⌘4)")
                Button("Instructions") { model?.navigate(.instructions) }.keyboardShortcut("5")
                    .help("Show this project’s instructions (⌘5)")
                Divider()
                Button("Toggle List/Board") { model?.listMode.toggle() }.keyboardShortcut("l")
                    .help("Switch between the task list and board (⌘L)")
                Button("Toggle Inspector") { model?.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
                    .help("Show or hide task details (⌥⌘I)")
                Button("Back") { model?.goBack() }.keyboardShortcut("[").disabled(model?.canGoBack != true)
                    .help("Return to the previous view (⌘[)")
                Button("Forward") { model?.goForward() }.keyboardShortcut("]").disabled(model?.canGoForward != true)
                    .help("Go forward in navigation history (⌘])")
                Button("Find") { model?.findRequested.toggle() }.keyboardShortcut("f")
                    .help("Search tasks in the current view (⌘F)")
            }
            CommandMenu("Task") {
                Button("Edit Task…") { model?.editingTask = model?.selectedTask }
                    .help("Edit the selected task (⇧⌘E)")
                    .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model?.selectedTask == nil)
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
                Button("Pause / Resume Task") {
                    guard let model, let task = model.selectedTask else { return }
                    model.perform { try await model.core.pause(task.id, paused: !task.paused) }
                }.keyboardShortcut(".").disabled(model?.selectedTask == nil)
                    .help("Pause or resume work on the selected task (⌘.)")
                Button("Pause / Resume Project") {
                    guard let model, let project = model.selectedProject else { return }
                    model.perform { try model.pauseProject(project) }
                }.disabled(model?.selectedProject == nil)
                    .help("Pause or resume agent work in this project")
                Button("Pause / Resume All") { guard let model else { return }; model.perform { try model.pauseAll() } }.keyboardShortcut("p", modifiers: [.command, .option])
                    .help("Pause or resume agents across all projects (⌥⌘P)")
            }
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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let core else { return .terminateNow }
        Task { await core.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
