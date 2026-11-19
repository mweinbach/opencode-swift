#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Injectable environment variable & directory provider for deterministic cross-platform testing.
public protocol EnvironmentProviding: Sendable {
    func variable(_ name: String) -> String?
    var homeDirectory: String? { get }
    var temporaryDirectory: String { get }
}

public struct DictionaryEnvironment: EnvironmentProviding, Equatable, Sendable {
    public let variables: [String: String]
    public let homeDirectory: String?
    public let temporaryDirectory: String

    public init(
        variables: [String: String] = [:],
        homeDirectory: String? = nil,
        temporaryDirectory: String = "/tmp"
    ) {
        self.variables = variables
        self.homeDirectory = homeDirectory
        self.temporaryDirectory = temporaryDirectory
    }

    public func variable(_ name: String) -> String? {
        variables[name]
    }
}

public struct SystemEnvironment: EnvironmentProviding, Sendable {
    public static let shared = SystemEnvironment()

    public init() {}

    public func variable(_ name: String) -> String? {
        #if os(WASI)
        return nil
        #else
        return ProcessInfo.processInfo.environment[name]
        #endif
    }

    public var homeDirectory: String? {
        if let override = variable("OPENCODE_TEST_HOME"), !override.isEmpty {
            return override
        }
        #if os(Windows)
        if let profile = variable("USERPROFILE"), !profile.isEmpty {
            return profile
        }
        if let drive = variable("HOMEDRIVE"), let path = variable("HOMEPATH") {
            return drive + path
        }
        return nil
        #elseif os(WASI)
        return variable("HOME")
        #else
        if let home = variable("HOME"), !home.isEmpty {
            return home
        }
        return nil
        #endif
    }

    public var temporaryDirectory: String {
        #if os(Windows)
        if let tmp = variable("TEMP") ?? variable("TMP"), !tmp.isEmpty {
            return tmp
        }
        return "C:\\Windows\\Temp"
        #elseif os(WASI)
        return variable("TMPDIR") ?? "/tmp"
        #else
        if let tmp = variable("TMPDIR"), !tmp.isEmpty {
            return tmp
        }
        return "/tmp"
        #endif
    }
}
