#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeUtil

/// Sentinel replacement text written in place of redacted credentials.
// parity: http-recorder/src/redaction/redactor.ts#REDACTED [status=implemented hash=c1486d8f010f]
public let REDACTED = "[REDACTED]"

private let percentEncodedRedacted = "%5BREDACTED%5D"

private let defaultRedactHeaders: [String] = [
    "authorization",
    "cookie",
    "proxy-authorization",
    "set-cookie",
    "x-api-key",
    "x-amz-security-token",
    "x-goog-api-key",
]

private let defaultRedactQuery: [String] = [
    "access_token",
    "api-key",
    "api_key",
    "apikey",
    "code",
    "key",
    "signature",
    "sig",
    "token",
    "x-amz-credential",
    "x-amz-security-token",
    "x-amz-signature",
]

private let defaultRequestHeaders: [String] = [
    "content-type",
    "accept",
    "openai-beta",
]

private let defaultResponseHeaders: [String] = [
    "content-type",
]

private let defaultRedactJsonFields: [String] = [
    "access_token",
    "api_key",
    "apikey",
    "client_secret",
    "password",
    "refresh_token",
    "secret",
    "token",
]

private func redactionSet(_ values: [String]?, defaults: [String]) -> Set<String> {
    var set = Set(defaults.map { $0.lowercased() })
    if let values {
        for value in values {
            set.insert(value.lowercased())
        }
    }
    return set
}

private func decodeQueryComponent(_ raw: String) -> String {
    let plusAsSpace = raw.replacing("+", with: " ")
    return plusAsSpace.removingPercentEncoding ?? plusAsSpace
}

private func isValidScheme(_ scheme: String) -> Bool {
    guard let first = scheme.utf8.first else { return false }
    let isAlpha = (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A)
    guard isAlpha else { return false }
    for b in scheme.utf8 {
        let ok = (b >= 0x41 && b <= 0x5A)
            || (b >= 0x61 && b <= 0x7A)
            || (b >= 0x30 && b <= 0x39)
            || b == UInt8(ascii: "+")
            || b == UInt8(ascii: "-")
            || b == UInt8(ascii: ".")
        if !ok { return false }
    }
    return true
}

/// Redacts embedded URL credentials and sensitive query parameters, then applies an optional custom transform.
// parity: http-recorder/src/redaction/redactor.ts#redactUrl [status=implemented hash=d949a850b720]
public func redactUrl(
    _ raw: String,
    query: [String]? = nil,
    transform: (@Sendable (String) -> String)? = nil
) -> String {
    guard var components = URLComponents(string: raw),
          let scheme = components.scheme,
          isValidScheme(scheme) else {
        return transform?(raw) ?? raw
    }

    if let user = components.percentEncodedUser, !user.isEmpty {
        components.percentEncodedUser = percentEncodedRedacted
    }
    if let password = components.percentEncodedPassword, !password.isEmpty {
        components.percentEncodedPassword = percentEncodedRedacted
    }

    if let rawQuery = components.percentEncodedQuery, !rawQuery.isEmpty {
        let redacted = redactionSet(query, defaults: defaultRedactQuery)
        let parts = rawQuery.split(separator: "&", omittingEmptySubsequences: false)
        var emittedRedactedKeys: Set<String> = []
        var rebuilt: [String] = []
        rebuilt.reserveCapacity(parts.count)

        for part in parts {
            let segment = String(part)
            let rawKey: String
            if let eq = segment.firstIndex(of: "=") {
                rawKey = String(segment[..<eq])
            } else {
                rawKey = segment
            }
            let decodedKey = decodeQueryComponent(rawKey)
            if redacted.contains(decodedKey.lowercased()) {
                if emittedRedactedKeys.insert(decodedKey).inserted {
                    rebuilt.append("\(rawKey)=\(percentEncodedRedacted)")
                }
            } else {
                rebuilt.append(segment)
            }
        }
        components.percentEncodedQuery = rebuilt.joined(separator: "&")
    }

    let output = components.string ?? raw
    return transform?(output) ?? output
}

/// Filters headers to the allow-list (lowercased) and replaces sensitive values with `[REDACTED]`.
// parity: http-recorder/src/redaction/redactor.ts#redactHeaders [status=implemented hash=db224324b59a]
public func redactHeaders(
    _ headers: [String: String],
    allow: [String],
    redact: [String]? = nil
) -> [String: String] {
    let allowed = Set(allow.map { $0.lowercased() })
    let redacted = redactionSet(redact, defaults: defaultRedactHeaders)
    var out: [String: String] = [:]
    for key in headers.keys.sorted(by: jsStringLessThan) {
        let lower = key.lowercased()
        guard allowed.contains(lower) else { continue }
        let value = headers[key]!
        out[lower] = redacted.contains(lower) ? REDACTED : value
    }
    return out
}

/// Partial redactor hook usable with `composeRedactors` / `Redactor.compose`.
public struct PartialRedactor: Sendable {
    public let request: (@Sendable (RequestSnapshot) -> RequestSnapshot)?
    public let response: (@Sendable (ResponseSnapshot) -> ResponseSnapshot)?

    public init(
        request: (@Sendable (RequestSnapshot) -> RequestSnapshot)? = nil,
        response: (@Sendable (ResponseSnapshot) -> ResponseSnapshot)? = nil
    ) {
        self.request = request
        self.response = response
    }
}

/// Request and response snapshot redactor matching `packages/http-recorder/src/redaction/redactor.ts#Redactor`.
// parity: http-recorder/src/redaction/redactor.ts#Redactor [status=implemented hash=420f006d6727]
public struct Redactor: Sendable {
    public let request: @Sendable (RequestSnapshot) -> RequestSnapshot
    public let response: @Sendable (ResponseSnapshot) -> ResponseSnapshot

