import SwiftUI
import AVKit

struct OpenInMenu: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Menu {
            ForEach(model.installedEditors) { app in
                Button { model.openLocation(appID: app.id) } label: { appLabel(app) }.help("Open code in \(app.name)")
            }
            Divider()
            Button("Terminal", systemImage: "terminal") { model.openLocation(appID: "com.apple.Terminal") }.help("Open a Terminal at this location (⌃⌘T)")
            ForEach([("iTerm", "com.googlecode.iterm2"), ("Ghostty", "com.mitchellh.ghostty")], id: \.1) { name, id in
                if NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
                    Button(name) { model.openLocation(appID: id) }.help("Open this location in \(name)")
                }
            }
            Button("Open in Finder", systemImage: "folder") { model.openLocation() }.help("Open this folder in Finder (⌥⌘R)")
            Divider()
            Menu("Default Editor") {
                ForEach(model.installedEditors) { app in
                    Button { model.perform { try model.setEditor(app.id) } } label: {
                        Label(app.name, systemImage: model.defaultEditor?.id == app.id ? "checkmark" : "app")
                    }.help("Use \(app.name) as this project’s default editor")
                }
            }.help("Choose the editor used by Open Code (⌘O)")
        } label: {
            if let app = model.defaultEditor { appLabel(app, prefix: "Open in ") }
            else { Label("Open in…", systemImage: "arrow.up.forward.app") }
        } primaryAction: {
            model.openLocation(appID: model.defaultEditor?.id)
        }
        .help("Open this location in your default editor (⌘O)")
    }
    private func appLabel(_ app: InstalledApp, prefix: String = "") -> some View {
        Label { Text(prefix + app.name) } icon: { Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 16, height: 16) }
    }
}

struct RecordingPlayer: View {
    let path: String
    @State private var player: AVPlayer?
    var body: some View {
        Group {
            if FileManager.default.fileExists(atPath: path) {
                VideoPlayer(player: player).accessibilityLabel("Proof recording")
            } else { ContentUnavailableView("Recording unavailable", systemImage: "video.slash") }
        }
        .task(id: path) { player?.pause(); player = AVPlayer(url: URL(fileURLWithPath: path)) }
        .onDisappear { player?.pause(); player = nil }
    }
}

struct ReviewEvidence: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let task: WorkTask
    let proof: Proof
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Proof of work").font(.headline).accessibilityAddTraits(.isHeader)
            if !proof.complete || proof.commitSHA == nil {
                Label("Fresh proof required", systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                Text("Send this task back for fresh proof before opening a pull request.").font(.caption).foregroundStyle(.secondary)
            }
            Text(proof.summary).textSelection(.enabled)
            if let rationale = proof.rationale { Text(rationale).font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(proof.checks.enumerated()), id: \.offset) { _, check in
                Button { model.reviewSheet = .log(check.logPath) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: check.status == "passed" ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(check.status == "passed" ? Color.green : .red)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(check.name).foregroundStyle(.primary)
                            Text("\(check.status.capitalized) · \(check.durationSec, specifier: "%.1f")s").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help("Read output for \(check.name)")
            }
            if let path = proof.recordingPath {
                Divider()
                HStack {
                    Text("Recording").font(.headline)
                    Spacer()
                    Button("Expand Recording", systemImage: "arrow.up.left.and.arrow.down.right") { openWindow(id: "recording", value: path) }
                        .labelStyle(.iconOnly).help("Open the recording in a larger player window")
                }
                RecordingPlayer(path: path).aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                if let seconds = proof.recordingDuration { Text(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))).font(.caption).foregroundStyle(.secondary) }
            } else {
                Text(proof.recordingRequired ? "Required recording is missing" : "Recording not required for this task").font(.caption).foregroundStyle(.secondary)
            }
            if !proof.screenshots.isEmpty {
                Divider()
                Text("Before and after").font(.headline)
                ForEach(Array(proof.screenshots.enumerated()), id: \.offset) { index, path in
                    if let image = NSImage(contentsOfFile: path) {
                        Button { model.reviewSheet = .image(path) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(index == 0 ? "Before" : "After").font(.caption).foregroundStyle(.secondary)
                                Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }.buttonStyle(.plain).help("Expand the \(index == 0 ? "before" : "after") screenshot")
                    }
                }
            }
            Button { model.reviewSheet = .changes(task.id) } label: {
                HStack {
                    Label("Changes", systemImage: "doc")
                    Spacer(minLength: 4)
                    Text("\(proof.files) files · +\(proof.additions) −\(proof.deletions)").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("Review the summary and changed files")
        }
    }
}

