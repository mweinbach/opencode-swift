import OpenCodePlatform

/// Portable HTTP & WebSocket cassette recorder/replayer (`packages/http-recorder`).
public enum OpenCodeRecorderModule {
    public static let upstreamPackage = "http-recorder"
}

/// Public HTTP and WebSocket cassette recording facade matching `packages/http-recorder/src/index.ts#HttpRecorder`.
// parity: http-recorder/src/index.ts#HttpRecorder [status=implemented hash=d0d600747bf0]
public enum HttpRecorder {
    // parity: http-recorder/src/index.ts#HttpRecorder.JsonValue [status=implemented hash=2d0702c16ad2]
    public typealias JsonValue = OpenCodeRecorder.JsonValue

    // parity: http-recorder/src/index.ts#HttpRecorder.CassetteMetadata [status=implemented hash=af2442d0cd7d]
    public typealias CassetteMetadata = OpenCodeRecorder.CassetteMetadata

    // parity: http-recorder/src/index.ts#HttpRecorder.RecorderOptions [status=implemented hash=45725c45230d]
    public typealias RecorderOptions = OpenCodeRecorder.RecorderOptions

    // parity: http-recorder/src/index.ts#HttpRecorder.RedactOptions [status=implemented hash=430c063bbc56]
    public typealias RedactOptions = OpenCodeRecorder.RedactOptions

    // parity: http-recorder/src/index.ts#HttpRecorder.RequestMatcher [status=implemented hash=c5a1c9988d4b]
    public typealias RequestMatcher = OpenCodeRecorder.RequestMatcher

    // parity: http-recorder/src/index.ts#HttpRecorder.RequestSnapshot [status=implemented hash=8b7db488a783]
    public typealias RequestSnapshot = OpenCodeRecorder.RequestSnapshot

    // parity: http-recorder/src/index.ts#HttpRecorder.SocketRecorderOptions [status=implemented hash=06a544ba9874]
    public typealias SocketRecorderOptions = OpenCodeRecorder.SocketRecorderOptions

    public static func layer(
        _ name: String,
        options: RecorderOptions = RecorderOptions(),
        upstream: any HTTPTransport,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) -> RecordingHTTPTransport {
        HTTPRecorder.layer(
            name,
            options: options,
            upstream: upstream,
            fileSystem: fileSystem,
            environment: environment
        )
    }

    public static func layerFetch(
        _ name: String,
        options: RecorderOptions = RecorderOptions(),
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) -> RecordingHTTPTransport {
        HTTPRecorder.layerFetch(
            name,
            options: options,
            fileSystem: fileSystem,
            environment: environment
        )
    }

    public static func layerSocket(
        _ name: String,
        options: SocketRecorderOptions = SocketRecorderOptions(),
        upstream: any RecorderSocket,
        cassette: (any CassetteStoreInterface)? = nil,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) -> RecordingWebSocket {
        WebSocketRecorder.layerSocket(
            name,
            options: options,
            upstream: upstream,
            cassette: cassette,
            fileSystem: fileSystem,
            environment: environment
        )
    }

    public static func layerWebSocketConstructor(
        _ name: String,
        options: SocketRecorderOptions = SocketRecorderOptions(),
        upstream: @escaping WebSocketTransportConstructor,
        cassette: (any CassetteStoreInterface)? = nil,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) -> RecordingWebSocketConstructor {
        WebSocketRecorder.layerWebSocketConstructor(
            name,
            options: options,
            upstream: upstream,
            cassette: cassette,
            fileSystem: fileSystem,
            environment: environment
        )
    }

    public static func hasCassetteSync(_ name: String, directory: String? = nil) throws -> Bool {
        try OpenCodeRecorder.hasCassetteSync(name, directory: directory)
    }

    public static func removeCassetteSync(_ name: String, directory: String? = nil) throws {
        try OpenCodeRecorder.removeCassetteSync(name, directory: directory)
    }
}
