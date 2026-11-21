import Testing
import OpenCodeAI
import OpenCodeSchema

@Suite("AI flattenToolRequest Sanitization Parity Tests")
struct FlattenToolRequestParityTests {
    private func makeModel(provider: String = "openai", id: String = "gpt-5") -> AIProtocolUtils.ModelDescriptor {
        AIProtocolUtils.ModelDescriptor(id: id, provider: provider)
    }

    @Test("flattenToolRequest sanitizes undeclared tool names while preserving declared names verbatim")
    func sanitizesUndeclaredToolNames() {
        let declaredDot = AIProtocolUtils.ToolDefinition(
            name: "custom.declared",
            description: "declared",
            inputSchema: [:]
        )
        let namespaced = AIProtocolUtils.ToolEntry.namespace(
            name: "fs",
            description: nil,
            tools: [
                .tool(AIProtocolUtils.ToolDefinition(name: "read", description: "read", inputSchema: [:])),
            ]
        )
        let request = AIProtocolUtils.LLMRequest(
            model: makeModel(),
            messages: [
                AIProtocolUtils.Message(role: .assistant, content: [
                    .toolCall(AIProtocolUtils.ToolCallPart(id: "c1", name: "a.b.c", input: .object([:]))),
                    .toolCall(AIProtocolUtils.ToolCallPart(id: "c2", name: "custom.declared", input: .object([:]))),
                    .toolCall(AIProtocolUtils.ToolCallPart(id: "c3", name: "read", namespace: "fs", input: .object([:]))),
                    .toolCall(AIProtocolUtils.ToolCallPart(id: "c4", name: "", input: .object([:]))),
                    .toolCall(AIProtocolUtils.ToolCallPart(id: "c5", name: "a😀b", input: .object([:]))),
                ]),
                AIProtocolUtils.Message(role: .tool, content: [
                    .toolResult(AIProtocolUtils.ToolResultPart(id: "c1", name: "a.b.c", result: .text("ok"))),
                    .toolResult(AIProtocolUtils.ToolResultPart(id: "c2", name: "custom.declared", result: .text("ok"))),
                    .toolResult(AIProtocolUtils.ToolResultPart(id: "c3", name: "read", namespace: "fs", result: .text("ok"))),
                ]),
            ],
            tools: [.tool(declaredDot), namespaced]
        )

        let flattened = AIProtocolUtils.ProviderShared.flattenToolRequest(request)
        #expect(flattened.tools.map(\.name) == ["custom.declared", "fs_read"])

        let assistantCalls = flattened.request.messages[0].content.compactMap { part -> String? in
            if case .toolCall(let call) = part { return call.name }
            return nil
        }
        #expect(assistantCalls == ["a_b_c", "custom.declared", "fs_read", "_", "a__b"])

        let toolResults = flattened.request.messages[1].content.compactMap { part -> String? in
            if case .toolResult(let res) = part { return res.name }
            return nil
        }
        #expect(toolResults == ["a_b_c", "custom.declared", "fs_read"])
    }
}
