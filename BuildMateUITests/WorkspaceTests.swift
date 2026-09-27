import XCTest

@MainActor
final class WorkspaceTests: XCTestCase {
    // Catches broken native navigation, CLI setup, database-to-screen updates and launch restoration.
    func testProjectSetupBoardTranscriptAndRestorationInBothAppearances() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "BuildMateUI-\(UUID())")
        let bin = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fixtures = Bundle(for: Self.self).resourceURL!.appending(path: "Fixtures")
        for name in ["gh", "codex", "twg"] {
            let target = bin.appending(path: name)
            try FileManager.default.copyItem(at: fixtures.appending(path: name), to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        }
        let environment = ["PATH": bin.path + ":/usr/bin:/bin", "HOME": root.path, "BUILD_MATE_FIXTURE": root.path,
                           "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"]
        let runner = ProcessRunner(environment: environment)
        let repo = root.appending(path: "clone"), remote = root.appending(path: "remote.git")
        _ = try await runner.run("git", ["init", "--bare", "--initial-branch=main", remote.path])
        _ = try await runner.run("git", ["clone", remote.path, repo.path])
        try "Fixture".write(to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
        _ = try await runner.run("git", ["add", "."], cwd: repo.path)
        _ = try await runner.run("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Seed"], cwd: repo.path)
        _ = try await runner.run("git", ["push", "origin", "main"], cwd: repo.path)
        // Host identity is parsed locally; any pushes stay on the local bare remote.
        _ = try await runner.run("git", ["remote", "set-url", "origin", "git@github.com:fixture/repo.git"], cwd: repo.path)
        _ = try await runner.run("git", ["remote", "set-url", "--push", "origin", remote.path], cwd: repo.path)
        _ = try await runner.run("git", ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], cwd: repo.path)
        let store = try Store(root: root.appending(path: "data"))
        var settings = AppSettings(); settings.paused = true; try store.saveSettings(settings)
        let app = XCUIApplication()
        func visibleText(_ text: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        }
        app.launchEnvironment = environment.merging(["BUILD_MATE_DATA_ROOT": store.root.path, "BUILD_MATE_APPEARANCE": "light"]) { _, new in new }
        continueAfterFailure = false
        app.launch()
        defer { app.terminate(); try? store.db.close(); try? FileManager.default.removeItem(at: root) }
        let path = app.textFields["repository-path"]
        XCTAssertTrue(path.waitForExistence(timeout: 15))
        path.click(); path.typeText(repo.path)
        try Data().write(to: root.appending(path: "signed-out"))
        app.buttons["confirm-add-project"].click()
        XCTAssertTrue(app.buttons["Copy Command"].waitForExistence(timeout: 10))
        try FileManager.default.removeItem(at: root.appending(path: "signed-out"))
        app.buttons["Check Again"].click()
        XCTAssertTrue(visibleText("GitHub CLI is signed in").waitForExistence(timeout: 10))
        app.buttons["confirm-add-project"].click()
        XCTAssertTrue(visibleText("No work queued yet").waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        let brief = app.textViews["task-description"]
        XCTAssertTrue(brief.waitForExistence(timeout: 5))
        brief.typeText("Please make the CLI output more compact and easier to scan.")
        XCTAssertTrue(app.buttons["Add to queue"].isEnabled)
        app.buttons["Add to queue"].click()
        XCTAssertTrue(visibleText("Keep command output compact").waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["task-actions"].waitForExistence(timeout: 5))
        app.typeKey("e", modifierFlags: [.command, .shift])
        let title = app.textFields["edit-task-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click(); title.typeKey("a", modifierFlags: .command); title.typeText("Make output easier to read")
        app.buttons["Save Changes"].click()
        XCTAssertTrue(visibleText("Make output easier to read").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Add to Backlog"].exists)
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.buttons["task-1"].waitForExistence(timeout: 5))
        try app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/buildmate-board-light.png"))
        let task = try XCTUnwrap(store.all(WorkTask.self).first)
        let session = try store.session(for: task.id)
        try store.save(Message(sessionId: session.id, role: "agent", body: "I will keep the output compact and readable."))
        app.buttons["task-1"].click()
        XCTAssertTrue(visibleText("I will keep the output compact and readable.").waitForExistence(timeout: 5))
        try app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/buildmate-task-light.png"))
        let composer = app.textFields["task-message"]
        composer.click(); composer.typeText("Remember this next time")
        // Navigation must not discard an unsent task draft.
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.buttons["task-1"].waitForExistence(timeout: 5))
        app.buttons["task-1"].click()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Remember this next time")
        XCTAssertEqual(app.buttons["send-task-message"].label, "Save message")
        app.buttons["send-task-message"].click()
        XCTAssertTrue(visibleText("Remember this next time").waitForExistence(timeout: 5))
        app.terminate()
        app.launchEnvironment["BUILD_MATE_APPEARANCE"] = "dark"
        app.launch()
        XCTAssertTrue(visibleText("I will keep the output compact and readable.").waitForExistence(timeout: 15))
        let details = app.descendants(matching: .any)["task-details"]
        XCTAssertFalse(details.exists)
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(details.waitForNonExistence(timeout: 5))
        // The details preference survives another app launch.
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(details.waitForExistence(timeout: 15))
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(details.waitForNonExistence(timeout: 5))
        try app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/buildmate-task-dark.png"))
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.buttons["task-1"].waitForExistence(timeout: 5))
        try app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/buildmate-board-dark.png"))
        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Make output easier to read")).firstMatch.waitForExistence(timeout: 5))
        // Search belongs to Tasks, persists there, and never becomes a dead control in chat.
        app.typeKey("f", modifierFlags: .command)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("No matching task title")
        XCTAssertTrue(visibleText("No matches").waitForExistence(timeout: 5))
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.searchFields.firstMatch.waitForNonExistence(timeout: 5))
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(visibleText("No matches").waitForExistence(timeout: 5))
        app.typeKey("f", modifierFlags: .command)
        search.typeKey("a", modifierFlags: .command); search.typeKey(.delete, modifierFlags: [])

        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(visibleText("Nothing needs you").waitForExistence(timeout: 5))
        let status = try await runner.run("git", ["status", "--porcelain"], cwd: repo.path)
        XCTAssertEqual(status.output, "")
    }
}
