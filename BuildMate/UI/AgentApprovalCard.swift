import SwiftUI

struct AgentApprovalCard: View {
    @Environment(AppModel.self) private var model
    let message: Message
    @State private var submitting = false
    private var status: String { message.payload["status"].string ?? "expired" }
    private var summary: String {
        switch status {
        case "allowed": "Allowed"
        case "denied": "Denied"
        case "resolved": "Resolved by Codex"
        default: "No longer active — ask the agent to retry if needed"
        }
    }
    var body: some View {
        if message.isPendingAgentApproval {
            VStack(alignment: .leading, spacing: 12) {
                Label(message.body, systemImage: "lock.shield").font(.headline).accessibilityAddTraits(.isHeader)
                if let agent = message.payload["agent"].string { Text("Requested by \(agent)").font(.caption).foregroundStyle(.secondary) }
                if let reason = message.payload["reason"].string, !reason.isEmpty { Text(reason).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                if let details = message.payload["details"].string, !details.isEmpty {
                    ScrollView([.horizontal, .vertical]) {
                        Text(details).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }.frame(maxHeight: 220).fixedSize(horizontal: false, vertical: true)
                        .background(AppSurface.recessed, in: RoundedRectangle(cornerRadius: 8))
                }
                if let raw = message.payload["url"].string, let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? "") {
                    Link("Open \(url.host ?? "request") in browser", destination: url).help("Open the connected tool’s request in your browser")
                }
                HStack(spacing: 10) {
                    Spacer()
                    Button("Deny") { respond(false) }.buttonStyle(.bordered).help("Decline this request and let the agent find another approach")
                    Button(submitting ? "Sending…" : (message.payload["allowLabel"].string ?? "Allow once")) { respond(true) }
                        .buttonStyle(.borderedProminent).help("Approve only the action or access shown above")
                }.disabled(submitting)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(AppSurface.raised, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.purple.opacity(0.25)))
                .accessibilityElement(children: .contain).accessibilityIdentifier("agent-approval-\(message.id)")
        } else {
            Label("\(message.body) · \(summary)", systemImage: status == "allowed" ? "checkmark.shield" : "lock.shield")
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
    private func respond(_ allow: Bool) {
        submitting = true
        model.perform {
            defer { submitting = false }
            try await model.core.resolveAgentApproval(message.id, allow: allow)
        }
    }
}
