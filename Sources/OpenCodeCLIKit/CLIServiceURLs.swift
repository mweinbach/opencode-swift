#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeClient
import OpenCodeUtil

/// Server URL validation, lookup, and loopback detection (`packages/cli/src/services/service-urls.ts`).
public enum CLIServiceURLs {
    /// Validates and normalizes an HTTP(S) server URL without credentials, query parameters, or fragment.
    // parity: cli/src/services/service-urls.ts#parseServerURL [status=implemented hash=464cdeab410c]
    public static func parseServerURL(_ value: String) throws -> String {
        guard !value.contains("?"),
              !value.contains("#"),
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw CLIError("Expected an HTTP(S) server URL without credentials, query parameters, or a fragment")
        }
        components.scheme = scheme
        if host.allSatisfy(\.isASCII) {
            components.host = host.lowercased()
        }
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        guard let normalizedURL = components.url?.absoluteString else {
            throw CLIError("Expected an HTTP(S) server URL without credentials, query parameters, or a fragment")
        }
        var result = normalizedURL
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    /// Formats `components.host` like WHATWG `URL.hostname` (wrapping bare IPv6 addresses in `[...]`).
    public static func whatwgHostname(from components: URLComponents) -> String? {
        guard let host = components.host, !host.isEmpty else { return nil }
        let lowered = host.allSatisfy(\.isASCII) ? host.lowercased() : host
        if lowered.contains(":"), !lowered.hasPrefix("[") {
            return "[\(lowered)]"
        }
        return lowered
    }

    /// Returns `[url]` when an explicit override is provided, otherwise queries `client.server.info().urls`.
    // parity: cli/src/services/service-urls.ts#serverURLs [status=implemented hash=20763d11fbef]
    public static func serverURLs(
        _ infoURLs: @Sendable () async throws -> [String],
        url: String? = nil
    ) async throws -> [String] {
        if let url {
            return [url]
        }
        return try await infoURLs()
    }

    /// Convenience overload reading `client.server.info().urls` when `url` is `nil`.
    public static func serverURLs(
        client: OpenCodeClient,
        url: String? = nil
    ) async throws -> [String] {
        try await serverURLs({ try await client.server.info().urls }, url: url)
    }

    /// Whether `hostname` (in WHATWG `URL.hostname` form) refers to the local loopback interface.
    // parity: cli/src/services/service-urls.ts#isLoopback [status=implemented hash=c7cb483690f8]
    public static func isLoopback(_ hostname: String) -> Bool {
        hostname == "localhost"
            || hostname.hasSuffix(".localhost")
            || hostname.hasPrefix("127.")
            || hostname == "[::1]"
    }
}
