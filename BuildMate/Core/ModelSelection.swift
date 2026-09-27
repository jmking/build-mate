import Foundation
import GRDB

struct AgentModel: Identifiable, Sendable {
    var id: String
    var name: String
    var isDefault: Bool
    var efforts: [String]
    var defaultEffort: String?

    static func resolve(_ models: [Self], model: String?, effort: String?, inheritedModel: String? = nil, inheritedEffort: String? = nil) throws -> (model: String, effort: String?) {
        let model = model ?? inheritedModel
        let choice = model.flatMap { id in models.first { $0.id == id } } ?? (model == nil ? models.first { $0.isDefault } ?? models.first : nil)
        guard let choice else { throw CoreError.invalid("\(model ?? "The selected model") is unavailable from the selected agent provider. Choose another model.") }
        let effort = effort ?? inheritedEffort ?? choice.defaultEffort
        if let effort, !choice.efforts.contains(effort) { throw CoreError.invalid("\(choice.name) does not support \(effort) effort. Choose a supported effort level.") }
        return (choice.id, effort)
    }
}

extension Orchestrator {
    func configuredProvider(for ownerID: UUID) throws -> AgentProvider {
        try store.db.read { try AgentConfiguration.fetchOne($0, key: ownerID)?.provider ?? .codex }
    }

    func models(refresh: Bool = false, provider: AgentProvider = .codex) async throws -> [AgentModel] {
        if !refresh, let models = modelCatalogues[provider], !models.isEmpty { return models }
        let client = provider.makeRunner()
        do {
            try await client.start(runner: runner, cwd: store.root.path, timeout: 5)
            let models = try await client.models()
            await client.stop()
            modelCatalogues[provider] = models
            return models
        } catch { await client.stop(); throw error }
    }

    /// Update only the preference; never interrupt, change lifecycle state or replace the conversation.
    func setModel(ownerID: UUID, projectChat: Bool, model: String, effort: String?) throws {
        let provider = try configuredProvider(for: ownerID)
        let selection = try AgentModel.resolve(modelCatalogues[provider] ?? [], model: model, effort: effort)
        if projectChat { _ = try store.get(Project.self, ownerID) }
        else { _ = try store.get(WorkTask.self, ownerID) }
        try store.save(AgentConfiguration(id: ownerID, model: selection.model, effort: selection.effort, provider: provider))
    }
    func modelSelection(ownerID: UUID, defaultModel: String?, defaultEffort: String?, inheritedModel: String? = nil, inheritedEffort: String? = nil) throws -> (model: String, effort: String?) {
        let saved = try store.db.read { try AgentConfiguration.fetchOne($0, key: ownerID) }
        let catalogue = modelCatalogues[saved?.provider ?? .codex] ?? []
        if saved?.recommended == true, defaultModel != nil || defaultEffort != nil {
            return try AgentModel.resolve(catalogue, model: defaultModel ?? saved?.model, effort: defaultEffort ?? (defaultModel == nil ? saved?.effort : nil), inheritedEffort: inheritedEffort)
        }
        return try AgentModel.resolve(catalogue, model: saved?.model ?? defaultModel, effort: saved == nil ? defaultEffort : saved?.effort, inheritedModel: inheritedModel, inheritedEffort: inheritedEffort)
    }
}
