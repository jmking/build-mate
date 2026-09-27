import Foundation

extension Orchestrator {
    func usageHeld(provider: AgentProvider = .codex) -> Bool {
        let usage = accountUsage[provider] ?? UsageSnapshot()
        guard !usageOverrides.contains(provider), !usage.canUseCredits, let window = usage.limitingWindow else { return false }
        return window.remaining < ((try? store.settings().usageHoldThreshold) ?? 15)
    }

    func usageBlocksDispatch(provider: AgentProvider) -> Bool {
        let usage = accountUsage[provider] ?? UsageSnapshot()
        return usageHeld(provider: provider) || (usage.refreshing && usage.updatedAt == nil)
    }

    func resumeDespiteUsage(provider: AgentProvider = .codex) async {
        usageOverrides.insert(provider); await tick()
    }

    func receiveUsage(_ update: AgentUsageUpdate, provider: AgentProvider) {
        var snapshot = accountUsage[provider] ?? UsageSnapshot()
        snapshot.apply(update)
        accountUsage[provider] = snapshot
        if let window = snapshot.limitingWindow, window.remaining >= ((try? store.settings().usageHoldThreshold) ?? 15) {
            usageOverrides.remove(provider)
        }
    }

    func refreshUsage(provider: AgentProvider = .codex) async {
        guard accountUsage[provider]?.refreshing != true, !shuttingDown else { return }
        accountUsage[provider, default: UsageSnapshot()].refreshing = true
        usageRefreshDates[provider] = Date()
        let client = provider.makeRunner(); usageClients[provider] = client
        defer { accountUsage[provider]?.refreshing = false; usageClients[provider] = nil }
        do {
            // Metadata only: no agent session, turn or model request.
            try await client.start(runner: runner, cwd: store.root.path, timeout: 5)
            receiveUsage(try await client.readUsage(), provider: provider)
        } catch { accountUsage[provider]?.error = runner.redacted(error.localizedDescription) }
        await client.stop()
    }
}
