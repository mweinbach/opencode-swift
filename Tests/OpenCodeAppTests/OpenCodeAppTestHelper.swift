import Foundation
import Synchronization
import OpenCodeApp
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeSDK
import OpenCodeServer
import OpenCodeUtil

/// Foundation-backed helpers for `OpenCodeAppTests`.
/// Kept strictly separate from `import Testing` to satisfy the macOS CLT cross-import rule.
enum OpenCodeAppTestHelper {
    static func makeTempDirectory(prefix: String = "opencode-app-test") throws -> String {
        let base = FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #if os(Windows)
        return dir.path.replacing("/", with: "\\")
        #else
        return dir.path
        #endif
    }

    static func removeDirectory(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    static func dataByteCount(_ data: Data?) -> Int {
        data?.count ?? 0
    }

    static func hasPNGMagicBytes(_ data: Data?) -> Bool {
        guard let data, data.count >= 8 else { return false }
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        return Array(data.prefix(8)) == magic
    }

    static func assetURLPath(_ asset: OpenCodeIdentityAssets.Asset) -> String? {
        OpenCodeIdentityAssets.url(for: asset)?.path
    }

    static func makeEvent(
        id: String = "evt_\(Identifier.ascending())",
        type: String,
        data: [String: JSONValue],
        created: Double = Double(Flock.currentEpochMs())
    ) -> OpenCodeEvent {
        OpenCodeEvent(
            id: id,
            type: type,
            created: created,
            data: .object(data)
        )
    }

    /// Creates a real `OpenCodeClient` transport that records HTTP headers while forwarding to an embedded SDK host.
    final class HeaderRecordingTransport: HTTPTransport, Sendable {
        private let inner: any HTTPTransport
        private let recordedAuthHeaders = Mutex<[String]>([])

        init(inner: any HTTPTransport) {
            self.inner = inner
        }

        var authorizationHeaders: [String] {
            recordedAuthHeaders.withLock { $0 }
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            if let auth = ClientHTTPHeaders.value(in: request.headers, for: "Authorization") {
                recordedAuthHeaders.withLock { $0.append(auth) }
            }
            return try await inner.send(request)
        }

        func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
            if let auth = ClientHTTPHeaders.value(in: request.headers, for: "Authorization") {
                recordedAuthHeaders.withLock { $0.append(auth) }
            }
            return try await inner.stream(request)
        }
    }

    static func makeAuthenticatedServerHandle(
        password: String,
        version: String = "remote-auth-test",
        directory: String
    ) async throws -> ServerFetch.Handle {
        let options = ServerOptions(
            app: ServerOptions.AppOptions(name: "opencode", version: version, channel: "local"),
            password: password,
            config: ServerOptions.ConfigOptions(
                directory: directory,
                project: false,
                claude: false
            )
        )
        return try await ServerFetch.make(
            options: options,
            boot: ServerFetch.BootOptions(defaultDirectory: directory)
        )
    }

    /// Creates a `MockHTTPTransport` that streams a scripted list of `OpenCodeEvent` SSE frames on `/api/event`
    /// while forwarding all other requests to an embedded SDK host!
    static func makeLiveSSETransport(
        forwardingTo host: any HTTPTransport,
        sseEvents: [OpenCodeEvent]
    ) -> any HTTPTransport {
        final class ScriptedSSETransport: HTTPTransport, Sendable {
            let host: any HTTPTransport
            let ssePayload: [UInt8]

            init(host: any HTTPTransport, events: [OpenCodeEvent]) {
                self.host = host
                var raw = ""
                for event in events {
                    if let json = try? ClientCodec.encodeString(event) {
                        raw += "data: \(json)\n\n"
                    }
                }
                self.ssePayload = Array(raw.utf8)
            }

            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                try await host.send(request)
            }

            func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
                if request.url.contains("/api/event") {
                    let payload = self.ssePayload
                    let (chunks, cont) = AsyncThrowingStream<[UInt8], Error>.makeStream()
                    cont.yield(payload)
                    cont.finish()
                    return HTTPStreamingResponse(
                        head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "text/event-stream"]),
                        chunks: chunks
                    )
                }
                return try await host.stream(request)
            }
        }
        return ScriptedSSETransport(host: host, events: sseEvents)
    }
}
