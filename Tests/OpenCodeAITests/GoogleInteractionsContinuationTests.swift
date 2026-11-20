import Testing
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

@Suite("Google Interactions continuation, safety settings and Office documents")
struct GoogleInteractionsContinuationTests {
    private func request(store: Bool = false) -> AIProtocolUtils.LLMRequest {
        AIProtocolUtils.LLMRequest(
            model: .init(id: "gemini-3-pro", provider: "google", baseURL: "https://generativelanguage.googleapis.com/v1beta"),
            messages: [.user("Write a long essay")],
            providerOptions: [
                "store": .bool(store),
                "safetySettings": .array([
                    .object(["category": .string("HARM_CATEGORY_HATE_SPEECH"), "threshold": .string("BLOCK_ONLY_HIGH")]),
                ]),
            ]
        )
    }

    @Test("Request body maps safety settings to the Interactions shape")
    func safetySettingsBody() throws {
        let body = try AIProtocols.GoogleInteractions.fromRequest(request())
        #expect(body["safety_settings"] == .array([
            .object(["type": .string("hate_speech"), "threshold": .string("block_only_high")]),
        ]))
    }

    @Test("Office documents are accepted as document input; other documents are rejected")
    func officeDocuments() throws {
        let docx = AIProtocolUtils.MediaAsset.base64(
            "AAAA",
            mediaType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        )
        let content = try AIProtocols.GoogleInteractions.mediaContent(docx)
        #expect(content["type"] == .string("document"))
        let zip = AIProtocolUtils.MediaAsset.base64("AAAA", mediaType: "application/zip")
        #expect(throws: AIProtocolUtils.ProtocolError.self) {
            _ = try AIProtocols.GoogleInteractions.mediaContent(zip)
        }
    }

    @Test("A requires_continuation response continues with its token and sums usage across requests")
    func continuesAcrossRequests() async throws {
        let first = AITestHelpers.sseBytes([
            (nil, #"{"event_type":"interaction.created","interaction":{"id":"int_1"}}"#),
            (nil, #"{"event_type":"step.start","index":0,"step":{"type":"model_output"}}"#),
            (nil, #"{"event_type":"step.delta","index":0,"delta":{"type":"text","text":"Part one. "}}"#),
            (nil, #"{"event_type":"step.stop","index":0}"#),
            (nil, #"{"event_type":"interaction.completed","interaction":{"id":"int_1","status":"requires_continuation","continuation_token":"tok_1","usage":{"total_input_tokens":100,"total_output_tokens":10,"total_tokens":110}}}"#),
        ])
        let second = AITestHelpers.sseBytes([
            (nil, #"{"event_type":"step.start","index":0,"step":{"type":"model_output"}}"#),
            (nil, #"{"event_type":"step.delta","index":0,"delta":{"type":"text","text":"Part two."}}"#),
            (nil, #"{"event_type":"step.stop","index":0}"#),
            (nil, #"{"event_type":"interaction.completed","interaction":{"id":"int_1","status":"completed","usage":{"total_input_tokens":120,"total_output_tokens":5,"total_tokens":125}}}"#),
        ])
        let transport = OpenCodePlatform.MockHTTPTransport()
        transport.enqueueStream(chunks: [first])
        transport.enqueueStream(chunks: [second])

        let events = try await AIProtocols.GoogleInteractions.route.executeStream(request(store: true), transport: transport)

        let requests = transport.recordedRequests
        #expect(requests.count == 2)
        let continued = try AITestHelpers.decodeRequestBody(requests[1])
        #expect(continued["continuation_token"] == .string("tok_1"))
        // A stored interaction continues by id instead of resending its input.
        #expect(continued["previous_interaction_id"] == .string("int_1"))
        #expect(continued["input"] == nil)

        let texts = events.compactMap { event -> String? in
            if case .textDelta(_, let text, _) = event { return text }
            return nil
        }
        #expect(texts == ["Part one. ", "Part two."])
        // The second request's blocks get hop-qualified ids, so they never collide with the first request's.
        #expect(events.contains { if case .textStart("1:0", _) = $0 { return true }; return false })
        let finishes = events.filter { if case .finish = $0 { return true }; return false }
        #expect(finishes.count == 1)
        if case .finish(let reason, let usage, _) = events.last {
            #expect(reason.normalized == .stop)
            #expect(usage?.inputTokens == 100)
            #expect(usage?.outputTokens == 15)
            #expect(usage?.totalTokens == 115)
            #expect(usage?.providerMetadata?["google"]?["requests"] == .int(2))
        } else {
            Issue.record("Expected one finish event at the end")
        }
    }

    @Test("A stream dropped after a checkpoint reconnects from the token")
    func reconnectsAfterDroppedStream() async throws {
        let dropped = AITestHelpers.sseBytes([
            (nil, #"{"event_type":"interaction.status_update","interaction_id":"int_2","status":"in_progress","continuation_token":"tok_a"}"#),
        ])
        let resumed = AITestHelpers.sseBytes([
            (nil, #"{"event_type":"step.start","index":0,"step":{"type":"model_output"}}"#),
            (nil, #"{"event_type":"step.delta","index":0,"delta":{"type":"text","text":"Hello"}}"#),
            (nil, #"{"event_type":"step.stop","index":0}"#),
            (nil, #"{"event_type":"interaction.completed","interaction":{"id":"int_2","status":"completed"}}"#),
        ])
        let transport = OpenCodePlatform.MockHTTPTransport()
        transport.enqueueStream(chunks: [dropped], trailingError: HTTPTransportError.networkFailure("connection reset"))
        transport.enqueueStream(chunks: [resumed])

        let events = try await AIProtocols.GoogleInteractions.route.executeStream(request(), transport: transport)
        #expect(transport.recordedRequests.count == 2)
        let continued = try AITestHelpers.decodeRequestBody(transport.recordedRequests[1])
        #expect(continued["continuation_token"] == .string("tok_a"))
        // Unstored requests resend their input with the token.
        #expect(continued["input"] != nil)
        #expect(events.contains { if case .textDelta(_, "Hello", _) = $0 { return true }; return false })
    }

    @Test("A drop without a checkpoint surfaces the transport failure")
    func dropWithoutCheckpointFails() async throws {
        let partial = AITestHelpers.sseBytes([
            (nil, #"{"event_type":"step.start","index":0,"step":{"type":"model_output"}}"#),
            (nil, #"{"event_type":"step.delta","index":0,"delta":{"type":"text","text":"Hel"}}"#),
        ])
        let transport = OpenCodePlatform.MockHTTPTransport()
        transport.enqueueStream(chunks: [partial], trailingError: HTTPTransportError.networkFailure("connection reset"))
        await #expect(throws: HTTPTransportError.self) {
            _ = try await AIProtocols.GoogleInteractions.route.executeStream(request(), transport: transport)
        }
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("Function calls stream their arguments and finish as tool calls")
    func functionCalls() throws {
        let bytes = AITestHelpers.sseBytes([
            (nil, #"{"event_type":"step.start","index":0,"step":{"type":"function_call","id":"call_1","name":"search"}}"#),
            (nil, #"{"event_type":"step.delta","index":0,"delta":{"type":"arguments_delta","arguments":"{\"q\":\"swift\"}"}}"#),
            (nil, #"{"event_type":"step.stop","index":0}"#),
            (nil, #"{"event_type":"interaction.completed","interaction":{"id":"int_3","status":"completed"}}"#),
        ])
        let events = try AIProtocols.GoogleInteractions.parseSSEStream(bytes, request: request())
        #expect(events.contains {
            if case .toolCall("call_1", "search", _, let input, _, _) = $0 { return input == .object(["q": .string("swift")]) }
            return false
        })
        if case .finish(let reason, _, _) = events.last {
            #expect(reason.normalized == .toolCalls)
        } else {
            Issue.record("Expected finish event")
        }
    }
}
