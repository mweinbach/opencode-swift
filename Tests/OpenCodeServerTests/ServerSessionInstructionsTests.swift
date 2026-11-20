import Testing
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeServer

/// Server-level coverage for `core/src/session/context.ts#node`: the live session runner combines the
/// Location's instruction services into the first model request, and reconciles later changes as updates.
@Suite("Server session instruction baseline")
struct ServerSessionInstructionsTests {
    static let globalAgents = "/tmp/opencode-live-test/config/AGENTS.md"

    static func strings(_ value: JSONValue?) -> [String] {
        switch value {
        case .string(let text): return [text]
        case .array(let items): return items.flatMap { strings($0) }
        case .object(let object): return object.keys.sorted().flatMap { strings(object[$0]) }
        default: return []
        }
    }

    @Test("skills, discovered AGENTS.md and the Code Mode catalog reach the first request; an edit arrives as a <system-update>")
    func instructionsReachModel() async throws {
        let skill = """
        ---
        name: Tidy
        description: Tidies Swift sources before review
        ---
        Run swift format.
        """
        let harness = try await LiveExecutionFixture.makeHarness(
            env: ["ANTHROPIC_API_KEY": "sk-ant-live-secret"],
            initialFiles: [
                Self.globalAgents: LiveExecutionFixture.bytes("Global rule v1: answer tersely."),
                "/tmp/opencode-live-test/config/skills/tidy/SKILL.md": LiveExecutionFixture.bytes(skill),
            ],
            responses: [
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["First answer."]),
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["Second answer."]),
            ]
        )
        defer { Task { await harness.close() } }

        let created = try await harness.client.session.create(SessionCreateInput(title: "Instruction baseline"))
        _ = try await harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Hello"))
        await harness.runtime.sessionExecution.awaitIdle(created.id)

        let first = try #require(harness.mockTransport.recordedRequests.first)
        let firstJSON = try LiveExecutionFixture.decodeJSON(first.body ?? [])
        let system = Self.strings(firstJSON["system"]).joined(separator: "\n\n")
        #expect(system.contains("Instructions from: \(Self.globalAgents)\nGlobal rule v1: answer tersely."))
        #expect(system.contains("<available_skills>"))
        #expect(system.contains("Tidies Swift sources before review"))
        #expect(system.contains("## Code Mode tools (call only inside `execute`)"))
        #expect(!Self.strings(firstJSON["messages"]).contains { $0.contains("<system-update>") })

        // Upstream's prompt-cache order: catalog and skills, then project instructions, then date and environment.
        let anchors = ["# Code Mode", "<available_skills>", "Instructions from:", "Today's date:", "<env>"]
        let positions = anchors.compactMap { system.range(of: $0)?.lowerBound }
        #expect(positions.count == anchors.count)
        #expect(positions == positions.sorted())

        // Editing AGENTS.md mid-session reaches the next step as an update, not a rewritten baseline.
        try await harness.fileSystem.writeFile(
            LiveExecutionFixture.bytes("Global rule v2: answer in full sentences."),
            to: Self.globalAgents,
            createDirectories: true
        )
        _ = try await harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Again"))
        await harness.runtime.sessionExecution.awaitIdle(created.id)

        let requests = harness.mockTransport.recordedRequests
        #expect(requests.count == 2)
        let second = try #require(requests.last)
        let secondJSON = try LiveExecutionFixture.decodeJSON(second.body ?? [])
        let secondSystem = Self.strings(secondJSON["system"]).joined(separator: "\n\n")
        #expect(secondSystem.contains("Global rule v1: answer tersely."))
        #expect(!secondSystem.contains("Global rule v2"))
        let updates = Self.strings(secondJSON["messages"]).filter { $0.contains("<system-update>") }
        #expect(updates.count == 1)
        #expect(updates.first?.contains(Self.globalAgents) == true)
        #expect(updates.first?.contains("Global rule v2: answer in full sentences.") == true)
    }
}
