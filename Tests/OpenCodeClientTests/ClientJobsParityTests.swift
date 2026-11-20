import Testing
import Synchronization
import OpenCodeClient
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

@Suite("Client background jobs and send chain")
struct ClientJobsParityTests {
    private static let sessionID = "ses_root"

    private static func job(_ id: String, status: String, kind: String = "shell", session: String = sessionID) -> JSONValue {
        var obj: [String: JSONValue] = [
            "kind": .string(kind),
            "id": .string(id),
            "sessionID": .string(session),
            "status": .string(status),
            "time": .object(["started": .int(1)]),
        ]
        switch kind {
        case "shell":
            obj["shellID"] = .string("sh_\(id)")
            obj["command"] = .string("sleep 10")
        case "video":
            obj["path"] = .string("clip.mp4")
        default:
            break
        }
        return .object(obj)
    }

    @Test("job.cancel posts to the cancel route and accepts 204")
    func cancelRoute() async throws {
        let seen = Mutex<[String]>([])
        let transport = MockHTTPTransport { request in
            seen.withLock { $0.append("\(request.method) \(request.url)") }
            return ClientTestHelper.emptyResponse(status: 204)
        }
        let client = OpenCode.make(ClientOptions(baseUrl: "http://127.0.0.1:4096", transport: transport))
        try await client.experimental.job.cancel(ExperimentalJobCancelInput(id: "job/1"))
        #expect(seen.withLock { $0 } == ["POST http://127.0.0.1:4096/api/experimental/job/job%2F1/cancel"])
    }

    @Test("createData syncs running jobs of a tree and follows experimental.job.updated")
    func jobStore() async throws {
        let transport = MockHTTPTransport { request in
            if request.url.contains("/api/experimental/job") {
                return try ClientTestHelper.jsonResponse(body: ClientDataEnvelope(data: [Self.job("job_1", status: "running")]))
            }
            return ClientTestHelper.emptyResponse(status: 204)
        }
        let bus = ClientDataEventBus()
        let client = OpenCode.make(ClientOptions(baseUrl: "http://127.0.0.1:4096", transport: transport))
        let store = createData(CreateDataInput(api: { client }, directory: "/repo", event: bus, omitToolFileData: { false }))

        try await store.syncJobs(Self.sessionID)
        #expect(store.jobs(Self.sessionID).count == 1)

        // A job of the tree starts: it joins the synced tree.
        bus.emit(OpenCodeEvent(
            id: "evt_1",
            type: "experimental.job.updated",
            created: 2,
            data: .object(["info": Self.job("job_2", status: "running", kind: "video")])
        ))
        #expect(store.jobs(Self.sessionID).count == 2)

        // A job settles: it leaves the store.
        bus.emit(OpenCodeEvent(
            id: "evt_2",
            type: "experimental.job.updated",
            created: 3,
            data: .object(["info": Self.job("job_1", status: "completed")])
        ))
        let remaining = store.jobs(Self.sessionID)
        #expect(remaining.count == 1)
        if case .video(let video) = remaining.first {
            #expect(video.path == "clip.mp4")
        } else {
            Issue.record("Expected the running video job to remain")
        }
        store.dispose()
    }

    @Test("sequence runs requests of a session in submission order")
    func sequenceOrder() async throws {
        let store = createData(CreateDataInput(
            api: { OpenCode.make(ClientOptions(baseUrl: "http://127.0.0.1:4096", transport: MockHTTPTransport { _ in
                ClientTestHelper.emptyResponse(status: 204)
            })) },
            directory: "/repo",
            event: ClientDataEventBus(),
            omitToolFileData: { false }
        ))
        let order = Mutex<[String]>([])
        let first = Task {
            try await store.sequence(Self.sessionID, send: {
                try await Task.sleep(for: .milliseconds(30))
                order.withLock { $0.append("first") }
                return 1
            })
        }
        try await Task.sleep(for: .milliseconds(5))
        let second = try await store.sequence(Self.sessionID, send: {
            order.withLock { $0.append("second") }
            return 2
        })
        #expect(try await first.value == 1)
        #expect(second == 2)
        #expect(order.withLock { $0 } == ["first", "second"])
        store.dispose()
    }
}