struct PreviewControls: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let task: WorkTask
    private var preview: PreviewStatus? { model.previews[task.id] }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try it yourself").font(.headline).accessibilityAddTraits(.isHeader)
            HStack {
                Button { model.runPreview(task) } label: {
                    Label(preview?.phase == "ready" ? "Open Preview" : preview?.phase == "starting" ? "Starting…" : "Run locally", systemImage: "play.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).disabled(preview?.phase == "starting")
                    .help("Run this worktree locally and open it in your browser")
                if preview != nil && preview?.phase != "failed" {
                    Button("Stop Preview", systemImage: "stop.fill") { model.perform { await model.core.stopPreview(task.id) } }
                        .labelStyle(.iconOnly).help("Stop this preview and free its port")
                }
            }
            if preview?.phase == "starting" { ProgressView().controlSize(.small).accessibilityLabel("Starting local preview") }
            if let error = preview?.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            if let preview, !preview.log.isEmpty {
                DisclosureGroup("Preview output") { ScrollView { Text(preview.log).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 140) }
                    .help("Show output from the preview command")
            }
            Button("Configure Preview…") { model.reviewSheet = .previewSetup(task.projectId) }.buttonStyle(.borderless)
                .help("Set this project’s preview command, port variable and ready path")
        }.animation(reduceMotion ? nil : .smooth(duration: 0.2), value: preview?.phase)
    }
}

