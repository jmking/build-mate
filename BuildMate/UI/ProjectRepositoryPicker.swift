import AppKit
import SwiftUI

struct ProjectRepositoryPicker: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID
    @State private var adding = false
    @State private var removing: UUID?

    private var repositories: [ProjectRepository] { model.repositories(projectID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Repositories").font(.subheadline.weight(.medium))
                Spacer()
                Button(action: choose) { Label("Add repositories…", systemImage: "plus").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).disabled(adding || removing != nil)
                    .help("Choose repository folders to add to this project")
                    .accessibilityIdentifier("add-project-repositories")
            }
            if repositories.isEmpty {
                Text("Add a repository to start work.").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(repositories) { repository in
                HStack(spacing: 12) {
                    Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(repository.name).lineLimit(1).truncationMode(.middle)
                        Text((repository.repoPath as NSString).abbreviatingWithTildeInPath)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }.frame(maxWidth: .infinity, alignment: .leading).help(repository.repoPath)
                    Button {
                        removing = repository.id
                        model.perform {
                            defer { removing = nil }
                            try await model.core.removeRepository(repository.id)
                            await model.refresh()
                        }
                    } label: { Label("Remove \(repository.name)", systemImage: "minus.circle").labelStyle(.iconOnly) }
                        .buttonStyle(.borderless).disabled(adding || removing != nil)
                        .help("Remove this repository from the project; files on disk are kept. Finish or delete its unfinished tasks first")
                        .accessibilityIdentifier("remove-repository-\(repository.id)")
                }.padding(.vertical, 3)
            }
            if adding { ProgressView("Adding repositories…").controlSize(.small) }
        }.padding(.vertical, 4)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.prompt = "Add"; panel.message = "Choose folders containing Git repositories."
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        adding = true
        model.perform {
            defer { adding = false }
            for path in paths {
                try await model.core.addRepository(projectID: projectID, path: path)
                await model.refresh()
            }
        }
    }
}
