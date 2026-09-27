import SwiftUI

struct ModelPicker: View {
    @Environment(AppModel.self) private var app
    let ownerID: UUID
    var projectChat = false
    @State private var expanded = false
    @State private var models: [AgentModel] = []
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    private var project: Project? { app.snapshot.projects.first { $0.id == (projectChat ? ownerID : task?.projectId) } }
    private var task: WorkTask? { app.snapshot.tasks.first { $0.id == ownerID } }
    private var configuration: AgentConfiguration? { app.snapshot.agentConfigurations.first { $0.id == ownerID } }
    private var effectiveConfiguration: AgentConfiguration? {
        configuration?.recommended == true && !projectChat && project?.settings.model != nil ? nil : configuration
    }
    private var selectedModel: String? {
        effectiveConfiguration?.model ?? (projectChat ? "gpt-6-astra" : project?.settings.model) ?? session?.activeModel
    }
    private var selectedEffort: String? {
        if configuration?.recommended == true, !projectChat, let effort = project?.settings.effort { return effort }
        if let effort = effectiveConfiguration?.effort { return effort }
        if let effort = projectChat ? "high" : project?.settings.effort { return effort }
        return session?.activeModel == selectedModel ? session?.activeEffort : nil
    }
    private var choice: AgentModel? {
        if let selectedModel { return models.first { $0.id == selectedModel } }
        return nil
    }
    private var name: String { choice?.name ?? (selectedModel == "gpt-6-astra" ? "Astra" : selectedModel ?? "Codex default") }
    private var session: Session? { app.snapshot.sessions.first { $0.ownerId == ownerID && $0.ownerType == (projectChat ? "project" : "task") } }
    private var pending: Bool {
        guard session?.currentTurn != nil else { return false }
        return session?.activeModel != (selectedModel ?? choice?.id) || session?.activeEffort != selectedEffort
    }
    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 5) {
                Text(name)
                if let selectedEffort { Text("· \(effortName(selectedEffort))").foregroundStyle(.secondary) }
                Image(systemName: "chevron.down").font(.caption2)
            }.font(.caption).lineLimit(1)
        }.buttonStyle(.borderless).controlSize(.small).foregroundStyle(.secondary)
            .help("Choose the model and reasoning effort; changes apply on the next turn")
            .accessibilityLabel("Model and effort: \(name), \(selectedEffort.map(effortName) ?? "model default")")
            .accessibilityIdentifier("model-effort-picker")
            .popover(isPresented: $expanded) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Model and effort").font(.headline)
                        Spacer()
                        Button("Refresh Models", systemImage: "arrow.clockwise") { load(refresh: true) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(loading || saving)
                            .help("Refresh available models and effort levels")
                    }
                    Picker("Model", selection: Binding(get: { selectedModel ?? choice?.id ?? "" }, set: chooseModel)) {
                        if selectedModel == nil { Text("Codex default").tag("") }
                        if let selectedModel, !models.contains(where: { $0.id == selectedModel }) {
                            Text("\(name) · unavailable").tag(selectedModel)
                        }
                        ForEach(models) { Text($0.name).tag($0.id) }
                    }.disabled(loading || saving).help("Choose the model for this conversation")
                    if let choice, !choice.efforts.isEmpty {
                        Picker("Effort", selection: Binding(get: { selectedEffort ?? "" }, set: { save(model: choice.id, effort: $0) })) {
                            if selectedEffort == nil { Text("Codex default").tag("") }
                            ForEach(choice.efforts, id: \.self) { Text(effortName($0)).tag($0) }
                        }.disabled(saving).help("Choose how much reasoning effort this model uses")
                    }
                    if selectedModel != nil && choice == nil && !loading {
                        Text("This model isn’t available in the installed Codex. Choose an available model or update Codex, then refresh.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let config = configuration, config.recommended, let reason = config.rationale {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                    if pending { Text("Your selection applies to the next response.").font(.caption).foregroundStyle(.secondary) }
                    if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    if loading || saving { ProgressView().controlSize(.small).accessibilityLabel(loading ? "Loading models" : "Saving model") }
                }.padding(20).frame(width: 340).foregroundStyle(.primary).presentationBackground(AppSurface.sheet)
            }
            .onAppear { load() }
    }
    private func effortName(_ value: String) -> String { value == "xhigh" ? "Extra High" : value.capitalized }
    private func chooseModel(_ id: String) {
        guard let choice = models.first(where: { $0.id == id }) else { return }
        let effort = selectedEffort.flatMap { choice.efforts.contains($0) ? $0 : nil } ?? choice.defaultEffort
        save(model: id, effort: effort)
    }
    private func save(model: String, effort: String?) {
        saving = true; error = nil
        Task {
            defer { saving = false }
            do { try await app.core.setModel(ownerID: ownerID, projectChat: projectChat, model: model, effort: effort); await app.refresh() }
            catch { self.error = error.localizedDescription }
        }
    }
    private func load(refresh: Bool = false) {
        guard !loading else { return }
        loading = true; error = nil
        Task {
            defer { loading = false }
            do { models = try await app.core.models(refresh: refresh) }
            catch { self.error = error.localizedDescription }
        }
    }
}
