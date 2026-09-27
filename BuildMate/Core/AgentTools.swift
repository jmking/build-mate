import Foundation

/// Build Mate tool schemas are shared by provider transports. Operations live in the orchestrator.
enum AgentTools {
    static let task: JSON = .array([
        tool("ask_question", "Ask the user before making an unclear decision. Blocking questions wait for an answer. Include suggestedAnswer only when you have a reasonable default for the user to confirm.",
             ["prompt": "string", "allowsFreeText": "boolean", "blocking": "boolean", "suggestedAnswer": "string"], required: ["prompt", "blocking"], options: true),
        tool("submit_plan", "Submit your plan before editing. Wait for approval when required.", ["plan": "string", "affectedPaths": "array"], required: ["plan"]),
        reviewTool,
        tool("review_action", "Inspect failed CI, request an evidenced bounded rerun, queue a reviewer reply, or finish a PR triage pass with no code changes.", ["action": "string", "runId": "string", "reason": "string", "feedbackId": "string", "body": "string", "resolve": "boolean"], required: ["action"]),
        .object(["name": .string("complete_qa"), "description": .string("After inspecting all collected evidence and correcting defects, attest QA of this exact proof revision."), "inputSchema": .object([
            "type": .string("object"), "additionalProperties": .bool(false),
            "properties": .object(["proofToken": .object(["type": .string("string")]), "assessment": .object(["type": .string("string")]), "inspectedPaths": .object(["type": .string("array"), "items": .object(["type": .string("string")])])]),
            "required": .array(["proofToken", "assessment", "inspectedPaths"].map(JSON.string))
        ])]),
        tool("note", "Record a short progress note.", ["text": "string"], required: ["text"])
    ])
    private static let reviewTool: JSON = .object([
        "name": .string("request_review"),
        "description": .string("Request review after committing. Write summary as concise, readable Markdown about the changes, with paragraphs and bullets where useful; never put a JSON object inside the summary text. This summary becomes the PR body: include only what changed and why, with no proof reports, recording details, validation logs, commit hashes or Build Mate branding. Put evidence explanations in rationale and checks instead. Classify visual changes and explain the relevant evidence, respecting the user's proof choice and brief. Supply meaningful check commands; Build Mate runs them independently alongside configured checks. For required visual proof supply a recordingCommand that writes a playable MP4 to $BUILD_MATE_RECORDING_PATH (up to 180 seconds), unless the project has one configured. For visual changes with screenshots enabled, supply screenshotsCommand writing before/after PNGs to $BUILD_MATE_BEFORE_PATH and $BUILD_MATE_AFTER_PATH. Commands run in the task worktree. Do not push or open a PR."),
        "inputSchema": .object([
            "type": .string("object"), "additionalProperties": .bool(false),
            "properties": .object([
                "summary": .object(["type": .string("string")]),
                "needsRecording": .object(["type": .string("boolean")]),
                "rationale": .object(["type": .string("string")]),
                "recordingCommand": .object(["type": .string("string")]),
                "screenshotsCommand": .object(["type": .string("string")]),
                "checks": .object(["type": .string("array"), "items": .object([
                    "type": .string("object"), "additionalProperties": .bool(false),
                    "properties": .object(["name": .object(["type": .string("string")]), "command": .object(["type": .string("string")])]),
                    "required": .array([.string("name"), .string("command")])
                ])])
            ]),
            "required": .array(["summary", "needsRecording", "rationale", "checks"].map(JSON.string))
        ])
    ])
    private static func tool(_ name: String, _ description: String, _ fields: [String: String], required: [String], options: Bool = false) -> JSON {
        var properties = fields.mapValues { type in type == "array" ? JSON.object(["type": .string("array"), "items": .object(["type": .string("string")])]) : JSON.object(["type": .string(type)]) }
        if options { properties["options"] = .object(["type": .string("array"), "items": .object(["type": .string("string")])]) }
        return .object(["name": .string(name), "description": .string(description), "inputSchema": .object([
            "type": .string("object"), "properties": .object(properties),
            "required": .array(required.map(JSON.string)), "additionalProperties": .bool(false)
        ])])
    }

    static let project: JSON = {
        func field(_ type: String) -> JSON { .object(["type": .string(type)]) }
        func array(_ item: JSON) -> JSON { .object(["type": .string("array"), "items": item]) }
        func object(_ properties: [String: JSON], _ required: [String]) -> JSON {
            .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(JSON.string)), "additionalProperties": .bool(false)])
        }
        func tool(_ name: String, _ description: String, _ properties: [String: JSON], _ required: [String]) -> JSON {
            .object(["name": .string(name), "description": .string(description), "inputSchema": object(properties, required)])
        }
        let tasks = array(object(["title": field("string"), "description": field("string"), "dependsOnIndex": array(field("integer")),
            "dependsOnTaskIds": array(field("string")), "attachmentIds": array(field("string")), "acceptanceCriteria": array(field("string")), "affectedPaths": array(field("string")),
            "model": field("string"), "effort": field("string"), "modelRationale": field("string")], ["title", "description", "dependsOnIndex", "acceptanceCriteria", "model", "effort", "modelRationale"]))
        return .array([
            tool("propose_tasks", "Propose actionable tasks for the user to select. Dependencies use zero-based indices and must refer to earlier items.", ["tasks": tasks], ["tasks"]),
            tool("create_tasks", "Only after an explicit user request. Use proposalId for an existing proposal, or tasks for new work. Every selected task goes straight to Queue. selectedIndexes defaults to all. Never recreate a completed proposal.", ["tasks": tasks, "proposalId": field("string"), "selectedIndexes": array(field("integer"))], []),
            tool("ask_question", "Ask the user to clarify the project or task scope. Waits for an answer.", ["prompt": field("string"), "options": array(field("string")), "allowsFreeText": field("boolean")], ["prompt"]),
            tool("project_status", "Read this project's tasks, open task questions and PRs.", [:], []),
            tool("refine_task", "Apply changed requirements to an existing task, including built work and open PRs. Finished work gets a linked follow-up. Preserve the complete outcome and constraints. Explicit pauses and model choices are preserved.", ["taskId": field("string"), "description": field("string"), "title": field("string"), "attachmentIds": array(field("string"))], ["taskId", "description"]),
            tool("reshape_tasks", "Replace unpublished tasks with coherent delivery units: split a large task or combine related tasks. Retains source work and rewires dependents. Describe all original requirements in the replacements. Do not use on unrelated work.", ["taskIds": array(field("string")), "tasks": tasks, "reason": field("string")], ["taskIds", "tasks", "reason"]),
            tool("note", "Record a concise progress note.", ["text": field("string")], ["text"])
        ])
    }()

}
