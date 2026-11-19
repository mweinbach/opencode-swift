#if os(macOS) || os(Linux) || os(Windows)
import Foundation
#elseif canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeAI
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Helpers and synthetic binary fixtures for `RealSubsystemsWiringTests`.
/// Intentionally does NOT `import Testing` (macOS CLT cross-import overlay rule).
enum RealSubsystemsWiringHelper {
    final class MockEnv: EnvironmentProviding, Sendable {
        let vars: [String: String]
        let home: String

        init(vars: [String: String] = [:], home: String = "/tmp/opencode-test-home") {
            self.vars = vars
            self.home = home
        }

        func variable(_ name: String) -> String? { vars[name] }
        func allVariables() -> [String: String] { vars }
        var currentDirectory: String { "/tmp" }
        var homeDirectory: String? { home }
        var temporaryDirectory: String { "/tmp" }
    }

    final class RecordingHTTPTransport: HTTPTransport, Sendable {
        private let recorded = Mutex<[HTTPRequest]>([])
        private let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse

        init(handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
            self.handler = handler
        }

        var requests: [HTTPRequest] {
            recorded.withLock { $0 }
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            recorded.withLock { $0.append(request) }
            return try await handler(request)
        }

        func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
            let resp = try await send(request)
            let body = resp.body
            let chunks = AsyncThrowingStream<[UInt8], any Error> { continuation in
                if !body.isEmpty { continuation.yield(body) }
                continuation.finish()
            }
            return HTTPStreamingResponse(head: resp.head, chunks: chunks)
        }
    }

    final class RecordingProcessSpawner: ProcessSpawner, Sendable {
        private let specs = Mutex<[ProcessSpec]>([])
        private let handler: @Sendable (ProcessSpec) async throws -> ProcessOutput

        init(handler: @escaping @Sendable (ProcessSpec) async throws -> ProcessOutput) {
            self.handler = handler
        }

        var recordedSpecs: [ProcessSpec] { specs.withLock { $0 } }

        func run(_ spec: ProcessSpec) async throws -> ProcessOutput {
            specs.withLock { $0.append(spec) }
            return try await handler(spec)
        }
    }

    static func utf8(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    static func decodeUTF8(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    static func jsonResponse(
        _ status: Int = 200,
        headers: [String: String] = [:],
        body: JSONValue
    ) throws -> HTTPResponse {
        var merged = headers
        if !merged.keys.contains(where: { $0.lowercased() == "content-type" }) {
            merged["content-type"] = "application/json"
        }
        let data = try JSONEncoder().encode(body)
        return HTTPResponse(head: HTTPResponseHead(statusCode: status, headers: merged), body: Array(data))
    }

    static func textResponse(
        _ status: Int = 200,
        headers: [String: String] = [:],
        body: String
    ) -> HTTPResponse {
        HTTPResponse(head: HTTPResponseHead(statusCode: status, headers: headers), body: Array(body.utf8))
    }

    static func decodeJSON(_ bytes: [UInt8]) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(bytes))
    }

    // MARK: - Temporary Git Repository Helper (POSIX)

    #if os(macOS) || os(Linux)
    static func makeTempGitRepo(branch: String = "feat-real-vcs") async throws -> String {
        let dir = "\(FileManager.default.temporaryDirectory.path)/opencode-vcs-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let spawner = CrossSpawnSpawner.HostProcessSpawner.shared
        let git = CoreSubsystems.Util.GitExecutable.gitExecutable()

        func run(_ args: [String]) async throws {
            let out = try await spawner.run(ProcessSpec(executable: git, arguments: args, workingDirectory: dir))
            if out.exitCode != 0 {
                throw PlatformError.ioFailure("git \(args.joined(separator: " ")) failed: \(decodeUTF8(out.stderr))")
            }
        }

        try await run(["init", "-b", branch])
        try await run(["config", "user.name", "OpenCode Test"])
        try await run(["config", "user.email", "test@opencode.ai"])

        let helloPath = "\(dir)/hello.txt"
        try Data("line1\nline2\n".utf8).write(to: URL(fileURLWithPath: helloPath))
        try await run(["add", "hello.txt"])
        try await run(["commit", "-m", "initial commit"])

        // Modify tracked file and create an untracked file
        try Data("line1\nline2-edited\nline3-added\n".utf8).write(to: URL(fileURLWithPath: helloPath))
        let untrackedPath = "\(dir)/notes.txt"
        try Data("brand new untracked line\n".utf8).write(to: URL(fileURLWithPath: untrackedPath))
        return dir
    }

    static func removeTempDir(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
    #endif

    // MARK: - Binary Image Fixtures (PNG, GIF, JPEG SOF0/SOF2, WebP VP8/VP8L/VP8X)

    static func makePNG(width: Int, height: Int) -> [UInt8] {
        var bytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D,
            0x49, 0x48, 0x44, 0x52, // IHDR
        ]
        bytes.append(UInt8((width >> 24) & 0xFF))
        bytes.append(UInt8((width >> 16) & 0xFF))
        bytes.append(UInt8((width >> 8) & 0xFF))
        bytes.append(UInt8(width & 0xFF))
        bytes.append(UInt8((height >> 24) & 0xFF))
        bytes.append(UInt8((height >> 16) & 0xFF))
        bytes.append(UInt8((height >> 8) & 0xFF))
        bytes.append(UInt8(height & 0xFF))
        bytes.append(contentsOf: [8, 6, 0, 0, 0])
        return bytes
    }

    static func makeGIF(width: Int, height: Int) -> [UInt8] {
        [
            0x47, 0x49, 0x46, 0x38, 0x39, 0x61, // GIF89a
            UInt8(width & 0xFF), UInt8((width >> 8) & 0xFF),
            UInt8(height & 0xFF), UInt8((height >> 8) & 0xFF),
        ]
    }

    /// Synthesizes a valid JPEG header containing SOI, APP0 (JFIF), DQT, and an SOF0 (0xC0) or SOF2 (0xC2) frame header.
    static func makeJPEG(width: Int, height: Int, progressive: Bool = false) -> [UInt8] {
        var bytes: [UInt8] = [0xFF, 0xD8] // SOI
        // APP0 JFIF segment (length = 16: 2 length bytes + 14 payload bytes)
        bytes.append(contentsOf: [0xFF, 0xE0, 0x00, 0x10])
        bytes.append(contentsOf: [0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])
        // APP1 dummy EXIF segment (length = 8: 2 length + 6 payload)
        bytes.append(contentsOf: [0xFF, 0xE1, 0x00, 0x08, 0x45, 0x78, 0x69, 0x66, 0x00, 0x00])
        // SOF0 (0xC0) or SOF2 (0xC2) segment: length = 11 (2 len + 1 precision + 2 height + 2 width + 1 components + 3 comp info)
        bytes.append(0xFF)
        bytes.append(progressive ? 0xC2 : 0xC0)
        bytes.append(contentsOf: [0x00, 0x0B, 0x08])
        // Height (big-endian) then Width (big-endian)
        bytes.append(UInt8((height >> 8) & 0xFF))
        bytes.append(UInt8(height & 0xFF))
        bytes.append(UInt8((width >> 8) & 0xFF))
        bytes.append(UInt8(width & 0xFF))
        bytes.append(contentsOf: [0x01, 0x01, 0x11, 0x00])
        // EOI
        bytes.append(contentsOf: [0xFF, 0xD9])
        return bytes
    }

    /// Synthesizes a valid lossy WebP (`VP8 `) header.
    static func makeWebPVP8(width: Int, height: Int) -> [UInt8] {
        var bytes: [UInt8] = [
            0x52, 0x49, 0x46, 0x46, // RIFF
            0x1A, 0x00, 0x00, 0x00, // file size - 8
            0x57, 0x45, 0x42, 0x50, // WEBP
            0x56, 0x50, 0x38, 0x20, // "VP8 "
            0x0E, 0x00, 0x00, 0x00, // chunk size
            0x00, 0x00, 0x00,       // keyframe tag (bit 0 == 0)
            0x9D, 0x01, 0x2A,       // VP8 start code
        ]
        bytes.append(UInt8(width & 0xFF))
        bytes.append(UInt8((width >> 8) & 0x3F))
        bytes.append(UInt8(height & 0xFF))
        bytes.append(UInt8((height >> 8) & 0x3F))
        return bytes
    }

    /// Synthesizes a valid lossless WebP (`VP8L`) header.
    static func makeWebPVP8L(width: Int, height: Int) -> [UInt8] {
        let wMinus1 = UInt32(width - 1) & 0x3FFF
        let hMinus1 = UInt32(height - 1) & 0x3FFF
        let packed = wMinus1 | (hMinus1 << 14)
        return [
            0x52, 0x49, 0x46, 0x46, // RIFF
            0x11, 0x00, 0x00, 0x00, // file size - 8
            0x57, 0x45, 0x42, 0x50, // WEBP
            0x56, 0x50, 0x38, 0x4C, // "VP8L"
            0x05, 0x00, 0x00, 0x00, // chunk size
            0x2F,                   // VP8L signature
            UInt8(packed & 0xFF),
            UInt8((packed >> 8) & 0xFF),
            UInt8((packed >> 16) & 0xFF),
            UInt8((packed >> 24) & 0xFF),
        ]
    }

    /// Synthesizes a valid extended WebP (`VP8X`) header.
    static func makeWebPVP8X(width: Int, height: Int) -> [UInt8] {
        let w = width - 1
        let h = height - 1
        return [
            0x52, 0x49, 0x46, 0x46, // RIFF
            0x16, 0x00, 0x00, 0x00, // file size - 8
            0x57, 0x45, 0x42, 0x50, // WEBP
            0x56, 0x50, 0x38, 0x58, // "VP8X"
            0x0A, 0x00, 0x00, 0x00, // chunk size (10 bytes)
            0x00,                   // flags
            0x00, 0x00, 0x00,       // reserved
            UInt8(w & 0xFF), UInt8((w >> 8) & 0xFF), UInt8((w >> 16) & 0xFF),
            UInt8(h & 0xFF), UInt8((h >> 8) & 0xFF), UInt8((h >> 16) & 0xFF),
        ]
    }
}
