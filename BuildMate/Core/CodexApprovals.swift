import Foundation

extension CodexClient {
    /// Translate native approvals here; the workflow never constructs Codex permission payloads.
    func permissionRequest(_ event: JSON) -> AgentPermissionRequest? {
        let id = event["id"], params = event["params"]
        guard id != .null, let method = event["method"].string else { return nil }
        let item = approvalItems[(params["threadId"].string ?? "") + ":" + (params["itemId"].string ?? "")] ?? .null
        var title: String, details: String, label = "Allow once", url: String?
        let allowed: JSON, denied: JSON
        switch method {
        case "item/commandExecution/requestApproval":
            let command = params["command"].string ?? item["command"].string
            let host = params["networkApprovalContext"]["host"].string
            guard command != nil || host != nil else { return nil }
            // Some servers restrict the offered decisions. Never substitute a persistent rule.
            if case .array(let decisions) = params["availableDecisions"], !decisions.contains(.string("accept")) { return nil }
            title = host == nil ? (params["kind"].string == "writeStdin" ? "Allow terminal input?" : "Allow command?") : "Allow network access?"
            details = host.map { "Host: \($0)\nProtocol: \(params["networkApprovalContext"]["protocol"].string ?? "unspecified")" } ?? command!
            if let cwd = params["cwd"].string ?? item["cwd"].string { details += "\n\nWorking directory: " + cwd }
            if params["additionalPermissions"] != .null {
                guard let permissions = Self.permissionDetails(params["additionalPermissions"]) else { return nil }
                details += "\n\n" + permissions
            }
            allowed = .object(["decision": .string("accept")]); denied = .object(["decision": .string("decline")])
        case "item/fileChange/requestApproval":
            let changes = item["changes"].array
            guard !changes.isEmpty else { return nil } // The user must be able to inspect the proposed edit.
            title = "Allow file changes?"
            details = changes.map { change in
                [change["path"].string, change["diff"].string].compactMap { $0 }.joined(separator: "\n")
            }.joined(separator: "\n\n")
            guard !details.isEmpty else { return nil }
            if let root = params["grantRoot"].string { details += "\n\nRequested write root: " + root }
            allowed = .object(["decision": .string("accept")]); denied = .object(["decision": .string("decline")])
        case "item/permissions/requestApproval":
            guard let description = Self.permissionDetails(params["permissions"]), !description.isEmpty else { return nil }
            title = "Allow additional access?"; details = description; label = "Allow for this turn"
            if let cwd = params["cwd"].string { details += "\n\nWorking directory: " + cwd }
            allowed = .object(["permissions": params["permissions"], "scope": .string("turn")])
            denied = .object(["permissions": .object([:]), "scope": .string("turn")])
        case "mcpServer/elicitation/request":
            title = "Allow connected tool?"
            details = "Tool server: " + (params["serverName"].string ?? "Unknown")
            if params["mode"].string == "url", let link = params["url"].string,
               let parsed = URL(string: link), ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil {
                url = link; label = "Continue"; details += "\nComplete the request in your browser, then continue."
                allowed = .object(["action": .string("accept"), "content": .null])
            } else if params["mode"].string == "form", params["requestedSchema"]["type"].string == "object",
                      params["requestedSchema"]["properties"] == .object([:]), params["requestedSchema"]["required"].array.isEmpty {
                allowed = .object(["action": .string("accept"), "content": .object([:])])
            } else { return nil } // Structured forms and secret entry need a dedicated, validated input UI.
            denied = .object(["action": .string("decline"), "content": .null])
        default: return nil
        }
        return AgentPermissionRequest(id: id.text, title: title, reason: params["reason"].string ?? params["message"].string ?? "",
                                      details: details, allowLabel: label, url: url, allowsMissingTurn: method == "mcpServer/elicitation/request") { accept in
            try await self.respondApproval(id, result: accept ? allowed : denied)
        }
    }

    private static func permissionDetails(_ value: JSON) -> String? {
        guard case .object(let profile) = value, Set(profile.keys).isSubset(of: ["network", "fileSystem"]) else { return nil }
        var lines: [String] = []
        if value["network"] != .null {
            guard case .object(let network) = value["network"], Set(network.keys).isSubset(of: ["enabled"]) else { return nil }
            if value["network"]["enabled"].bool == true { lines.append("Network access") }
        }
        if value["fileSystem"] != .null {
            guard case .object(let files) = value["fileSystem"], Set(files.keys).isSubset(of: ["read", "write", "entries", "globScanMaxDepth"]) else { return nil }
            for key in ["read", "write"] {
                for path in value["fileSystem"][key].array {
                    guard let path = path.string else { return nil }
                    lines.append("\(key.capitalized): \(path)")
                }
            }
            for entry in value["fileSystem"]["entries"].array {
                guard let access = entry["access"].string else { return nil }
                let path = entry["path"]
                let description: String
                switch path["type"].string {
                case "path": guard let text = path["path"].string else { return nil }; description = text
                case "glob_pattern": guard let text = path["pattern"].string else { return nil }; description = "pattern " + text
                case "special":
                    guard let kind = path["value"]["kind"].string, kind != "unknown" else { return nil }
                    description = kind.replacingOccurrences(of: "_", with: " ") + (path["value"]["subpath"].string.map { "/" + $0 } ?? "")
                default: return nil
                }
                lines.append("\(access.capitalized): \(description)")
            }
            if let depth = value["fileSystem"]["globScanMaxDepth"].int { lines.append("Maximum folder scan depth: \(depth)") }
        }
        return lines.joined(separator: "\n")
    }
}
