import SwiftUI

/// Supporting activity stays in the inspector; the parent conversation remains the main surface.
struct SubagentActivityView: View {
    let agents: [Subagent]
    @State private var expanded = false
    @State private var selectedID: UUID?
    private var orderedAgents: [Subagent] {
        agents.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
    }
    private var activeCount: Int { agents.filter(\.isActive).count }
    private var doneCount: Int { agents.filter { $0.status.lowercased() == "completed" }.count }
    private var summary: String {
        if activeCount + doneCount < agents.count {
            return activeCount > 0 ? "\(activeCount) active · \(agents.count) total" : "\(agents.count) \(agents.count == 1 ? "agent" : "agents")"
        }
        return [(activeCount > 0 ? "\(activeCount) active" : nil), (doneCount > 0 ? "\(doneCount) done" : nil)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        if !agents.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(orderedAgents) { agent in
                        Button { selectedID = agent.id } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: agent.activitySymbol)
                                    .foregroundStyle(agent.activityColor).frame(width: 16).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(agent.displayName).font(.callout.weight(.medium)).foregroundStyle(.primary)
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                    Text(agent.statusLabel).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Inspect \(agent.displayName)’s prompt and result")
                            .accessibilityLabel("\(agent.displayName), \(agent.statusLabel)")
                            .accessibilityHint("Shows this subagent’s prompt and result")
                            .accessibilityIdentifier("subagent-\(agent.id.uuidString)")
                    }
                }.padding(.top, 12)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Subagents")
                    Spacer(minLength: 0)
                    Text(summary).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .help("Show or hide subagent activity")
            .accessibilityIdentifier("subagent-activity")
            .sheet(isPresented: Binding(get: { selectedID != nil }, set: { if !$0 { selectedID = nil } })) {
                SubagentDetailView(agent: agents.first { $0.id == selectedID })
                    .presentationBackground(AppSurface.sheet)
            }
        }
    }
}

private struct SubagentDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let agent: Subagent?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let agent {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(agent.displayName).font(.title2.weight(.semibold)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    Label { Text(agent.statusLabel).foregroundStyle(.secondary) } icon: {
                        Image(systemName: agent.activitySymbol).foregroundStyle(agent.activityColor)
                    }.font(.callout).fixedSize()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if !agent.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Prompt").font(.headline).accessibilityAddTraits(.isHeader)
                                MarkdownBrief(agent.prompt)
                            }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Result").font(.headline).accessibilityAddTraits(.isHeader)
                            if !agent.result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                MarkdownBrief(agent.result)
                            } else {
                                Text(agent.isActive ? "Working…" : "No result was reported.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 6)
                }
            } else {
                ContentUnavailableView("Subagent unavailable", systemImage: "info.circle")
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .help("Close subagent details (Esc)").accessibilityIdentifier("close-subagent-details")
            }
        }.padding(24).frame(width: 600, height: 560)
            .accessibilityIdentifier("subagent-details")
    }
}

private extension Subagent {
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Subagent" : trimmed
    }
    var activitySymbol: String {
        switch status.lowercased() {
        case "completed": "checkmark.circle"
        case "errored", "error", "failed": "exclamationmark.circle"
        case "pendinginit", "running": "circle.dotted"
        case "shutdown", "interrupted", "closed": "stop.circle"
        default: "circle"
        }
    }
    var activityColor: Color {
        switch status.lowercased() {
        case "completed": .green
        case "errored", "error", "failed": .red
        case "pendinginit", "running": .accentColor
        default: .secondary
        }
    }
}
