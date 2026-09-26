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
                Button("New Project…") { model?.showAddProject = true }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button("Needs You") { model?.destination = .needsYou }.keyboardShortcut("1")
                Button("Chat") { model?.navigate(.chat) }.keyboardShortcut("2")
                Button("Backlog") { model?.navigate(.backlog) }.keyboardShortcut("3")
                Button("Tasks") { model?.navigate(.tasks) }.keyboardShortcut("4")
                Button("Instructions") { model?.navigate(.instructions) }.keyboardShortcut("5")
                Divider()
                Button("Toggle List/Board") { model?.listMode.toggle() }.keyboardShortcut("l")
                Button("Toggle Inspector") { model?.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
                Button("Back") { model?.goBack() }.keyboardShortcut("[").disabled(model?.canGoBack != true)
                Button("Forward") { model?.goForward() }.keyboardShortcut("]").disabled(model?.canGoForward != true)
                Button("Find") { model?.findRequested.toggle() }.keyboardShortcut("f")
            }
            CommandMenu("Task") {
                Button("Pause / Resume Task") {
                    guard let model, let task = model.selectedTask else { return }
                    model.perform { try await model.core.pause(task.id, paused: !task.paused) }
                }.keyboardShortcut(".").disabled(model?.selectedTask == nil)
                Button("Pause / Resume Project") {
                    guard let model, let project = model.selectedProject else { return }
                    model.perform { try model.pauseProject(project) }
                }.disabled(model?.selectedProject == nil)
                Button("Pause / Resume All") { guard let model else { return }; model.perform { try model.pauseAll() } }.keyboardShortcut("p", modifiers: [.command, .option])
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