struct LifecycleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sheet: ReviewSheet
    @State private var note = ""
    @State private var command = ""
    @State private var portVariable = "PORT"
    @State private var readyPath = "/"
    @State private var log = ""
    @State private var failure: String?
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            content
            if let failure { Text(failure).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(actionable ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving).help("Close this sheet (Esc)")
                if actionable {
                    Button(actionTitle) { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .disabled(saving || !valid).help(actionTitle + " (Return)")
                }
            }
        }.padding(28).frame(width: 620).interactiveDismissDisabled(saving)
        .task {
            if case .previewSetup(let id) = sheet, let project = model.snapshot.projects.first(where: { $0.id == id }) {
                command = project.settings.previewCommand; portVariable = project.settings.previewPortEnvVar; readyPath = project.settings.previewReadyPath
            }
            if case .log(let path) = sheet {
                do { log = try String(contentsOfFile: path, encoding: .utf8) }
                catch { failure = "This check log is no longer available." }
            }
        }
    }
    private var title: String {
        switch sheet { case .sendBack: "Send back for changes"; case .changes: "Changes"; case .previewSetup: "Local Preview"; case .defaults: "Use the agent’s suggestions?"; case .log: "Check output"; case .image: "Screenshot" }
    }
    private var actionable: Bool { switch sheet { case .sendBack, .previewSetup, .defaults: true; default: false } }
    private var actionTitle: String { switch sheet { case .sendBack: "Send Back"; case .defaults: "Use Suggestions"; default: "Save Configuration" } }
    private var valid: Bool {
        switch sheet {
        case .sendBack: !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .previewSetup: !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .defaults(let id): !questions(id).isEmpty && questions(id).allSatisfy { $0.suggestedAnswer != nil }
        default: true
        }
    }
    private func questions(_ id: UUID) -> [Question] { model.snapshot.questions.filter { $0.taskId == id && $0.answer == nil && $0.blocking } }
    @ViewBuilder private var content: some View {
        switch sheet {
        case .sendBack:
            Text("Describe what needs changing. The agent keeps its context and must provide fresh proof. Paused work stays paused.").foregroundStyle(.secondary)
            TextEditor(text: $note).frame(height: 170).accessibilityLabel("Requested changes")
        case .previewSetup:
            Text("Runs in the task’s worktree. Use the port variable in your command and bind to 127.0.0.1. Saving does not run it.").foregroundStyle(.secondary)
            TextField("Command (for example: npm run dev -- --port $PORT --host 127.0.0.1)", text: $command).textFieldStyle(.roundedBorder).accessibilityLabel("Preview command")
            TextField("Port environment variable", text: $portVariable).textFieldStyle(.roundedBorder)
            TextField("Ready path", text: $readyPath).textFieldStyle(.roundedBorder)
            Text("Previews stop on quit or 30 minutes after you last open them from Build Mate.").font(.caption).foregroundStyle(.secondary)
        case .defaults(let id):
            ForEach(questions(id)) { question in
                VStack(alignment: .leading, spacing: 6) { Text(question.prompt).fontWeight(.medium); Text(question.suggestedAnswer ?? "No suggestion provided").foregroundStyle(.secondary) }
            }
        case .image(let path):
            if let image = NSImage(contentsOfFile: path) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 450).accessibilityLabel("Proof screenshot") }
            else { Text("This screenshot is no longer available.") }
        case .log:
            ScrollView { Text(log.isEmpty ? "No output was recorded." : log).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 330)
        case .changes(let id):
            if let proof = model.snapshot.proofs.first(where: { $0.taskId == id }) {
                Text(proof.summary).textSelection(.enabled)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(proof.changes) { file in
                            HStack(alignment: .firstTextBaseline) {
                                Text(file.path).font(.body.monospaced()).textSelection(.enabled)
                                Spacer()
                                Text(file.additions.map { "+\($0)" } ?? "Binary").foregroundStyle(.secondary)
                                if let count = file.deletions { Text("−\(count)").foregroundStyle(.secondary) }
                                Button("Open File", systemImage: "arrow.up.forward.app") {
                                    model.openLocation(task: model.snapshot.tasks.first { $0.id == id }, appID: model.defaultEditor?.id, file: file.path)
                                }.labelStyle(.iconOnly).help("Open \(file.path) in your editor")
                            }
                        }
                        if proof.changes.isEmpty { Text("No file details were saved with this proof.").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 330)
            }
        }
    }
    private func save() {
        saving = true; failure = nil
        Task {
            defer { saving = false }
            do {
                switch sheet {
                case .sendBack(let id): try await model.core.sendBack(id, note: note)
                case .defaults(let id):
                    for question in questions(id) { if let answer = question.suggestedAnswer { try await model.core.answer(question.id, text: answer, useSuggested: true) } }
                case .previewSetup(let id):
                    command = command.trimmingCharacters(in: .whitespacesAndNewlines)
                    portVariable = portVariable.trimmingCharacters(in: .whitespacesAndNewlines)
                    readyPath = readyPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard portVariable.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                          !["PATH", "HOME", "TMPDIR", "SHELL"].contains(portVariable), readyPath.hasPrefix("/"), !readyPath.hasPrefix("//"), !readyPath.contains("#") else { throw CoreError.invalid("Use a port variable such as PORT and a ready path beginning with /.") }
                    var project = try model.store.get(Project.self, id)
                    project.settings.previewCommand = command; project.settings.previewPortEnvVar = portVariable; project.settings.previewReadyPath = readyPath
                    for task in model.snapshot.tasks where task.projectId == id { await model.core.stopPreview(task.id) }
                    try model.store.save(project); try model.store.workflow(for: project)
                default: break
                }
                await model.refresh(); dismiss()
            } catch { failure = error.localizedDescription }
        }
    }
}
