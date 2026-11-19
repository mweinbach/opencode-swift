/// Cross-platform filesystem and subprocess protocol boundaries.
/// Concrete host implementations live behind `#if os(...)` guards, while pure tests and
/// restricted environments (iOS/WASI) can supply in-memory or remote implementations.

public enum PlatformError: Error, Equatable, Sendable {
    case unsupportedOnPlatform(PlatformOS, operation: String)
    case notFound(String)
    case ioFailure(String)
}

public protocol OpenCodeFileSystem: Sendable {
    func readFile(at path: String) async throws -> [UInt8]
    func writeFile(_ bytes: [UInt8], to path: String, createDirectories: Bool) async throws
    func exists(at path: String) async -> Bool
    func remove(at path: String) async throws
}

public struct ProcessSpec: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String?
    public let environment: [String: String]?

    public init(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

public struct ProcessOutput: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: [UInt8]
    public let stderr: [UInt8]

    public init(exitCode: Int32, stdout: [UInt8], stderr: [UInt8]) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessSpawner: Sendable {
    func run(_ spec: ProcessSpec) async throws -> ProcessOutput
}