    public init(
        request: @escaping @Sendable (RequestSnapshot) -> RequestSnapshot,
        response: @escaping @Sendable (ResponseSnapshot) -> ResponseSnapshot
    ) {
        self.request = request
        self.response = response
    }

    public func asPartial() -> PartialRedactor {
        PartialRedactor(request: request, response: response)
    }

    /// Composes zero or more partial redactors left-to-right.
    // parity: http-recorder/src/redaction/redactor.ts#compose [status=implemented hash=294335208cf6]
    public static func compose(_ redactors: PartialRedactor...) -> Redactor {
        compose(redactors)
    }

    /// Composes an array of partial redactors left-to-right.
    public static func compose(_ redactors: [PartialRedactor]) -> Redactor {
        let requestFns = redactors.compactMap(\.request)
        let responseFns = redactors.compactMap(\.response)

        let reqFn: @Sendable (RequestSnapshot) -> RequestSnapshot
        if requestFns.isEmpty {
            reqFn = { $0 }
        } else {
            reqFn = { snapshot in requestFns.reduce(snapshot) { value, fn in fn(value) } }
        }

        let resFn: @Sendable (ResponseSnapshot) -> ResponseSnapshot
        if responseFns.isEmpty {
            resFn = { $0 }
        } else {
            resFn = { snapshot in responseFns.reduce(snapshot) { value, fn in fn(value) } }
        }

        return Redactor(request: reqFn, response: resFn)
    }

    /// Builds a redactor with secure defaults extended by `options`.
    // parity: http-recorder/src/redaction/redactor.ts#make [status=implemented hash=073f7e9107c0]
    public static func make(_ options: RedactOptions = RedactOptions()) -> Redactor {
        let fields = Set((defaultRedactJsonFields + (options.jsonFields ?? [])).map(normalizeField))
        let reqAllow = defaultRequestHeaders + (options.allowRequestHeaders ?? []) + (options.headers ?? [])
        let resAllow = defaultResponseHeaders + (options.allowResponseHeaders ?? []) + (options.headers ?? [])
        let customHeaders = options.headers
        let queryParams = options.queryParameters
        let urlTransform = options.url
        let bodyTransform = options.body

        return compose(
            PartialRedactor(request: { snapshot in
                RequestSnapshot(
                    method: snapshot.method,
                    url: snapshot.url,
                    headers: redactHeaders(snapshot.headers, allow: reqAllow, redact: customHeaders),
                    body: snapshot.body
                )
            }),
            PartialRedactor(response: { snapshot in
                ResponseSnapshot(
                    status: snapshot.status,
                    headers: redactHeaders(snapshot.headers, allow: resAllow, redact: customHeaders),
                    body: snapshot.body,
                    bodyEncoding: snapshot.bodyEncoding
                )
            }),
            PartialRedactor(request: { snapshot in
                RequestSnapshot(
                    method: snapshot.method,
                    url: redactUrl(snapshot.url, query: queryParams, transform: urlTransform),
                    headers: snapshot.headers,
                    body: snapshot.body
                )
            }),
            PartialRedactor(
                request: { snapshot in
                    RequestSnapshot(
                        method: snapshot.method,
                        url: snapshot.url,
                        headers: snapshot.headers,
                        body: redactBody(snapshot.body, fields: fields, transform: bodyTransform)
                    )
                },
                response: { snapshot in
                    ResponseSnapshot(
                        status: snapshot.status,
                        headers: snapshot.headers,
                        body: redactBody(snapshot.body, fields: fields, transform: bodyTransform),
                        bodyEncoding: snapshot.bodyEncoding
                    )
                }
            )
        )
    }
}

private func normalizeField(_ field: String) -> String {
    var out: [UInt8] = []
    out.reserveCapacity(field.utf8.count)
    for byte in field.utf8 {
        if byte >= 0x41 && byte <= 0x5A {
            out.append(byte + 32)
        } else if (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) {
            out.append(byte)
        }
    }
    return String(decoding: out, as: UTF8.self)
}

private func redactJsonFields(_ value: PureJSONValue, fields: Set<String>) -> (value: PureJSONValue, changed: Bool) {
    switch value {
    case .array(let items):
        var changed = false
        var out: [PureJSONValue] = []
        out.reserveCapacity(items.count)
        for item in items {
            let result = redactJsonFields(item, fields: fields)
            if result.changed { changed = true }
            out.append(result.value)
        }
        return (.array(out), changed)
    case .object(let entries):
        var changed = false
        var out: [(String, PureJSONValue)] = []
        out.reserveCapacity(entries.count)
        for (key, child) in entries {
            if fields.contains(normalizeField(key)) {
                if child != .string(REDACTED) {
                    changed = true
                }
                out.append((key, .string(REDACTED)))
            } else {
                let result = redactJsonFields(child, fields: fields)
                if result.changed { changed = true }
                out.append((key, result.value))
            }
        }
        return (.object(out), changed)
    case .null, .bool, .number, .string:
        return (value, false)
    }
}

private func redactBody(
    _ value: String,
    fields: Set<String>,
    transform: (@Sendable (String) -> String)?
) -> String {
    let redacted: String
    if let parsed = PureJSON.parse(value) {
        let result = redactJsonFields(parsed, fields: fields)
        redacted = result.changed ? PureJSON.stringifyCompact(result.value) : value
    } else {
        redacted = value
    }
    return transform?(redacted) ?? redacted
}
