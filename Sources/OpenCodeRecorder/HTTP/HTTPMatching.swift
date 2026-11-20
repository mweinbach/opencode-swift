import OpenCodePlatform
import OpenCodeUtil

/// Produces a deterministic canonical JSON string representation of a `RequestSnapshot`
/// with recursively sorted header and JSON body keys.
// parity: http-recorder/src/http/matching.ts#canonicalSnapshot [status=implemented hash=9c45124aef90]
public func canonicalSnapshot(_ snapshot: RequestSnapshot) -> String {
    let bodyValue: PureJSONValue
    if let parsed = decodeJson(snapshot.body) {
        bodyValue = canonicalizeJson(parsed)
    } else {
        bodyValue = .string(snapshot.body)
    }
    let headersValue = canonicalizeJson(SchemaJSONHelper.encodeStringMap(snapshot.headers))
    let payload: PureJSONValue = .object([
        ("method", .string(snapshot.method)),
        ("url", .string(snapshot.url)),
        ("headers", headersValue),
        ("body", bodyValue),
    ])
    return PureJSON.stringifyCompact(payload)
}

/// Default HTTP request matcher comparing canonicalized method, URL, headers, and JSON/text body.
// parity: http-recorder/src/http/matching.ts#defaultMatcher [status=implemented hash=739c162bfe7e]
public func defaultMatcher(_ incoming: RequestSnapshot, _ recorded: RequestSnapshot) -> Bool {
    canonicalSnapshot(incoming) == canonicalSnapshot(recorded)
}

private func isSameJSONScalar(_ expected: PureJSONValue?, _ received: PureJSONValue?) -> Bool {
    switch (expected, received) {
    case (.none, .none):
        return true
    case (.some(.null), .some(.null)):
        return true
    case let (.some(.bool(a)), .some(.bool(b))):
        return a == b
    case let (.some(.number(a)), .some(.number(b))):
        return a == b && a.sign == b.sign
    case let (.some(.string(a)), .some(.string(b))):
        return a == b
    default:
        return false
    }
}

private func objectDictionary(_ entries: [(String, PureJSONValue)]) -> [String: PureJSONValue] {
    var dict: [String: PureJSONValue] = [:]
    dict.reserveCapacity(entries.count)
    for (key, value) in entries {
        dict[key] = value
    }
    return dict
}

private func valueDiffs(
    expected: PureJSONValue?,
    received: PureJSONValue?,
    base: String = "$",
    limit: Int = 8,
    environment: any EnvironmentProviding = SystemEnvironment.shared
) -> [String] {
    if isSameJSONScalar(expected, received) {
        return []
    }
    if case .some(.object(let expEntries)) = expected,
       case .some(.object(let recEntries)) = received {
        let expDict = objectDictionary(expEntries)
        let recDict = objectDictionary(recEntries)
        let allKeys = Set(expDict.keys).union(recDict.keys).sorted(by: jsStringLessThan)
        var diffs: [String] = []
        for key in allKeys {
            let childDiffs = valueDiffs(
                expected: expDict[key],
                received: recDict[key],
                base: "\(base).\(key)",
                limit: limit,
                environment: environment
            )
            diffs.append(contentsOf: childDiffs)
            if diffs.count >= limit {
                return Array(diffs.prefix(limit))
            }
        }
        return diffs
    }
    if case .some(.array(let expItems)) = expected,
       case .some(.array(let recItems)) = received {
        let count = max(expItems.count, recItems.count)
        var diffs: [String] = []
        for index in 0..<count {
            let expVal = index < expItems.count ? expItems[index] : nil
            let recVal = index < recItems.count ? recItems[index] : nil
            let childDiffs = valueDiffs(
                expected: expVal,
                received: recVal,
                base: "\(base)[\(index)]",
                limit: limit,
                environment: environment
            )
            diffs.append(contentsOf: childDiffs)
            if diffs.count >= limit {
                return Array(diffs.prefix(limit))
            }
        }
        return diffs
    }
    let expText = safeText(expected, environment: environment)
    let recText = safeText(received, environment: environment)
    return ["\(base) expected \(expText), received \(recText)"]
}

