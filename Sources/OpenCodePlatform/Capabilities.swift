/// Identifies every operating system and runtime platform supported by Swift 6+.
public enum PlatformOS: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case macOS
    case iOS
    case tvOS
    case watchOS
    case visionOS
    case linux
    case windows
    case android
    case freeBSD
    case wasi
    case unknown

    public var isApple: Bool {
        switch self {
        case .macOS, .iOS, .tvOS, .watchOS, .visionOS: true
        default: false
        }
    }

    public var isPOSIX: Bool {
        switch self {
        case .macOS, .iOS, .tvOS, .watchOS, .visionOS, .linux, .android, .freeBSD: true
        default: false
        }
    }

    public var pathSeparator: Character {
        self == .windows ? "\\" : "/"
    }
}

/// Describes host OS capabilities available at runtime on the current Swift target.
public struct PlatformCapabilities: Equatable, Hashable, Sendable, Codable {
    public let supportsSubprocesses: Bool
    public let supportsPTY: Bool
    public let supportsLocalHTTPServer: Bool
    public let supportsTerminalUI: Bool
    public let supportsNativeFileLocks: Bool
    public let supportsUnixDomainSockets: Bool
    public let supportsNamedPipes: Bool

    public init(
        supportsSubprocesses: Bool,
        supportsPTY: Bool,
        supportsLocalHTTPServer: Bool,
        supportsTerminalUI: Bool,
        supportsNativeFileLocks: Bool,
        supportsUnixDomainSockets: Bool,
        supportsNamedPipes: Bool
    ) {
        self.supportsSubprocesses = supportsSubprocesses
        self.supportsPTY = supportsPTY
        self.supportsLocalHTTPServer = supportsLocalHTTPServer
        self.supportsTerminalUI = supportsTerminalUI
        self.supportsNativeFileLocks = supportsNativeFileLocks
        self.supportsUnixDomainSockets = supportsUnixDomainSockets
        self.supportsNamedPipes = supportsNamedPipes
    }

    public static func forOS(_ os: PlatformOS) -> PlatformCapabilities {
        switch os {
        case .macOS, .linux, .freeBSD:
            return PlatformCapabilities(
                supportsSubprocesses: true,
                supportsPTY: true,
                supportsLocalHTTPServer: true,
                supportsTerminalUI: true,
                supportsNativeFileLocks: true,
                supportsUnixDomainSockets: true,
                supportsNamedPipes: false
            )
        case .windows:
            return PlatformCapabilities(
                supportsSubprocesses: true,
                supportsPTY: true, // ConPTY
                supportsLocalHTTPServer: true,
                supportsTerminalUI: true, // Windows VT console
                supportsNativeFileLocks: true,
                supportsUnixDomainSockets: false,
                supportsNamedPipes: true
            )
        case .android:
            return PlatformCapabilities(
                supportsSubprocesses: true,
                supportsPTY: true,
                supportsLocalHTTPServer: true,
                supportsTerminalUI: true,
                supportsNativeFileLocks: true,
                supportsUnixDomainSockets: true,
                supportsNamedPipes: false
            )
        case .iOS, .tvOS, .watchOS, .visionOS:
            return PlatformCapabilities(
                supportsSubprocesses: false,
                supportsPTY: false,
                supportsLocalHTTPServer: true,
                supportsTerminalUI: false,
                supportsNativeFileLocks: true,
                supportsUnixDomainSockets: true,
                supportsNamedPipes: false
            )
        case .wasi, .unknown:
            return PlatformCapabilities(
                supportsSubprocesses: false,
                supportsPTY: false,
                supportsLocalHTTPServer: false,
                supportsTerminalUI: false,
                supportsNativeFileLocks: false,
                supportsUnixDomainSockets: false,
                supportsNamedPipes: false
            )
        }
    }
}

public enum Platform {
    public static var current: PlatformOS {
        #if os(macOS)
        return .macOS
        #elseif os(iOS)
        return .iOS
        #elseif os(tvOS)
        return .tvOS
        #elseif os(watchOS)
        return .watchOS
        #elseif os(visionOS)
        return .visionOS
        #elseif os(Linux)
        return .linux
        #elseif os(Windows)
        return .windows
        #elseif os(Android)
        return .android
        #elseif os(FreeBSD)
        return .freeBSD
        #elseif os(WASI)
        return .wasi
        #else
        return .unknown
        #endif
    }

    public static var capabilities: PlatformCapabilities {
        PlatformCapabilities.forOS(current)
    }
}
