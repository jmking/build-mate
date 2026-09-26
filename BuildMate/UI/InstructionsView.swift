import SwiftUI
import AppKit

struct InstructionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    var projectID: UUID?
    @State private var text = ""
    @State private var loaded = false
    @State private var pending: Task<Void, Never>?
    @State private var status = "Saved"
    private var project: Project? { model.snapshot.projects.first { $0.id == projectID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(projectID == nil ? "Instructions for all projects" : "Project instructions").font(.title2.weight(.semibold))
                Spacer()
                Text(status).font(.caption).foregroundStyle(.secondary).accessibilityLabel("Instructions: \(status)")
            }
            TextEditor(text: $text).font(.system(size: 14)).scrollContentBackground(.hidden)
                .padding(12).background(AppSurface.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
                .accessibilityLabel(projectID == nil ? "Global instructions" : "Project instructions")
                .help("Markdown instructions, saved automatically; changes apply on the next agent turn")
            Text("Applies from the next turn. Project instructions take precedence over instructions for all projects.")
                .font(.caption).foregroundStyle(.secondary)
            if let project {
                Text("Agents also follow").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let content = try? String(contentsOfFile: project.repoPath + "/AGENTS.md", encoding: .utf8) {
                    HStack {
                        Label("AGENTS.md · \(content.components(separatedBy: .newlines).count) lines", systemImage: "doc.text")
                        Spacer()
                        Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: project.repoPath + "/AGENTS.md")) }
                            .help("Open the repository’s AGENTS.md")
                    }
                }
                HStack {
                    Label("Instructions for all projects", systemImage: "sun.max")
                    Spacer()
                    Button("Edit…") { model.settingsTab = "instructions"; openSettings() }
                        .help("Edit global instructions in Settings")
                }
            }
        }.padding(24).frame(maxWidth: 850, maxHeight: .infinity).frame(maxWidth: .infinity)
            .onAppear { text = project?.instructions ?? model.settings.instructions; loaded = true }
            .onChange(of: text) {
                guard loaded else { return }
                pending?.cancel(); status = "Saving…"
                pending = Task { try? await Task.sleep(for: .seconds(1)); guard !Task.isCancelled else { return }; save() }
            }
            .onDisappear { pending?.cancel(); if loaded { save() } }
    }
    private func save() {
        do { try model.store.saveInstructions(text, projectID: projectID); status = "Saved" }
        catch { status = "Couldn’t save"; model.error = error.localizedDescription }
    }
}
