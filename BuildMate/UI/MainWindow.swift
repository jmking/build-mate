import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @Environment(\.openSettings) private var openSettings
    @State private var showErrorDetails = false
    @State private var renamingProject: Project?
    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $model.destination) {
                Label("Needs You", systemImage: "tray").badge(model.needsCount).tag(Destination.needsYou)
                Section {
                    ForEach(model.snapshot.projects) { project in
                        DisclosureGroup(isExpanded: Binding(get: { model.isProjectExpanded(project.id) }, set: { model.setProjectExpanded(project.id, expanded: $0) })) {
                            ForEach([ProjectPage.chat, .tasks]) { page in
                                Label(page.rawValue, systemImage: page.symbol)
                                    .badge(page == .tasks ? model.snapshot.tasks.filter { $0.projectId == project.id && model.needsYou($0) }.count : page == .chat ? model.chatQuestionCount(project.id) : 0)
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
                        .contextMenu { projectActions(project) }
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
            .navigationSplitViewColumnWidth(min: 210, ideal: 232, max: 300)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.workers == 0 ? "No agents working" : "\(model.workers) working")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .accessibilityLabel("\(model.workers) of \(model.settings.agentsAtOnce) agents working")
                        Spacer(minLength: 8)
                        Button(model.settings.paused ? "Resume All" : "Pause All", systemImage: model.settings.paused ? "play.fill" : "pause.fill") {
                            model.perform { try model.pauseAll() }
                        }.buttonStyle(.borderless).font(.caption)
                            .help(model.settings.paused ? "Resume eligible work across all projects (⌥⌘P)" : "Pause all work across all projects (⌥⌘P)")
                    }
                    UsageFooter()
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
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
                if let project = contextProject, project.paused, !model.settings.paused {
                    HStack {
                        Label("Project paused", systemImage: "pause.circle")
                        Spacer()
                        Button("Resume Project") { model.perform { try model.pauseProject(project) } }
                            .help("Resume eligible work in \(project.name)")
                    }.padding(12).background(AppSurface.raised)
                }
                if let error = model.schedulerError {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Background action needs attention", systemImage: "exclamationmark.triangle")
                            Spacer()
                            Button("Dismiss", systemImage: "xmark") { model.dismissSchedulerError() }
                                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Dismiss this background action error")
                        }
                        DisclosureGroup("Details", isExpanded: $showErrorDetails) {
                            ScrollView {
                                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 120)
                        }.font(.caption)
                    }.padding(12).background(AppSurface.raised)
                        .onChange(of: error) { showErrorDetails = false }
                }
                if let project = model.selectedProject, model.repositories(project.id).allSatisfy({ $0.host == .bitbucket }), let reason = project.runBlockReason,
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
                ToolbarItemGroup(placement: .navigation) {
                    Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                        .disabled(!model.canGoBack).help("Back (⌘[)")
                    Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                        .disabled(!model.canGoForward).help("Forward (⌘])")
                }
                if case .project(_, .tasks) = model.destination {
                    ToolbarItem(placement: .primaryAction) {
                        Picker("Task layout", selection: $model.listMode) {
                            Image(systemName: "square.grid.2x2").tag(false).help("Show tasks as a board (⌘L)")
                            Image(systemName: "list.bullet").tag(true).help("Show tasks as a list (⌘L)")
                        }.pickerStyle(.segmented).frame(width: 78).help("Toggle List/Board (⌘L)")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { model.showNewTask = true } label: { Label("New Task", systemImage: "plus") }
                            .help("New Task (⌘N)")
                    }
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
                if let project = contextProject {
                    if model.selectedTask == nil {
                        ToolbarItem(placement: .primaryAction) {
                            Menu("Project") { projectActions(project) }.help("Project actions and instructions")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        OpenInMenu().disabled(model.selectedTask != nil && model.selectedTask?.worktreePath == nil)
                    }
                }
                if showsInspector {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    ToolbarItem(placement: .primaryAction) {
                        Button { model.showInspector.toggle() } label: { Label("Details", systemImage: "info.circle") }
                            .help("Show or hide details (⌥⌘I)")
                    }
                }
            }
            .modifier(TaskCollectionSearch())
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: columnVisibility)
        .onChange(of: model.toggleSidebar) { columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly }
        .frame(minWidth: 900, minHeight: 620)
        .sheet(item: $renamingProject) { RenameProjectSheet(project: $0).presentationBackground(AppSurface.sheet) }
        .sheet(isPresented: $model.showAddProject) { AddProjectSheet().presentationBackground(AppSurface.sheet) }
        .sheet(isPresented: $model.showNewTask) { NewTaskSheet().presentationBackground(AppSurface.sheet) }
        .sheet(item: $model.reviewSheet) { LifecycleSheet(sheet: $0).presentationBackground(AppSurface.sheet) }
        .sheet(item: $model.editingTask) { EditTaskSheet(task: $0).presentationBackground(AppSurface.sheet) }
        .alert("Delete task?", isPresented: Binding(get: { model.taskToDelete != nil }, set: { if !$0 { model.taskToDelete = nil } }), presenting: model.taskToDelete) { task in
            Button("Delete Task", role: .destructive) { model.perform { try await model.deleteTask(task) } }
                .help("Stop the agent and permanently delete this task")
            Button("Cancel", role: .cancel) {}.help("Keep this task")
        } message: { task in
            Text("Delete ‘\(task.title)’? Its agent and preview will stop. Its chat history, attachments, proof and worktree—including uncommitted changes—will be deleted. Dependent tasks will be paused. Git branches and existing pull requests will remain. This cannot be undone.")
        }
        .alert("Unable to complete the action", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }.help("Dismiss this error")
        } message: { Text(model.error ?? "") }

    }
    private var contextProject: Project? {
        switch model.destination {
        case .project, .task: model.selectedProject
        default: nil
        }
    }
    private var showsInspector: Bool {
        switch model.destination {
        case .task, .project(_, .chat): true
        default: false
        }
    }
    @ViewBuilder private func projectActions(_ project: Project) -> some View {
        Button("Rename Project…", systemImage: "pencil") { renamingProject = project }
            .help("Change the name shown for this project")

        Button(project.paused ? "Resume Project" : "Pause Project", systemImage: project.paused ? "play" : "pause") {
            model.perform { try model.pauseProject(project) }
        }.help(project.paused ? "Resume work in \(project.name)" : "Pause work in \(project.name)")
        Divider()
        Button("Instructions…", systemImage: "doc.text") { model.destination = .project(project.id, .instructions) }
            .help("Edit instructions for \(project.name) (⌘4)")
        Button("Project Settings…", systemImage: "gearshape") {
            if model.selectedProject?.id != project.id { model.destination = .project(project.id, .chat) }
            model.settingsProjectID = project.id
            model.settingsTab = "general"
            openSettings()
        }.help("Edit settings for \(project.name)")
        Divider()
        Button("Open Project in Finder", systemImage: "folder") {
            model.perform {
                guard let repository = model.repositories(project.id).first, NSWorkspace.shared.open(URL(fileURLWithPath: repository.repoPath)) else {
                    throw CoreError.invalid("This project folder could not be opened.")
                }
            }
        }.disabled(model.repositories(project.id).isEmpty).help("Open this project’s checkout in Finder")
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
            case .chat: ProjectChatView(projectID: id).id(id)
            case .instructions:
                InstructionsView(projectID: id).id(id)
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

private struct TaskCollectionSearch: ViewModifier {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        @Bindable var model = model
        if model.canSearch {
            content.searchable(text: $model.search, prompt: "Search tasks")
                .searchFocused($focused)
                .onChange(of: model.findRequested) { focused = true }
        } else {
            content
        }
    }
}
