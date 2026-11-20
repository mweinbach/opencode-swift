#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodePlatform
import OpenCodeUtil

/// A potential leaked secret detected inside a cassette before persistence.
// parity: http-recorder/src/redaction/secrets.ts#SecretFinding [status=implemented hash=9098f3fe1611]
public struct SecretFinding: Equatable, Hashable, Sendable, Codable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

/// Runtime schema for `SecretFinding`.
// parity: http-recorder/src/redaction/secrets.ts#SecretFindingSchema [status=implemented hash=0a440363b0fe]
public let SecretFindingSchema = RecorderSchema<SecretFinding>(
    name: "SecretFinding",
    decode: { value in
        let obj = try SchemaJSONHelper.objectMap(value, schema: "SecretFinding")
        return SecretFinding(
            path: try SchemaJSONHelper.requiredString(obj, key: "path", schema: "SecretFinding"),
            reason: try SchemaJSONHelper.requiredString(obj, key: "reason", schema: "SecretFinding")
        )
    },
    encode: { finding in
        .object([
            ("path", .string(finding.path)),
            ("reason", .string(finding.reason)),
        ])
    }
)

private struct SecretPattern: Sendable {
    let label: String
    let matches: @Sendable (String) -> Bool
}

private let secretPatterns: [SecretPattern] = [
    SecretPattern(label: "bearer token") { text in
        text.firstMatch(of: #/\bBearer\s+[A-Za-z0-9._~+/=-]{16,}\b/#.ignoresCase().asciiOnlyWordCharacters()) != nil
    },
    SecretPattern(label: "API key") { text in
        text.firstMatch(of: #/\bsk-[A-Za-z0-9][A-Za-z0-9_-]{20,}\b/#.asciiOnlyWordCharacters()) != nil
    },
    SecretPattern(label: "Anthropic API key") { text in
        text.firstMatch(of: #/\bsk-ant-[A-Za-z0-9_-]{20,}\b/#.asciiOnlyWordCharacters()) != nil
    },
    SecretPattern(label: "Google API key") { text in
        text.firstMatch(of: #/\bAIza[0-9A-Za-z_-]{20,}\b/#.asciiOnlyWordCharacters()) != nil
    },
    SecretPattern(label: "AWS access key") { text in
        text.firstMatch(of: #/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/#.asciiOnlyWordCharacters()) != nil
    },
    SecretPattern(label: "GitHub token") { text in
        text.firstMatch(of: #/\bgh[pousr]_[A-Za-z0-9_]{20,}\b/#.asciiOnlyWordCharacters()) != nil
    },
    SecretPattern(label: "private key") { text in
        text.firstMatch(of: #/-----BEGIN [A-Z ]*PRIVATE KEY-----/#) != nil
    },
]

private let safeEnvValues: Set<String> = ["fixture", "test", "test-key"]

private func isSecretEnvName(_ name: String) -> Bool {
    name.firstMatch(
        of: #/(?:API|AUTH|BEARER|CREDENTIAL|KEY|PASSWORD|SECRET|TOKEN)/#.ignoresCase()
    ) != nil
}

internal func allEnvironmentVariables(_ environment: any EnvironmentProviding) -> [String: String] {
    if let dict = environment as? DictionaryEnvironment {
        return dict.variables
    }
    #if os(WASI)
    return [:]
    #else
    return ProcessInfo.processInfo.environment
    #endif
}

private func envSecrets(from environment: any EnvironmentProviding) -> [(name: String, value: String)] {
    let vars = allEnvironmentVariables(environment)
    return vars.keys.sorted(by: jsStringLessThan).compactMap { name -> (name: String, value: String)? in
        guard let value = vars[name], !value.isEmpty else { return nil }
        guard isSecretEnvName(name) else { return nil }
        guard value.utf16.count >= 12 else { return nil }
        guard !safeEnvValues.contains(value.lowercased()) else { return nil }
        return (name: name, value: value)
    }
}

private func pathFor(_ base: String, _ key: String) -> String {
    base.isEmpty ? key : "\(base).\(key)"
}

private func stringEntries(_ value: PureJSONValue, base: String = "") -> [(path: String, value: String)] {
    switch value {
    case .string(let s):
        return [(path: base, value: s)]
    case .array(let items):
        var out: [(path: String, value: String)] = []
        for (index, item) in items.enumerated() {
            out.append(contentsOf: stringEntries(item, base: "\(base)[\(index)]"))
        }
        return out
    case .object(let entries):
        var out: [(path: String, value: String)] = []
        for (key, child) in entries {
            out.append(contentsOf: stringEntries(child, base: pathFor(base, key)))
        }
        return out
    case .null, .bool, .number:
        return []
    }
}

/// Scans a JSON value tree for credential patterns and credential-like environment variable values.
// parity: http-recorder/src/redaction/secrets.ts#secretFindings [status=implemented hash=13416fee356a]
public func secretFindings(
    _ value: PureJSONValue,
    environment: any EnvironmentProviding = SystemEnvironment.shared
) -> [SecretFinding] {
    let environmentList = envSecrets(from: environment)
    var findings: [SecretFinding] = []
    for entry in stringEntries(value) {
        for pattern in secretPatterns where pattern.matches(entry.value) {
            findings.append(SecretFinding(path: entry.path, reason: pattern.label))
        }
        for item in environmentList where entry.value.contains(item.value) {
            findings.append(SecretFinding(path: entry.path, reason: "environment secret \(item.name)"))
        }
    }
    return findings
}

/// Scans a `JsonValue` tree for potential secrets.
public func secretFindings(
    _ value: JsonValue,
    environment: any EnvironmentProviding = SystemEnvironment.shared
) -> [SecretFinding] {
    secretFindings(value.toPureJSON(), environment: environment)
}

/// Scans a single string for potential secrets.
public func secretFindings(
    _ text: String,
    environment: any EnvironmentProviding = SystemEnvironment.shared
) -> [SecretFinding] {
    secretFindings(PureJSONValue.string(text), environment: environment)
}

/// Scans a `Cassette` for potential secrets.
public func secretFindings(
    _ cassette: Cassette,
    environment: any EnvironmentProviding = SystemEnvironment.shared
) -> [SecretFinding] {
    secretFindings(encodeCassette(cassette), environment: environment)
}

/// Scans an `Interaction` for potential secrets.
public func secretFindings(
    _ interaction: Interaction,
    environment: any EnvironmentProviding = SystemEnvironment.shared
) -> [SecretFinding] {
    secretFindings(InteractionSchema.encode(interaction), environment: environment)
}

/// Scans `CassetteMetadata` for potential secrets.
public func secretFindings(
    _ metadata: CassetteMetadata,
    environment: any EnvironmentProviding = SystemEnvironment.shared
) -> [SecretFinding] {
    secretFindings(CassetteMetadataSchema.encode(metadata), environment: environment)
}
