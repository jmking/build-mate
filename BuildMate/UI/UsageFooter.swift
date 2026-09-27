import SwiftUI

struct UsageFooter: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false
    private var window: UsageWindow? { model.usage.limitingWindow }
    private func tint(_ remaining: Int) -> Color { remaining < model.settings.usageHoldThreshold ? .red : remaining < 25 ? .orange : .accentColor }
    private var accessibilityStatus: String {
        var parts = [window.map { "\($0.remaining) percent remaining in the \($0.duration)" } ?? (model.usage.refreshing ? "Checking usage" : "Usage unavailable")]
        if let credits = model.usage.credits { parts.append(credits.label) }
        if model.usageHeld { parts.append("New work on hold") }
        if model.usage.error != nil { parts.append(window == nil ? "Couldn’t refresh usage" : "Last known usage; couldn’t refresh") }
        return parts.joined(separator: ". ")
    }
    var body: some View {
        Button { expanded.toggle() } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("Codex")
                    Spacer(minLength: 4)
                    if model.usage.canUseCredits, let credits = model.usage.credits {
                        Text(credits.label).monospacedDigit().foregroundStyle(.secondary)
                    } else if let window {
                        Text("\(window.remaining)% left").monospacedDigit().foregroundStyle(tint(window.remaining))
                    } else {
                        Text(model.usage.refreshing ? "Checking…" : "Usage unavailable").foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                if model.usageHeld { Text("New work on hold").foregroundStyle(.orange) }
                if (window != nil || model.usage.credits != nil) && model.usage.error != nil { Text("Last known usage").foregroundStyle(.secondary) }
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).help("View account usage and reset times")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Codex usage")
            .accessibilityValue(accessibilityStatus)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("usage-details")
            .popover(isPresented: $expanded, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Codex usage").font(.headline)
                    Text("Shared across your Codex account, including other apps and sessions.").font(.caption).foregroundStyle(.secondary)
                    if let credits = model.usage.credits {
                        Text(credits.label).font(.callout).monospacedDigit()
                    }
                    if model.usage.windows.isEmpty {
                        Text("No usage windows reported. Check that Codex is installed and signed in.").font(.callout)
                    }
                    ForEach(model.usage.windows) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(item.name) · \(item.duration)")
                                Spacer()
                                Text("\(item.remaining)% left").monospacedDigit()
                            }.font(.callout)
                            ProgressView(value: Double(item.remaining), total: 100).tint(tint(item.remaining))
                            Text(item.resetsAt.map { "Resets " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Reset time unavailable")
                                .font(.caption).foregroundStyle(.secondary)
                        }.accessibilityElement(children: .combine)
                    }
                    if let error = model.usage.error {
                        Text("Couldn’t refresh usage. " + error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let updated = model.usage.updatedAt {
                        Text("Last checked \(updated.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                    if model.usageHeld {
                        Text("New tasks on hold").font(.headline)
                        Button("Resume Anyway") { model.perform { await model.core.resumeDespiteUsage() } }
                            .help("Allow new work until usage recovers or Build Mate restarts")
                    } else if model.usage.canUseCredits {
                        Text("Available credits let work continue when included usage runs out.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("New work pauses below \(model.settings.usageHoldThreshold)% included usage when no usable credits are reported. Running agents continue.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button("Refresh") { model.perform { await model.core.refreshUsage() } }.disabled(model.usage.refreshing)
                            .help("Check your latest Codex usage and reset times")
                    }
                }.padding(20).frame(width: 350)
                    .presentationBackground(AppSurface.sheet)
            }
    }
}