private func headerDiffs(
    expected: [String: String],
    received: [String: String],
    environment: any EnvironmentProviding
) -> [String] {
    let allKeys = Set(expected.keys).union(received.keys).sorted(by: jsStringLessThan)
    var diffs: [String] = []
    for key in allKeys {
        let expVal = expected[key]
        let recVal = received[key]
        if expVal == recVal { continue }
        if expVal == nil {
            diffs.append("  \(key) unexpected \(safeText(recVal, environment: environment))")
        } else if recVal == nil {
            diffs.append("  \(key) missing expected \(safeText(expVal, environment: environment))")
        } else {
            let eText = safeText(expVal, environment: environment)
            let rText = safeText(recVal, environment: environment)
            diffs.append("  \(key) expected \(eText), received \(rText)")
        }
    }
    return diffs
}

/// Computes human-readable, secret-scrubbed diff lines between expected and received HTTP request snapshots.
// parity: http-recorder/src/http/matching.ts#requestDiff [status=implemented hash=8b5c7cc92fb0]
public func requestDiff(
    expected: RequestSnapshot,
    received: RequestSnapshot,
    environment: any EnvironmentProviding = SystemEnvironment.shared
) -> [String] {
    var lines: [String] = []
    if expected.method != received.method {
        lines.append("method:")
        lines.append("  expected \(expected.method), received \(received.method)")
    }
    if expected.url != received.url {
        lines.append("url:")
        lines.append("  expected \(expected.url)")
        lines.append("  received \(received.url)")
    }
    let headers = headerDiffs(expected: expected.headers, received: received.headers, environment: environment)
    if !headers.isEmpty {
        lines.append("headers:")
        lines.append(contentsOf: headers.prefix(8))
    }
    let expectedBody = jsonBody(expected.body)
    let receivedBody = jsonBody(received.body)
    let bodyLines: [String]
    if let expectedBody, let receivedBody {
        bodyLines = valueDiffs(
            expected: expectedBody,
            received: receivedBody,
            environment: environment
        ).map { "  \($0)" }
    } else if expected.body == received.body {
        bodyLines = []
    } else {
        let expText = safeText(expected.body, environment: environment)
        let recText = safeText(received.body, environment: environment)
        bodyLines = ["  expected \(expText), received \(recText)"]
    }
    if !bodyLines.isEmpty {
        lines.append("body:")
        lines.append(contentsOf: bodyLines)
    }
    return lines
}

/// Outcome of searching recorded HTTP interactions for a matching request.
public enum MatchSelection: Equatable, Hashable, Sendable {
    case matched(index: Int)
    case unmatched(detail: String)
}

/// Selects the first unused recorded interaction matching `incoming`, or produces a diff against the first unused interaction.
// parity: http-recorder/src/http/matching.ts#selectFirstMatching [status=implemented hash=50f1d12aa1ce]
public func selectFirstMatching(
    interactions: [HttpInteraction],
    incoming: RequestSnapshot,
    match: RequestMatcher = defaultMatcher,
    used: Set<Int> = [],
    environment: any EnvironmentProviding = SystemEnvironment.shared
) -> MatchSelection {
    var firstUnused: HttpInteraction?
    for index in 0..<interactions.count {
        if used.contains(index) { continue }
        let interaction = interactions[index]
        if firstUnused == nil {
            firstUnused = interaction
        }
        if match(incoming, interaction.request) {
            return .matched(index: index)
        }
    }
    guard let firstUnused else {
        return .unmatched(detail: "all \(interactions.count) recorded interactions have already been consumed")
    }
    let detail = requestDiff(
        expected: firstUnused.request,
        received: incoming,
        environment: environment
    ).joined(separator: "\n")
    return .unmatched(detail: detail)
}
