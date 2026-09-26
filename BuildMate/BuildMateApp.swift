import SwiftUI

@main
struct BuildMateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var error: String?
    @State private var core: Orchestrator?

    var body: some Scene {
        WindowGroup("Build Mate") {
            ContentUnavailableView {
                Label("Build Mate", systemImage: "hammer")
            } description: {
                Text(error ?? "Core is ready. Project setup and the task workspace arrive in milestone 3.")
            }
            .frame(minWidth: 1100, minHeight: 700)
            .task {
                guard core == nil else { return }
                do {
                    let store = try Store()
                    let orchestrator = Orchestrator(store: store)
                    core = orchestrator
                    delegate.core = orchestrator
                    await orchestrator.start()
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var core: Orchestrator?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let core else { return .terminateNow }
        Task {
            await core.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
