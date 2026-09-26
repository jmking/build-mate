import SwiftUI

struct AgentMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Build Mate").font(.headline)
                    Text(model.settings.paused ? "All agents paused" : "\(model.workers) agents active").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.settings.paused ? "Resume All" : "Pause All", systemImage: model.settings.paused ? "play" : "pause") { model.perform { try model.pauseAll() } }
                    .labelStyle(.iconOnly).help(model.settings.paused ? "Resume all agents" : "Pause all agents")
                Button("New Task", systemImage: "plus") { show(); model.showNewTask = true }.labelStyle(.iconOnly)
                    .disabled(model.snapshot.projects.isEmpty).help("Create a new task")
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Needs You").font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                    if model.attentionItems.isEmpty { Text("Nothing needs your attention").font(.callout).foregroundStyle(.secondary) }
                    ForEach(model.attentionItems) { item in
                        Button {
                            model.destination = item.ownerType == "task" ? .task(item.ownerID) : .project(item.ownerID, .chat); show()
                        } label: { row(item.title, detail: item.detail, symbol: "circle.fill", color: .orange) }
                            .buttonStyle(.plain).help("Open \(item.title)")
                    }
                    Divider()
                    Text("Building").font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                    ForEach(model.snapshot.tasks.filter { $0.state == .building }) { task in
                        Button { model.destination = .task(task.id); show() } label: {
                            row(task.title, detail: task.paused || model.settings.paused || model.snapshot.projects.first(where: { $0.id == task.projectId })?.paused == true ? "Paused" : "Building", symbol: "play.circle", color: .accentColor)
                        }.buttonStyle(.plain).help("Open \(task.title)")
                    }
                    ForEach(model.snapshot.projects.filter { project in model.snapshot.sessions.contains { $0.ownerType == "project" && $0.ownerId == project.id && ["running", "waiting", "queued"].contains($0.status) } }) { project in
                        Button { model.destination = .project(project.id, .chat); show() } label: {
                            row(project.name, detail: project.paused || model.settings.paused ? "Chat paused" : "Project chat", symbol: "bubble.left", color: .accentColor)
                        }.buttonStyle(.plain).help("Open project chat for \(project.name)")
                    }
                    if model.snapshot.tasks.allSatisfy({ $0.state != .building }) { Text("No tasks building").font(.callout).foregroundStyle(.secondary) }
                }
            }.frame(maxHeight: 300)
            Divider()
            UsageFooter()
            HStack {
                Text("\(model.snapshot.tasks.filter { $0.state == .inPR }.count) in PR").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Settings", systemImage: "gearshape") { openSettings(); NSApp.activate() }.labelStyle(.iconOnly).help("Open Build Mate Settings")
                Button("Open Build Mate") { show() }.help("Show the main workspace")
            }
        }.padding(18).frame(width: 340)
    }
    private func show() { openWindow(id: "main"); NSApp.activate() }
    private func row(_ title: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.caption).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) { Text(title).lineLimit(2); Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}
