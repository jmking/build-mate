import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @FocusState private var searchFocused: Bool
    @State private var collapsedProjects: Set<UUID> = []
    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $model.destination) {
                Label("Needs You", systemImage: "tray").badge(model.needsCount).tag(Destination.needsYou)
                Section {
                    ForEach(model.snapshot.projects) { project in
                        DisclosureGroup(isExpanded: Binding(get: { !collapsedProjects.contains(project.id) }, set: { expanded in
                            if expanded { collapsedProjects.remove(project.id) } else { collapsedProjects.insert(project.id) }
                        })) {
                            ForEach(ProjectPage.allCases) { page in
                                Label(page.rawValue, systemImage: page.symbol)
                                    .badge(page == .backlog ? model.snapshot.tasks.filter { $0.projectId == project.id && $0.state == .backlog }.count : page == .tasks ? model.snapshot.tasks.filter { $0.projectId == project.id && model.needsYou($0) }.count : 0)
                                    .tag(Destination.project(project.id, page))
                            }
                        } label: {
                            Label {
                                HStack(spacing: 6) {
                                    Text(project.name).lineLimit(1)
                                    if project.paused { Image(systemName: "pause.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Project paused") }
                                }
                            } icon: {
                                Image(systemName: "folder").symbolVariant(.none).foregroundStyle(Color.primary).accessibilityHidden(true)
                            }
                            .padding(.leading, 4)
                        }
                    }
                } header: {
                    HStack {
                        Text("Projects")
                        Spacer()
                        Button { model.showAddProject = true } label: { Image(systemName: "plus").frame(width: 20, height: 20) }
                            .buttonStyle(.plain).help("Add Project (⇧⌘N)").accessibilityLabel("Add Project")
                            .padding(.trailing, 10)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: collapsedProjects)
            .navigationSplitViewColumnWidth(min: 210, ideal: 232, max: 300)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(model.workers) of \(model.settings.agentsAtOnce) agents busy").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    UsageFooter()
                    Button(model.settings.paused ? "Resume All" : "Pause All", systemImage: model.settings.paused ? "play.fill" : "pause.fill") {
                        model.perform { try model.pauseAll() }
                    }.buttonStyle(.borderless)
                        .help(model.settings.paused ? "Resume eligible tasks across all projects (⌥⌘P)" : "Pause all agents across all projects (⌥⌘P)")
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppSurface.sidebar)
        } detail: {
            VStack(spacing: 0) {
                if model.settings.paused {
                    HStack {
                        Label("All agents paused", systemImage: "pause.circle")
                        Spacer()
                        Button("Resume All") { model.perform { try model.pauseAll() } }
                            .help("Resume eligible tasks across all projects (⌥⌘P)")
                    }.padding(12).background(AppSurface.raised)
                }
                if let error = model.schedulerError {
                    Label(error, systemImage: "exclamationmark.triangle").padding(12).frame(maxWidth: .infinity, alignment: .leading).background(AppSurface.raised)
                }
                if let project = model.selectedProject, let reason = project.runBlockReason,
                   case .project(_, .tasks) = model.destination {
                    Label(reason, systemImage: "info.circle").font(.callout).padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading).background(AppSurface.raised)
                }
                ZStack { content.transition(.opacity) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.18), value: model.destination)
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: model.settings.paused)
            .background(AppSurface.window)
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .toolbar {
                if model.selectedTask == nil {
                    ToolbarItemGroup {
                        if case .project(_, .tasks) = model.destination {
                            Picker("Task layout", selection: $model.listMode) {
                                Image(systemName: "square.grid.2x2").tag(false).help("Show tasks as a board (⌘L)")
                                Image(systemName: "list.bullet").tag(true).help("Show tasks as a list (⌘L)")
                            }.pickerStyle(.segmented).frame(width: 78).help("Toggle List/Board (⌘L)")
                        }
                        if model.selectedProject != nil { OpenInMenu() }
                        Button { model.showNewTask = true } label: { Label("New Task", systemImage: "plus") }
                            .disabled(model.snapshot.projects.isEmpty).help("New Task (⌘N)")
                    }
                } else {
                    ToolbarItemGroup {
                        Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }.disabled(!model.canGoBack).help("Back (⌘[)")
                        Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }.disabled(!model.canGoForward).help("Forward (⌘])")
                        Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }.help("Toggle Inspector (⌥⌘I)")
                    }
                }
            }
        }
        .searchable(text: $model.search, prompt: "Search tasks")
        .searchFocused($searchFocused)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: columnVisibility)
        .onChange(of: model.findRequested) { searchFocused = true }
        .frame(minWidth: 1100, minHeight: 700)
        .sheet(isPresented: $model.showAddProject) { AddProjectSheet().presentationBackground(AppSurface.sheet) }
        .sheet(isPresented: $model.showNewTask) { NewTaskSheet().presentationBackground(AppSurface.sheet) }
        .sheet(item: $model.reviewSheet) { LifecycleSheet(sheet: $0).presentationBackground(AppSurface.sheet) }
        .sheet(item: $model.editingTask) { EditTaskSheet(task: $0).presentationBackground(AppSurface.sheet) }
        .alert("Unable to complete the action", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }.help("Dismiss this error")
        } message: { Text(model.error ?? "") }
        .task { await model.observe() }
    }
    @ViewBuilder private var content: some View {
        switch model.destination {
        case .needsYou, nil: NeedsYouView()
        case .task(let id):
            if let task = model.snapshot.tasks.first(where: { $0.id == id }) { TaskDetailView(task: task).id(task.id) }
            else { ContentUnavailableView("Task not found", systemImage: "questionmark.folder") }
        case .project(let id, let page):
            switch page {
            case .tasks: TaskBoard(projectID: id).id(id)
            case .backlog: TaskList(tasks: model.tasks(id).filter { $0.state == .backlog }, emptyTitle: "Backlog is empty", emptyDescription: "Tasks you add to Backlog wait until you move them to Queue.")
            case .chat: ContentUnavailableView("Project chat", systemImage: "bubble.left", description: Text("Project conversations are coming soon. Create a task with ⌘N."))
            case .instructions:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Project instructions").font(.title2)
                        Text(model.selectedProject?.instructions.isEmpty == false ? model.selectedProject!.instructions : "No project instructions yet.").textSelection(.enabled)
                        Text("The instructions editor is coming soon. Codex follows your repository’s AGENTS.md.").foregroundStyle(.secondary)
                    }.frame(maxWidth: 720, alignment: .leading).padding(32)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private var title: String {
        if let task = model.selectedTask { return task.title }
        if case .project(_, let page) = model.destination { return page.rawValue }
        return "Needs You"
    }
    private var subtitle: String {
        if let task = model.selectedTask { return model.projectName(task.projectId) }
        if case .project = model.destination { return model.selectedProject?.name ?? "" }
        return "\(model.needsCount) waiting across \(model.snapshot.projects.count) projects"
    }
}
