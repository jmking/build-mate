import Foundation
import GRDB

struct CodexModel: Identifiable, Sendable {
    var id: String
    var name: String
    var isDefault: Bool
    var efforts: [String]
    var defaultEffort: String?

    static func resolve(_ models: [Self], model: String?, effort: String?, inheritedModel: String? = nil, inheritedEffort: String? = nil) throws -> (model: String, effort: String?) {
        let model = model ?? inheritedModel
        let choice = model.flatMap { id in models.first { $0.id == id } } ?? (model == nil ? models.first { $0.isDefault } ?? models.first : nil)
        guard let choice else { throw CoreError.invalid("\(model ?? "The selected model") is unavailable in Codex. Choose another model.") }
        let effort = effort ?? inheritedEffort ?? choice.defaultEffort
        if let effort, !choice.efforts.contains(effort) { throw CoreError.invalid("\(choice.name) does not support \(effort) effort. Choose a supported effort level.") }
        return (choice.id, effort)
    }
}

extension CodexClient {
    func models() async throws -> [CodexModel] {
        var result: [CodexModel] = []
        var cursor: String?
        var cursors: Set<String> = []
        repeat {
            var params: [String: JSON] = ["limit": .number(100), "includeHidden": .bool(false)]
            if let cursor { params["cursor"] = .string(cursor) }
            let page = try await request("model/list", params)
            for value in page["data"].array {
                guard value["hidden"].bool != true, let id = value["model"].string ?? value["id"].string,
                      !result.contains(where: { $0.id == id }) else { continue }
                result.append(CodexModel(id: id, name: value["displayName"].string ?? id, isDefault: value["isDefault"].bool == true,
                                         efforts: value["supportedReasoningEfforts"].array.compactMap { $0["reasoningEffort"].string },
                                         defaultEffort: value["defaultReasoningEffort"].string))
            }
            cursor = page["nextCursor"].string
            if let cursor, !cursors.insert(cursor).inserted { throw CoreError.invalid("Codex repeated a model catalogue page. Try refreshing.") }
        } while cursor != nil
        guard !result.isEmpty else { throw CoreError.invalid("Codex did not report any available models.") }
        return result
    }
}

extension Orchestrator {
    func models(refresh: Bool = false) async throws -> [CodexModel] {
        if !refresh && !availableModels.isEmpty { return availableModels }
        let client = CodexClient()
        do {
            try await client.start(runner: runner, cwd: store.root.path, timeout: 5)
            let models = try await client.models()
            await client.stop()
            availableModels = models
            return models
        } catch { await client.stop(); throw error }
    }

    /// Update only the preference; never interrupt, change lifecycle state or replace the conversation.
    func setModel(ownerID: UUID, projectChat: Bool, model: String, effort: String?) throws {
        let selection = try CodexModel.resolve(availableModels, model: model, effort: effort)
        if projectChat { _ = try store.get(Project.self, ownerID) }
        else { _ = try store.get(WorkTask.self, ownerID) }
        try store.save(AgentConfiguration(id: ownerID, model: selection.model, effort: selection.effort))
    }
    func modelSelection(ownerID: UUID, defaultModel: String?, defaultEffort: String?, inheritedModel: String? = nil, inheritedEffort: String? = nil) throws -> (model: String, effort: String?) {
        let saved = try store.db.read { try AgentConfiguration.fetchOne($0, key: ownerID) }
        return try CodexModel.resolve(availableModels, model: saved?.model ?? defaultModel, effort: saved == nil ? defaultEffort : saved?.effort, inheritedModel: inheritedModel, inheritedEffort: inheritedEffort)
    }
}
