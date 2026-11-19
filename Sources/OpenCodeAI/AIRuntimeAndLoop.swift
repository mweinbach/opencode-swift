#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Core portable utilities: bytes, JSON codecs, media-type magic-byte sniffing, provider error
/// code extraction, record narrowing, and UTF-16 lone surrogate sanitization.
///
/// Ports `packages/ai/src/utils/{bytes,json,media-type,provider-codes,record,sanitize}.ts`.
public enum AIUtils {

    // MARK: - src/utils/bytes.ts

    // parity: ai/src/utils/bytes.ts#concatBytes [status=implemented hash=33698e16ea27]
    public static func concatBytes(_ chunks: [[UInt8]]) -> [UInt8] {
        if chunks.count == 1 { return chunks[0] }
        let total = chunks.reduce(0) { $0 + $1.count }
        var out: [UInt8] = []
        out.reserveCapacity(total)
        for chunk in chunks {
            out.append(contentsOf: chunk)
        }
        return out
    }

    // MARK: - src/utils/json.ts

    // parity: ai/src/utils/json.ts#Json [status=adapted hash=3ad4b5e09e3a]
    public struct Json: Sendable {
        public init() {}

        public func decode(_ text: String) throws -> JSONValue {
            try AIUtils.decodeJson(text)
        }

        public func encode(_ value: JSONValue) throws -> String {
            try AIUtils.encodeJson(value)
        }
    }

    // parity: ai/src/utils/json.ts#decodeJson [status=implemented hash=13051b6f3275]
    public static func decodeJson(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    // parity: ai/src/utils/json.ts#encodeJson [status=implemented hash=2ba304bcad39]
    public static func encodeJson(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - src/utils/media-type.ts

    private static func ascii(_ bytes: [UInt8], _ start: Int, _ end: Int) -> String {
        guard start >= 0, end <= bytes.count, start <= end else { return "" }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private static func startsWith(_ bytes: [UInt8], _ prefix: [UInt8]) -> Bool {
        guard bytes.count >= prefix.count else { return false }
        for i in 0..<prefix.count {
            if bytes[i] != prefix[i] { return false }
        }
        return true
    }

    /// Sniff a media type from leading magic bytes.
    // parity: ai/src/utils/media-type.ts#detectMediaType [status=implemented hash=5bbcf9b1fbfa]
    public static func detectMediaType(_ bytes: [UInt8]) -> String? {
        if startsWith(bytes, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if startsWith(bytes, [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if startsWith(bytes, [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if bytes.count >= 12 && ascii(bytes, 0, 4) == "RIFF" {
            let riffType = ascii(bytes, 8, 12)
            if riffType == "WEBP" { return "image/webp" }
            if riffType == "WAVE" { return "audio/wav" }
        }
        if startsWith(bytes, [0x25, 0x50, 0x44, 0x46]) { return "application/pdf" }
        if bytes.count >= 12 && ascii(bytes, 4, 8) == "ftyp" {
            let brand = ascii(bytes, 8, 12)
            let rawBoxSize = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
            let boxEnd = min(Int(rawBoxSize), bytes.count)
            var compatible: [String] = []
            if boxEnd >= 20 {
                let count = (boxEnd - 16) / 4
                compatible.reserveCapacity(count)
                for idx in 0..<count {
                    compatible.append(ascii(bytes, 16 + idx * 4, 20 + idx * 4))
                }
            }
            let generic = brand == "mif1" || brand == "msf1"
            if brand == "avif" || brand == "avis" || (generic && (compatible.contains("avif") || compatible.contains("avis"))) {
                return "image/avif"
            }
            if generic || brand == "heic" || brand == "heix" || brand == "hevc" || brand == "hevx" {
                return "image/heic"
            }
            if brand == "qt  " { return "video/quicktime" }
            if brand == "M4A " { return "audio/mp4" }
            return "video/mp4"
        }
        if startsWith(bytes, [0x1A, 0x45, 0xDF, 0xA3]) { return "video/webm" }
        if startsWith(bytes, [0x49, 0x44, 0x33]) { return "audio/mpeg" }
        if bytes.count >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0 {
            return (bytes[1] & 0x06) == 0 ? "audio/aac" : "audio/mpeg"
        }
        if startsWith(bytes, [0x4F, 0x67, 0x67, 0x53]) { return "audio/ogg" }
        if startsWith(bytes, [0x66, 0x4C, 0x61, 0x43]) { return "audio/flac" }
        return nil
    }

    private static let extensionTable: [(ext: String, mime: String)] = [
        ("png", "image/png"),
        ("jpg", "image/jpeg"),
        ("jpeg", "image/jpeg"),
        ("gif", "image/gif"),
        ("webp", "image/webp"),
        ("avif", "image/avif"),
        ("heic", "image/heic"),
        ("heif", "image/heif"),
        ("pdf", "application/pdf"),
        ("mp4", "video/mp4"),
        ("mov", "video/quicktime"),
        ("webm", "video/webm"),
        ("mp3", "audio/mpeg"),
        ("m4a", "audio/mp4"),
        ("wav", "audio/wav"),
        ("ogg", "audio/ogg"),
        ("flac", "audio/flac"),
        ("aac", "audio/aac"),
        ("txt", "text/plain"),
        ("md", "text/markdown"),
        ("csv", "text/csv"),
    ]

    private static let extensionsByExt: [String: String] = Dictionary(uniqueKeysWithValues: extensionTable)

    private static let extensionAliases: [String: String] = [
        "audio/mp3": "mp3",
        "audio/m4a": "m4a",
        "audio/x-m4a": "m4a",
        "audio/webm": "webm",
        "audio/wave": "wav",
        "audio/x-wav": "wav",
        "audio/x-flac": "flac",
    ]

    private static func extensionMediaType(_ path: String) -> String? {
        guard let dot = path.lastIndex(of: ".") else { return nil }
        let ext = String(path[path.index(after: dot)...]).lowercased()
        return extensionsByExt[ext]
    }

    /// Media type of a file's contents: sniffed magic bytes, then the path's extension.
    // parity: ai/src/utils/media-type.ts#fileMediaType [status=implemented hash=640f9c01d682]
    public static func fileMediaType(_ bytes: [UInt8], path: String) -> String? {
        detectMediaType(bytes) ?? extensionMediaType(path)
    }

    // parity: ai/src/utils/media-type.ts#mediaTypeExtension [status=implemented hash=4a214067fd35]
    public static func mediaTypeExtension(_ mediaType: String) -> String? {
        let base = mediaType.split(separator: ";", maxSplits: 1).first.map(String.init) ?? mediaType
        let normalized = base.trimmingCharacters(in: .whitespaces).lowercased()
        if let alias = extensionAliases[normalized] { return alias }
        return extensionTable.first { $0.mime == normalized }?.ext
    }

    // MARK: - src/utils/provider-codes.ts

    /// Error codes a provider error body carries, in their original case.
    // parity: ai/src/utils/provider-codes.ts#providerCodes [status=implemented hash=46b2753a78c9]
    public static func providerCodes(_ value: JSONValue?) -> [String] {
        guard let value else { return [] }
        let decoded: JSONValue
        if case .string(let s) = value {
            guard let parsed = try? decodeJson(s) else { return [] }
            decoded = parsed
        } else {
            decoded = value
        }
        guard case .object(let obj) = decoded else { return [] }

        func objectField(_ dict: [String: JSONValue], _ key: String) -> [String: JSONValue]? {
            if case .object(let inner) = dict[key] { return inner }
            return nil
        }
        func stringField(_ dict: [String: JSONValue]?, _ key: String) -> String? {
            if let dict, case .string(let s) = dict[key] { return s }
            return nil
        }

        let error = objectField(obj, "error")
        let inner = error.flatMap { objectField($0, "innererror") }
        let metadata = error.flatMap { objectField($0, "metadata") }
        let response = objectField(obj, "response")
        let responseError = response.flatMap { objectField($0, "error") }
        let exception = objectField(obj, "exception")

        var out: [String] = []
        if let code = stringField(obj, "code") { out.append(code) }
        out.append(contentsOf: awsErrorType(stringField(obj, "__type")))
        out.append(contentsOf: awsErrorType(stringField(obj, "code")))
        if let v = stringField(obj, "error_type") { out.append(v) }
        if let v = stringField(error, "code") { out.append(v) }
        if let v = stringField(error, "type") { out.append(v) }
        if let v = stringField(error, "status") { out.append(v) }
        if let v = stringField(error, "error_type") { out.append(v) }
        if let error, case .array(let details) = error["details"] {
            for detail in details {
                if case .object(let dObj) = detail, case .string(let reason) = dObj["reason"] {
                    out.append(reason)
                }
            }
        }
        if let v = stringField(inner, "code") { out.append(v) }
        if let v = stringField(metadata, "error_type") { out.append(v) }
        if let v = stringField(responseError, "code") { out.append(v) }
        if let v = stringField(response, "error_type") { out.append(v) }
        if let v = stringField(exception, "type") { out.append(v) }
        return out
    }

    public static func providerCodes(_ rawString: String) -> [String] {
        providerCodes(.string(rawString))
    }

    /// Strips AWS restJson1 error namespace (`ns#Name`) and URI suffix (`Name:uri`).
    // parity: ai/src/utils/provider-codes.ts#awsErrorType [status=implemented hash=eefa8bb3a50e]
    public static func awsErrorType(_ value: String?) -> [String] {
        guard let value else { return [] }
        let withoutSuffix: Substring
        if let colon = value.firstIndex(of: ":") {
            withoutSuffix = value[..<colon]
        } else {
            withoutSuffix = value[...]
        }
        if let hash = withoutSuffix.firstIndex(of: "#") {
            return [String(withoutSuffix[withoutSuffix.index(after: hash)...])]
        }
        return [String(withoutSuffix)]
    }

    // MARK: - src/utils/record.ts

    // parity: ai/src/utils/record.ts#isRecord [status=implemented hash=edbb9bd43aff]
    public static func isRecord(_ value: JSONValue?) -> Bool {
        if case .object = value { return true }
        return false
    }

    // MARK: - src/utils/sanitize.ts

    /// Replace lone UTF-16 surrogates with U+FFFD in UTF-16 code-unit sequences, strings, and nested JSON values.
    // parity: ai/src/utils/sanitize.ts#sanitizeSurrogates [status=implemented hash=04fcea9d6eb6]
    public static func sanitizeSurrogates(_ utf16Units: [UInt16]) -> String {
        var sanitized: [UInt16] = []
        sanitized.reserveCapacity(utf16Units.count)
        var i = 0
        while i < utf16Units.count {
            let unit = utf16Units[i]
            if unit >= 0xD800 && unit <= 0xDBFF {
                if i + 1 < utf16Units.count {
                    let next = utf16Units[i + 1]
                    if next >= 0xDC00 && next <= 0xDFFF {
                        sanitized.append(unit)
                        sanitized.append(next)
                        i += 2
                        continue
                    }
                }
                sanitized.append(0xFFFD)
                i += 1
            } else if unit >= 0xDC00 && unit <= 0xDFFF {
                sanitized.append(0xFFFD)
                i += 1
            } else {
                sanitized.append(unit)
                i += 1
            }
        }
        return String(decoding: sanitized, as: UTF16.self)
    }

    public static func sanitizeSurrogates(_ value: String) -> String {
        sanitizeSurrogates(Array(value.utf16))
    }

    public static func sanitizeSurrogates(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s):
            return .string(sanitizeSurrogates(s))
        case .array(let items):
            return .array(items.map(sanitizeSurrogates))
        case .object(let dict):
            var next: [String: JSONValue] = [:]
            next.reserveCapacity(dict.count)
            for (k, v) in dict {
                next[sanitizeSurrogates(k)] = sanitizeSurrogates(v)
            }
            return .object(next)
        default:
            return value
        }
    }
}

/// Provider failure classification: context overflow, payload-too-large, content policy, quota,
/// authentication, rate limit, provider internal, invalid request, and unknown provider errors.
///
/// Ports `packages/ai/src/provider-error.ts`.
public enum AIErrorClassifier {
    private static func matches(_ pattern: String, in text: String, caseInsensitive: Bool = true) -> Bool {
        let opts = caseInsensitive ? "(?i)\(pattern)" : pattern
        guard let regex = try? Regex(opts) else { return false }
        return text.firstMatch(of: regex) != nil
    }

    private static let overflowPatterns: [String] = [
        "prompt is too long",
        "input is too long for (?:the )?(?:requested|selected) model",
        "too large for the model'?s configured input limit",
        "exceeded this model context window limit",
        "exceeds the context window",
        "exceeds (?:the )?(?:model'?s )?maximum context length(?: of [\\d,]+ tokens?|\\s*\\([\\d,]+\\))",
        "input token count.*exceeds the maximum",
        "number of input tokens exceeds maximum length",
        "tokens in request more than max tokens allowed",
        "maximum prompt length is \\d+",
        "reduce the length of the messages",
        "requested input length \\d+ exceeds maximum input length",
        "maximum context length is \\d+ tokens",
        "exceeds (?:the )?maximum allowed input length of [\\d,]+ tokens?",
        "input(?: \\(\\d+ tokens\\))? is longer than the model'?s context length",
        "exceeds the limit of \\d+",
        "exceeds the available context size",
        "greater than the context length",
        "`inputs` tokens \\+ `max_new_tokens` must be <= \\d+",
        "context window exceeds limit",
        "context window exceeded",
        "exceeded model token limit",
        "context[_ ]length[_ ]exceeded",
        "context length is only \\d+ tokens",
        "input length.*exceeds.*context length",
        "prompt (?:too long|exceeds max length|超长)",
        "too large for model with \\d+ maximum context length",
        "prompt has [\\d,]+ tokens?, but the configured context size is [\\d,]+ tokens?",
        "model_context_window_exceeded",
        "range of input length should be",
        "too many tokens",
        "token limit exceeded",
        "request_too_large",
    ]

    private static let payloadPatterns: [String] = [
        "request entity too large",
        "payload too large",
        "request too large",
    ]

    private static let overflowExclusions: [String] = [
        "^(?:throttling error|service unavailable):",
        "rate limit",
        "too many requests",
        "max[_ ]tokens must be less than",
        "too many tokens(?: per day)?, please wait",
    ]

    // parity: ai/src/provider-error.ts#isContextOverflow [status=implemented hash=b095b43d0df3]
    public static func isContextOverflow(_ message: String) -> Bool {
        for exclusion in overflowExclusions where matches(exclusion, in: message) {
            return false
        }
        for pattern in overflowPatterns where matches(pattern, in: message) {
            return true
        }
        return matches("^4(?:00|13)\\s*(?:status code)?\\s*\\(no body\\)", in: message)
    }

    private static func isPayloadTooLarge(_ message: String) -> Bool {
        payloadPatterns.contains { matches($0, in: message) }
    }

    // parity: ai/src/provider-error.ts#isContextOverflowFailure [status=implemented hash=39dd5d67c713]
    public static func isContextOverflowFailure(_ failure: any Error) -> Bool {
        guard let aiError = failure as? AISchema.AIError,
              case .invalidRequest(let req) = aiError.reason
        else {
            return false
        }
        return req.classification == .contextOverflow
    }

    // parity: ai/src/provider-error.ts#isRetryable [status=implemented hash=045e59774354]
    public static func isRetryable(_ error: AISchema.AIError) -> Bool {
        error.isRetryable
    }

    private static let quotaCodes: Set<String> = [
        "insufficient_quota",
        "usage_not_included",
        "billing_error",
        "gousagelimiterror",
        "budgetlimiterror",
        "freeusagelimiterror",
        "creditlimitexceeded",
    ]

    private static let authCodes: Set<String> = [
        "authentication_error",
        "permission_error",
        "permission_denied",
        "api_key_invalid",
    ]

    private static let serverCodes: Set<String> = [
        "api_error",
        "internal_error",
        "internalserverexception",
        "modelstreamerrorexception",
        "overloaded_error",
        "server_error",
        "server_is_overloaded",
        "slow_down",
        "serviceunavailableexception",
    ]

    private static let invalidRequestCodes: Set<String> = [
        "model_not_found",
        "invalid_prompt",
        "invalid_request",
        "invalid_request_error",
        "validationexception",
    ]

    private static let contentPolicyCodes: Set<String> = [
        "content_filter",
        "content_moderation",
        "responsibleaipolicyviolation",
        "content_policy_violation",
        "image_content_policy_violation",
        "refusal",
        "datainspectionfailed",
        "moderation_blocked",
        "safety",
        "prohibited_content",
        "blocklist",
        "image_safety",
        "content_blocked",
    ]

    private static let authText = "incorrect api key provided"
    private static let rateLimitText = "rate increased too quickly|rate[-_\\s]?limit|too[_\\s]?many[_\\s]?requests"
    private static let quotaText =
        "insufficient[-_\\s]?(?:quota|balance)|(?<!token_)quota[-_\\s]?exceeded|budget exceeded|usage limit|(?<!rate[-_\\s]?)limit exhausted|package has expired|plan does not yet include"
    private static let contentPolicyText =
        "violating our usage policy|blocked by content filtering policy|content[-_\\s]?policy|rejected (?:as a result of our|by the) safety system|detected potentially unsafe or sensitive content"
    private static let serverErrorText =
        "\\b(?:try again|(?:please |you can )?retry (?:the |this |your )?request|try (?:the |this |your )?request again|(?:currently |temporarily )?at capacity|overloaded|temporarily unavailable|service[-_\\s]?unavailable|(?:server|internal)[-_\\s]?error|server (?:is )?busy|provider returned (?:an )?error|resource[-_\\s]?exhausted|upstream (?:connect|connection|request)|request buffer limit while retrying upstream)\\b"

    private static func gatewayCodeLabel(_ message: String) -> String? {
        guard let regex = try? Regex("^[^:\\n]+: \\[([A-Za-z0-9_.-]+)\\]"),
              let match = message.firstMatch(of: regex),
              match.output.count >= 2,
              let sub = match.output[1].substring
        else {
            return nil
        }
        return String(sub)
    }

    private static func nonEmptyMessage(_ value: JSONValue?) -> String? {
        guard case .string(let s) = value, s.contains(where: { !$0.isWhitespace }) else { return nil }
        return s
    }

    // parity: ai/src/provider-error.ts#providerErrorMessage [status=implemented hash=39dc977a6c35]
    public static func providerErrorMessage(_ body: String) -> String? {
        guard let parsed = try? AIUtils.decodeJson(body), case .object(let obj) = parsed else {
            return nil
        }
        if case .object(let errorObj) = obj["error"], let msg = nonEmptyMessage(errorObj["message"]) {
            return msg
        }
        if let msg = nonEmptyMessage(obj["error"]) { return msg }
        if let msg = nonEmptyMessage(obj["message"]) { return msg }
        if let msg = nonEmptyMessage(obj["Message"]) { return msg }
        if let msg = nonEmptyMessage(obj["detail"]) { return msg }
        if case .array(let errors) = obj["errors"], let first = errors.first,
           case .object(let firstObj) = first, let msg = nonEmptyMessage(firstObj["message"]) {
            return msg
        }
        return nil
    }

    // parity: ai/src/provider-error.ts#ProviderFailure [status=implemented hash=cb8d98f021ce]
    public struct ProviderFailure: Equatable, Sendable {
        public let message: String
        public let status: Int?
        public let rawBody: String?
        public let data: JSONValue?
        public let http: AISchema.HttpContext?
        public let cause: String?
        public let retryAfterMs: Int?
        public let rateLimit: AISchema.HttpRateLimitDetails?

        public init(
            message: String,
            status: Int? = nil,
            rawBody: String? = nil,
            data: JSONValue? = nil,
            http: AISchema.HttpContext? = nil,
            cause: String? = nil,
            retryAfterMs: Int? = nil,
            rateLimit: AISchema.HttpRateLimitDetails? = nil
        ) {
            self.message = message
            self.status = status
            self.rawBody = rawBody
            self.data = data
            self.http = http
            self.cause = cause
            self.retryAfterMs = retryAfterMs
            self.rateLimit = rateLimit
        }
    }

    // parity: ai/src/provider-error.ts#classifyProviderFailure [status=implemented hash=1b423f4b403f]
    public static func classifyProviderFailure(_ input: ProviderFailure) -> AISchema.AIErrorReason {
        let body = input.rawBody ?? ""
        var rawCodes: [String] = []
        rawCodes.append(contentsOf: AIUtils.providerCodes(input.data))
        rawCodes.append(contentsOf: AIUtils.providerCodes(body))
        rawCodes.append(contentsOf: AIUtils.providerCodes(input.message))
        if let gw = gatewayCodeLabel(input.message) { rawCodes.append(gw) }
        rawCodes.append(contentsOf: AIUtils.awsErrorType(input.http?.headers["x-amzn-errortype"]))
        let codes = rawCodes.map { $0.lowercased() }

        let text = [input.message, body].filter { !$0.isEmpty }.joined(separator: "\n")
        let clientScoped = input.status == nil || (input.status! >= 400 && input.status! < 500)

        if clientScoped && (
            codes.contains("context_length_exceeded") ||
            codes.contains("model_context_window_exceeded") ||
            codes.contains("request_too_large") ||
            (input.status != 429 && !codes.contains("throttlingexception") && isContextOverflow(text))
        ) {
            return .invalidRequest(AISchema.InvalidRequestError(
                message: input.message,
                body: input.rawBody,
                http: input.http,
                cause: input.cause,
                classification: .contextOverflow
            ))
        }

        if input.status == 413 || isPayloadTooLarge(text) {
            return .invalidRequest(AISchema.InvalidRequestError(
                message: input.message,
                body: input.rawBody,
                http: input.http,
                cause: input.cause,
                classification: .payloadTooLarge
            ))
        }

        if codes.contains(where: { contentPolicyCodes.contains($0) }) || (clientScoped && matches(contentPolicyText, in: input.message)) {
            return .contentPolicy(AISchema.ContentPolicyError(
                message: input.message,
                body: input.rawBody,
                http: input.http,
                cause: input.cause
            ))
        }

        if input.status == 402 ||
            codes.contains(where: { quotaCodes.contains($0) }) ||
            (input.status == 429 && matches(quotaText, in: text)) {
            return .quotaExceeded(AISchema.QuotaExceededError(
                message: input.message,
                body: input.rawBody,
                http: input.http,
                cause: input.cause,
                retryAfterMs: input.retryAfterMs
            ))
        }

        if input.status == 401 ||
            input.status == 403 ||
            codes.contains(where: { authCodes.contains($0) }) ||
            (input.status == 400 && matches(authText, in: text)) {
            return .authentication(AISchema.AuthenticationError(
                message: input.message,
                body: input.rawBody,
                http: input.http,
                cause: input.cause
            ))
        }

        if input.status == 429 ||
            codes.contains(where: { $0.contains("rate_limit") || $0 == "too_many_requests" || $0 == "throttlingexception" }) ||
            matches(rateLimitText, in: text) {
            return .rateLimit(AISchema.RateLimitError(
                message: input.message,
                body: input.rawBody,
                http: input.http,
                cause: input.cause,
                retryAfterMs: input.retryAfterMs,
                rateLimit: input.rateLimit
            ))
        }

        if input.status == 408 ||
            input.status == 409 ||
            (input.status != nil && input.status! >= 500) ||
            ((input.status == nil || input.status! < 400) && (
                (!codes.contains(where: { invalidRequestCodes.contains($0) }) && matches(serverErrorText, in: text)) ||
                codes.contains(where: { serverCodes.contains($0) || $0.contains("exhausted") || $0.contains("unavailable") })
            )) {
            return .providerInternal(AISchema.ProviderInternalError(
                message: input.message,
                body: input.rawBody,
                http: input.http,
                cause: input.cause,
                retryAfterMs: input.retryAfterMs
            ))
        }

        if codes.contains(where: { invalidRequestCodes.contains($0) }) {
            return .invalidRequest(AISchema.InvalidRequestError(
                message: input.message,
                body: input.rawBody,
                http: input.http,
                cause: input.cause
            ))
        }

        if let status = input.status, status >= 400 && status < 500 {
            return .invalidRequest(AISchema.InvalidRequestError(
                message: input.message,
                body: input.rawBody,
                http: input.http,
                cause: input.cause
            ))
        }

        return .unknownProvider(AISchema.UnknownProviderError(
            message: input.message,
            body: input.rawBody,
            http: input.http,
            cause: input.cause
        ))
    }
}

/// Provider package entrypoint settings and model factory contracts.
/// Ports `packages/ai/src/provider-package.ts`.
public enum AIPackage {
    // parity: ai/src/provider-package.ts#Settings [status=implemented hash=1a21d9b9a1a7]
    public struct Settings: Equatable, Hashable, Sendable, Codable {
        public let baseURL: String?
        public let headers: [String: String]?
        public let body: [String: JSONValue]?
        public let extra: [String: JSONValue]

        public init(
            baseURL: String? = nil,
            headers: [String: String]? = nil,
            body: [String: JSONValue]? = nil,
            extra: [String: JSONValue] = [:]
        ) {
            self.baseURL = baseURL
            self.headers = headers
            self.body = body
            self.extra = extra
        }
    }

    // parity: ai/src/provider-package.ts#Model [status=implemented hash=8f2f07080469]
    public typealias Model = @Sendable (String, Settings?) -> AISchema.LanguageModel

    // parity: ai/src/provider-package.ts#Definition [status=implemented hash=2453204f8641]
    public struct Definition: Sendable {
        public let model: Model

        public init(model: @escaping Model) {
            self.model = model
        }
    }
}

/// Prompt-cache breakpoint auto-placement policy.
/// Ports `packages/ai/src/cache-policy.ts`.
public enum AICachePolicy {
    private static let autoPolicy = AISchema.CachePolicyObject(tools: true, system: true, messages: .tail(1))
    private static let qwenPolicy = AISchema.CachePolicyObject(tools: nil, system: true, messages: .tail(1))
    private static let nonePolicy = AISchema.CachePolicyObject()
    private static let breakpointCap = 4

    private static let respectsInlineHints: Set<String> = [
        "alibaba-chat",
        "alibaba-messages",
        "anthropic-messages",
        "anthropic-compatible-messages",
        "bedrock-mantle-messages",
        "cloudflare-ai-gateway-messages",
        "google-vertex-messages",
        "meta-messages",
        "minimax-messages",
        "moonshot-messages",
        "vercel-ai-gateway-messages",
        "zai-coding-messages",
        "bedrock-converse",
        "openrouter",
        "digitalocean",
    ]

    private static func isAuto(_ policy: AISchema.CachePolicy?) -> Bool {
        switch policy {
        case nil, .some(.auto):
            return true
        case .some(.none):
            return false
        case .some(.object(let obj)):
            return obj.tools == nil && obj.system == nil && obj.messages == nil
        }
    }

    private static func resolve(_ policy: AISchema.CachePolicy?) -> AISchema.CachePolicyObject {
        switch policy {
        case .some(.none):
            return nonePolicy
        case .some(.object(let obj)) where !isAuto(policy):
            return obj
        default:
            return autoPolicy
        }
    }

    private static func gatewayPolicy(_ modelID: String) -> AISchema.CachePolicyObject {
        let id = modelID.hasPrefix("~") ? String(modelID.dropFirst()) : modelID
        if id.hasPrefix("anthropic/") { return autoPolicy }
        if id.hasPrefix("qwen/") || id.hasPrefix("alibaba/qwen") { return qwenPolicy }
        return nonePolicy
    }

    private static func selectPolicy(_ request: AISchema.LLMRequest) -> AISchema.CachePolicyObject {
        let format = request.model.compatibility?.cacheFormat
        let route = request.model.route.id
        let auto = isAuto(request.cache)
        if format == .alibaba {
            if auto { return qwenPolicy }
            let resolved = resolve(request.cache)
            return AISchema.CachePolicyObject(tools: false, system: resolved.system, messages: resolved.messages, ttl: resolved.ttl)
        }
        if format == .anthropic {
            return resolve(request.cache)
        }
        if !respectsInlineHints.contains(route) {
            return nonePolicy
        }
        if !auto {
            return resolve(request.cache)
        }
        if route == "openrouter" || route == "vercel-ai-gateway-messages" {
            return gatewayPolicy(request.model.id.rawValue)
        }
        if route == "alibaba-chat" {
            return request.model.id.rawValue.lowercased().hasPrefix("qwen") ? qwenPolicy : nonePolicy
        }
        return autoPolicy
    }

    /// The requested cache lifetime, for routes that send it as a request-level option instead of on markers.
    // parity: ai/src/cache-policy.ts#requestTTL [status=implemented hash=afea2413ccd7]
    public static func requestTTL(_ request: AISchema.LLMRequest) -> AISchema.CacheTTL? {
        if case .object(let obj) = request.cache { return obj.ttl }
        return nil
    }

    private static func countToolHints(_ tools: [AISchema.ToolEntry]) -> Int {
        tools.reduce(0) { count, entry in
            switch entry {
            case .tool(let def): count + (def.cache == nil ? 0 : 1)
            case .namespace(let ns): count + countToolHints(ns.tools)
            }
        }
    }

    private static func countHints(_ request: AISchema.LLMRequest) -> Int {
        let toolCount = countToolHints(request.tools)
        let sysCount = request.system.reduce(0) { $0 + ($1.cache == nil ? 0 : 1) }
        let msgCount = request.messages.reduce(0) { sum, msg in
            sum + msg.contentParts.reduce(0) { pSum, part in
                pSum + (part.isCacheable && part.cache != nil ? 1 : 0)
            }
        }
        return toolCount + sysCount + msgCount
    }

    private static func markLastTool(
        _ tools: [AISchema.ToolEntry],
        hint: AISchema.CacheHint,
        budget: inout Int
    ) -> [AISchema.ToolEntry] {
        guard let last = tools.last else { return tools }
        var result = tools
        switch last {
        case .namespace(let ns):
            let nested = markLastTool(ns.tools, hint: hint, budget: &budget)
            result[result.count - 1] = .namespace(AISchema.ToolNamespace(name: ns.name, description: ns.description, tools: nested))
            return result
        case .tool(let def):
            if def.cache != nil || budget == 0 { return tools }
            budget -= 1
            result[result.count - 1] = .tool(def.withCache(hint))
            return result
        }
    }

    private static func markSystemBoundaries(
        _ system: [AISchema.SystemPart],
        hint: AISchema.CacheHint,
        budget: inout Int
    ) -> [AISchema.SystemPart] {
        guard !system.isEmpty else { return system }
        var result = system
        for index in result.indices {
            if (index != 0 && index != result.count - 1) || result[index].cache != nil || budget == 0 {
                continue
            }
            budget -= 1
            let p = result[index]
            result[index] = AISchema.SystemPart(text: p.text, cache: hint, metadata: p.metadata)
        }
        return result
    }

    private static func isMarker(_ message: AISchema.Message) -> Bool {
        AIEffortUpdates.effortUpdate(message) != nil || AIToolUpdates.toolsUpdate(message) != nil
    }

    private static func cacheMessage(_ message: AISchema.Message, at partIndex: Int, hint: AISchema.CacheHint) -> AISchema.Message {
        switch message {
        case .system(let m):
            var content = m.content
            if case .text(let t) = content[partIndex] {
                content[partIndex] = .text(AISchema.TextPart(text: t.text, cache: hint, providerMetadata: t.providerMetadata))
            }
            return .system(AISchema.SystemMessage(id: m.id, content: content, tools: m.tools))
        case .user(let m):
            var content = m.content
            switch content[partIndex] {
            case .text(let t):
                content[partIndex] = .text(AISchema.TextPart(text: t.text, cache: hint, providerMetadata: t.providerMetadata))
            case .media(let mp):
                content[partIndex] = .media(AISchema.MediaPart(media: mp.media, filename: mp.filename, cache: hint, providerMetadata: mp.providerMetadata))
            }
            return .user(AISchema.UserMessage(id: m.id, content: content, providerMetadata: m.providerMetadata))
        case .assistant(let m):
            var content = m.content
            switch content[partIndex] {
            case .text(let t):
                content[partIndex] = .text(AISchema.TextPart(text: t.text, cache: hint, providerMetadata: t.providerMetadata))
            case .reasoning(let r):
                content[partIndex] = .reasoning(AISchema.ReasoningPart(text: r.text, encrypted: r.encrypted, cache: hint, providerMetadata: r.providerMetadata))
            case .toolCall(let tc):
                content[partIndex] = .toolCall(AISchema.ToolCallPart(id: tc.id, name: tc.name, namespace: tc.namespace, input: tc.input, providerExecuted: tc.providerExecuted, cache: hint, providerMetadata: tc.providerMetadata))
            case .toolResult(let tr):
                content[partIndex] = .toolResult(AISchema.ToolResultPart(id: tr.id, name: tr.name, namespace: tr.namespace, result: tr.result, providerExecuted: tr.providerExecuted, cache: hint, providerMetadata: tr.providerMetadata))
            case .media(let mp):
                content[partIndex] = .media(AISchema.MediaPart(media: mp.media, filename: mp.filename, cache: hint, providerMetadata: mp.providerMetadata))
            case .compaction:
                break
            }
            return .assistant(AISchema.AssistantMessage(id: m.id, content: content, providerMetadata: m.providerMetadata))
        case .tool(let m):
            var content = m.content
            let tr = content[partIndex]
            content[partIndex] = AISchema.ToolResultPart(
                id: tr.id,
                name: tr.name,
                namespace: tr.namespace,
                result: tr.result,
                providerExecuted: tr.providerExecuted,
                cache: hint,
                providerMetadata: tr.providerMetadata
            )
            return .tool(AISchema.ToolMessage(id: m.id, content: content))
        }
    }

    private static func markMessageAt(
        _ messages: inout [AISchema.Message],
        index: Int,
        hint: AISchema.CacheHint,
        budget: inout Int
    ) {
        guard index >= 0 && index < messages.count, budget > 0 else { return }
        let parts = messages[index].contentParts
        guard !parts.isEmpty else { return }
        let lastTextIndex = parts.lastIndex {
            if case .text = $0 { return true }
            return false
        }
        let markAt = lastTextIndex ?? parts.lastIndex(where: \.isCacheable)
        guard let markAt else { return }
        let existing = parts[markAt]
        guard existing.isCacheable && existing.cache == nil else { return }
        budget -= 1
        messages[index] = cacheMessage(messages[index], at: markAt, hint: hint)
    }

    private static func markMessages(
        _ messages: [AISchema.Message],
        strategy: AISchema.CachePolicyObject.MessagesStrategy,
        hint: AISchema.CacheHint,
        budget: inout Int
    ) -> [AISchema.Message] {
        guard !messages.isEmpty else { return messages }
        var next = messages
        switch strategy {
        case .latestUserMessage:
            if let idx = next.lastIndex(where: { $0.role == .user }) {
                markMessageAt(&next, index: idx, hint: hint, budget: &budget)
            }
        case .latestAssistant:
            if let idx = next.lastIndex(where: { $0.role == .assistant }) {
                markMessageAt(&next, index: idx, hint: hint, budget: &budget)
            }
        case .tail(let count):
            var start = next.count
            var remaining = count
            while remaining > 0 && start > 0 {
                start -= 1
                if !isMarker(next[start]) {
                    remaining -= 1
                }
            }
            for i in start..<next.count where !isMarker(next[i]) {
                markMessageAt(&next, index: i, hint: hint, budget: &budget)
            }
        }
        return next
    }

    // parity: ai/src/cache-policy.ts#applyCachePolicy [status=implemented hash=e1f30a789dd4]
    public static func applyCachePolicy(_ request: AISchema.LLMRequest) -> AISchema.LLMRequest {
        let policy = selectPolicy(request)
        guard policy.tools == true || policy.system == true || policy.messages != nil else {
            return request
        }
        let hint = AISchema.CacheHint(type: .ephemeral, ttl: requestTTL(request))
        var budget = max(0, breakpointCap - countHints(request))
        let tools = policy.tools == true ? markLastTool(request.tools, hint: hint, budget: &budget) : request.tools
        let system = policy.system == true ? markSystemBoundaries(request.system, hint: hint, budget: &budget) : request.system
        let messages = if let msgStrategy = policy.messages {
            markMessages(request.messages, strategy: msgStrategy, hint: hint, budget: &budget)
        } else {
            request.messages
        }
        return request.replacing(system: system, messages: messages, tools: tools)
    }

    /// Whether the cache policy places inline markers.
    // parity: ai/src/cache-policy.ts#placesMarkers [status=implemented hash=e89a4614c7e0]
    public static func placesMarkers(_ request: AISchema.LLMRequest) -> Bool {
        let policy = selectPolicy(request)
        return policy.tools == true || policy.system == true || policy.messages != nil
    }
}

/// Mid-conversation reasoning effort update markers.
/// Ports `packages/ai/src/effort-updates.ts`.
public enum AIEffortUpdates {
    // parity: ai/src/effort-updates.ts#effortUpdate [status=implemented hash=7bcc2b463fa6]
    public static func effortUpdate(_ message: AISchema.Message) -> AISchema.EffortPart? {
        guard case .system(let sys) = message, sys.content.count == 1,
              case .effort(let part) = sys.content[0]
        else {
            return nil
        }
        return part
    }

    // parity: ai/src/effort-updates.ts#stripEffortUpdates [status=implemented hash=077beb5213bd]
    public static func stripEffortUpdates(_ request: AISchema.LLMRequest) -> AISchema.LLMRequest {
        let filtered = request.messages.filter { effortUpdate($0) == nil }
        return filtered.count == request.messages.count ? request : request.replacing(messages: filtered)
    }

    // parity: ai/src/effort-updates.ts#applyEffortUpdates [status=implemented hash=c950d225fe6f]
    public static func applyEffortUpdates(_ request: AISchema.LLMRequest) -> AISchema.LLMRequest {
        if request.model.route.supportsEffortUpdates?(request) == true {
            return request
        }
        return stripEffortUpdates(request)
    }

    // parity: ai/src/effort-updates.ts#resolveEffortUpdates [status=implemented hash=9475e65fe0e8]
    public static func resolveEffortUpdates(
        _ request: AISchema.LLMRequest,
        current: AISchema.ReasoningEffort?
    ) -> (request: AISchema.LLMRequest, effort: AISchema.ReasoningEffort?) {
        let updates = request.messages.compactMap(effortUpdate)
        if updates.isEmpty {
            return (request, current)
        }
        if updates.last?.effort != current {
            return (stripEffortUpdates(request), current)
        }
        return (request, updates.first?.previous)
    }
}

/// Tool call/result history normalization.
/// Ports `packages/ai/src/tool-history.ts`.
public enum AIToolHistory {
    private static let emptyToolOutput = "(no tool output)"
    private static let missingToolResult = "Tool result missing"

    // parity: ai/src/tool-history.ts#normalizeToolHistory [status=implemented hash=a40484f94562]
    public static func normalizeToolHistory(_ messages: [AISchema.Message]) -> [AISchema.Message] {
        var normalized: [AISchema.Message] = []
        var pendingOrder: [AISchema.ToolCallID] = []
        var pending: [AISchema.ToolCallID: AISchema.ToolCallPart] = [:]
        var held: [AISchema.Message] = []

        func releaseHeld() {
            guard pending.isEmpty else { return }
            normalized.append(contentsOf: held)
            held.removeAll(keepingCapacity: true)
        }

        func appendMissingResults() {
            if !pending.isEmpty {
                let calls = pendingOrder.compactMap { pending[$0] }
                let parts = calls.map { call in
                    AISchema.ToolResultPart.make(
                        id: call.id,
                        name: call.name,
                        namespace: call.namespace,
                        result: .error(.string(missingToolResult))
                    )
                }
                normalized.append(.tool(AISchema.ToolMessage(content: parts)))
                pending.removeAll(keepingCapacity: true)
                pendingOrder.removeAll(keepingCapacity: true)
            }
            releaseHeld()
        }

        for message in messages {
            if message.role == .user || message.role == .assistant {
                appendMissingResults()
            }

            if case .tool(let toolMsg) = message {
                var nextContent: [AISchema.ToolResultPart] = []
                nextContent.reserveCapacity(toolMsg.content.count)
                for part in toolMsg.content {
                    if part.providerExecuted == true {
                        nextContent.append(part)
                        continue
                    }
                    let call = pending.removeValue(forKey: part.id)
                    nextContent.append(normalizeToolResult(part, matching: call))
                }
                if !nextContent.isEmpty {
                    normalized.append(.tool(AISchema.ToolMessage(id: toolMsg.id, content: nextContent)))
                }
                releaseHeld()
                continue
            }

            if message.role == .system && !pending.isEmpty {
                held.append(message)
                continue
            }

            normalized.append(message)
            if case .assistant(let assistantMsg) = message {
                for part in assistantMsg.content {
                    if case .toolCall(let call) = part, call.providerExecuted != true {
                        if pending[call.id] == nil { pendingOrder.append(call.id) }
                        pending[call.id] = call
                    }
                }
            }
        }
        appendMissingResults()

        return normalized
    }

    private static func normalizeToolResult(
        _ part: AISchema.ToolResultPart,
        matching call: AISchema.ToolCallPart?
    ) -> AISchema.ToolResultPart {
        let name = call?.name ?? part.name
        let namespace = call != nil ? call?.namespace : part.namespace
        let normalizedValue: AISchema.ToolResultValue
        switch part.result {
        case .text(.string("")):
            normalizedValue = .text(.string(emptyToolOutput))
        case .error(.string("")):
            normalizedValue = .error(.string(emptyToolOutput))
        case .content(let items):
            let filtered = items.filter { item in
                if case .text(let t) = item, t.text.isEmpty { return false }
                return true
            }
            if filtered.isEmpty {
                normalizedValue = .text(.string(emptyToolOutput))
            } else {
                normalizedValue = .content(filtered)
            }
        default:
            normalizedValue = part.result
        }
        return AISchema.ToolResultPart(
            id: part.id,
            name: name,
            namespace: namespace,
            result: normalizedValue,
            providerExecuted: part.providerExecuted,
            cache: part.cache,
            providerMetadata: part.providerMetadata
        )
    }
}

/// Incremental mid-conversation tool update planning and folding.
/// Ports `packages/ai/src/tool-updates.ts`.
public enum AIToolUpdates {
    // parity: ai/src/tool-updates.ts#ToolUpdate [status=implemented hash=313aa6ddc91f]
    public typealias ToolUpdate = AISchema.Capabilities.ToolUpdateKind

    // parity: ai/src/tool-updates.ts#ToolUpdateEncoding [status=implemented hash=ca42c50f45e2]
    public struct ToolUpdateEncoding: Sendable {
        public let kinds: [ToolUpdate]
        public let placeable: (@Sendable (AISchema.LLMRequest, Int) -> Bool)?
        public let declarable: (@Sendable (AISchema.ToolEntry) -> Bool)?

        public init(
            kinds: [ToolUpdate],
            placeable: (@Sendable (AISchema.LLMRequest, Int) -> Bool)? = nil,
            declarable: (@Sendable (AISchema.ToolEntry) -> Bool)? = nil
        ) {
            self.kinds = kinds
            self.placeable = placeable
            self.declarable = declarable
        }
    }

    // parity: ai/src/tool-updates.ts#toolsUpdate [status=implemented hash=1386821b9124]
    public static func toolsUpdate(_ message: AISchema.Message) -> AISchema.ToolChanges? {
        if case .system(let sys) = message { return sys.tools }
        return nil
    }

    // parity: ai/src/tool-updates.ts#addsTools [status=implemented hash=60c4a39ab4f2]
    public static func addsTools(_ request: AISchema.LLMRequest) -> Bool {
        request.messages.contains { (toolsUpdate($0)?.add.isEmpty == false) }
    }

    // parity: ai/src/tool-updates.ts#toolUpdateKinds [status=implemented hash=e78a3c5947c6]
    public static func toolUpdateKinds(_ request: AISchema.LLMRequest) -> [ToolUpdate] {
        guard let encoding = request.model.route.toolUpdates,
              let modelUpdates = request.model.capabilities?.tools?.updates
        else {
            return []
        }
        return modelUpdates.filter { encoding.kinds.contains($0) }
    }

    /// Apply one change: removals first, then additions replace a same-named item in place or append.
    // parity: ai/src/tool-updates.ts#foldTools [status=implemented hash=ab275823c3b8]
    public static func foldTools<Item>(
        _ tools: [Item],
        add: [Item],
        remove: [String],
        nameOf: (Item) -> String
    ) -> [Item] {
        let removeSet = Set(remove)
        var addedOrder: [String] = []
        var addedMap: [String: Item] = [:]
        for item in add {
            let name = nameOf(item)
            if addedMap[name] == nil { addedOrder.append(name) }
            addedMap[name] = item
        }
        var kept: [Item] = []
        var keptNames: Set<String> = []
        for item in tools {
            let name = nameOf(item)
            if removeSet.contains(name) { continue }
            let resolved = addedMap[name] ?? item
            kept.append(resolved)
            keptNames.insert(name)
        }
        for name in addedOrder where !keptNames.contains(name) {
            if let item = addedMap[name] {
                kept.append(item)
            }
        }
        return kept
    }

    public static func foldTools(
        _ tools: [AISchema.ToolEntry],
        add: [AISchema.ToolEntry],
        remove: [String]
    ) -> [AISchema.ToolEntry] {
        foldTools(tools, add: add, remove: remove, nameOf: \.name)
    }

    private struct PlanStep {
        let index: Int
        let native: Bool
        let tools: [AISchema.ToolEntry]
        let changes: AISchema.ToolChanges
    }

    private static func flattenToolNames(_ tools: [AISchema.ToolEntry], path: [String] = []) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        func visit(_ entries: [AISchema.ToolEntry], prefix: [String]) {
            for entry in entries {
                switch entry {
                case .namespace(let ns):
                    visit(ns.tools, prefix: prefix + [ns.name])
                case .tool(let def):
                    let flatName = prefix.isEmpty ? def.name : (prefix + [def.name]).joined(separator: "_")
                    if seen.insert(flatName).inserted {
                        result.append(flatName)
                    }
                }
            }
        }
        visit(tools, prefix: path)
        return result
    }

    /// Flattened names of the tools in `before` that `after` no longer has.
    // parity: ai/src/tool-updates.ts#withdrawnTools [status=implemented hash=24d22237a514]
    public static func withdrawnTools(before: [AISchema.ToolEntry], after: [AISchema.ToolEntry]) -> [String] {
        let kept = Set(flattenToolNames(after))
        return flattenToolNames(before).filter { !kept.contains($0) }
    }

    private static func plan(_ request: AISchema.LLMRequest, supported: [ToolUpdate]) -> AISchema.LLMRequest {
        var changes: [(index: Int, tools: AISchema.ToolChanges)] = []
        for (idx, msg) in request.messages.enumerated() {
            if case .system(let sys) = msg, let tc = sys.tools {
                changes.append((idx, tc))
            }
        }
        if changes.isEmpty { return request }

        let encoding = request.model.route.toolUpdates
        let firstTurn = request.messages.firstIndex { $0.role != .system }

        var currentTools = request.tools
        var declared = Set(request.tools.map(\.name))
        var steps: [PlanStep] = []

        for change in changes {
            let addedNames = change.tools.add.map(\.name)
            let addedSet = Set(addedNames)
            let removeSet = Set(change.tools.remove)
            let removed = currentTools.filter { removeSet.contains($0.name) && !addedSet.contains($0.name) }
            let nextTools = foldTools(currentTools, add: change.tools.add, remove: change.tools.remove)

            var kinds: [ToolUpdate] = []
            if !removed.isEmpty || !withdrawnTools(before: currentTools, after: nextTools).isEmpty {
                kinds.append(.remove)
            }
            for name in addedNames {
                kinds.append(declared.contains(name) ? .replace : .add)
            }

            let canPlace = encoding?.placeable?(request, change.index) ?? true
            let allDeclarable = (change.tools.add + removed).allSatisfy { encoding?.declarable?($0) ?? true }
            let isNative = firstTurn != nil
                && change.index > firstTurn!
                && kinds.allSatisfy { supported.contains($0) }
                && allDeclarable
                && canPlace

            steps.append(PlanStep(
                index: change.index,
                native: isNative,
                tools: nextTools,
                changes: AISchema.ToolChanges(add: change.tools.add, remove: removed.map(\.name))
            ))
            currentTools = nextTools
            declared.formUnion(addedNames)
        }

        let cut = steps.lastIndex(where: { !$0.native }) ?? -1
        var kept: [Int: AISchema.ToolChanges] = [:]
        if cut + 1 < steps.count {
            for step in steps[(cut + 1)...] {
                kept[step.index] = step.changes
            }
        }

        let topTools = cut == -1 ? request.tools : steps[cut].tools
        var nextMessages: [AISchema.Message] = []
        nextMessages.reserveCapacity(request.messages.count)
        for (idx, msg) in request.messages.enumerated() {
            guard case .system(let sys) = msg, sys.tools != nil else {
                nextMessages.append(msg)
                continue
            }
            if let tc = kept[idx], (!tc.add.isEmpty || !tc.remove.isEmpty) {
                nextMessages.append(.system(AISchema.SystemMessage(id: sys.id, content: sys.content, tools: tc)))
            } else if !sys.content.isEmpty {
                nextMessages.append(.system(AISchema.SystemMessage(id: sys.id, content: sys.content, tools: nil)))
            }
        }
        return request.replacing(messages: nextMessages, tools: topTools)
    }

    // parity: ai/src/tool-updates.ts#planToolUpdates [status=implemented hash=39b9433c2f5e]
    public static func planToolUpdates(_ request: AISchema.LLMRequest) -> AISchema.LLMRequest {
        plan(request, supported: toolUpdateKinds(request))
    }

    // parity: ai/src/tool-updates.ts#foldToolUpdates [status=implemented hash=5ee635b2a842]
    public static func foldToolUpdates(_ request: AISchema.LLMRequest) -> AISchema.LLMRequest {
        plan(request, supported: [])
    }

    // parity: ai/src/tool-updates.ts#mapToolUpdates [status=implemented hash=03b79d07110c]
    public static func mapToolUpdates(
        _ request: AISchema.LLMRequest,
        _ transform: ([AISchema.ToolEntry]) -> [AISchema.ToolEntry]
    ) -> AISchema.LLMRequest {
        guard request.messages.contains(where: { toolsUpdate($0) != nil }) else {
            return request
        }
        let mapped = request.messages.map { msg -> AISchema.Message in
            guard case .system(let sys) = msg, let tc = sys.tools else { return msg }
            return .system(AISchema.SystemMessage(
                id: sys.id,
                content: sys.content,
                tools: AISchema.ToolChanges(add: transform(tc.add), remove: tc.remove)
            ))
        }
        return request.replacing(messages: mapped)
    }
}

/// Type-safe tool construction and concurrent runtime dispatch.
/// Ports `packages/ai/src/tool.ts` and `packages/ai/src/tool-runtime.ts`.
public enum AITool {
    // parity: ai/src/tool.ts#ToolSchema [status=adapted hash=0ede5a1306aa]
    public struct ToolSchemaCodec<T: Sendable>: Sendable {
        public let jsonSchema: AISchema.JsonSchema
        public let decode: @Sendable (JSONValue) throws -> T
        public let encode: @Sendable (T) throws -> JSONValue

        public init(
            jsonSchema: AISchema.JsonSchema,
            decode: @escaping @Sendable (JSONValue) throws -> T,
            encode: @escaping @Sendable (T) throws -> JSONValue
        ) {
            self.jsonSchema = jsonSchema
            self.decode = decode
            self.encode = encode
        }

        public static func codable(_ type: T.Type, jsonSchema: AISchema.JsonSchema) -> ToolSchemaCodec<T> where T: Codable {
            ToolSchemaCodec(
                jsonSchema: jsonSchema,
                decode: { raw in
                    let data = try JSONEncoder().encode(raw)
                    return try JSONDecoder().decode(T.self, from: data)
                },
                encode: { value in
                    let data = try JSONEncoder().encode(value)
                    return try JSONDecoder().decode(JSONValue.self, from: data)
                }
            )
        }
    }

    // parity: ai/src/tool.ts#ToolInput [status=adapted hash=d0d36188098c]
    public enum ToolInput: Sendable {
        case schema(ToolSchemaCodec<JSONValue>)
        case jsonSchema(AISchema.JsonSchema)

        public var jsonSchema: AISchema.JsonSchema {
            switch self {
            case .schema(let s): s.jsonSchema
            case .jsonSchema(let j): j
            }
        }
    }

    // parity: ai/src/tool.ts#ToolInputType [status=adapted hash=3921ee04adc0]
    public typealias ToolInputType = JSONValue

    // parity: ai/src/tool.ts#ToolExecuteContext [status=implemented hash=2e671ca53c04]
    public struct ToolExecuteContext: Equatable, Hashable, Sendable {
        public let id: AISchema.ToolCallID
        public let name: String
        public let namespace: String?

        public init(id: AISchema.ToolCallID, name: String, namespace: String? = nil) {
            self.id = id
            self.name = name
            self.namespace = namespace
        }
    }

    // parity: ai/src/tool.ts#ToolExecute [status=implemented hash=95ab4b3af473]
    public typealias ToolExecute = @Sendable (JSONValue, ToolExecuteContext?) async throws -> JSONValue

    // parity: ai/src/tool.ts#ToolModelOutputInput [status=implemented hash=8052905dfb63]
    public struct ToolModelOutputInput: Equatable, Sendable {
        public let id: AISchema.ToolCallID
        public let input: JSONValue
        public let output: JSONValue

        public init(id: AISchema.ToolCallID, input: JSONValue, output: JSONValue) {
            self.id = id
            self.input = input
            self.output = output
        }
    }

    // parity: ai/src/tool.ts#ToolToModelOutput [status=implemented hash=7dfbfd286552]
    public typealias ToolToModelOutput = @Sendable (ToolModelOutputInput) -> [ToolSchema.Content]

    // parity: ai/src/tool.ts#FreeformOption [status=implemented hash=cf32b77d23ad]
    public typealias FreeformOption = AISchema.Freeform?

    // parity: ai/src/tool.ts#NoExecute [status=adapted hash=8cf1e6a3362c]
    public enum NoExecute: Sendable {}

    // parity: ai/src/tool.ts#Tool [status=implemented hash=79a62aa7be34]
    public struct Tool: Sendable {
        public let name: String
        public let description: String
        public let input: ToolInput
        public let outputSchema: AISchema.JsonSchema?
        public let execute: ToolExecute?
        public let toModelOutput: ToolToModelOutput?
        public let toStructuredOutput: (@Sendable (JSONValue) -> JSONValue)?
        internal let decodeInput: @Sendable (JSONValue) throws -> JSONValue
        internal let encodeSuccess: @Sendable (JSONValue) throws -> JSONValue
        internal let legacyResult: Bool
        public let definition: AISchema.ToolDefinition

        public init(
            name: String,
            description: String,
            input: ToolInput,
            outputSchema: AISchema.JsonSchema? = nil,
            execute: ToolExecute? = nil,
            toModelOutput: ToolToModelOutput? = nil,
            toStructuredOutput: (@Sendable (JSONValue) -> JSONValue)? = nil,
            decodeInput: @escaping @Sendable (JSONValue) throws -> JSONValue,
            encodeSuccess: @escaping @Sendable (JSONValue) throws -> JSONValue,
            legacyResult: Bool,
            definition: AISchema.ToolDefinition
        ) {
            self.name = name
            self.description = description
            self.input = input
            self.outputSchema = outputSchema
            self.execute = execute
            self.toModelOutput = toModelOutput
            self.toStructuredOutput = toStructuredOutput
            self.decodeInput = decodeInput
            self.encodeSuccess = encodeSuccess
            self.legacyResult = legacyResult
            self.definition = definition
        }

        internal func project(input: JSONValue, id: AISchema.ToolCallID, output: JSONValue) -> AISchema.ToolOutput {
            let structured = toStructuredOutput?(output) ?? output
            let content: [ToolSchema.Content]
            if let toModelOutput {
                content = toModelOutput(ToolModelOutputInput(id: id, input: input, output: output))
            } else if case .string(let s) = output {
                content = [.text(ToolSchema.TextContent(text: s))]
            } else {
                content = []
            }
            return AISchema.ToolOutput.make(structured, content: content)
        }
    }

    // parity: ai/src/tool.ts#ExecutableTool [status=implemented hash=6e474f2fd0a3]
    public typealias ExecutableTool = Tool

    // parity: ai/src/tool.ts#ToolChangesInput [status=implemented hash=35abd7d42733]
    public struct ToolChangesInput: Sendable {
        public enum AddItem: Sendable {
            case tool(Tool)
            case entry(AISchema.ToolEntryInput)

            public var name: String {
                switch self {
                case .tool(let t): t.name
                case .entry(let e): e.name
                }
            }

            public var toolEntry: AISchema.ToolEntry {
                switch self {
                case .tool(let t): .tool(t.definition)
                case .entry(let e): AISchema.ToolEntry.make(e)
                }
            }
        }

        public enum RemoveItem: Sendable {
            case name(String)
            case tool(Tool)
            case entry(AISchema.ToolEntryInput)

            public var name: String {
                switch self {
                case .name(let s): s
                case .tool(let t): t.name
                case .entry(let e): e.name
                }
            }
        }

        public let add: [AddItem]
        public let remove: [RemoveItem]

        public init(add: [AddItem] = [], remove: [RemoveItem] = []) {
            self.add = add
            self.remove = remove
        }

        public func toToolChanges() -> AISchema.ToolChanges {
            AISchema.ToolChanges(
                add: add.map(\.toolEntry),
                remove: remove.map(\.name)
            )
        }
    }

    // parity: ai/src/tool.ts#ToolOptions [status=implemented hash=f17c6b9ee954]
    public struct ToolOptions: Sendable {
        public let name: String
        public let description: String
        public let input: ToolInput
        public let outputSchema: AISchema.JsonSchema?
        public let successCodec: ToolSchemaCodec<JSONValue>?
        public let freeform: FreeformOption
        public let execute: ToolExecute?
        public let toModelOutput: ToolToModelOutput?
        public let toStructuredOutput: (@Sendable (JSONValue) -> JSONValue)?

        public init(
            name: String,
            description: String,
            input: ToolInput = .jsonSchema(["type": .string("object"), "properties": .object([:])]),
            outputSchema: AISchema.JsonSchema? = nil,
            successCodec: ToolSchemaCodec<JSONValue>? = nil,
            freeform: FreeformOption = nil,
            execute: ToolExecute? = nil,
            toModelOutput: ToolToModelOutput? = nil,
            toStructuredOutput: (@Sendable (JSONValue) -> JSONValue)? = nil
        ) {
            self.name = name
            self.description = description
            self.input = input
            self.outputSchema = outputSchema
            self.successCodec = successCodec
            self.freeform = freeform
            self.execute = execute
            self.toModelOutput = toModelOutput
            self.toStructuredOutput = toStructuredOutput
        }
    }

    private static let annotationKeywords: Set<String> = [
        "title", "description", "default", "examples", "readOnly", "writeOnly",
    ]

    /// Normalizes a no-argument `{ not: { type: "null" } }` JSON schema to an explicit empty-object schema.
    // parity: ai/src/tool.ts#emptyInputJsonSchema [status=implemented hash=86a90058f158]
    public static func emptyInputJsonSchema(_ schema: AISchema.JsonSchema) -> AISchema.JsonSchema? {
        guard case .object(let notObj) = schema["not"],
              notObj.count == 1,
              case .string("null") = notObj["type"]
        else {
            return nil
        }
        var rest = schema
        rest.removeValue(forKey: "not")
        guard rest.keys.allSatisfy({ annotationKeywords.contains($0) }) else {
            return nil
        }
        rest["type"] = .string("object")
        rest["properties"] = .object([:])
        rest["additionalProperties"] = .bool(false)
        return rest
    }

    // parity: ai/src/tool.ts#build [status=implemented hash=9557ed3385be]
    public static func build(_ config: ToolOptions, execute: ToolExecute?) throws(AISchema.AIError) -> Tool {
        let inputSchema: AISchema.JsonSchema
        let decodeFn: @Sendable (JSONValue) throws -> JSONValue
        let encodeFn: @Sendable (JSONValue) throws -> JSONValue
        let legacy: Bool

        switch config.input {
        case .jsonSchema(let raw):
            inputSchema = raw
            decodeFn = { $0 }
            encodeFn = { $0 }
            legacy = config.toModelOutput == nil && config.toStructuredOutput == nil
        case .schema(let codec):
            inputSchema = emptyInputJsonSchema(codec.jsonSchema) ?? codec.jsonSchema
            decodeFn = codec.decode
            if let successCodec = config.successCodec {
                encodeFn = successCodec.encode
            } else {
                encodeFn = { $0 }
            }
            legacy = false
        }

        if config.freeform != nil && AISchema.ToolDefinition.freeformField(inputSchema) == nil {
            throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                message: "A freeform tool needs exactly one parameter, a required string"
            )))
        }

        let def = AISchema.ToolDefinition(
            name: config.name,
            description: config.description,
            inputSchema: inputSchema,
            outputSchema: config.successCodec?.jsonSchema ?? config.outputSchema,
            freeform: config.freeform
        )

        return Tool(
            name: config.name,
            description: config.description,
            input: config.input,
            outputSchema: def.outputSchema,
            execute: execute,
            toModelOutput: config.toModelOutput,
            toStructuredOutput: config.toStructuredOutput,
            decodeInput: decodeFn,
            encodeSuccess: encodeFn,
            legacyResult: legacy,
            definition: def
        )
    }

    // parity: ai/src/tool.ts#tool [status=implemented hash=bc00c1d82a29]
    public static func tool(_ config: ToolOptions) throws(AISchema.AIError) -> Tool {
        try build(config, execute: config.execute)
    }

    // parity: ai/src/tool.ts#toDefinitions [status=implemented hash=6185ea027160]
    public static func toDefinitions(_ tools: [Tool]) -> [AISchema.ToolDefinition] {
        tools.map(\.definition)
    }

    // MARK: - src/tool-runtime.ts

    // parity: ai/src/tool-runtime.ts#ToolSettlement [status=implemented hash=777ddcaf9a0d]
    public struct ToolSettlement: Equatable, Sendable {
        public let result: AISchema.ToolResultValue
        public let output: AISchema.ToolOutput?

        public init(result: AISchema.ToolResultValue, output: AISchema.ToolOutput? = nil) {
            self.result = result
            self.output = output
        }
    }

    // parity: ai/src/tool-runtime.ts#DispatchResult [status=implemented hash=09ce9b126733]
    public struct DispatchResult: Equatable, Sendable {
        public let result: AISchema.ToolResultValue
        public let output: AISchema.ToolOutput?
        public let events: [AISchema.LLMEvent]

        public init(
            result: AISchema.ToolResultValue,
            output: AISchema.ToolOutput? = nil,
            events: [AISchema.LLMEvent]
        ) {
            self.result = result
            self.output = output
            self.events = events
        }
    }

    // parity: ai/src/tool-runtime.ts#PendingCall [status=implemented hash=6ea3e5dd9cba]
    public struct PendingCall: Equatable, Sendable {
        public let call: AISchema.ToolCallPart
        public let error: String?

        public init(call: AISchema.ToolCallPart, error: String? = nil) {
            self.call = call
            self.error = error
        }
    }

    private static func makeDispatchResult(
        call: AISchema.ToolCallPart,
        settlement: ToolSettlement
    ) -> DispatchResult {
        DispatchResult(
            result: settlement.result,
            output: settlement.output,
            events: [
                .toolResult(AISchema.ToolResult(
                    id: call.id,
                    name: call.name,
                    namespace: call.namespace,
                    result: settlement.result,
                    output: settlement.output,
                    providerMetadata: call.providerMetadata
                ))
            ]
        )
    }

    /// Execute one canonical tool call. Catches `ToolFailure` as an error tool-result; other thrown errors propagate.
    // parity: ai/src/tool-runtime.ts#dispatch [status=implemented hash=fe56b5053aec]
    public static func dispatch(_ tools: [Tool], call: AISchema.ToolCallPart) async throws -> DispatchResult {
        let lookupName = call.namespace.map { "\($0).\(call.name)" } ?? call.name
        guard let tool = tools.first(where: { $0.name == lookupName }) else {
            return makeDispatchResult(
                call: call,
                settlement: ToolSettlement(result: .error(.string(
                    "No tool named \"\(lookupName)\" is currently available. Please use a tool from the available tool list."
                )))
            )
        }
        guard let execute = tool.execute else {
            return makeDispatchResult(
                call: call,
                settlement: ToolSettlement(result: .error(.string("Tool has no execute handler: \(lookupName)")))
            )
        }

        let decoded: JSONValue
        do {
            decoded = try tool.decodeInput(call.input)
        } catch {
            return makeDispatchResult(
                call: call,
                settlement: ToolSettlement(result: .error(.string("Invalid tool input: \(error)")))
            )
        }

        let rawOutput: JSONValue
        do {
            rawOutput = try await execute(decoded, ToolExecuteContext(id: call.id, name: call.name, namespace: call.namespace))
        } catch let failure as AISchema.ToolFailure {
            return makeDispatchResult(
                call: call,
                settlement: ToolSettlement(result: .error(.string(failure.message)))
            )
        }

        let encoded: JSONValue
        do {
            encoded = try tool.encodeSuccess(rawOutput)
        } catch {
            return makeDispatchResult(
                call: call,
                settlement: ToolSettlement(result: .error(.string(
                    "Tool returned an invalid value for its success schema: \(error)"
                )))
            )
        }

        if tool.legacyResult,
           let data = try? JSONEncoder().encode(encoded),
           let parsedResult = try? JSONDecoder().decode(AISchema.ToolResultValue.self, from: data) {
            return makeDispatchResult(
                call: call,
                settlement: ToolSettlement(result: parsedResult, output: AISchema.ToolOutput.fromResultValue(parsedResult))
            )
        }

        let output = tool.project(input: decoded, id: call.id, output: encoded)
        let resultVal = AISchema.ToolOutput.toResultValue(output)
        let settlement: ToolSettlement = resultVal.kind == .error
            ? ToolSettlement(result: resultVal)
            : ToolSettlement(result: resultVal, output: output)
        return makeDispatchResult(call: call, settlement: settlement)
    }

    /// Run a step's tool calls concurrently, preserving call order.
    // parity: ai/src/tool-runtime.ts#runTools [status=implemented hash=d4a17c9d9882]
    public static func runTools(_ tools: [Tool], calls: [PendingCall]) async throws -> [DispatchResult] {
        guard !calls.isEmpty else { return [] }
        var ordered = [DispatchResult?](repeating: nil, count: calls.count)
        try await withThrowingTaskGroup(of: (Int, DispatchResult).self) { group in
            for (index, item) in calls.enumerated() {
                group.addTask {
                    if let error = item.error {
                        return (index, makeDispatchResult(call: item.call, settlement: ToolSettlement(result: .error(.string(error)))))
                    }
                    let res = try await dispatch(tools, call: item.call)
                    return (index, res)
                }
            }
            for try await (index, res) in group {
                ordered[index] = res
            }
        }
        return ordered.compactMap { $0 }
    }

    // parity: ai/src/tool-runtime.ts#ToolRuntime [status=implemented hash=de029082e5fc]
    public enum ToolRuntime {
        public static func dispatch(_ tools: [Tool], call: AISchema.ToolCallPart) async throws -> DispatchResult {
            try await AITool.dispatch(tools, call: call)
        }
    }
}

/// Multi-step agent tool loop helpers and stream collector.
/// Ports `packages/ai/src/loop.ts`.
public enum AILoop {
    private static func invalidCall(_ event: AISchema.ToolInputError) -> AISchema.ToolCallPart {
        AISchema.ToolCallPart.make(id: event.id, name: event.name, namespace: event.namespace, input: .object([:]))
    }

    private static func withInvalidCalls(
        _ message: AISchema.AssistantMessage,
        calls: [AISchema.ToolCallPart]
    ) -> AISchema.AssistantMessage {
        guard !calls.isEmpty else { return message }
        return AISchema.AssistantMessage(
            id: message.id,
            content: message.content + calls.map { .toolCall($0) },
            providerMetadata: message.providerMetadata
        )
    }

    /// Client calls to answer before the next step.
    // parity: ai/src/loop.ts#pendingCalls [status=implemented hash=8aa2d0f9d0d9]
    public static func pendingCalls(_ response: AISchema.LLMResponse, answerTool: String? = nil) -> [AITool.PendingCall] {
        if response.finishReason.normalized == .length { return [] }
        if let answerTool, response.toolCalls.contains(where: { $0.name == answerTool }) { return [] }
        var out: [AITool.PendingCall] = response.toolCalls
            .filter { $0.providerExecuted != true }
            .map { AITool.PendingCall(call: $0.asToolCallPart) }
        for event in response.events {
            if case .toolInputError(let err) = event {
                out.append(AITool.PendingCall(
                    call: invalidCall(err),
                    error: "Invalid tool arguments: the input is not valid JSON. Received: \(err.raw)"
                ))
            }
        }
        return out
    }

    /// The step's assistant message followed by one tool message per call, in call order.
    // parity: ai/src/loop.ts#stepMessages [status=implemented hash=1f1cd0277d58]
    public static func stepMessages(
        response: AISchema.LLMResponse,
        calls: [AITool.PendingCall],
        results: [AITool.DispatchResult]
    ) -> [AISchema.Message] {
        let invalidCalls = calls.compactMap { $0.error == nil ? nil : $0.call }
        var messages: [AISchema.Message] = [.assistant(withInvalidCalls(response.message, calls: invalidCalls))]
        for (idx, item) in calls.enumerated() where idx < results.count {
            messages.append(AISchema.Message.tool(
                id: item.call.id,
                name: item.call.name,
                namespace: item.call.namespace,
                result: results[idx].result,
                providerMetadata: item.call.providerMetadata
            ))
        }
        return messages
    }

    /// The request for the step after `response`, with its messages and tool results appended.
    // parity: ai/src/loop.ts#nextRequest [status=implemented hash=c4b253f35e17]
    public static func nextRequest(
        _ request: AISchema.LLMRequest,
        response: AISchema.LLMResponse,
        calls: [AITool.PendingCall],
        results: [AITool.DispatchResult],
        keepForcedChoice: Bool
    ) -> AISchema.LLMRequest {
        let nextChoice: AISchema.ToolChoice?
        if !keepForcedChoice, let choice = request.toolChoice, (choice.type == .required || choice.type == .tool) {
            nextChoice = AISchema.ToolChoice(type: .auto, disableParallelToolUse: choice.disableParallelToolUse)
        } else {
            nextChoice = request.toolChoice
        }
        return request.replacing(
            messages: request.messages + stepMessages(response: response, calls: calls, results: results),
            toolChoice: .some(nextChoice)
        )
    }

    /// Sum usage across steps (`contextTokens` keeps the latest call's value).
    // parity: ai/src/loop.ts#addUsage [status=implemented hash=2f6722d7d8fe]
    public static func addUsage(_ total: AISchema.Usage?, _ step: AISchema.Usage?) -> AISchema.Usage? {
        guard let total else { return step }
        guard let step else { return total }
        func sum(_ a: Double?, _ b: Double?) -> Double? {
            if a == nil && b == nil { return nil }
            return (a ?? 0) + (b ?? 0)
        }
        return AISchema.Usage(
            contextTokens: step.contextTokens ?? total.contextTokens,
            inputTokens: sum(total.inputTokens, step.inputTokens),
            outputTokens: sum(total.outputTokens, step.outputTokens),
            nonCachedInputTokens: sum(total.nonCachedInputTokens, step.nonCachedInputTokens),
            cacheReadInputTokens: sum(total.cacheReadInputTokens, step.cacheReadInputTokens),
            cacheWriteInputTokens: sum(total.cacheWriteInputTokens, step.cacheWriteInputTokens),
            reasoningTokens: sum(total.reasoningTokens, step.reasoningTokens),
            totalTokens: sum(total.totalTokens, step.totalTokens),
            cost: sum(total.cost, step.cost)
        )
    }

    // parity: ai/src/loop.ts#Collected [status=implemented hash=dcbe2e4e71bf]
    public struct Collected: Equatable, Sendable {
        public let text: String
        public let steps: [AISchema.LLMResponse]
        public let messages: [AISchema.Message]
        public let usage: AISchema.Usage?
        public let finishReason: AISchema.FinishReasonDetails
        public let object: JSONValue?

        public init(
            text: String,
            steps: [AISchema.LLMResponse],
            messages: [AISchema.Message],
            usage: AISchema.Usage? = nil,
            finishReason: AISchema.FinishReasonDetails,
            object: JSONValue? = nil
        ) {
            self.text = text
            self.steps = steps
            self.messages = messages
            self.usage = usage
            self.finishReason = finishReason
            self.object = object
        }
    }

    // parity: ai/src/loop.ts#CollectResult [status=implemented hash=77aa6402f3eb]
    public typealias CollectResult = Collected

    /// Run a stream from `stream` or `loop` to the end and fold its events into the final `Collected` result.
    // parity: ai/src/loop.ts#collect [status=implemented hash=b3b302235e25]
    public static func collect(_ events: AsyncThrowingStream<AISchema.LLMEvent, Error>) async throws -> Collected {
        var steps: [AISchema.LLMResponse] = []
        var messages: [AISchema.Message] = []
        var step = AISchema.ResponseFold.empty()
        var betweenSteps = false
        var assistantIndex = -1
        var invalid: [AISchema.ToolCallPart] = []
        var finishEvent: AISchema.Finish? = nil

        func closeStep(reason: AISchema.FinishReasonDetails, usage: AISchema.Usage?) {
            guard !step.events.isEmpty else { return }
            let response = AISchema.LLMResponse(
                message: step.message,
                events: step.events,
                usage: usage ?? step.usage,
                finishReason: reason
            )
            steps.append(response)
            messages.append(.assistant(response.message))
            assistantIndex = messages.count - 1
            invalid = step.events.compactMap { ev in
                if case .toolInputError(let err) = ev { return invalidCall(err) }
                return nil
            }
            step = AISchema.ResponseFold.empty()
        }

        for try await event in events {
            switch event {
            case .finish(let f):
                closeStep(reason: f.reason, usage: f.usage)
                finishEvent = f
            case .toolResult(let tr) where betweenSteps:
                if let call = invalid.first(where: { $0.id == tr.id }),
                   assistantIndex >= 0,
                   case .assistant(let prev) = messages[assistantIndex] {
                    messages[assistantIndex] = .assistant(withInvalidCalls(prev, calls: [call]))
                }
                messages.append(AISchema.Message.tool(
                    id: tr.id,
                    name: tr.name,
                    namespace: tr.namespace,
                    result: tr.result,
                    providerMetadata: tr.providerMetadata
                ))
            case .stepStart:
                betweenSteps = false
                step = AISchema.ResponseFold.reduce(step, event)
            case .stepFinish(let sf):
                step = AISchema.ResponseFold.reduce(step, event)
                closeStep(reason: sf.reason, usage: sf.usage)
                betweenSteps = true
            default:
                step = AISchema.ResponseFold.reduce(step, event)
            }
        }

        guard let finishEvent else {
            throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                message: "The stream ended without a finish event.",
                classification: .incompleteStream
            )))
        }

        return Collected(
            text: steps.last?.text ?? "",
            steps: steps,
            messages: messages,
            usage: finishEvent.usage,
            finishReason: finishEvent.reason,
            object: finishEvent.object
        )
    }
}

/// High-level text LLM API: request normalization, single-step generate/stream, structured
/// object extraction, multi-step tool loops, and compaction.
///
/// Ports `packages/ai/src/llm.ts`.
public enum AILLM {
    // parity: ai/src/llm.ts#PromptOrMessages [status=implemented hash=e9f33d1743b3]
    public enum PromptOrMessages: Sendable {
        case prompt(AISchema.Message.UserContentInput)
        case messages([AISchema.Message.Input])

        public static func promptText(_ text: String) -> PromptOrMessages {
            .prompt(.text(text))
        }

        public static func messages(_ list: [AISchema.Message]) -> PromptOrMessages {
            .messages(list.map { .message($0) })
        }
    }

    // parity: ai/src/llm.ts#OutputSchema [status=implemented hash=3e2c8f6e025c]
    public typealias OutputSchema = AITool.ToolInput

    // parity: ai/src/llm.ts#OutputType [status=adapted hash=dd5a608327ac]
    public typealias OutputType = JSONValue

    // parity: ai/src/llm.ts#ObjectResponse [status=implemented hash=98dfd16b53db]
    public struct ObjectResponse: Equatable, Sendable {
        public let response: AISchema.LLMResponse
        public let object: JSONValue

        public init(response: AISchema.LLMResponse, object: JSONValue) {
            self.response = response
            self.object = object
        }
    }

    // parity: ai/src/llm.ts#ObjectEvent [status=implemented hash=ff381c0a4a61]
    public typealias ObjectEvent = AISchema.LLMEvent

    // parity: ai/src/llm.ts#LoopObjectEvent [status=implemented hash=7a2964f89154]
    public typealias LoopObjectEvent = AISchema.LLMEvent

    public enum SystemInput: Sendable {
        case text(String)
        case part(AISchema.SystemPart)
        case parts([AISchema.SystemPart])

        public var parts: [AISchema.SystemPart] {
            switch self {
            case .text(let s): AISchema.SystemPart.content(s)
            case .part(let p): [p]
            case .parts(let ps): ps
            }
        }
    }

    // parity: ai/src/llm.ts#LLMRequestInput [status=implemented hash=e83e87203d2c]
    public struct LLMRequestInput: Sendable {
        public let id: String?
        public let model: AISchema.LanguageModel
        public let system: SystemInput?
        public let input: PromptOrMessages?
        public let tools: [AITool.ToolChangesInput.AddItem]?
        public let toolChoice: AISchema.ToolChoice.Input?
        public let maxTokens: Int?
        public let temperature: Double?
        public let topP: Double?
        public let topK: Int?
        public let frequencyPenalty: Double?
        public let presencePenalty: Double?
        public let seed: Int?
        public let stop: [String]?
        public let providerOptions: AISchema.ProviderOptions?
        public let headers: [String: String]?
        public let timeout: AISchema.RequestTimeout?
        public let http: AISchema.HttpOptions?
        public let fetch: (any HTTPTransport)?
        public let cache: AISchema.CachePolicy?
        public let promptCacheKey: String?
        public let includeRaw: Bool?
        public let schema: OutputSchema?

        public init(
            id: String? = nil,
            model: AISchema.LanguageModel,
            system: SystemInput? = nil,
            input: PromptOrMessages?,
            tools: [AITool.ToolChangesInput.AddItem]? = nil,
            toolChoice: AISchema.ToolChoice.Input? = nil,
            maxTokens: Int? = nil,
            temperature: Double? = nil,
            topP: Double? = nil,
            topK: Int? = nil,
            frequencyPenalty: Double? = nil,
            presencePenalty: Double? = nil,
            seed: Int? = nil,
            stop: [String]? = nil,
            providerOptions: AISchema.ProviderOptions? = nil,
            headers: [String: String]? = nil,
            timeout: AISchema.RequestTimeout? = nil,
            http: AISchema.HttpOptions? = nil,
            fetch: (any HTTPTransport)? = nil,
            cache: AISchema.CachePolicy? = nil,
            promptCacheKey: String? = nil,
            includeRaw: Bool? = nil,
            schema: OutputSchema? = nil
        ) {
            self.id = id
            self.model = model
            self.system = system
            self.input = input
            self.tools = tools
            self.toolChoice = toolChoice
            self.maxTokens = maxTokens
            self.temperature = temperature
            self.topP = topP
            self.topK = topK
            self.frequencyPenalty = frequencyPenalty
            self.presencePenalty = presencePenalty
            self.seed = seed
            self.stop = stop
            self.providerOptions = providerOptions
            self.headers = headers
            self.timeout = timeout
            self.http = http
            self.fetch = fetch
            self.cache = cache
            self.promptCacheKey = promptCacheKey
            self.includeRaw = includeRaw
            self.schema = schema
        }
    }

    // parity: ai/src/llm.ts#LLMLoopInput [status=implemented hash=5b6eb697b6f6]
    public struct LLMLoopInput: Sendable {
        public let request: LLMRequestInput
        public let tools: [AITool.ExecutableTool]
        public let until: (@Sendable ([AISchema.LLMResponse]) -> Bool)?

        public init(
            request: LLMRequestInput,
            tools: [AITool.ExecutableTool],
            until: (@Sendable ([AISchema.LLMResponse]) -> Bool)? = nil
        ) {
            self.request = request
            self.tools = tools
            self.until = until
        }
    }

    private static let objectToolName = "generate_object"

    /// Normalize text request input into a plain `AISchema.LLMRequest`.
    // parity: ai/src/llm.ts#request [status=implemented hash=e76bb07ee142]
    public static func request(_ input: LLMRequestInput) throws(AISchema.AIError) -> AISchema.LLMRequest {
        guard let promptOrMessages = input.input else {
            throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                message: "Pass exactly one of `prompt` or `messages`, not both or neither"
            )))
        }
        let messages: [AISchema.Message] = switch promptOrMessages {
        case .prompt(let userContent):
            [AISchema.Message.make(.user(AISchema.Message.UserInput(content: userContent)))]
        case .messages(let list):
            list.map(AISchema.Message.make)
        }
        return AISchema.LLMRequest(
            id: input.id,
            model: input.model,
            system: input.system?.parts ?? [],
            messages: messages,
            tools: input.tools?.map(\.toolEntry) ?? [],
            toolChoice: input.toolChoice.map(AISchema.ToolChoice.make),
            maxTokens: input.maxTokens,
            temperature: input.temperature,
            topP: input.topP,
            topK: input.topK,
            frequencyPenalty: input.frequencyPenalty,
            presencePenalty: input.presencePenalty,
            seed: input.seed,
            stop: input.stop,
            providerOptions: input.providerOptions,
            headers: input.headers,
            timeout: input.timeout,
            http: input.http,
            fetch: input.fetch,
            cache: input.cache,
            promptCacheKey: input.promptCacheKey,
            includeRaw: input.includeRaw
        )
    }

    private static func prepare(_ input: LLMRequestInput) throws(AISchema.AIError) -> (request: AISchema.LLMRequest, outputTool: AITool.Tool?) {
        let outputTool: AITool.Tool?
        let effectiveInput: LLMRequestInput
        if let schema = input.schema {
            let builtTool = try AITool.tool(AITool.ToolOptions(
                name: objectToolName,
                description: "Return the structured result by calling this tool.",
                input: schema
            ))
            outputTool = builtTool
            let existing = input.tools ?? []
            let forcedChoice: AISchema.ToolChoice.Input = existing.isEmpty
                ? .choice(AISchema.ToolChoice.named(objectToolName))
                : .choice(AISchema.ToolChoice(type: .required))
            effectiveInput = LLMRequestInput(
                id: input.id,
                model: input.model,
                system: input.system,
                input: input.input,
                tools: existing + [.tool(builtTool)],
                toolChoice: forcedChoice,
                maxTokens: input.maxTokens,
                temperature: input.temperature,
                topP: input.topP,
                topK: input.topK,
                frequencyPenalty: input.frequencyPenalty,
                presencePenalty: input.presencePenalty,
                seed: input.seed,
                stop: input.stop,
                providerOptions: input.providerOptions,
                headers: input.headers,
                timeout: input.timeout,
                http: input.http,
                fetch: input.fetch,
                cache: input.cache,
                promptCacheKey: input.promptCacheKey,
                includeRaw: input.includeRaw,
                schema: nil
            )
        } else {
            outputTool = nil
            effectiveInput = input
        }

        let built = try request(effectiveInput)
        var seen: Set<String> = []
        for entry in built.tools {
            if !seen.insert(entry.name).inserted {
                throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                    message: "Duplicate tool name: \(entry.name)"
                )))
            }
        }
        return (built, outputTool)
    }

    private static func decodeObject(_ outputTool: AITool.Tool, response: AISchema.LLMResponse) throws(AISchema.AIError) -> JSONValue {
        func invalid(_ message: String, cause: String? = nil) -> AISchema.AIError {
            AISchema.AIError(
                reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(message: message, cause: cause)),
                partial: response
            )
        }
        if response.finishReason.normalized == .length {
            throw invalid("output hit the token limit before the forced tool call completed")
        }
        guard let call = response.toolCalls.first(where: { $0.name == objectToolName }) else {
            throw invalid("model did not call the forced `\(objectToolName)` tool")
        }
        do {
            return try outputTool.decodeInput(call.input)
        } catch {
            throw invalid("schema decode failed: \(error)", cause: String(describing: error))
        }
    }

    private static func runnableTools(
        base: [AITool.Tool],
        messages: [AISchema.Message.Input]
    ) -> [AITool.Tool] {
        var current: [AITool.ToolChangesInput.AddItem] = base.map { .tool($0) }
        for input in messages {
            if case .system(let sys) = input, let changes = sys.tools {
                current = AIToolUpdates.foldTools(
                    current,
                    add: changes.add,
                    remove: changes.remove.map(\.name),
                    nameOf: \.name
                )
            }
        }
        return current.compactMap { item in
            if case .tool(let t) = item { return t }
            return nil
        }
    }

    // parity: ai/src/llm.ts#generate [status=implemented hash=7d77e4922a78]
    public static func generate(
        _ input: LLMRequestInput,
        options: AIRoute.StreamOptions? = nil,
        client: any AIRoute.Interface
    ) async throws -> AISchema.LLMResponse {
        let prepared = try prepare(input)
        let response = try await client.generate(prepared.request, options: options)
        if let outputTool = prepared.outputTool {
            _ = try decodeObject(outputTool, response: response)
        }
        return response
    }

    public static func generateObject(
        _ input: LLMRequestInput,
        options: AIRoute.StreamOptions? = nil,
        client: any AIRoute.Interface
    ) async throws -> ObjectResponse {
        let prepared = try prepare(input)
        let response = try await client.generate(prepared.request, options: options)
        guard let outputTool = prepared.outputTool else {
            throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                message: "generateObject requires `schema` on the request input"
            )))
        }
        let decoded = try decodeObject(outputTool, response: response)
        return ObjectResponse(response: response, object: decoded)
    }

    // parity: ai/src/llm.ts#stream [status=implemented hash=d567cb83823c]
    public static func stream(
        _ input: LLMRequestInput,
        options: AIRoute.StreamOptions? = nil,
        client: any AIRoute.Interface
    ) -> AsyncThrowingStream<AISchema.LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prepared = try prepare(input)
                    var state = AISchema.ResponseFold.empty()
                    var finish: AISchema.Finish? = nil
                    do {
                        for try await event in client.stream(prepared.request, options: options) {
                            state = AISchema.ResponseFold.reduce(state, event)
                            if case .finish(let f) = event {
                                finish = f
                            } else {
                                continuation.yield(event)
                            }
                        }
                    } catch let aiError as AISchema.AIError {
                        throw AISchema.withPartial(aiError, partial: AISchema.ResponseFold.partial(state))
                    }
                    if let response = AISchema.ResponseFold.complete(state), let finish {
                        let decodedObj: JSONValue? = if let outputTool = prepared.outputTool {
                            try decodeObject(outputTool, response: response)
                        } else {
                            nil
                        }
                        continuation.yield(.finish(AISchema.Finish(
                            reason: finish.reason,
                            usage: response.usage,
                            message: response.message,
                            providerMetadata: finish.providerMetadata,
                            object: decodedObj
                        )))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Stream model calls, executing client tool calls between steps until no pending calls remain,
    /// output hits `length`, or `until` returns `true`.
    // parity: ai/src/llm.ts#loop [status=implemented hash=c6f878f2ee9b]
    public static func loop(
        _ input: LLMLoopInput,
        options: AIRoute.StreamOptions? = nil,
        client: any AIRoute.Interface
    ) -> AsyncThrowingStream<AISchema.LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let toolItems: [AITool.ToolChangesInput.AddItem] = input.tools.map { .tool($0) }
                    let mergedInput = LLMRequestInput(
                        id: input.request.id,
                        model: input.request.model,
                        system: input.request.system,
                        input: input.request.input,
                        tools: toolItems,
                        toolChoice: input.request.toolChoice,
                        maxTokens: input.request.maxTokens,
                        temperature: input.request.temperature,
                        topP: input.request.topP,
                        topK: input.request.topK,
                        frequencyPenalty: input.request.frequencyPenalty,
                        presencePenalty: input.request.presencePenalty,
                        seed: input.request.seed,
                        stop: input.request.stop,
                        providerOptions: input.request.providerOptions,
                        headers: input.request.headers,
                        timeout: input.request.timeout,
                        http: input.request.http,
                        fetch: input.request.fetch,
                        cache: input.request.cache,
                        promptCacheKey: input.request.promptCacheKey,
                        includeRaw: input.request.includeRaw,
                        schema: input.request.schema
                    )
                    let prepared = try prepare(mergedInput)
                    let initialMessages: [AISchema.Message.Input] = if case .messages(let m) = input.request.input { m } else { [] }
                    let executableTools = runnableTools(base: input.tools, messages: initialMessages)

                    var currentRequest = prepared.request
                    var completedSteps: [AISchema.LLMResponse] = []
                    var totalUsage: AISchema.Usage? = nil

                    while true {
                        let stepIndex = completedSteps.count
                        var state = AISchema.ResponseFold.empty()
                        var stepFinishEvent: AISchema.Finish? = nil
                        do {
                            for try await rawEvent in client.stream(currentRequest, options: options) {
                                let reindexed: AISchema.LLMEvent = switch rawEvent {
                                case .stepStart:
                                    .stepStart(AISchema.StepStart(index: stepIndex))
                                case .stepFinish(let sf):
                                    .stepFinish(AISchema.StepFinish(
                                        index: stepIndex,
                                        reason: sf.reason,
                                        usage: sf.usage,
                                        providerMetadata: sf.providerMetadata
                                    ))
                                default:
                                    rawEvent
                                }
                                state = AISchema.ResponseFold.reduce(state, reindexed)
                                if case .finish(let f) = reindexed {
                                    stepFinishEvent = f
                                } else {
                                    continuation.yield(reindexed)
                                }
                            }
                        } catch let aiError as AISchema.AIError {
                            throw AISchema.withPartial(aiError, partial: AISchema.ResponseFold.partial(state))
                        }

                        guard let response = AISchema.ResponseFold.complete(state), let finish = stepFinishEvent else {
                            break
                        }
                        totalUsage = AILoop.addUsage(totalUsage, response.usage)
                        let calls = AILoop.pendingCalls(response, answerTool: prepared.outputTool != nil ? objectToolName : nil)
                        completedSteps.append(response)

                        if calls.isEmpty || input.until?(completedSteps) == true {
                            let decodedObj: JSONValue? = if calls.isEmpty, let outputTool = prepared.outputTool {
                                try decodeObject(outputTool, response: response)
                            } else {
                                nil
                            }
                            continuation.yield(.finish(AISchema.Finish(
                                reason: finish.reason,
                                usage: totalUsage,
                                message: response.message,
                                providerMetadata: finish.providerMetadata,
                                object: decodedObj
                            )))
                            break
                        }

                        let results = try await AITool.runTools(executableTools, calls: calls)
                        for res in results {
                            for ev in res.events {
                                continuation.yield(ev)
                            }
                        }
                        currentRequest = AILoop.nextRequest(
                            currentRequest,
                            response: response,
                            calls: calls,
                            results: results,
                            keepForcedChoice: prepared.outputTool != nil
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // parity: ai/src/llm.ts#compact [status=implemented hash=6a098df06073]
    public static func compact(
        _ input: LLMRequestInput,
        options: AIRoute.CompactOptions = .endpoint(nil),
        client: any AIRoute.Interface
    ) async throws -> AIRoute.CompactionResult {
        let normalized = try request(input)
        return try await AIRoute.compactRequest(normalized, options: options, client: client)
    }
}

/// Portable media asset representation, lazy byte/base64 caching, data-URL parsing,
/// file I/O via `OpenCodeFileSystem`, and media model/client abstractions.
///
/// Ports `packages/ai/src/{media,media-model,media-client}.ts`.
public enum AIMedia {
    private static let octetStream = "application/octet-stream"

    // parity: ai/src/media.ts#Source [status=implemented hash=72a54222141a]
    public enum Source: Equatable, Hashable, Sendable, Codable {
        case bytes(data: [UInt8], mediaType: String)
        case base64(data: String, mediaType: String)
        case url(url: String, mediaType: String?, expiresAt: Double?)
        case ref(provider: AISchema.ProviderID, id: String, mediaType: String?)

        public var mediaType: String? {
            switch self {
            case .bytes(_, let mt): mt
            case .base64(_, let mt): mt
            case .url(_, let mt, _): mt
            case .ref(_, _, let mt): mt
            }
        }

        public var typeName: String {
            switch self {
            case .bytes: "bytes"
            case .base64: "base64"
            case .url: "url"
            case .ref: "ref"
            }
        }

        enum CodingKeys: String, CodingKey {
            case type, data, mediaType, url, expiresAt, provider, id
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "bytes":
                let mt = try c.decode(String.self, forKey: .mediaType)
                if let b64 = try? c.decode(String.self, forKey: .data) {
                    let decoded = try base64ToBytes(b64)
                    self = .bytes(data: decoded, mediaType: mt)
                } else {
                    self = .bytes(data: try c.decode([UInt8].self, forKey: .data), mediaType: mt)
                }
            case "base64":
                self = .base64(
                    data: try c.decode(String.self, forKey: .data),
                    mediaType: try c.decode(String.self, forKey: .mediaType)
                )
            case "url":
                self = .url(
                    url: try c.decode(String.self, forKey: .url),
                    mediaType: try c.decodeIfPresent(String.self, forKey: .mediaType),
                    expiresAt: try c.decodeIfPresent(Double.self, forKey: .expiresAt)
                )
            case "ref":
                self = .ref(
                    provider: try c.decode(AISchema.ProviderID.self, forKey: .provider),
                    id: try c.decode(String.self, forKey: .id),
                    mediaType: try c.decodeIfPresent(String.self, forKey: .mediaType)
                )
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown Media.Source type '\(type)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(typeName, forKey: .type)
            switch self {
            case .bytes(let data, let mt):
                try c.encode(bytesToBase64(data), forKey: .data)
                try c.encode(mt, forKey: .mediaType)
            case .base64(let data, let mt):
                try c.encode(data, forKey: .data)
                try c.encode(mt, forKey: .mediaType)
            case .url(let url, let mt, let expiresAt):
                try c.encode(url, forKey: .url)
                try c.encodeIfPresent(mt, forKey: .mediaType)
                try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
            case .ref(let provider, let id, let mt):
                try c.encode(provider, forKey: .provider)
                try c.encode(id, forKey: .id)
                try c.encodeIfPresent(mt, forKey: .mediaType)
            }
        }
    }

    // parity: ai/src/media.ts#AspectRatio [status=implemented hash=86c5bc0a6ccd]
    public struct AspectRatio: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            guard Self.isValid(rawValue) else { return nil }
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        public static func isValid(_ value: String) -> Bool {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return false }
            return isDecimal(parts[0]) && isDecimal(parts[1])
        }

        private static func isDecimal(_ s: Substring) -> Bool {
            let b = Array(s.utf8)
            guard !b.isEmpty else { return false }
            var i = 0
            while i < b.count && b[i] >= 0x30 && b[i] <= 0x39 { i += 1 }
            guard i > 0 else { return false }
            if i == b.count { return true }
            guard b[i] == 0x2E else { return false }
            i += 1
            let start = i
            while i < b.count && b[i] >= 0x30 && b[i] <= 0x39 { i += 1 }
            return i > start && i == b.count
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard Self.isValid(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid Media.AspectRatio '\(s)'")
            }
            self.rawValue = s
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
    }

    // parity: ai/src/media.ts#Kind [status=implemented hash=4bb222e1194e]
    public enum Kind: String, Equatable, Hashable, Sendable, Codable {
        case image
        case video
        case audio
        case document
        case other
    }

    // parity: ai/src/media.ts#kindOf [status=implemented hash=e1405aea816d]
    public static func kindOf(_ mediaType: String) -> Kind {
        let lower = mediaType.lowercased()
        if lower.hasPrefix("image/") { return .image }
        if lower.hasPrefix("video/") { return .video }
        if lower.hasPrefix("audio/") { return .audio }
        if lower == "application/pdf" || lower.hasPrefix("text/") { return .document }
        return .other
    }

    // parity: ai/src/media.ts#Info [status=implemented hash=0ecf42de4863]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let width: Double?
        public let height: Double?
        public let durationSeconds: Double?
        public let sampleRate: Double?
        public let channels: Double?
        public let encoding: String?
        public let format: String?

        public init(
            width: Double? = nil,
            height: Double? = nil,
            durationSeconds: Double? = nil,
            sampleRate: Double? = nil,
            channels: Double? = nil,
            encoding: String? = nil,
            format: String? = nil
        ) {
            self.width = width
            self.height = height
            self.durationSeconds = durationSeconds
            self.sampleRate = sampleRate
            self.channels = channels
            self.encoding = encoding
            self.format = format
        }
    }

    // parity: ai/src/media.ts#Inline [status=implemented hash=7c640861d00d]
    public struct Inline: Equatable, Hashable, Sendable {
        public let mime: String
        public let base64: String
        public let dataUrl: String

        public init(mime: String, base64: String, dataUrl: String) {
            self.mime = mime
            self.base64 = base64
            self.dataUrl = dataUrl
        }
    }

    // parity: ai/src/media.ts#AssetOptions [status=implemented hash=1352a936a106]
    public struct AssetOptions: Sendable {
        public let info: Info?
        public let providerMetadata: AISchema.ProviderMetadata?
        public let headers: [String: String]?
        public let middleware: AIRequestExecutor.HttpMiddleware?

        public init(
            info: Info? = nil,
            providerMetadata: AISchema.ProviderMetadata? = nil,
            headers: [String: String]? = nil,
            middleware: AIRequestExecutor.HttpMiddleware? = nil
        ) {
            self.info = info
            self.providerMetadata = providerMetadata
            self.headers = headers
            self.middleware = middleware
        }
    }

    // parity: ai/src/media.ts#AssetEncoded [status=implemented hash=4274ccf79369]
    public struct AssetEncoded: Equatable, Hashable, Sendable, Codable {
        public let source: Source
        public let info: Info?
        public let providerMetadata: AISchema.ProviderMetadata?

        public init(source: Source, info: Info? = nil, providerMetadata: AISchema.ProviderMetadata? = nil) {
            self.source = source
            self.info = info
            self.providerMetadata = providerMetadata
        }
    }

    // parity: ai/src/media.ts#Asset [status=implemented hash=951bb72e15f3]
    public final class Asset: Equatable, Sendable, Codable {
        // parity: ai/src/media.ts#Asset.Input [status=implemented hash=88b7a8fd1370]
        public struct Input: Sendable {
            public let source: Source
            public let info: Info?
            public let providerMetadata: AISchema.ProviderMetadata?
            public let headers: [String: String]?
            public let middleware: AIRequestExecutor.HttpMiddleware?

            public init(
                source: Source,
                info: Info? = nil,
                providerMetadata: AISchema.ProviderMetadata? = nil,
                headers: [String: String]? = nil,
                middleware: AIRequestExecutor.HttpMiddleware? = nil
            ) {
                self.source = source
                self.info = info
                self.providerMetadata = providerMetadata
                self.headers = headers
                self.middleware = middleware
            }
        }

        private struct Cache: Sendable {
            var bytes: [UInt8]?
            var base64: String?
        }

        public let source: Source
        public let mediaType: String
        public let kind: Kind
        public let info: Info?
        public let expiresAt: Double?
        public let providerMetadata: AISchema.ProviderMetadata?
        public let headers: [String: String]?
        public let middleware: AIRequestExecutor.HttpMiddleware?
        private let cache = Mutex(Cache())

        public init(_ input: Input) {
            self.source = input.source
            let sniffed: String? = if case .bytes(let data, _) = input.source {
                AIUtils.detectMediaType(data)
            } else {
                nil
            }
            self.mediaType = input.source.mediaType ?? sniffed ?? AIMedia.octetStream
            self.kind = AIMedia.kindOf(self.mediaType)
            self.info = input.info
            if case .url(_, _, let exp) = input.source {
                self.expiresAt = exp
                self.headers = input.headers
                self.middleware = input.middleware
            } else {
                self.expiresAt = nil
                self.headers = nil
                self.middleware = nil
            }
            self.providerMetadata = input.providerMetadata
        }

        public static func == (lhs: Asset, rhs: Asset) -> Bool {
            lhs.source == rhs.source && lhs.info == rhs.info && lhs.providerMetadata == rhs.providerMetadata
        }

        public func inline() -> Inline? {
            switch source {
            case .bytes(let data, _):
                let b64 = cache.withLock { c -> String in
                    if let existing = c.base64 { return existing }
                    let encoded = bytesToBase64(data)
                    c.base64 = encoded
                    return encoded
                }
                let mime = mediaType.lowercased()
                return Inline(mime: mime, base64: b64, dataUrl: "data:\(mime);base64,\(b64)")
            case .base64(let b64, _):
                let mime = mediaType.lowercased()
                return Inline(mime: mime, base64: b64, dataUrl: "data:\(mime);base64,\(b64)")
            case .url, .ref:
                return nil
            }
        }

        public func bytes(executor: AIRequestExecutor.RequestExecutorService? = nil) async throws -> [UInt8] {
            switch source {
            case .bytes(let data, _):
                return data
            case .ref(let provider, let id, _):
                throw AIMedia.invalid("Cannot materialize provider ref \(provider.rawValue):\(id)")
            case .base64(let b64, _):
                if let cached = cache.withLock({ $0.bytes }) { return cached }
                let decoded: [UInt8]
                do {
                    decoded = try base64ToBytes(b64)
                } catch {
                    throw AIMedia.invalid("Media asset contains invalid base64 data", cause: String(describing: error))
                }
                cache.withLock { $0.bytes = decoded }
                return decoded
            case .url(let rawUrl, _, _):
                if let cached = cache.withLock({ $0.bytes }) { return cached }
                guard let executor else {
                    throw AIMedia.invalid("Downloading url media asset requires a RequestExecutor")
                }
                let req = HTTPRequest(method: "GET", url: rawUrl, headers: headers ?? [:])
                let resp = try await AIRequestExecutor.$CurrentMiddleware.withValue(middleware) {
                    try await executor.execute(req, middleware: nil)
                }
                let data = try await AIRequestExecutor.responseBytes(resp)
                cache.withLock { $0.bytes = data }
                return data
            }
        }

        public func stream(executor: AIRequestExecutor.RequestExecutorService? = nil) -> AsyncThrowingStream<[UInt8], Error> {
            if case .url(let rawUrl, _, _) = source, cache.withLock({ $0.bytes }) == nil {
                return AsyncThrowingStream { continuation in
                    let task = Task {
                        do {
                            guard let executor else {
                                throw AIMedia.invalid("Downloading url media asset requires a RequestExecutor")
                            }
                            let req = HTTPRequest(method: "GET", url: rawUrl, headers: headers ?? [:])
                            let resp = try await AIRequestExecutor.$CurrentMiddleware.withValue(middleware) {
                                try await executor.execute(req, middleware: nil)
                            }
                            for try await chunk in AIRequestExecutor.responseStream(resp) {
                                continuation.yield(chunk)
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let data = try await self.bytes(executor: executor)
                        if !data.isEmpty { continuation.yield(data) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        public func base64(executor: AIRequestExecutor.RequestExecutorService? = nil) async throws -> String {
            if case .base64(let b64, _) = source { return b64 }
            if let cached = cache.withLock({ $0.base64 }) { return cached }
            let raw = try await bytes(executor: executor)
            let encoded = bytesToBase64(raw)
            cache.withLock { $0.base64 = encoded }
            return encoded
        }

        public func dataUrl(executor: AIRequestExecutor.RequestExecutorService? = nil) async throws -> String {
            let b64 = try await base64(executor: executor)
            return "data:\(mediaType);base64,\(b64)"
        }

        public func toEncoded() -> AssetEncoded {
            AssetEncoded(source: source, info: info, providerMetadata: providerMetadata)
        }

        public func materialize(executor: AIRequestExecutor.RequestExecutorService? = nil) async throws -> Asset {
            switch source {
            case .bytes, .base64:
                return self
            case .url, .ref:
                let data = try await bytes(executor: executor)
                return AIMedia.bytes(
                    data,
                    mediaType: source.mediaType,
                    options: AssetOptions(info: info, providerMetadata: providerMetadata)
                )
            }
        }

        public convenience init(from decoder: Decoder) throws {
            let encoded = try AssetEncoded(from: decoder)
            self.init(Input(source: encoded.source, info: encoded.info, providerMetadata: encoded.providerMetadata))
        }

        public func encode(to encoder: Encoder) throws {
            try toEncoded().encode(to: encoder)
        }
    }

    // parity: ai/src/media.ts#AssetSchema [status=adapted hash=337ef619c4be]
    public static func AssetSchema(_ encoded: AssetEncoded) -> Asset {
        Asset(Asset.Input(source: encoded.source, info: encoded.info, providerMetadata: encoded.providerMetadata))
    }

    // parity: ai/src/media.ts#ImageAsset [status=implemented hash=e48a32f779d1]
    public struct ImageAsset: Equatable, Sendable, Codable {
        public let asset: Asset

        public init(validating asset: Asset) throws(AISchema.AIError) {
            guard Self.isValid(asset) else {
                throw AIMedia.invalid("expected an image, got \(asset.mediaType)")
            }
            self.asset = asset
        }

        public static func isValid(_ asset: Asset) -> Bool {
            if asset.kind == .image { return true }
            switch asset.source {
            case .url(_, let mt, _), .ref(_, _, let mt):
                return mt == nil
            case .bytes, .base64:
                return false
            }
        }

        public init(from decoder: Decoder) throws {
            let asset = try Asset(from: decoder)
            guard Self.isValid(asset) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "expected an image, got \(asset.mediaType)"
                ))
            }
            self.asset = asset
        }

        public func encode(to encoder: Encoder) throws {
            try asset.encode(to: encoder)
        }
    }

    // parity: ai/src/media.ts#ImageAssetSchema [status=adapted hash=bd5db310f2aa]
    public static func ImageAssetSchema(_ asset: Asset) throws(AISchema.AIError) -> ImageAsset {
        try ImageAsset(validating: asset)
    }

    // parity: ai/src/media.ts#from [status=implemented hash=5b034aa03be7]
    public static func from(_ source: Source, options: AssetOptions? = nil) -> Asset {
        Asset(Asset.Input(
            source: source,
            info: options?.info,
            providerMetadata: options?.providerMetadata,
            headers: options?.headers,
            middleware: options?.middleware
        ))
    }

    // parity: ai/src/media.ts#bytes [status=implemented hash=b7d4d0f5a9e8]
    public static func bytes(_ data: [UInt8], mediaType: String? = nil, options: AssetOptions? = nil) -> Asset {
        from(.bytes(data: data, mediaType: mediaType ?? AIUtils.detectMediaType(data) ?? octetStream), options: options)
    }

    // parity: ai/src/media.ts#base64 [status=implemented hash=67c1f7d7dd50]
    public static func base64(_ data: String, mediaType: String, options: AssetOptions? = nil) -> Asset {
        from(.base64(data: data, mediaType: mediaType), options: options)
    }

    // parity: ai/src/media.ts#url [status=implemented hash=10e3ae92ca2c]
    public static func url(
        _ value: String,
        mediaType: String? = nil,
        expiresAt: Double? = nil,
        options: AssetOptions? = nil
    ) -> Asset {
        from(.url(url: value, mediaType: mediaType, expiresAt: expiresAt), options: options)
    }

    // parity: ai/src/media.ts#ref [status=implemented hash=ec0d291d0c69]
    public static func ref(
        provider: String,
        id: String,
        mediaType: String? = nil,
        options: AssetOptions? = nil
    ) -> Asset {
        from(.ref(provider: AISchema.ProviderID.make(provider), id: id, mediaType: mediaType), options: options)
    }

    // parity: ai/src/media.ts#parseDataUrl [status=implemented hash=0d5e5f4fb37d]
    public static func parseDataUrl(_ value: String, options: AssetOptions? = nil) -> Asset? {
        let lowerPrefix = value.prefix(5).lowercased()
        guard lowerPrefix == "data:" else { return nil }
        let afterScheme = value.dropFirst(5)
        guard let commaIdx = afterScheme.firstIndex(of: ",") else { return nil }
        let header = afterScheme[..<commaIdx]
        let payload = String(afterScheme[afterScheme.index(after: commaIdx)...])
        let segments = header.split(separator: ";", omittingEmptySubsequences: false)
        guard segments.count >= 2,
              let mimeSeg = segments.first, !mimeSeg.isEmpty,
              segments.last?.lowercased() == "base64"
        else {
            return nil
        }
        return base64(payload, mediaType: String(mimeSeg), options: options)
    }

    // parity: ai/src/media.ts#fromDataUrl [status=implemented hash=e44343a7fd58]
    public static func fromDataUrl(_ dataUrl: String, options: AssetOptions? = nil) throws(AISchema.AIError) -> Asset {
        guard let asset = parseDataUrl(dataUrl, options: options) else {
            throw invalid("Media data URLs must contain a MIME type and base64 data")
        }
        return asset
    }

    // parity: ai/src/media.ts#Data [status=implemented hash=5398ee4e1860]
    public enum DataInput: Sendable {
        case bytes([UInt8])
        case url(URL)
        case string(String)
    }

    // parity: ai/src/media.ts#Input [status=implemented hash=2f494f439c20]
    public enum Input: Sendable {
        case asset(Asset)
        case data(DataInput)

        public static func bytes(_ data: [UInt8]) -> Input { .data(.bytes(data)) }
        public static func url(_ url: URL) -> Input { .data(.url(url)) }
        public static func string(_ string: String) -> Input { .data(.string(string)) }
    }

    private static func isBase64String(_ value: String) -> Bool {
        var seenEquals = 0
        var seenTrailingSpace = false
        for b in value.utf8 {
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C {
                if seenEquals > 0 { seenTrailingSpace = true }
                continue
            }
            if seenTrailingSpace { return false }
            if b == 0x3D { // '='
                seenEquals += 1
                if seenEquals > 2 { return false }
                continue
            }
            if seenEquals > 0 { return false }
            let ok = (b >= 0x41 && b <= 0x5A)
                || (b >= 0x61 && b <= 0x7A)
                || (b >= 0x30 && b <= 0x39)
                || b == 0x2B || b == 0x2F || b == 0x2D || b == 0x5F
            if !ok { return false }
        }
        return true
    }

    private static func sniffBase64(_ value: String) -> String? {
        let prefix = String(value.prefix(64))
        guard let decoded = try? base64ToBytes(prefix) else { return nil }
        return AIUtils.detectMediaType(decoded)
    }

    // parity: ai/src/media.ts#make [status=implemented hash=6235841c2172]
    public static func make(_ input: Input, mediaType: String? = nil) throws(AISchema.AIError) -> Asset {
        switch input {
        case .asset(let asset):
            return asset
        case .data(.bytes(let raw)):
            guard let resolved = mediaType ?? AIUtils.detectMediaType(raw) else {
                throw invalid("Media data needs a mediaType because its type cannot be detected")
            }
            return bytes(raw, mediaType: resolved)
        case .data(.url(let u)):
            return url(u.absoluteString, mediaType: mediaType)
        case .data(.string(let value)):
            let lower = value.lowercased()
            if lower.hasPrefix("data:") {
                guard let parsed = parseDataUrl(value) else {
                    throw invalid("Media data URLs must contain a MIME type and base64 data")
                }
                if let mediaType, case .base64(let payload, _) = parsed.source {
                    return base64(payload, mediaType: mediaType)
                }
                return parsed
            }
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                return url(value, mediaType: mediaType)
            }
            guard isBase64String(value) else {
                throw invalid("Media strings must be base64, a data URL or an http(s) URL; read files with Media.file")
            }
            guard let resolved = mediaType ?? sniffBase64(value) else {
                throw invalid("Media data needs a mediaType because its type cannot be detected")
            }
            return base64(value, mediaType: resolved)
        }
    }

    // parity: ai/src/media.ts#image [status=implemented hash=62b0d0552efa]
    public static func image(_ input: Input, mediaType: String? = nil) throws(AISchema.AIError) -> ImageAsset {
        let asset = try make(input, mediaType: mediaType)
        return try ImageAsset(validating: asset)
    }

    // parity: ai/src/media.ts#file [status=implemented hash=dfa27af1eea9]
    public static func file(
        _ path: String,
        options: AssetOptions? = nil,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
    ) async throws -> Asset {
        let data: [UInt8]
        do {
            data = try await fileSystem.readFile(at: path)
        } catch {
            throw invalid("Failed to read media file \(path)", cause: String(describing: error))
        }
        return bytes(data, mediaType: AIUtils.fileMediaType(data, path: path), options: options)
    }

    // parity: ai/src/media.ts#write [status=implemented hash=50b19445f52f]
    public static func write(
        _ asset: Asset,
        to path: String,
        executor: AIRequestExecutor.RequestExecutorService? = nil,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
    ) async throws {
        let temporary = "\(path).\(UUID().uuidString).tmp"
        do {
            var chunks: [[UInt8]] = []
            for try await chunk in asset.stream(executor: executor) {
                chunks.append(chunk)
            }
            try await fileSystem.writeFile(AIUtils.concatBytes(chunks), to: temporary, createDirectories: true)
            try await fileSystem.rename(from: temporary, to: path)
        } catch let aiError as AISchema.AIError {
            try? await fileSystem.remove(at: temporary)
            throw aiError
        } catch {
            try? await fileSystem.remove(at: temporary)
            throw invalid("Failed to write media file \(path)", cause: String(describing: error))
        }
    }

    internal static func invalid(_ message: String, cause: String? = nil) -> AISchema.AIError {
        AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(message: message, cause: cause)))
    }

    // MARK: - src/media-model.ts

    // parity: ai/src/media-model.ts#MediaModel [status=implemented hash=d7674a429170]
    public struct MediaModel<Route: Sendable>: Sendable {
        // parity: ai/src/media-model.ts#MediaModel.Options [status=implemented hash=329c4ad82ab8]
        public typealias Options = AISchema.ProviderOptions

        // parity: ai/src/media-model.ts#MediaModel.Input [status=implemented hash=0f5e18a0b6af]
        public struct Input: Sendable {
            public let id: String
            public let provider: String
            public let route: Route
            public let transport: AISchema.TransportOptions?
            public let providerOptions: AISchema.ProviderOptions?

            public init(
                id: String,
                provider: String,
                route: Route,
                transport: AISchema.TransportOptions? = nil,
                providerOptions: AISchema.ProviderOptions? = nil
            ) {
                self.id = id
                self.provider = provider
                self.route = route
                self.transport = transport
                self.providerOptions = providerOptions
            }
        }

        // parity: ai/src/media-model.ts#MediaModel.RouteInput [status=implemented hash=e9ab54953ac2]
        public struct RouteInput<Request: Sendable, WireProto: Sendable>: Sendable {
            public let wireProtocol: WireProto
            public let path: AIEndpoint.EndpointPart<AIRoute.MediaProtocol.Body, Request>
            public let baseURL: String?
            public let headers: [String: String]?

            public init(
                protocol wireProtocol: WireProto,
                path: AIEndpoint.EndpointPart<AIRoute.MediaProtocol.Body, Request>,
                baseURL: String? = nil,
                headers: [String: String]? = nil
            ) {
                self.wireProtocol = wireProtocol
                self.path = path
                self.baseURL = baseURL
                self.headers = headers
            }
        }

        // parity: ai/src/media-model.ts#MediaModel.InlineRouteInput [status=implemented hash=abd041d7d504]
        public typealias InlineRouteInput<Request: AIRoute.MediaRoute.MediaRequest, Response: Sendable> =
            RouteInput<Request, AIRoute.MediaProtocol.Inline<Request, Response>>

        // parity: ai/src/media-model.ts#MediaModel.StreamRouteInput [status=implemented hash=41309efcbd74]
        public typealias StreamRouteInput<Request: AIRoute.MediaRoute.MediaRequest, Event: Sendable, Frame: Sendable, State: Sendable> =
            RouteInput<AIRoute.MediaProtocol.Addressed<Request>, AIRoute.MediaProtocol.Streamed<Request, Event, Frame, State>>

        // parity: ai/src/media-model.ts#MediaModel.QueuedRouteInput [status=implemented hash=374420ff6afb]
        public typealias QueuedRouteInput<Request: AIRoute.MediaRoute.MediaRequest, Response: Sendable, Token: Codable & Sendable> =
            RouteInput<Request, AIRoute.MediaProtocol.Queued<Request, Response, Token>>

        // parity: ai/src/media-model.ts#MediaModel.AnyRouteInput [status=implemented hash=7a29dba05ca9]
        public enum AnyRouteInput<Request: AIRoute.MediaRoute.MediaRequest, Event: Sendable, Response: Sendable, Frame: Sendable, State: Sendable, Token: Codable & Sendable>: Sendable {
            case inline(InlineRouteInput<Request, Response>)
            case stream(StreamRouteInput<Request, Event, Frame, State>)
            case queued(QueuedRouteInput<Request, Response, Token>)

            public var provider: AISchema.ProviderID {
                switch self {
                case .inline(let r): r.wireProtocol.provider
                case .stream(let r): r.wireProtocol.provider
                case .queued(let r): r.wireProtocol.provider
                }
            }
        }

        public let id: AISchema.ModelID
        public let provider: AISchema.ProviderID
        public let route: Route
        public let transport: AISchema.TransportOptions?
        public let providerOptions: AISchema.ProviderOptions?

        public init(_ input: Input) {
            self.id = AISchema.ModelID.make(input.id)
            self.provider = AISchema.ProviderID.make(input.provider)
            self.route = input.route
            self.transport = input.transport
            self.providerOptions = input.providerOptions
        }

        public var descriptor: AIRoute.MediaRoute.ModelDescriptor {
            AIRoute.MediaRoute.ModelDescriptor(
                id: id.rawValue,
                provider: provider,
                transport: transport,
                providerOptions: providerOptions
            )
        }
    }

    // parity: ai/src/media-model.ts#composeQueuedRoute [status=implemented hash=a4ba52ba4aa0]
    public static func composeQueuedRoute<Request: AIRoute.MediaRoute.MediaRequest, Response: Sendable, Token: Codable & Sendable>(
        _ route: MediaModel<Void>.QueuedRouteInput<Request, Response, Token>,
        input: AIRoute.MediaRoute.ModelInput
    ) -> AIRoute.MediaRoute.QueuedRoute<Request, Response> {
        AIRoute.MediaRoute.queued(AIRoute.MediaRoute.QueuedInput(
            protocol: route.wireProtocol,
            endpoint: AIEndpoint.path(route.path, baseURL: input.baseURL ?? route.baseURL),
            auth: input.auth,
            headers: route.headers
        ))
    }

    // parity: ai/src/media-model.ts#composeRoute [status=implemented hash=68975241e91b]
    public static func composeRoute<Request: AIRoute.MediaRoute.MediaRequest, Event: Sendable, Response: Sendable, Frame: Sendable, State: Sendable, Token: Codable & Sendable>(
        _ route: MediaModel<Void>.AnyRouteInput<Request, Event, Response, Frame, State, Token>,
        input: AIRoute.MediaRoute.ModelInput,
        collect: @escaping @Sendable ([Event]) async throws -> Response
    ) -> AIRoute.MediaRoute.AnyRoute<Request, Event, Response> {
        switch route {
        case .inline(let r):
            return .inline(AIRoute.MediaRoute.inline(AIRoute.MediaRoute.InlineInput(
                protocol: r.wireProtocol,
                endpoint: AIEndpoint.path(r.path, baseURL: input.baseURL ?? r.baseURL),
                auth: input.auth,
                headers: r.headers
            )))
        case .stream(let r):
            return .stream(AIRoute.MediaRoute.stream(AIRoute.MediaRoute.StreamInput(
                protocol: r.wireProtocol,
                endpoint: AIEndpoint.path(r.path, baseURL: input.baseURL ?? r.baseURL),
                auth: input.auth,
                headers: r.headers,
                collect: collect
            )))
        case .queued(let r):
            return .queued(composeQueuedRoute(r, input: input))
        }
    }

    // parity: ai/src/media-model.ts#tryRequest [status=implemented hash=770485c7383e]
    public static func tryRequest<A>(_ make: () throws -> A) throws(AISchema.AIError) -> A {
        do {
            return try make()
        } catch let aiError as AISchema.AIError {
            throw aiError
        } catch {
            throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                message: String(describing: error),
                cause: String(describing: error)
            )))
        }
    }

    // MARK: - src/media-client.ts

    public enum MediaClient {
        // parity: ai/src/media-client.ts#RoutedRequest [status=implemented hash=2a68dea1f75c]
        public protocol RoutedRequest: AIRoute.MediaRoute.MediaRequest {
            associatedtype Event: Sendable
            associatedtype Response: Sendable
            var route: AIRoute.MediaRoute.AnyRoute<Self, Event, Response> { get }
        }

        // parity: ai/src/media-client.ts#Input [status=implemented hash=8aa3c23f809e]
        public struct Input<Event: Sendable, Response: Sendable>: Sendable {
            public let modality: String
            public let responseEvents: @Sendable (Response) -> [Event]

            public init(modality: String, responseEvents: @escaping @Sendable (Response) -> [Event]) {
                self.modality = modality
                self.responseEvents = responseEvents
            }
        }

        // parity: ai/src/media-client.ts#Interface [status=implemented hash=da1f7e86ed75]
        public struct Interface<Req: RoutedRequest>: Sendable {
            public let generate: @Sendable (Req, AIGeneration.AwaitOptions?) async throws -> Req.Response
            public let stream: @Sendable (Req, AIGeneration.AwaitOptions?) -> AsyncThrowingStream<AIGeneration.ResultEvent<Req.Event>, Error>
            public let start: @Sendable (Req) async throws -> AIGeneration.Generation<Req.Response>
            public let resume: @Sendable (AIRoute.MediaRoute.ModelDescriptor, AIRoute.MediaRoute.AnyRoute<Req, Req.Event, Req.Response>, JSONValue) async throws -> AIGeneration.Generation<Req.Response>

            public init(
                generate: @escaping @Sendable (Req, AIGeneration.AwaitOptions?) async throws -> Req.Response,
                stream: @escaping @Sendable (Req, AIGeneration.AwaitOptions?) -> AsyncThrowingStream<AIGeneration.ResultEvent<Req.Event>, Error>,
                start: @escaping @Sendable (Req) async throws -> AIGeneration.Generation<Req.Response>,
                resume: @escaping @Sendable (AIRoute.MediaRoute.ModelDescriptor, AIRoute.MediaRoute.AnyRoute<Req, Req.Event, Req.Response>, JSONValue) async throws -> AIGeneration.Generation<Req.Response>
            ) {
                self.generate = generate
                self.stream = stream
                self.start = start
                self.resume = resume
            }
        }

        // parity: ai/src/media-client.ts#notQueued [status=implemented hash=35c8d81d77c7]
        public static func notQueued(
            modality: String,
            provider: AISchema.ProviderID,
            routeID: String,
            operation: String
        ) -> AISchema.AIError {
            AISchema.AIError(reason: .unsupportedOperation(AISchema.UnsupportedOperationError(
                message: "\(provider.rawValue)/\(routeID) is not a queued route; use generate or stream",
                operation: "\(modality).\(operation)",
                provider: provider,
                route: routeID
            )))
        }

        // parity: ai/src/media-client.ts#operations [status=implemented hash=3de1814288c1]
        public static func operations<Req: RoutedRequest>(
            execute: @escaping AIRoute.MediaRoute.Execute,
            input: Input<Req.Event, Req.Response>
        ) -> Interface<Req> {
            let startOp: @Sendable (Req) async throws -> AIGeneration.Generation<Req.Response> = { req in
                guard case .queued(let queuedRoute) = req.route else {
                    throw notQueued(modality: input.modality, provider: req.route.provider, routeID: req.route.id, operation: "start")
                }
                return try await queuedRoute.start(req, execute)
            }
            return Interface(
                generate: { req, options in
                    switch req.route {
                    case .inline(let r): return try await r.generate(req, execute)
                    case .stream(let r): return try await r.generate(req, execute)
                    case .queued:
                        let gen = try await startOp(req)
                        return try await gen.await(options)
                    }
                },
                stream: { req, options in
                    switch req.route {
                    case .stream(let r):
                        return AsyncThrowingStream { continuation in
                            let task = Task {
                                do {
                                    for try await ev in r.stream(req, execute) {
                                        continuation.yield(.event(ev))
                                    }
                                    continuation.finish()
                                } catch {
                                    continuation.finish(throwing: error)
                                }
                            }
                            continuation.onTermination = { _ in task.cancel() }
                        }
                    case .queued:
                        return AsyncThrowingStream { continuation in
                            let task = Task {
                                do {
                                    let gen = try await startOp(req)
                                    for try await ev in AIGeneration.resultEvents(gen, expand: input.responseEvents, options: options) {
                                        continuation.yield(ev)
                                    }
                                    continuation.finish()
                                } catch {
                                    continuation.finish(throwing: error)
                                }
                            }
                            continuation.onTermination = { _ in task.cancel() }
                        }
                    case .inline(let r):
                        return AsyncThrowingStream { continuation in
                            let task = Task {
                                do {
                                    let res = try await r.generate(req, execute)
                                    for ev in input.responseEvents(res) {
                                        continuation.yield(.event(ev))
                                    }
                                    continuation.finish()
                                } catch {
                                    continuation.finish(throwing: error)
                                }
                            }
                            continuation.onTermination = { _ in task.cancel() }
                        }
                    }
                },
                start: startOp,
                resume: { model, route, token in
                    guard case .queued(let queuedRoute) = route else {
                        throw notQueued(modality: input.modality, provider: route.provider, routeID: route.id, operation: "resume")
                    }
                    return try await queuedRoute.resume(model, token, execute)
                }
            )
        }

        // parity: ai/src/media-client.ts#make [status=implemented hash=113eaecc3777]
        public static func make<Req: RoutedRequest>(
            executor: AIRequestExecutor.RequestExecutorService,
            input: Input<Req.Event, Req.Response>
        ) -> Interface<Req> {
            operations(execute: { req, mw in try await executor.execute(req, middleware: mw) }, input: input)
        }
    }
}

/// Asynchronous queued generation polling, progress events, cancellation, and deadlines.
/// Ports `packages/ai/src/generation.ts`.
public enum AIGeneration {
    // parity: ai/src/generation.ts#Status [status=implemented hash=4d2351c71b89]
    public enum Status: String, Equatable, Hashable, Sendable, Codable {
        case running
        case completed
        case error
    }

    // parity: ai/src/generation.ts#Reason [status=implemented hash=dd0a1627caff]
    public enum Reason: String, Equatable, Hashable, Sendable, Codable {
        case failed
        case cancelled
        case expired
    }

    // parity: ai/src/generation.ts#Snapshot [status=implemented hash=33c2ec84ef3c]
    public struct Snapshot: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let status: Status
        public let reason: Reason?
        public let progress: Double?

        public init(id: String, status: Status, reason: Reason? = nil, progress: Double? = nil) {
            self.id = id
            self.status = status
            self.reason = reason
            self.progress = progress
        }
    }

    // parity: ai/src/generation.ts#Route [status=implemented hash=857eef83acf5]
    public struct Route<Response: Sendable>: Sendable {
        public let status: @Sendable () async throws -> Snapshot
        public let result: @Sendable () async throws -> Response
        public let cancel: (@Sendable () async throws -> Void)?

        public init(
            status: @escaping @Sendable () async throws -> Snapshot,
            result: @escaping @Sendable () async throws -> Response,
            cancel: (@Sendable () async throws -> Void)? = nil
        ) {
            self.status = status
            self.result = result
            self.cancel = cancel
        }
    }

    // parity: ai/src/generation.ts#Poll [status=implemented hash=9aaeda9a7660]
    public struct Poll: Equatable, Hashable, Sendable {
        public let intervalMs: Double?
        public let timeoutMs: Double?

        public init(intervalMs: Double? = nil, timeoutMs: Double? = nil) {
            self.intervalMs = intervalMs
            self.timeoutMs = timeoutMs
        }
    }

    // parity: ai/src/generation.ts#AwaitOptions [status=implemented hash=fff5fdb3deef]
    public struct AwaitOptions: Equatable, Hashable, Sendable {
        public let poll: Poll?

        public init(poll: Poll? = nil) {
            self.poll = poll
        }
    }

    // parity: ai/src/generation.ts#ProgressEvent [status=implemented hash=08e311dfe503]
    public struct ProgressEvent: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let progress: Double?

        public init(id: String, progress: Double? = nil) {
            self.id = id
            self.progress = progress
        }

        enum CodingKeys: String, CodingKey { case type, id, progress }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.progress = try c.decodeIfPresent(Double.self, forKey: .progress)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("generation-progress", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(progress, forKey: .progress)
        }
    }

    // parity: ai/src/generation.ts#Observation [status=implemented hash=7fb25b095419]
    public typealias Observation = ProgressEvent

    // parity: ai/src/generation.ts#Event [status=implemented hash=203e2b9cbb42]
    public enum Event: Equatable, Hashable, Sendable, Codable {
        case progress(ProgressEvent)
        case finished(id: String, status: Status, reason: Reason?)

        enum CodingKeys: String, CodingKey { case type, id, status, reason, progress }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "generation-progress":
                self = .progress(try ProgressEvent(from: decoder))
            case "generation-finished":
                self = .finished(
                    id: try c.decode(String.self, forKey: .id),
                    status: try c.decode(Status.self, forKey: .status),
                    reason: try c.decodeIfPresent(Reason.self, forKey: .reason)
                )
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown Generation.Event type '\(type)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .progress(let p): try p.encode(to: encoder)
            case .finished(let id, let status, let reason):
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode("generation-finished", forKey: .type)
                try c.encode(id, forKey: .id)
                try c.encode(status, forKey: .status)
                try c.encodeIfPresent(reason, forKey: .reason)
            }
        }
    }

    public enum ResultEvent<A: Sendable>: Sendable {
        case observation(Observation)
        case event(A)
    }

    private static let defaultPollIntervalMs: Double = 5_000
    private static let defaultPollTimeoutMs: Double = 600_000

    // parity: ai/src/generation.ts#isTerminal [status=implemented hash=fb9153e882a9]
    public static func isTerminal(_ status: Status) -> Bool {
        status != .running
    }

    private static func timeoutError(id: String, timeoutMs: Double) -> AISchema.AIError {
        let clamped = max(0, Int(ceil(timeoutMs)))
        return AISchema.AIError(reason: .timeout(AISchema.TimeoutError(
            message: "Generation \(id) did not finish within \(clamped)ms",
            timeoutMs: clamped
        )))
    }

    // parity: ai/src/generation.ts#Generation [status=implemented hash=b69f38c5d22e]
    public struct Generation<Response: Sendable>: Sendable {
        public let route: Route<Response>
        public let token: JSONValue
        public let id: String
        public let status: Status
        public let reason: Reason?
        public let progress: Double?

        public init(route: Route<Response>, token: JSONValue, snapshot: Snapshot) {
            self.route = route
            self.token = token
            self.id = snapshot.id
            self.status = snapshot.status
            self.reason = snapshot.reason
            self.progress = snapshot.progress
        }

        public var snapshot: Snapshot {
            Snapshot(id: id, status: status, reason: reason, progress: progress)
        }

        public var terminal: Bool {
            AIGeneration.isTerminal(status)
        }

        public func refresh() async throws -> Generation<Response> {
            let next = try await route.status()
            return Generation(route: route, token: token, snapshot: next)
        }

        public func result() async throws -> Response {
            try await route.result()
        }

        public func cancel() async throws {
            if let cancelOp = route.cancel {
                try await cancelOp()
            }
        }

        public func `await`(_ options: AwaitOptions? = nil) async throws -> Response {
            let timeoutMs = options?.poll?.timeoutMs ?? AIGeneration.defaultPollTimeoutMs
            let intervalMs = options?.poll?.intervalMs ?? AIGeneration.defaultPollIntervalMs
            let deadline = Date().timeIntervalSince1970 * 1000.0 + timeoutMs
            var current = self
            while !current.terminal {
                let now = Date().timeIntervalSince1970 * 1000.0
                if now >= deadline {
                    throw AIGeneration.timeoutError(id: id, timeoutMs: timeoutMs)
                }
                let sleepMs = min(intervalMs, max(0, deadline - now))
                if sleepMs > 0 {
                    try? await Task.sleep(for: .milliseconds(sleepMs))
                }
                if Date().timeIntervalSince1970 * 1000.0 >= deadline {
                    throw AIGeneration.timeoutError(id: id, timeoutMs: timeoutMs)
                }
                current = try await current.refresh()
            }
            return try await current.result()
        }

        public func events(_ options: AwaitOptions? = nil) -> AsyncThrowingStream<Event, Error> {
            let gen = self
            return AsyncThrowingStream { continuation in
                let task = Task {
                    if gen.terminal {
                        continuation.yield(.finished(id: gen.id, status: gen.status, reason: gen.reason))
                        continuation.finish()
                        return
                    }
                    let timeoutMs = options?.poll?.timeoutMs ?? AIGeneration.defaultPollTimeoutMs
                    let intervalMs = options?.poll?.intervalMs ?? AIGeneration.defaultPollIntervalMs
                    let deadline = Date().timeIntervalSince1970 * 1000.0 + timeoutMs
                    var current = gen
                    do {
                        while !current.terminal {
                            let now = Date().timeIntervalSince1970 * 1000.0
                            if now >= deadline {
                                throw AIGeneration.timeoutError(id: gen.id, timeoutMs: timeoutMs)
                            }
                            current = try await current.refresh()
                            if current.terminal {
                                continuation.yield(.finished(id: current.id, status: current.status, reason: current.reason))
                                break
                            }
                            continuation.yield(.progress(ProgressEvent(id: current.id, progress: current.progress)))
                            let sleepMs = min(intervalMs, max(0, deadline - Date().timeIntervalSince1970 * 1000.0))
                            if sleepMs > 0 {
                                try? await Task.sleep(for: .milliseconds(sleepMs))
                            }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    // parity: ai/src/generation.ts#resultEvents [status=implemented hash=65df57f1b192]
    public static func resultEvents<Response: Sendable, A: Sendable>(
        _ generation: Generation<Response>,
        expand: @escaping @Sendable (Response) -> [A],
        options: AwaitOptions? = nil
    ) -> AsyncThrowingStream<ResultEvent<A>, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await ev in generation.events(options) {
                        if case .progress(let obs) = ev {
                            continuation.yield(.observation(obs))
                        }
                    }
                    let res = try await generation.result()
                    for item in expand(res) {
                        continuation.yield(.event(item))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Decision models, question/answer schemas, request normalization, and client answer validation.
/// Ports `packages/ai/src/{decision,decision-client}.ts`.
public enum AIDecision {
    // parity: ai/src/decision.ts#DecisionTextPart [status=implemented hash=0f3be5723150]
    public struct DecisionTextPart: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public init(text: String) { self.text = text }
        enum CodingKeys: String, CodingKey { case type, text }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.text = try c.decode(String.self, forKey: .text)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        }
    }

    // parity: ai/src/decision.ts#DecisionJsonPart [status=implemented hash=0eaa201e5dc4]
    public struct DecisionJsonPart: Equatable, Hashable, Sendable, Codable {
        public let value: JSONValue
        public init(value: JSONValue) { self.value = value }
        enum CodingKeys: String, CodingKey { case type, value }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.value = try c.decode(JSONValue.self, forKey: .value)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("json", forKey: .type)
            try c.encode(value, forKey: .value)
        }
    }

    // parity: ai/src/decision.ts#DecisionMediaPart [status=implemented hash=29c3f5930370]
    public struct DecisionMediaPart: Equatable, Sendable, Codable {
        public let media: AIMedia.Asset
        public let filename: String?
        public init(media: AIMedia.Asset, filename: String? = nil) {
            self.media = media
            self.filename = filename
        }
        enum CodingKeys: String, CodingKey { case type, media, filename }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.media = try c.decode(AIMedia.Asset.self, forKey: .media)
            self.filename = try c.decodeIfPresent(String.self, forKey: .filename)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("media", forKey: .type)
            try c.encode(media, forKey: .media)
            try c.encodeIfPresent(filename, forKey: .filename)
        }
    }

    // parity: ai/src/decision.ts#DecisionPart [status=implemented hash=c256697a0490]
    public enum DecisionPart: Equatable, Sendable, Codable {
        case text(DecisionTextPart)
        case json(DecisionJsonPart)
        case media(DecisionMediaPart)

        enum TagKeys: String, CodingKey { case type }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: TagKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "text": self = .text(try DecisionTextPart(from: decoder))
            case "json": self = .json(try DecisionJsonPart(from: decoder))
            case "media": self = .media(try DecisionMediaPart(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown DecisionPart type '\(type)'")
            }
        }
        public func encode(to encoder: Encoder) throws {
            switch self {
            case .text(let p): try p.encode(to: encoder)
            case .json(let p): try p.encode(to: encoder)
            case .media(let p): try p.encode(to: encoder)
            }
        }
    }

    // parity: ai/src/decision.ts#DecisionMediaPartInput [status=implemented hash=1ab7528f2828]
    public struct DecisionMediaPartInput: Sendable {
        public let media: AIMedia.Input
        public let mediaType: String?
        public let filename: String?

        public init(media: AIMedia.Input, mediaType: String? = nil, filename: String? = nil) {
            self.media = media
            self.mediaType = mediaType
            self.filename = filename
        }
    }

    // parity: ai/src/decision.ts#DecisionPartInput [status=implemented hash=f2775a456945]
    public enum DecisionPartInput: Sendable {
        case text(DecisionTextPart)
        case json(DecisionJsonPart)
        case media(DecisionMediaPartInput)
    }

    // parity: ai/src/decision.ts#DecisionInput [status=implemented hash=cf45f5dcda20]
    public enum DecisionInput: Sendable {
        case object([String: JSONValue])
        case parts([DecisionPartInput])
    }

    // parity: ai/src/decision.ts#ChoiceValue [status=implemented hash=62417c0fcd5d]
    public enum ChoiceValue: Equatable, Hashable, Sendable, Codable {
        case string(String)
        case bool(Bool)

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b); return }
            self = .string(try c.decode(String.self))
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .bool(let b): try c.encode(b)
            }
        }
    }

    // parity: ai/src/decision.ts#PredicateQuestion [status=implemented hash=11db0007f9e1]
    public struct PredicateQuestion: Equatable, Hashable, Sendable, Codable {
        public struct Criteria: Equatable, Hashable, Sendable, Codable {
            public let trueCriteria: String?
            public let falseCriteria: String?
            public init(trueCriteria: String? = nil, falseCriteria: String? = nil) {
                self.trueCriteria = trueCriteria
                self.falseCriteria = falseCriteria
            }
            enum CodingKeys: String, CodingKey { case trueCriteria = "true", falseCriteria = "false" }
        }
        public let name: String
        public let instructions: String
        public let criteria: Criteria?
        public init(name: String, instructions: String, criteria: Criteria? = nil) {
            self.name = name
            self.instructions = instructions
            self.criteria = criteria
        }
        enum CodingKeys: String, CodingKey { case name, type, instructions, criteria }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try c.decode(String.self, forKey: .name)
            self.instructions = try c.decode(String.self, forKey: .instructions)
            self.criteria = try c.decodeIfPresent(Criteria.self, forKey: .criteria)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode("predicate", forKey: .type)
            try c.encode(instructions, forKey: .instructions)
            try c.encodeIfPresent(criteria, forKey: .criteria)
        }
    }

    // parity: ai/src/decision.ts#ChoiceQuestion [status=implemented hash=f221acdd93ed]
    public struct ChoiceQuestion: Equatable, Hashable, Sendable, Codable {
        public struct Option: Equatable, Hashable, Sendable, Codable {
            public let value: ChoiceValue
            public let description: String?
            public init(value: ChoiceValue, description: String? = nil) {
                self.value = value
                self.description = description
            }
        }
        public let name: String
        public let instructions: String
        public let choices: [Option]
        public init(name: String, instructions: String, choices: [Option]) {
            self.name = name
            self.instructions = instructions
            self.choices = choices
        }
        enum CodingKeys: String, CodingKey { case name, type, instructions, choices }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try c.decode(String.self, forKey: .name)
            self.instructions = try c.decode(String.self, forKey: .instructions)
            self.choices = try c.decode([Option].self, forKey: .choices)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode("choice", forKey: .type)
            try c.encode(instructions, forKey: .instructions)
            try c.encode(choices, forKey: .choices)
        }
    }

    // parity: ai/src/decision.ts#ScoreQuestion [status=implemented hash=6950e6d5f81d]
    public struct ScoreQuestion: Equatable, Hashable, Sendable, Codable {
        public struct Level: Equatable, Hashable, Sendable, Codable {
            public let label: String
            public let description: String?
            public init(label: String, description: String? = nil) {
                self.label = label
                self.description = description
            }
        }
        public let name: String
        public let instructions: String
        public let levels: [Level]
        public init(name: String, instructions: String, levels: [Level]) {
            self.name = name
            self.instructions = instructions
            self.levels = levels
        }
        enum CodingKeys: String, CodingKey { case name, type, instructions, levels }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try c.decode(String.self, forKey: .name)
            self.instructions = try c.decode(String.self, forKey: .instructions)
            self.levels = try c.decode([Level].self, forKey: .levels)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode("score", forKey: .type)
            try c.encode(instructions, forKey: .instructions)
            try c.encode(levels, forKey: .levels)
        }
    }

    // parity: ai/src/decision.ts#DecisionQuestion [status=implemented hash=ce7af20f4fa4]
    public enum DecisionQuestion: Equatable, Hashable, Sendable, Codable {
        case predicate(PredicateQuestion)
        case choice(ChoiceQuestion)
        case score(ScoreQuestion)

        public var name: String {
            switch self {
            case .predicate(let q): q.name
            case .choice(let q): q.name
            case .score(let q): q.name
            }
        }

        enum TagKeys: String, CodingKey { case type }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: TagKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "predicate": self = .predicate(try PredicateQuestion(from: decoder))
            case "choice": self = .choice(try ChoiceQuestion(from: decoder))
            case "score": self = .score(try ScoreQuestion(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown DecisionQuestion type '\(type)'")
            }
        }
        public func encode(to encoder: Encoder) throws {
            switch self {
            case .predicate(let q): try q.encode(to: encoder)
            case .choice(let q): try q.encode(to: encoder)
            case .score(let q): try q.encode(to: encoder)
            }
        }
    }

    // parity: ai/src/decision.ts#DecisionQuestions [status=implemented hash=aca8c86d6f3e]
    public typealias DecisionQuestions = [DecisionQuestion]

    // parity: ai/src/decision.ts#PredicateAnswer [status=implemented hash=3ee028d0f42f]
    public struct PredicateAnswer: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let probability: Double
        public init(name: String, probability: Double) {
            self.name = name
            self.probability = probability
        }
        enum CodingKeys: String, CodingKey { case name, type, probability }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try c.decode(String.self, forKey: .name)
            self.probability = try c.decode(Double.self, forKey: .probability)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode("predicate", forKey: .type)
            try c.encode(probability, forKey: .probability)
        }
    }

    // parity: ai/src/decision.ts#ChoiceAnswer [status=implemented hash=05de144b77c6]
    public struct ChoiceAnswer: Equatable, Hashable, Sendable, Codable {
        public struct Entry: Equatable, Hashable, Sendable, Codable {
            public let value: ChoiceValue
            public let probability: Double
            public init(value: ChoiceValue, probability: Double) {
                self.value = value
                self.probability = probability
            }
        }
        public let name: String
        public let choice: ChoiceValue
        public let probabilities: [Entry]
        public let confidence: Double
        public init(name: String, choice: ChoiceValue, probabilities: [Entry], confidence: Double) {
            self.name = name
            self.choice = choice
            self.probabilities = probabilities
            self.confidence = confidence
        }
        enum CodingKeys: String, CodingKey { case name, type, choice, probabilities, confidence }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try c.decode(String.self, forKey: .name)
            self.choice = try c.decode(ChoiceValue.self, forKey: .choice)
            self.probabilities = try c.decode([Entry].self, forKey: .probabilities)
            self.confidence = try c.decode(Double.self, forKey: .confidence)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode("choice", forKey: .type)
            try c.encode(choice, forKey: .choice)
            try c.encode(probabilities, forKey: .probabilities)
            try c.encode(confidence, forKey: .confidence)
        }
    }

    // parity: ai/src/decision.ts#ScoreAnswer [status=implemented hash=b5ddaeacdf9e]
    public struct ScoreAnswer: Equatable, Hashable, Sendable, Codable {
        public struct Entry: Equatable, Hashable, Sendable, Codable {
            public let value: Int
            public let label: String
            public let probability: Double
            public init(value: Int, label: String, probability: Double) {
                self.value = value
                self.label = label
                self.probability = probability
            }
        }
        public let name: String
        public let score: Double
        public let probabilities: [Entry]
        public let confidence: Double
        public init(name: String, score: Double, probabilities: [Entry], confidence: Double) {
            self.name = name
            self.score = score
            self.probabilities = probabilities
            self.confidence = confidence
        }
        enum CodingKeys: String, CodingKey { case name, type, score, probabilities, confidence }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try c.decode(String.self, forKey: .name)
            self.score = try c.decode(Double.self, forKey: .score)
            self.probabilities = try c.decode([Entry].self, forKey: .probabilities)
            self.confidence = try c.decode(Double.self, forKey: .confidence)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode("score", forKey: .type)
            try c.encode(score, forKey: .score)
            try c.encode(probabilities, forKey: .probabilities)
            try c.encode(confidence, forKey: .confidence)
        }
    }

    // parity: ai/src/decision.ts#ErrorReason [status=implemented hash=96e6f5ba4ff4]
    public struct ErrorReason: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
        public let rawValue: String
        public static let refusal = ErrorReason(rawValue: "refusal")
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }
    }

    // parity: ai/src/decision.ts#ErrorAnswer [status=implemented hash=f4706684be0f]
    public struct ErrorAnswer: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let reason: ErrorReason
        public let message: String?
        public init(name: String, reason: ErrorReason, message: String? = nil) {
            self.name = name
            self.reason = reason
            self.message = message
        }
        enum CodingKeys: String, CodingKey { case name, type, reason, message }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try c.decode(String.self, forKey: .name)
            self.reason = try c.decode(ErrorReason.self, forKey: .reason)
            self.message = try c.decodeIfPresent(String.self, forKey: .message)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode("error", forKey: .type)
            try c.encode(reason, forKey: .reason)
            try c.encodeIfPresent(message, forKey: .message)
        }
    }

    // parity: ai/src/decision.ts#DecisionAnswer [status=implemented hash=65b5a89ee7cc]
    public enum DecisionAnswer: Equatable, Hashable, Sendable, Codable {
        case predicate(PredicateAnswer)
        case choice(ChoiceAnswer)
        case score(ScoreAnswer)
        case error(ErrorAnswer)

        public var name: String {
            switch self {
            case .predicate(let a): a.name
            case .choice(let a): a.name
            case .score(let a): a.name
            case .error(let a): a.name
            }
        }

        enum TagKeys: String, CodingKey { case type }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: TagKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "predicate": self = .predicate(try PredicateAnswer(from: decoder))
            case "choice": self = .choice(try ChoiceAnswer(from: decoder))
            case "score": self = .score(try ScoreAnswer(from: decoder))
            case "error": self = .error(try ErrorAnswer(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown DecisionAnswer type '\(type)'")
            }
        }
        public func encode(to encoder: Encoder) throws {
            switch self {
            case .predicate(let a): try a.encode(to: encoder)
            case .choice(let a): try a.encode(to: encoder)
            case .score(let a): try a.encode(to: encoder)
            case .error(let a): try a.encode(to: encoder)
            }
        }
    }

    // parity: ai/src/decision.ts#AnswerFor [status=adapted hash=448b3d9ada16]
    public typealias AnswerFor = DecisionAnswer

    // parity: ai/src/decision.ts#AnswersFor [status=adapted hash=63d5afd51bde]
    public typealias AnswersFor = [DecisionAnswer]

    // parity: ai/src/decision.ts#DecisionOptions [status=implemented hash=707ef249cecf]
    public typealias DecisionOptions = [String: JSONValue]

    // parity: ai/src/decision.ts#DecisionModelRoute [status=implemented hash=0965f7ac1a01]
    public struct DecisionModelRoute: Sendable {
        public let id: String
        public let generate: @Sendable (DecisionRequest, @escaping AIRoute.MediaRoute.Execute) async throws -> DecisionResponse

        public init(
            id: String,
            generate: @escaping @Sendable (DecisionRequest, @escaping AIRoute.MediaRoute.Execute) async throws -> DecisionResponse
        ) {
            self.id = id
            self.generate = generate
        }
    }

    // parity: ai/src/decision.ts#DecisionModelCompatibility [status=implemented hash=efcc87514a76]
    public struct DecisionModelCompatibility: Equatable, Hashable, Sendable, Codable {
        public enum MediaInput: String, Equatable, Hashable, Sendable, Codable {
            case assets
            case state
            case root
        }

        // parity: ai/src/decision.ts#DecisionModelCompatibility.Input [status=implemented hash=3d470ef66faf]
        public typealias Input = DecisionModelCompatibility

        public let mediaInput: MediaInput?
        public init(mediaInput: MediaInput? = nil) { self.mediaInput = mediaInput }

        // parity: ai/src/decision.ts#DecisionModelCompatibility.make [status=implemented hash=4b4fd2962dce]
        public static func make(_ input: Input) -> DecisionModelCompatibility { input }
    }

    // parity: ai/src/decision.ts#DecisionModel [status=implemented hash=3f55cf2cd164]
    public struct DecisionModel: Sendable {
        // parity: ai/src/decision.ts#DecisionModel.Input [status=implemented hash=8ade0fffc873]
        public struct Input: Sendable {
            public let id: AISchema.ModelID
            public let provider: AISchema.ProviderID
            public let route: DecisionModelRoute
            public let transport: AISchema.TransportOptions?
            public let compatibility: DecisionModelCompatibility?
            public let providerOptions: AISchema.ProviderOptions?

            public init(
                id: AISchema.ModelID,
                provider: AISchema.ProviderID,
                route: DecisionModelRoute,
                transport: AISchema.TransportOptions? = nil,
                compatibility: DecisionModelCompatibility? = nil,
                providerOptions: AISchema.ProviderOptions? = nil
            ) {
                self.id = id
                self.provider = provider
                self.route = route
                self.transport = transport
                self.compatibility = compatibility
                self.providerOptions = providerOptions
            }
        }

        // parity: ai/src/decision.ts#DecisionModel.MakeInput [status=implemented hash=dd1adc466d86]
        public struct MakeInput: Sendable {
            public let id: String
            public let provider: String
            public let route: DecisionModelRoute
            public let transport: AISchema.TransportOptions?
            public let compatibility: DecisionModelCompatibility?
            public let providerOptions: AISchema.ProviderOptions?

            public init(
                id: String,
                provider: String,
                route: DecisionModelRoute,
                transport: AISchema.TransportOptions? = nil,
                compatibility: DecisionModelCompatibility? = nil,
                providerOptions: AISchema.ProviderOptions? = nil
            ) {
                self.id = id
                self.provider = provider
                self.route = route
                self.transport = transport
                self.compatibility = compatibility
                self.providerOptions = providerOptions
            }
        }

        public let id: AISchema.ModelID
        public let provider: AISchema.ProviderID
        public let route: DecisionModelRoute
        public let transport: AISchema.TransportOptions?
        public let compatibility: DecisionModelCompatibility?
        public let providerOptions: AISchema.ProviderOptions?

        public init(_ input: Input) {
            self.id = input.id
            self.provider = input.provider
            self.route = input.route
            self.transport = input.transport
            self.compatibility = input.compatibility
            self.providerOptions = input.providerOptions
        }

        public static func make(_ input: MakeInput) -> DecisionModel {
            DecisionModel(Input(
                id: AISchema.ModelID.make(input.id),
                provider: AISchema.ProviderID.make(input.provider),
                route: input.route,
                transport: input.transport,
                compatibility: input.compatibility,
                providerOptions: input.providerOptions
            ))
        }
    }

    // parity: ai/src/decision.ts#DecisionModelSchema [status=adapted hash=9277159776b8]
    public static func DecisionModelSchema(_ value: Any) -> DecisionModel? {
        value as? DecisionModel
    }

    // parity: ai/src/decision.ts#DecisionModelOptions [status=adapted hash=352cfb49a96a]
    public typealias DecisionModelOptions = DecisionOptions

    // parity: ai/src/decision.ts#DecisionRequest [status=implemented hash=cbeda1b33eee]
    public struct DecisionRequest: AIRoute.MediaRoute.MediaRequest, Sendable {
        public let model: DecisionModel
        public let input: [DecisionPart]
        public let questions: DecisionQuestions
        public let providerOptions: AISchema.ProviderOptions?
        public let headers: [String: String]?
        public let timeout: AISchema.RequestTimeout?
        public let http: AISchema.HttpOptions?
        public let fetch: (any HTTPTransport)?

        public var modelDescriptor: AIRoute.MediaRoute.ModelDescriptor {
            AIRoute.MediaRoute.ModelDescriptor(
                id: model.id.rawValue,
                provider: model.provider,
                transport: model.transport,
                providerOptions: model.providerOptions
            )
        }

        public init(
            model: DecisionModel,
            input: [DecisionPart],
            questions: DecisionQuestions,
            providerOptions: AISchema.ProviderOptions? = nil,
            headers: [String: String]? = nil,
            timeout: AISchema.RequestTimeout? = nil,
            http: AISchema.HttpOptions? = nil,
            fetch: (any HTTPTransport)? = nil
        ) {
            self.model = model
            self.input = input
            self.questions = questions
            self.providerOptions = providerOptions
            self.headers = headers
            self.timeout = timeout
            self.http = http
            self.fetch = fetch
        }
    }

    // parity: ai/src/decision.ts#DecisionRequestInput [status=implemented hash=acfaa0eba33d]
    public struct DecisionRequestInput: Sendable {
        public let model: DecisionModel
        public let input: DecisionInput
        public let questions: DecisionQuestions
        public let providerOptions: AISchema.ProviderOptions?
        public let headers: [String: String]?
        public let timeout: AISchema.RequestTimeout?
        public let http: AISchema.HttpOptions?
        public let fetch: (any HTTPTransport)?

        public init(
            model: DecisionModel,
            input: DecisionInput,
            questions: DecisionQuestions,
            providerOptions: AISchema.ProviderOptions? = nil,
            headers: [String: String]? = nil,
            timeout: AISchema.RequestTimeout? = nil,
            http: AISchema.HttpOptions? = nil,
            fetch: (any HTTPTransport)? = nil
        ) {
            self.model = model
            self.input = input
            self.questions = questions
            self.providerOptions = providerOptions
            self.headers = headers
            self.timeout = timeout
            self.http = http
            self.fetch = fetch
        }
    }

    // parity: ai/src/decision.ts#DecisionUsage [status=implemented hash=f7e8ce310b75]
    public struct DecisionUsage: Equatable, Hashable, Sendable, Codable {
        public let inputTokens: Double?
        public let outputTokens: Double?
        public let totalTokens: Double?
        public let cost: Double?
        public init(inputTokens: Double? = nil, outputTokens: Double? = nil, totalTokens: Double? = nil, cost: Double? = nil) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.totalTokens = totalTokens
            self.cost = cost
        }
    }

    // parity: ai/src/decision.ts#DecisionResponse [status=implemented hash=7a3adf195339]
    public struct DecisionResponse: Equatable, Hashable, Sendable, Codable {
        public let answers: [DecisionAnswer]
        public let usage: DecisionUsage?
        public let providerMetadata: AISchema.ProviderMetadata?
        public init(answers: [DecisionAnswer], usage: DecisionUsage? = nil, providerMetadata: AISchema.ProviderMetadata? = nil) {
            self.answers = answers
            self.usage = usage
            self.providerMetadata = providerMetadata
        }
    }

    // parity: ai/src/decision.ts#DecisionResponseFor [status=adapted hash=b955a2fda07e]
    public typealias DecisionResponseFor = DecisionResponse

    // parity: ai/src/decision.ts#request [status=implemented hash=8f6791e50ab1]
    public static func request(_ input: DecisionRequestInput) throws(AISchema.AIError) -> DecisionRequest {
        let parts: [DecisionPart]
        switch input.input {
        case .object(let obj):
            parts = [.json(DecisionJsonPart(value: .object(obj)))]
        case .parts(let list):
            var built: [DecisionPart] = []
            built.reserveCapacity(list.count)
            for item in list {
                switch item {
                case .text(let t): built.append(.text(t))
                case .json(let j): built.append(.json(j))
                case .media(let m):
                    built.append(.media(DecisionMediaPart(
                        media: try AIMedia.make(m.media, mediaType: m.mediaType),
                        filename: m.filename
                    )))
                }
            }
            parts = built
        }
        return DecisionRequest(
            model: input.model,
            input: parts,
            questions: input.questions,
            providerOptions: input.providerOptions,
            headers: input.headers,
            timeout: input.timeout,
            http: input.http,
            fetch: input.fetch
        )
    }

    private static func validate(_ req: DecisionRequest) throws(AISchema.AIError) {
        if req.questions.isEmpty {
            throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                message: "Decision questions must not be empty"
            )))
        }
        let names = Set(req.questions.map(\.name))
        if names.count != req.questions.count {
            throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                message: "Decision question names must be unique"
            )))
        }
    }

    // parity: ai/src/decision.ts#generate [status=implemented hash=79810b64c720]
    public static func generate(
        _ input: DecisionRequestInput,
        client: DecisionClient.Service
    ) async throws -> DecisionResponse {
        let normalized = try request(input)
        try validate(normalized)
        return try await client.generate(normalized)
    }

    // parity: ai/src/decision.ts#Decision [status=implemented hash=86150e3f2df4]
    public enum Decision {
        public static func request(_ input: DecisionRequestInput) throws(AISchema.AIError) -> DecisionRequest {
            try AIDecision.request(input)
        }

        public static func generate(
            _ input: DecisionRequestInput,
            client: DecisionClient.Service
        ) async throws -> DecisionResponse {
            try await AIDecision.generate(input, client: client)
        }
    }

    // MARK: - src/decision-client.ts

    // parity: ai/src/decision-client.ts#DecisionClient [status=implemented hash=52f5982b2df6]
    public enum DecisionClient {
        // parity: ai/src/decision-client.ts#Execute [status=implemented hash=6af9517c737d]
        public typealias Execute = AIRoute.MediaRoute.Execute

        // parity: ai/src/decision-client.ts#Interface [status=implemented hash=2858f3b57758]
        public protocol Interface: Sendable {
            func generate(_ request: DecisionRequest) async throws -> DecisionResponse
        }

        // parity: ai/src/decision-client.ts#Service [status=implemented hash=1d9d0a8e5b9f]
        public struct Service: Interface, Sendable {
            public static let serviceID = "@opencode/AI/DecisionClient"
            private let runGenerate: @Sendable (DecisionRequest) async throws -> DecisionResponse

            public init(generate: @escaping @Sendable (DecisionRequest) async throws -> DecisionResponse) {
                self.runGenerate = generate
            }

            public func generate(_ request: DecisionRequest) async throws -> DecisionResponse {
                try await runGenerate(request)
            }
        }

        // parity: ai/src/decision-client.ts#generate [status=implemented hash=18506e88e430]
        public static func generate(_ request: DecisionRequest, client: Service) async throws -> DecisionResponse {
            try await client.generate(request)
        }

        public static func answersMatch(questions: [DecisionQuestion], answers: [DecisionAnswer]) -> Bool {
            guard questions.count == answers.count else { return false }
            for (question, answer) in zip(questions, answers) {
                guard answer.name == question.name else { return false }
                if case .error = answer { continue }
                switch question {
                case .predicate:
                    guard case .predicate = answer else { return false }
                case .choice(let q):
                    guard case .choice(let a) = answer else { return false }
                    let expected = q.choices.map(\.value)
                    let received = a.probabilities.map(\.value)
                    guard expected.contains(a.choice),
                          expected.count == received.count,
                          Set(received).count == received.count,
                          received.allSatisfy({ expected.contains($0) })
                    else { return false }
                case .score(let q):
                    guard case .score(let a) = answer,
                          a.score >= 0 && a.score <= Double(q.levels.count - 1)
                    else { return false }
                    let expected = Array(0..<q.levels.count)
                    let received = a.probabilities.map(\.value)
                    guard expected.count == received.count,
                          Set(received).count == received.count,
                          received.allSatisfy({ expected.contains($0) })
                    else { return false }
                }
            }
            return true
        }

        // parity: ai/src/decision-client.ts#layer [status=implemented hash=da9849eb82cb]
        public static func layer(executor: AIRequestExecutor.RequestExecutorService) -> Service {
            Service { request in
                let response = try await request.model.route.generate(request) { req, mw in
                    try await executor.execute(req, middleware: mw)
                }
                if answersMatch(questions: request.questions, answers: response.answers) {
                    return response
                }
                throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                    message: "Decision answers do not match the requested questions",
                    route: request.model.route.id
                )))
            }
        }

        // parity: ai/src/decision-client.ts#fetchLayer [status=adapted hash=83615b9a3599]
        public static func fetchLayer(transport: any HTTPTransport) -> Service {
            layer(executor: AIRequestExecutor.fetchLayer(transport: transport))
        }
    }
}

/// Embedding models, multimodal value inputs, request validation, and embedding client.
/// Ports `packages/ai/src/{embedding,embedding-client}.ts`.
public enum AIEmbedding {
    // parity: ai/src/embedding.ts#EmbeddingValue [status=implemented hash=5987f582be38]
    public enum EmbeddingValue: Equatable, Sendable, Codable {
        case text(String)
        case media(AIMedia.Asset)

        public init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
                self = .text(s)
                return
            }
            self = .media(try AIMedia.Asset(from: decoder))
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .text(let s):
                var single = encoder.singleValueContainer()
                try single.encode(s)
            case .media(let asset):
                try asset.encode(to: encoder)
            }
        }
    }

    // parity: ai/src/embedding.ts#EmbeddingValueInput [status=implemented hash=58c49ad48c0e]
    public enum EmbeddingValueInput: Sendable {
        case text(String)
        case media(AIMedia.Input)
    }

    // parity: ai/src/embedding.ts#EmbeddingInputType [status=implemented hash=1003bcc8bb96]
    public enum EmbeddingInputType: String, Equatable, Hashable, Sendable, Codable {
        case query
        case document
    }

    // parity: ai/src/embedding.ts#EmbeddingOptions [status=implemented hash=9b660fb46d8b]
    public typealias EmbeddingOptions = [String: JSONValue]

    // parity: ai/src/embedding.ts#EmbeddingModelRoute [status=implemented hash=ae47e9783fe4]
    public struct EmbeddingModelRoute: Sendable {
        public let id: String
        public let generate: @Sendable (EmbeddingRequest, @escaping AIRoute.MediaRoute.Execute) async throws -> EmbeddingResponse

        public init(
            id: String,
            generate: @escaping @Sendable (EmbeddingRequest, @escaping AIRoute.MediaRoute.Execute) async throws -> EmbeddingResponse
        ) {
            self.id = id
            self.generate = generate
        }
    }

    // parity: ai/src/embedding.ts#EmbeddingModel [status=implemented hash=1aacfb528b50]
    public struct EmbeddingModel: Sendable {
        // parity: ai/src/embedding.ts#EmbeddingModel.Input [status=implemented hash=f42764bcead7]
        public struct Input: Sendable {
            public let id: AISchema.ModelID
            public let provider: AISchema.ProviderID
            public let route: EmbeddingModelRoute
            public let transport: AISchema.TransportOptions?
            public let providerOptions: AISchema.ProviderOptions?

            public init(
                id: AISchema.ModelID,
                provider: AISchema.ProviderID,
                route: EmbeddingModelRoute,
                transport: AISchema.TransportOptions? = nil,
                providerOptions: AISchema.ProviderOptions? = nil
            ) {
                self.id = id
                self.provider = provider
                self.route = route
                self.transport = transport
                self.providerOptions = providerOptions
            }
        }

        // parity: ai/src/embedding.ts#EmbeddingModel.MakeInput [status=implemented hash=f774da45c43d]
        public struct MakeInput: Sendable {
            public let id: String
            public let provider: String
            public let route: EmbeddingModelRoute
            public let transport: AISchema.TransportOptions?
            public let providerOptions: AISchema.ProviderOptions?

            public init(
                id: String,
                provider: String,
                route: EmbeddingModelRoute,
                transport: AISchema.TransportOptions? = nil,
                providerOptions: AISchema.ProviderOptions? = nil
            ) {
                self.id = id
                self.provider = provider
                self.route = route
                self.transport = transport
                self.providerOptions = providerOptions
            }
        }

        public let id: AISchema.ModelID
        public let provider: AISchema.ProviderID
        public let route: EmbeddingModelRoute
        public let transport: AISchema.TransportOptions?
        public let providerOptions: AISchema.ProviderOptions?

        public init(_ input: Input) {
            self.id = input.id
            self.provider = input.provider
            self.route = input.route
            self.transport = input.transport
            self.providerOptions = input.providerOptions
        }

        public static func make(_ input: MakeInput) -> EmbeddingModel {
            EmbeddingModel(Input(
                id: AISchema.ModelID.make(input.id),
                provider: AISchema.ProviderID.make(input.provider),
                route: input.route,
                transport: input.transport,
                providerOptions: input.providerOptions
            ))
        }
    }

    // parity: ai/src/embedding.ts#EmbeddingModelSchema [status=adapted hash=6919d235531f]
    public static func EmbeddingModelSchema(_ value: Any) -> EmbeddingModel? {
        value as? EmbeddingModel
    }

    // parity: ai/src/embedding.ts#EmbeddingModelOptions [status=adapted hash=f9dc5ca84fb8]
    public typealias EmbeddingModelOptions = EmbeddingOptions

    // parity: ai/src/embedding.ts#EmbeddingRequest [status=implemented hash=00da2e1617e4]
    public struct EmbeddingRequest: AIRoute.MediaRoute.MediaRequest, Sendable {
        public let model: EmbeddingModel
        public let values: [EmbeddingValue]
        public let dimensions: Int?
        public let inputType: EmbeddingInputType?
        public let providerOptions: AISchema.ProviderOptions?
        public let headers: [String: String]?
        public let timeout: AISchema.RequestTimeout?
        public let http: AISchema.HttpOptions?
        public let fetch: (any HTTPTransport)?

        public var modelDescriptor: AIRoute.MediaRoute.ModelDescriptor {
            AIRoute.MediaRoute.ModelDescriptor(
                id: model.id.rawValue,
                provider: model.provider,
                transport: model.transport,
                providerOptions: model.providerOptions
            )
        }

        public init(
            model: EmbeddingModel,
            values: [EmbeddingValue],
            dimensions: Int? = nil,
            inputType: EmbeddingInputType? = nil,
            providerOptions: AISchema.ProviderOptions? = nil,
            headers: [String: String]? = nil,
            timeout: AISchema.RequestTimeout? = nil,
            http: AISchema.HttpOptions? = nil,
            fetch: (any HTTPTransport)? = nil
        ) {
            self.model = model
            self.values = values
            self.dimensions = dimensions
            self.inputType = inputType
            self.providerOptions = providerOptions
            self.headers = headers
            self.timeout = timeout
            self.http = http
            self.fetch = fetch
        }
    }

    // parity: ai/src/embedding.ts#EmbeddingRequestInput [status=implemented hash=de375909f4cc]
    public struct EmbeddingRequestInput: Sendable {
        public let model: EmbeddingModel
        public let values: [EmbeddingValueInput]
        public let dimensions: Int?
        public let inputType: EmbeddingInputType?
        public let providerOptions: AISchema.ProviderOptions?
        public let headers: [String: String]?
        public let timeout: AISchema.RequestTimeout?
        public let http: AISchema.HttpOptions?
        public let fetch: (any HTTPTransport)?

        public init(
            model: EmbeddingModel,
            values: [EmbeddingValueInput],
            dimensions: Int? = nil,
            inputType: EmbeddingInputType? = nil,
            providerOptions: AISchema.ProviderOptions? = nil,
            headers: [String: String]? = nil,
            timeout: AISchema.RequestTimeout? = nil,
            http: AISchema.HttpOptions? = nil,
            fetch: (any HTTPTransport)? = nil
        ) {
            self.model = model
            self.values = values
            self.dimensions = dimensions
            self.inputType = inputType
            self.providerOptions = providerOptions
            self.headers = headers
            self.timeout = timeout
            self.http = http
            self.fetch = fetch
        }
    }

    // parity: ai/src/embedding.ts#EmbeddingUsage [status=implemented hash=73f097d2af04]
    public struct EmbeddingUsage: Equatable, Hashable, Sendable, Codable {
        public let inputTokens: Double?
        public init(inputTokens: Double? = nil) { self.inputTokens = inputTokens }
    }

    // parity: ai/src/embedding.ts#EmbeddingResponse [status=implemented hash=df860b4de7c8]
    public struct EmbeddingResponse: Equatable, Hashable, Sendable, Codable {
        public let embeddings: [[Double]]
        public let usage: EmbeddingUsage?
        public let providerMetadata: AISchema.ProviderMetadata?
        public init(embeddings: [[Double]], usage: EmbeddingUsage? = nil, providerMetadata: AISchema.ProviderMetadata? = nil) {
            self.embeddings = embeddings
            self.usage = usage
            self.providerMetadata = providerMetadata
        }
    }

    // parity: ai/src/embedding.ts#request [status=implemented hash=31801940a981]
    public static func request(_ input: EmbeddingRequestInput) throws(AISchema.AIError) -> EmbeddingRequest {
        var values: [EmbeddingValue] = []
        values.reserveCapacity(input.values.count)
        for v in input.values {
            switch v {
            case .text(let s): values.append(.text(s))
            case .media(let m): values.append(.media(try AIMedia.make(m)))
            }
        }
        return EmbeddingRequest(
            model: input.model,
            values: values,
            dimensions: input.dimensions,
            inputType: input.inputType,
            providerOptions: input.providerOptions,
            headers: input.headers,
            timeout: input.timeout,
            http: input.http,
            fetch: input.fetch
        )
    }

    private static func validate(_ req: EmbeddingRequest) throws(AISchema.AIError) {
        if req.values.isEmpty {
            throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                message: "Embedding values must not be empty"
            )))
        }
        if let dims = req.dimensions, dims <= 0 {
            throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                message: "Embedding dimensions must be positive, got \(dims)"
            )))
        }
    }

    // parity: ai/src/embedding.ts#generate [status=implemented hash=b7958b306b2e]
    public static func generate(
        _ input: EmbeddingRequestInput,
        client: EmbeddingClient.Service
    ) async throws -> EmbeddingResponse {
        let normalized = try request(input)
        try validate(normalized)
        return try await client.generate(normalized)
    }

    // parity: ai/src/embedding.ts#Embedding [status=implemented hash=638c2d6a2d20]
    public enum Embedding {
        public static func request(_ input: EmbeddingRequestInput) throws(AISchema.AIError) -> EmbeddingRequest {
            try AIEmbedding.request(input)
        }

        public static func generate(
            _ input: EmbeddingRequestInput,
            client: EmbeddingClient.Service
        ) async throws -> EmbeddingResponse {
            try await AIEmbedding.generate(input, client: client)
        }
    }

    // MARK: - src/embedding-client.ts

    // parity: ai/src/embedding-client.ts#EmbeddingClient [status=implemented hash=b8436d6c1880]
    public enum EmbeddingClient {
        // parity: ai/src/embedding-client.ts#Execute [status=implemented hash=6af9517c737d]
        public typealias Execute = AIRoute.MediaRoute.Execute

        // parity: ai/src/embedding-client.ts#Interface [status=implemented hash=8304749a0856]
        public protocol Interface: Sendable {
            func generate(_ request: EmbeddingRequest) async throws -> EmbeddingResponse
        }

        // parity: ai/src/embedding-client.ts#Service [status=implemented hash=e10a1619aa16]
        public struct Service: Interface, Sendable {
            public static let serviceID = "@opencode/AI/EmbeddingClient"
            private let runGenerate: @Sendable (EmbeddingRequest) async throws -> EmbeddingResponse

            public init(generate: @escaping @Sendable (EmbeddingRequest) async throws -> EmbeddingResponse) {
                self.runGenerate = generate
            }

            public func generate(_ request: EmbeddingRequest) async throws -> EmbeddingResponse {
                try await runGenerate(request)
            }
        }

        // parity: ai/src/embedding-client.ts#generate [status=implemented hash=707a63d0b8f1]
        public static func generate(_ request: EmbeddingRequest, client: Service) async throws -> EmbeddingResponse {
            try await client.generate(request)
        }

        // parity: ai/src/embedding-client.ts#layer [status=implemented hash=9040f95c7176]
        public static func layer(executor: AIRequestExecutor.RequestExecutorService) -> Service {
            Service { request in
                let response = try await request.model.route.generate(request) { req, mw in
                    try await executor.execute(req, middleware: mw)
                }
                if response.embeddings.count == request.values.count {
                    return response
                }
                throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                    message: "Expected \(request.values.count) embeddings, got \(response.embeddings.count)",
                    route: request.model.route.id
                )))
            }
        }

        // parity: ai/src/embedding-client.ts#fetchLayer [status=adapted hash=83615b9a3599]
        public static func fetchLayer(transport: any HTTPTransport) -> Service {
            layer(executor: AIRequestExecutor.fetchLayer(transport: transport))
        }
    }
}

/// Image generation models, requests, responses, events, and client operations.
/// Ports `packages/ai/src/{image,image-client}.ts`.
public enum AIImage {
    // parity: ai/src/image.ts#ImageOptions [status=implemented hash=e215863e07c6]
    public typealias ImageOptions = AISchema.ProviderOptions

    // parity: ai/src/image.ts#ImageRoute [status=implemented hash=bd8d7f9b8d12]
    public typealias ImageRoute = AIRoute.MediaRoute.AnyRoute<ImageRequest, ImageEvent, ImageResponse>

    // parity: ai/src/image.ts#ImageAspectRatio [status=implemented hash=55884fcb2b04]
    public typealias ImageAspectRatio = AIMedia.AspectRatio

    // parity: ai/src/image.ts#ImageResolution [status=implemented hash=c0117381af2c]
    public struct ImageResolution: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
        public let rawValue: String
        public static let res1K = ImageResolution(rawValue: "1K")
        public static let res2K = ImageResolution(rawValue: "2K")
        public static let res4K = ImageResolution(rawValue: "4K")
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }
    }

    // parity: ai/src/image.ts#ImageModel [status=implemented hash=6d22b253cf9a]
    public struct ImageModel: Sendable {
        public let id: AISchema.ModelID
        public let provider: AISchema.ProviderID
        public let route: ImageRoute
        public let transport: AISchema.TransportOptions?
        public let providerOptions: AISchema.ProviderOptions?

        public init(
            id: String,
            provider: String,
            route: ImageRoute,
            transport: AISchema.TransportOptions? = nil,
            providerOptions: AISchema.ProviderOptions? = nil
        ) {
            self.id = AISchema.ModelID.make(id)
            self.provider = AISchema.ProviderID.make(provider)
            self.route = route
            self.transport = transport
            self.providerOptions = providerOptions
        }

        public var descriptor: AIRoute.MediaRoute.ModelDescriptor {
            AIRoute.MediaRoute.ModelDescriptor(
                id: id.rawValue,
                provider: provider,
                transport: transport,
                providerOptions: providerOptions
            )
        }

        public static func fromRoute<Frame: Sendable, State: Sendable>(
            _ routeInput: AIMedia.MediaModel<Void>.AnyRouteInput<ImageRequest, ImageEvent, ImageResponse, Frame, State, String>,
            input: AIRoute.MediaRoute.ModelInput
        ) -> ImageModel {
            ImageModel(
                id: input.id,
                provider: routeInput.provider.rawValue,
                route: AIMedia.composeRoute(routeInput, input: input, collect: collectResponse),
                transport: input.transport,
                providerOptions: input.providerOptions
            )
        }
    }

    // parity: ai/src/image.ts#ImageModelSchema [status=adapted hash=aba1fe6f0cf4]
    public static func ImageModelSchema(_ value: Any) -> ImageModel? {
        value as? ImageModel
    }

    // parity: ai/src/image.ts#ImageModelOptions [status=adapted hash=d2157c3bc85c]
    public typealias ImageModelOptions = ImageOptions

    // parity: ai/src/image.ts#ImageRequest [status=implemented hash=29a6bee7270e]
    public struct ImageRequest: AIMedia.MediaClient.RoutedRequest, Sendable {
        public typealias Event = ImageEvent
        public typealias Response = ImageResponse

        public let model: ImageModel
        public let prompt: String
        public let images: [AIMedia.Asset]?
        public let n: Int?
        public let aspect: ImageAspectRatio?
        public let resolution: ImageResolution?
        public let providerOptions: AISchema.ProviderOptions?
        public let headers: [String: String]?
        public let timeout: AISchema.RequestTimeout?
        public let http: AISchema.HttpOptions?
        public let fetch: (any HTTPTransport)?

        public var modelDescriptor: AIRoute.MediaRoute.ModelDescriptor { model.descriptor }
        public var route: ImageRoute { model.route }

        public init(
            model: ImageModel,
            prompt: String,
            images: [AIMedia.Asset]? = nil,
            n: Int? = nil,
            aspect: ImageAspectRatio? = nil,
            resolution: ImageResolution? = nil,
            providerOptions: AISchema.ProviderOptions? = nil,
            headers: [String: String]? = nil,
            timeout: AISchema.RequestTimeout? = nil,
            http: AISchema.HttpOptions? = nil,
            fetch: (any HTTPTransport)? = nil
        ) {
            self.model = model
            self.prompt = prompt
            self.images = images
            self.n = n
            self.aspect = aspect
            self.resolution = resolution
            self.providerOptions = providerOptions
            self.headers = headers
            self.timeout = timeout
            self.http = http
            self.fetch = fetch
        }
    }

    // parity: ai/src/image.ts#ImageRequestInput [status=implemented hash=df6ed2dd2f2c]
    public struct ImageRequestInput: Sendable {
        public let model: ImageModel
        public let prompt: String
        public let images: [AIMedia.Input]?
        public let n: Int?
        public let aspect: ImageAspectRatio?
        public let resolution: ImageResolution?
        public let providerOptions: AISchema.ProviderOptions?
        public let headers: [String: String]?
        public let timeout: AISchema.RequestTimeout?
        public let http: AISchema.HttpOptions?
        public let fetch: (any HTTPTransport)?

        public init(
            model: ImageModel,
            prompt: String,
            images: [AIMedia.Input]? = nil,
            n: Int? = nil,
            aspect: ImageAspectRatio? = nil,
            resolution: ImageResolution? = nil,
            providerOptions: AISchema.ProviderOptions? = nil,
            headers: [String: String]? = nil,
            timeout: AISchema.RequestTimeout? = nil,
            http: AISchema.HttpOptions? = nil,
            fetch: (any HTTPTransport)? = nil
        ) {
            self.model = model
            self.prompt = prompt
            self.images = images
            self.n = n
            self.aspect = aspect
            self.resolution = resolution
            self.providerOptions = providerOptions
            self.headers = headers
            self.timeout = timeout
            self.http = http
            self.fetch = fetch
        }
    }

    // parity: ai/src/image.ts#ImageJob [status=implemented hash=234d5c847b45]
    public struct ImageJob: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public init(id: String) { self.id = id }
    }

    // parity: ai/src/image.ts#ImageStatus [status=implemented hash=7a7474716d0d]
    public struct ImageStatus: Equatable, Hashable, Sendable, Codable {
        public let status: AIGeneration.Status
        public let reason: AIGeneration.Reason?
        public let progress: Double?
        public init(status: AIGeneration.Status, reason: AIGeneration.Reason? = nil, progress: Double? = nil) {
            self.status = status
            self.reason = reason
            self.progress = progress
        }
    }

    // parity: ai/src/image.ts#ImageResponse [status=implemented hash=aaf429aafb1d]
    public struct ImageResponse: Equatable, Sendable, Codable {
        public let images: [AIMedia.Asset]
        public let usage: AISchema.MediaUsage?
        public let providerMetadata: AISchema.ProviderMetadata?
        public init(images: [AIMedia.Asset], usage: AISchema.MediaUsage? = nil, providerMetadata: AISchema.ProviderMetadata? = nil) {
            self.images = images
            self.usage = usage
            self.providerMetadata = providerMetadata
        }
    }

    // parity: ai/src/image.ts#ImagePartialEvent [status=implemented hash=4cba4b643389]
    public struct ImagePartialEvent: Equatable, Sendable, Codable {
        public let index: Int
        public let image: AIMedia.Asset
        public init(index: Int, image: AIMedia.Asset) { self.index = index; self.image = image }
        enum CodingKeys: String, CodingKey { case type, index, image }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.index = try c.decode(Int.self, forKey: .index)
            self.image = try c.decode(AIMedia.Asset.self, forKey: .image)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("image-partial", forKey: .type)
            try c.encode(index, forKey: .index)
            try c.encode(image, forKey: .image)
        }
    }

    // parity: ai/src/image.ts#ImageOutputEvent [status=implemented hash=6a09fcb95a24]
    public struct ImageOutputEvent: Equatable, Sendable, Codable {
        public let index: Int
        public let image: AIMedia.Asset
        public init(index: Int, image: AIMedia.Asset) { self.index = index; self.image = image }
        enum CodingKeys: String, CodingKey { case type, index, image }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.index = try c.decode(Int.self, forKey: .index)
            self.image = try c.decode(AIMedia.Asset.self, forKey: .image)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("image", forKey: .type)
            try c.encode(index, forKey: .index)
            try c.encode(image, forKey: .image)
        }
    }

    // parity: ai/src/image.ts#ImageFinishEvent [status=implemented hash=f3f3a0e360b3]
    public struct ImageFinishEvent: Equatable, Hashable, Sendable, Codable {
        public let usage: AISchema.MediaUsage?
        public let providerMetadata: AISchema.ProviderMetadata?
        public init(usage: AISchema.MediaUsage? = nil, providerMetadata: AISchema.ProviderMetadata? = nil) {
            self.usage = usage
            self.providerMetadata = providerMetadata
        }
        enum CodingKeys: String, CodingKey { case type, usage, providerMetadata }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.usage = try c.decodeIfPresent(AISchema.MediaUsage.self, forKey: .usage)
            self.providerMetadata = try c.decodeIfPresent(AISchema.ProviderMetadata.self, forKey: .providerMetadata)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("finish", forKey: .type)
            try c.encodeIfPresent(usage, forKey: .usage)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        }
    }

    // parity: ai/src/image.ts#ImageEvent [status=implemented hash=6aa1affb388a]
    public enum ImageEvent: Equatable, Sendable, Codable {
        case generationProgress(AIGeneration.ProgressEvent)
        case imagePartial(ImagePartialEvent)
        case image(ImageOutputEvent)
        case finish(ImageFinishEvent)

        enum TagKeys: String, CodingKey { case type }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: TagKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "generation-progress": self = .generationProgress(try AIGeneration.ProgressEvent(from: decoder))
            case "image-partial": self = .imagePartial(try ImagePartialEvent(from: decoder))
            case "image": self = .image(try ImageOutputEvent(from: decoder))
            case "finish": self = .finish(try ImageFinishEvent(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown ImageEvent type '\(type)'")
            }
        }
        public func encode(to encoder: Encoder) throws {
            switch self {
            case .generationProgress(let e): try e.encode(to: encoder)
            case .imagePartial(let e): try e.encode(to: encoder)
            case .image(let e): try e.encode(to: encoder)
            case .finish(let e): try e.encode(to: encoder)
            }
        }
    }

    private static func collectResponse(_ events: [ImageEvent]) async throws -> ImageResponse {
        var finish: ImageFinishEvent? = nil
        var images: [AIMedia.Asset] = []
        for ev in events {
            switch ev {
            case .image(let out): images.append(out.image)
            case .finish(let f): finish = f
            case .generationProgress, .imagePartial: break
            }
        }
        guard let finish else {
            throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                message: "The image stream completed without a finish event",
                classification: .incompleteStream
            )))
        }
        return ImageResponse(images: images, usage: finish.usage, providerMetadata: finish.providerMetadata)
    }

    // parity: ai/src/image.ts#request [status=implemented hash=da3373d232be]
    public static func request(_ input: ImageRequestInput) throws(AISchema.AIError) -> ImageRequest {
        var assets: [AIMedia.Asset]? = nil
        if let rawImages = input.images {
            var built: [AIMedia.Asset] = []
            built.reserveCapacity(rawImages.count)
            for item in rawImages { built.append(try AIMedia.make(item)) }
            assets = built
        }
        return ImageRequest(
            model: input.model,
            prompt: input.prompt,
            images: assets,
            n: input.n,
            aspect: input.aspect,
            resolution: input.resolution,
            providerOptions: input.providerOptions,
            headers: input.headers,
            timeout: input.timeout,
            http: input.http,
            fetch: input.fetch
        )
    }

    // parity: ai/src/image.ts#generate [status=implemented hash=75d0b2c465fe]
    public static func generate(
        _ input: ImageRequestInput,
        options: AIGeneration.AwaitOptions? = nil,
        client: ImageClient.Service
    ) async throws -> ImageResponse {
        try await client.generate(try request(input), options: options)
    }

    // parity: ai/src/image.ts#stream [status=implemented hash=c21c87bc417f]
    public static func stream(
        _ input: ImageRequestInput,
        options: AIGeneration.AwaitOptions? = nil,
        client: ImageClient.Service
    ) -> AsyncThrowingStream<ImageEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try request(input)
                    for try await ev in client.stream(req, options: options) {
                        continuation.yield(ev)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // parity: ai/src/image.ts#start [status=implemented hash=53afab6ebf0f]
    public static func start(_ input: ImageRequestInput, client: ImageClient.Service) async throws -> ImageJob {
        try await client.start(try request(input))
    }

    // parity: ai/src/image.ts#status [status=implemented hash=aed455727d36]
    public static func status(model: ImageModel, id: String, client: ImageClient.Service) async throws -> ImageStatus {
        try await client.status(model: model, id: id)
    }

    // parity: ai/src/image.ts#result [status=implemented hash=18ca045c1742]
    public static func result(model: ImageModel, id: String, client: ImageClient.Service) async throws -> ImageResponse {
        try await client.result(model: model, id: id)
    }

    // parity: ai/src/image.ts#cancel [status=implemented hash=d91e9888c814]
    public static func cancel(model: ImageModel, id: String, client: ImageClient.Service) async throws {
        try await client.cancel(model: model, id: id)
    }

    // parity: ai/src/image.ts#Image [status=implemented hash=44679a9ff528]
    public enum Image {
        public static func request(_ input: ImageRequestInput) throws(AISchema.AIError) -> ImageRequest {
            try AIImage.request(input)
        }
    }

    // MARK: - src/image-client.ts

    // parity: ai/src/image-client.ts#ImageClient [status=implemented hash=a1a44b539686]
    public enum ImageClient {
        // parity: ai/src/image-client.ts#Interface [status=implemented hash=8fcfa3f5f888]
        public protocol Interface: Sendable {
            func generate(_ request: ImageRequest, options: AIGeneration.AwaitOptions?) async throws -> ImageResponse
            func stream(_ request: ImageRequest, options: AIGeneration.AwaitOptions?) -> AsyncThrowingStream<ImageEvent, Error>
            func start(_ request: ImageRequest) async throws -> ImageJob
            func status(model: ImageModel, id: String) async throws -> ImageStatus
            func result(model: ImageModel, id: String) async throws -> ImageResponse
            func cancel(model: ImageModel, id: String) async throws
        }

        // parity: ai/src/image-client.ts#ImageClientService [status=implemented hash=738eecbdee4c]
        public struct ImageClientService: Interface, Sendable {
            public static let serviceID = "@opencode/ImageClient"
            private let runGenerate: @Sendable (ImageRequest, AIGeneration.AwaitOptions?) async throws -> ImageResponse
            private let runStream: @Sendable (ImageRequest, AIGeneration.AwaitOptions?) -> AsyncThrowingStream<ImageEvent, Error>
            private let runStart: @Sendable (ImageRequest) async throws -> ImageJob
            private let runStatus: @Sendable (ImageModel, String) async throws -> ImageStatus
            private let runResult: @Sendable (ImageModel, String) async throws -> ImageResponse
            private let runCancel: @Sendable (ImageModel, String) async throws -> Void

            public init(
                generate: @escaping @Sendable (ImageRequest, AIGeneration.AwaitOptions?) async throws -> ImageResponse,
                stream: @escaping @Sendable (ImageRequest, AIGeneration.AwaitOptions?) -> AsyncThrowingStream<ImageEvent, Error>,
                start: @escaping @Sendable (ImageRequest) async throws -> ImageJob,
                status: @escaping @Sendable (ImageModel, String) async throws -> ImageStatus,
                result: @escaping @Sendable (ImageModel, String) async throws -> ImageResponse,
                cancel: @escaping @Sendable (ImageModel, String) async throws -> Void
            ) {
                self.runGenerate = generate
                self.runStream = stream
                self.runStart = start
                self.runStatus = status
                self.runResult = result
                self.runCancel = cancel
            }

            public func generate(_ request: ImageRequest, options: AIGeneration.AwaitOptions? = nil) async throws -> ImageResponse {
                try await runGenerate(request, options)
            }
            public func stream(_ request: ImageRequest, options: AIGeneration.AwaitOptions? = nil) -> AsyncThrowingStream<ImageEvent, Error> {
                runStream(request, options)
            }
            public func start(_ request: ImageRequest) async throws -> ImageJob {
                try await runStart(request)
            }
            public func status(model: ImageModel, id: String) async throws -> ImageStatus {
                try await runStatus(model, id)
            }
            public func result(model: ImageModel, id: String) async throws -> ImageResponse {
                try await runResult(model, id)
            }
            public func cancel(model: ImageModel, id: String) async throws {
                try await runCancel(model, id)
            }
        }

        // parity: ai/src/image-client.ts#Service [status=implemented hash=164add8420fa]
        public typealias Service = ImageClientService

        public static func responseEvents(_ response: ImageResponse) -> [ImageEvent] {
            var events = response.images.enumerated().map { idx, img in
                ImageEvent.image(ImageOutputEvent(index: idx, image: img))
            }
            events.append(.finish(ImageFinishEvent(usage: response.usage, providerMetadata: response.providerMetadata)))
            return events
        }

        // parity: ai/src/image-client.ts#layer [status=implemented hash=272cb3fb8659]
        public static func layer(executor: AIRequestExecutor.RequestExecutorService) -> Service {
            let media: AIMedia.MediaClient.Interface<ImageRequest> = AIMedia.MediaClient.operations(
                execute: { req, mw in try await executor.execute(req, middleware: mw) },
                input: AIMedia.MediaClient.Input<ImageEvent, ImageResponse>(modality: "image", responseEvents: responseEvents)
            )
            @Sendable func attach(_ model: ImageModel, id: String, op: String) async throws -> AIGeneration.Route<ImageResponse> {
                guard case .queued(let q) = model.route else {
                    throw AIMedia.MediaClient.notQueued(modality: "image", provider: model.route.provider, routeID: model.route.id, operation: op)
                }
                return try await q.attach(model.descriptor, .string(id)) { req, mw in
                    try await executor.execute(req, middleware: mw)
                }
            }
            return Service(
                generate: media.generate,
                stream: { req, opts in
                    AsyncThrowingStream { continuation in
                        let task = Task {
                            do {
                                for try await ev in media.stream(req, opts) {
                                    switch ev {
                                    case .observation(let obs): continuation.yield(.generationProgress(obs))
                                    case .event(let e): continuation.yield(e)
                                    }
                                }
                                continuation.finish()
                            } catch {
                                continuation.finish(throwing: error)
                            }
                        }
                        continuation.onTermination = { _ in task.cancel() }
                    }
                },
                start: { req in
                    let gen = try await media.start(req)
                    guard case .string(let id) = gen.token else {
                        throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                            message: "Expected string job ID token from image route"
                        )))
                    }
                    return ImageJob(id: id)
                },
                status: { model, id in
                    let route = try await attach(model, id: id, op: "status")
                    let snap = try await route.status()
                    return ImageStatus(status: snap.status, reason: snap.reason, progress: snap.progress)
                },
                result: { model, id in
                    let route = try await attach(model, id: id, op: "result")
                    return try await route.result()
                },
                cancel: { model, id in
                    let route = try await attach(model, id: id, op: "cancel")
                    guard let cancelOp = route.cancel else {
                        throw AISchema.AIError(reason: .unsupportedOperation(AISchema.UnsupportedOperationError(
                            message: "\(model.provider.rawValue)/\(model.route.id) has no way to cancel an image generation",
                            operation: "image.cancel",
                            provider: model.provider,
                            route: model.route.id
                        )))
                    }
                    try await cancelOp()
                }
            )
        }
    }
}

/// Speech synthesis models, requests, responses, events, and client operations.
/// Ports `packages/ai/src/{speech,speech-client}.ts`.
public enum AISpeech {
    // parity: ai/src/speech.ts#SpeechOptions [status=implemented hash=aad6e82b1a97]
    public typealias SpeechOptions = AISchema.ProviderOptions

    // parity: ai/src/speech.ts#SpeechRoute [status=implemented hash=30b0219b5d9d]
    public typealias SpeechRoute = AIRoute.MediaRoute.AnyRoute<SpeechRequest, SpeechEvent, SpeechResponse>

    // parity: ai/src/speech.ts#SpeechVoice [status=implemented hash=7e32f278dd42]
    public enum SpeechVoice: Equatable, Hashable, Sendable, Codable {
        case named(String)
        case custom(id: String)

        enum CodingKeys: String, CodingKey { case id }
        public init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) {
                self = .named(s)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .custom(id: try c.decode(String.self, forKey: .id))
        }
        public func encode(to encoder: Encoder) throws {
            switch self {
            case .named(let s):
                var c = encoder.singleValueContainer()
                try c.encode(s)
            case .custom(let id):
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
            }
        }
    }

    // parity: ai/src/speech.ts#SpeechFormat [status=implemented hash=7d8ae3be5930]
    public struct SpeechFormat: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
        public let rawValue: String
        public static let mp3 = SpeechFormat(rawValue: "mp3")
        public static let wav = SpeechFormat(rawValue: "wav")
        public static let pcm = SpeechFormat(rawValue: "pcm")
        public static let opus = SpeechFormat(rawValue: "opus")
        public static let aac = SpeechFormat(rawValue: "aac")
        public static let flac = SpeechFormat(rawValue: "flac")
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }
    }

    // parity: ai/src/speech.ts#SpeechTimestamp [status=implemented hash=bfc176018e98]
    public struct SpeechTimestamp: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public let startSeconds: Double
        public let endSeconds: Double
        public init(text: String, startSeconds: Double, endSeconds: Double) {
            self.text = text
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
        }
    }

    // parity: ai/src/speech.ts#SpeechModel [status=implemented hash=03beec2898a5]
    public struct SpeechModel: Sendable {
        public let id: AISchema.ModelID
        public let provider: AISchema.ProviderID
        public let route: SpeechRoute
        public let transport: AISchema.TransportOptions?
        public let providerOptions: AISchema.ProviderOptions?

        public init(
            id: String,
            provider: String,
            route: SpeechRoute,
            transport: AISchema.TransportOptions? = nil,
            providerOptions: AISchema.ProviderOptions? = nil
        ) {
            self.id = AISchema.ModelID.make(id)
            self.provider = AISchema.ProviderID.make(provider)
            self.route = route
            self.transport = transport
            self.providerOptions = providerOptions
        }

        public var descriptor: AIRoute.MediaRoute.ModelDescriptor {
            AIRoute.MediaRoute.ModelDescriptor(
                id: id.rawValue,
                provider: provider,
                transport: transport,
                providerOptions: providerOptions
            )
        }

        public static func fromRoute<Frame: Sendable, State: Sendable, Token: Codable & Sendable>(
            _ routeInput: AIMedia.MediaModel<Void>.AnyRouteInput<SpeechRequest, SpeechEvent, SpeechResponse, Frame, State, Token>,
            input: AIRoute.MediaRoute.ModelInput
        ) -> SpeechModel {
            SpeechModel(
                id: input.id,
                provider: routeInput.provider.rawValue,
                route: AIMedia.composeRoute(routeInput, input: input, collect: collectResponse),
                transport: input.transport,
                providerOptions: input.providerOptions
            )
        }
    }

    // parity: ai/src/speech.ts#SpeechModelSchema [status=adapted hash=9b3af186feab]
    public static func SpeechModelSchema(_ value: Any) -> SpeechModel? { value as? SpeechModel }

    // parity: ai/src/speech.ts#SpeechModelOptions [status=adapted hash=08faf41d459a]
    public typealias SpeechModelOptions = SpeechOptions

    // parity: ai/src/speech.ts#SpeechRequest [status=implemented hash=e574a0636868]
    public struct SpeechRequest: AIMedia.MediaClient.RoutedRequest, Sendable {
        public typealias Event = SpeechEvent
        public typealias Response = SpeechResponse

        public let model: SpeechModel
        public let text: String
        public let voice: SpeechVoice?
        public let format: SpeechFormat?
        public let speed: Double?
        public let language: String?
        public let instructions: String?
        public let timestamps: Bool?
        public let providerOptions: AISchema.ProviderOptions?
        public let headers: [String: String]?
        public let timeout: AISchema.RequestTimeout?
        public let http: AISchema.HttpOptions?
        public let fetch: (any HTTPTransport)?

        public var modelDescriptor: AIRoute.MediaRoute.ModelDescriptor { model.descriptor }
        public var route: SpeechRoute { model.route }

        public init(
            model: SpeechModel,
            text: String,
            voice: SpeechVoice? = nil,
            format: SpeechFormat? = nil,
            speed: Double? = nil,
            language: String? = nil,
            instructions: String? = nil,
            timestamps: Bool? = nil,
            providerOptions: AISchema.ProviderOptions? = nil,
            headers: [String: String]? = nil,
            timeout: AISchema.RequestTimeout? = nil,
            http: AISchema.HttpOptions? = nil,
            fetch: (any HTTPTransport)? = nil
        ) {
            self.model = model
            self.text = text
            self.voice = voice
            self.format = format
            self.speed = speed
            self.language = language
            self.instructions = instructions
            self.timestamps = timestamps
            self.providerOptions = providerOptions
            self.headers = headers
            self.timeout = timeout
            self.http = http
            self.fetch = fetch
        }
    }

    // parity: ai/src/speech.ts#SpeechRequestInput [status=implemented hash=564347efb4c4]
    public typealias SpeechRequestInput = SpeechRequest

    // parity: ai/src/speech.ts#SpeechResponse [status=implemented hash=9acd83e03b1a]
    public struct SpeechResponse: Equatable, Sendable, Codable {
        public let audio: AIMedia.Asset
        public let timestamps: [SpeechTimestamp]?
        public let usage: AISchema.MediaUsage?
        public let providerMetadata: AISchema.ProviderMetadata?
        public init(
            audio: AIMedia.Asset,
            timestamps: [SpeechTimestamp]? = nil,
            usage: AISchema.MediaUsage? = nil,
            providerMetadata: AISchema.ProviderMetadata? = nil
        ) {
            self.audio = audio
            self.timestamps = timestamps
            self.usage = usage
            self.providerMetadata = providerMetadata
        }
    }

    // parity: ai/src/speech.ts#SpeechAudioDeltaEvent [status=implemented hash=96a9b2cc136f]
    public struct SpeechAudioDeltaEvent: Equatable, Hashable, Sendable, Codable {
        public let chunk: [UInt8]
        public init(chunk: [UInt8]) { self.chunk = chunk }
        enum CodingKeys: String, CodingKey { case type, chunk }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.chunk = try c.decode([UInt8].self, forKey: .chunk)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("audio-delta", forKey: .type)
            try c.encode(chunk, forKey: .chunk)
        }
    }

    // parity: ai/src/speech.ts#SpeechTimestampsEvent [status=implemented hash=66f7f4de2dc8]
    public struct SpeechTimestampsEvent: Equatable, Hashable, Sendable, Codable {
        public let items: [SpeechTimestamp]
        public init(items: [SpeechTimestamp]) { self.items = items }
        enum CodingKeys: String, CodingKey { case type, items }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.items = try c.decode([SpeechTimestamp].self, forKey: .items)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("timestamps", forKey: .type)
            try c.encode(items, forKey: .items)
        }
    }

    // parity: ai/src/speech.ts#SpeechFinishEvent [status=implemented hash=91328645493e]
    public struct SpeechFinishEvent: Equatable, Sendable, Codable {
        public let audio: AIMedia.Asset
        public let usage: AISchema.MediaUsage?
        public let providerMetadata: AISchema.ProviderMetadata?
        public init(audio: AIMedia.Asset, usage: AISchema.MediaUsage? = nil, providerMetadata: AISchema.ProviderMetadata? = nil) {
            self.audio = audio
            self.usage = usage
            self.providerMetadata = providerMetadata
        }
        enum CodingKeys: String, CodingKey { case type, audio, usage, providerMetadata }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.audio = try c.decode(AIMedia.Asset.self, forKey: .audio)
            self.usage = try c.decodeIfPresent(AISchema.MediaUsage.self, forKey: .usage)
            self.providerMetadata = try c.decodeIfPresent(AISchema.ProviderMetadata.self, forKey: .providerMetadata)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("finish", forKey: .type)
            try c.encode(audio, forKey: .audio)
            try c.encodeIfPresent(usage, forKey: .usage)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        }
    }

    // parity: ai/src/speech.ts#SpeechEvent [status=implemented hash=352f5ff61f47]
    public enum SpeechEvent: Equatable, Sendable, Codable {
        case generationProgress(AIGeneration.ProgressEvent)
        case audioDelta(SpeechAudioDeltaEvent)
        case timestamps(SpeechTimestampsEvent)
        case finish(SpeechFinishEvent)

        enum TagKeys: String, CodingKey { case type }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: TagKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "generation-progress": self = .generationProgress(try AIGeneration.ProgressEvent(from: decoder))
            case "audio-delta": self = .audioDelta(try SpeechAudioDeltaEvent(from: decoder))
            case "timestamps": self = .timestamps(try SpeechTimestampsEvent(from: decoder))
            case "finish": self = .finish(try SpeechFinishEvent(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown SpeechEvent type '\(type)'")
            }
        }
        public func encode(to encoder: Encoder) throws {
            switch self {
            case .generationProgress(let e): try e.encode(to: encoder)
            case .audioDelta(let e): try e.encode(to: encoder)
            case .timestamps(let e): try e.encode(to: encoder)
            case .finish(let e): try e.encode(to: encoder)
            }
        }
    }

    private static func collectResponse(_ events: [SpeechEvent]) async throws -> SpeechResponse {
        var finish: SpeechFinishEvent? = nil
        var allTimestamps: [SpeechTimestamp] = []
        for ev in events {
            switch ev {
            case .timestamps(let ts): allTimestamps.append(contentsOf: ts.items)
            case .finish(let f): finish = f
            case .generationProgress, .audioDelta: break
            }
        }
        guard let finish else {
            throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                message: "The speech stream completed without a finish event",
                classification: .incompleteStream
            )))
        }
        return SpeechResponse(
            audio: finish.audio,
            timestamps: allTimestamps.isEmpty ? nil : allTimestamps,
            usage: finish.usage,
            providerMetadata: finish.providerMetadata
        )
    }

    // parity: ai/src/speech.ts#request [status=implemented hash=1b1bc9bffe5c]
    public static func request(_ input: SpeechRequestInput) -> SpeechRequest { input }

    // parity: ai/src/speech.ts#generate [status=implemented hash=646a54cf6573]
    public static func generate(_ input: SpeechRequestInput, client: SpeechClient.Service) async throws -> SpeechResponse {
        try await client.operations.generate(request(input), nil)
    }

    // parity: ai/src/speech.ts#stream [status=implemented hash=e1f663652706]
    public static func stream(_ input: SpeechRequestInput, client: SpeechClient.Service) -> AsyncThrowingStream<SpeechEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await ev in client.operations.stream(request(input), nil) {
                        switch ev {
                        case .observation(let obs): continuation.yield(.generationProgress(obs))
                        case .event(let e): continuation.yield(e)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // parity: ai/src/speech.ts#Speech [status=implemented hash=b854bb5bf464]
    public enum Speech {
        public static func request(_ input: SpeechRequestInput) -> SpeechRequest { AISpeech.request(input) }
    }

    // MARK: - src/speech-client.ts

    // parity: ai/src/speech-client.ts#SpeechClient [status=implemented hash=39c939aa77f6]
    public enum SpeechClient {
        // parity: ai/src/speech-client.ts#Interface [status=implemented hash=5d1d460ff9d9]
        public typealias Interface = AIMedia.MediaClient.Interface<SpeechRequest>

        // parity: ai/src/speech-client.ts#SpeechClientService [status=implemented hash=f21ce6e4b4c1]
        public struct SpeechClientService: Sendable {
            public static let serviceID = "@opencode/SpeechClient"
            public let operations: Interface
            public init(operations: Interface) { self.operations = operations }
        }

        // parity: ai/src/speech-client.ts#Service [status=implemented hash=7913baa57f1d]
        public typealias Service = SpeechClientService

        public static func layer(executor: AIRequestExecutor.RequestExecutorService) -> Service {
            let ops: Interface = AIMedia.MediaClient.make(
                executor: executor,
                input: AIMedia.MediaClient.Input<SpeechEvent, SpeechResponse>(modality: "speech") { response in
                    var events: [SpeechEvent] = []
                    if let ts = response.timestamps {
                        events.append(.timestamps(SpeechTimestampsEvent(items: ts)))
                    }
                    events.append(.finish(SpeechFinishEvent(
                        audio: response.audio,
                        usage: response.usage,
                        providerMetadata: response.providerMetadata
                    )))
                    return events
                }
            )
            return Service(operations: ops)
        }
    }
}

/// Speech transcription models, segments, words, requests, responses, events, and client.
/// Ports `packages/ai/src/{transcription,transcription-client}.ts`.
public enum AITranscription {
    // parity: ai/src/transcription.ts#TranscriptionOptions [status=implemented hash=9fc833381ec6]
    public typealias TranscriptionOptions = AISchema.ProviderOptions

    // parity: ai/src/transcription.ts#TranscriptionRoute [status=implemented hash=3fa032dcc358]
    public typealias TranscriptionRoute = AIRoute.MediaRoute.AnyRoute<TranscriptionRequest, TranscriptionEvent, TranscriptionResponse>

    // parity: ai/src/transcription.ts#TranscriptionTimestamps [status=implemented hash=f6b61aea545d]
    public enum TranscriptionTimestamps: String, Equatable, Hashable, Sendable, Codable {
        case none
        case segment
        case word
    }

    // parity: ai/src/transcription.ts#TranscriptionSegment [status=implemented hash=b221a89db293]
    public struct TranscriptionSegment: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public let startSeconds: Double
        public let endSeconds: Double
        public let speaker: String?
        public init(text: String, startSeconds: Double, endSeconds: Double, speaker: String? = nil) {
            self.text = text
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.speaker = speaker
        }
    }

    // parity: ai/src/transcription.ts#TranscriptionWord [status=implemented hash=2c294d586d5f]
    public struct TranscriptionWord: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public let startSeconds: Double
        public let endSeconds: Double
        public let speaker: String?
        public let confidence: Double?
        public init(text: String, startSeconds: Double, endSeconds: Double, speaker: String? = nil, confidence: Double? = nil) {
            self.text = text
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.speaker = speaker
            self.confidence = confidence
        }
    }

    // parity: ai/src/transcription.ts#TranscriptionModel [status=implemented hash=563f49ce7525]
    public struct TranscriptionModel: Sendable {
        public let id: AISchema.ModelID
        public let provider: AISchema.ProviderID
        public let route: TranscriptionRoute
        public let transport: AISchema.TransportOptions?
        public let providerOptions: AISchema.ProviderOptions?

        public init(
            id: String,
            provider: String,
            route: TranscriptionRoute,
            transport: AISchema.TransportOptions? = nil,
            providerOptions: AISchema.ProviderOptions? = nil
        ) {
            self.id = AISchema.ModelID.make(id)
            self.provider = AISchema.ProviderID.make(provider)
            self.route = route
            self.transport = transport
            self.providerOptions = providerOptions
        }

        public var descriptor: AIRoute.MediaRoute.ModelDescriptor {
            AIRoute.MediaRoute.ModelDescriptor(
                id: id.rawValue,
                provider: provider,
                transport: transport,
                providerOptions: providerOptions
            )
        }

        public static func fromRoute<Frame: Sendable, State: Sendable, Token: Codable & Sendable>(
            _ routeInput: AIMedia.MediaModel<Void>.AnyRouteInput<TranscriptionRequest, TranscriptionEvent, TranscriptionResponse, Frame, State, Token>,
            input: AIRoute.MediaRoute.ModelInput
        ) -> TranscriptionModel {
            TranscriptionModel(
                id: input.id,
                provider: routeInput.provider.rawValue,
                route: AIMedia.composeRoute(routeInput, input: input, collect: collectResponse),
                transport: input.transport,
                providerOptions: input.providerOptions
            )
        }
    }

    // parity: ai/src/transcription.ts#TranscriptionModelSchema [status=adapted hash=0a5f67c8a234]
    public static func TranscriptionModelSchema(_ value: Any) -> TranscriptionModel? { value as? TranscriptionModel }

    // parity: ai/src/transcription.ts#TranscriptionModelOptions [status=adapted hash=eeb9b7ac45de]
    public typealias TranscriptionModelOptions = TranscriptionOptions

    // parity: ai/src/transcription.ts#TranscriptionRequest [status=implemented hash=ca58ce5558a8]
    public struct TranscriptionRequest: AIMedia.MediaClient.RoutedRequest, Sendable {
        public typealias Event = TranscriptionEvent
        public typealias Response = TranscriptionResponse

        public let model: TranscriptionModel
        public let audio: AIMedia.Asset
        public let language: String?
        public let prompt: String?
        public let timestamps: TranscriptionTimestamps?
        public let diarize: Bool?
        public let speakers: Int?
        public let providerOptions: AISchema.ProviderOptions?
        public let headers: [String: String]?
        public let timeout: AISchema.RequestTimeout?
        public let http: AISchema.HttpOptions?
        public let fetch: (any HTTPTransport)?

        public var modelDescriptor: AIRoute.MediaRoute.ModelDescriptor { model.descriptor }
        public var route: TranscriptionRoute { model.route }

        public init(
            model: TranscriptionModel,
            audio: AIMedia.Asset,
            language: String? = nil,
            prompt: String? = nil,
            timestamps: TranscriptionTimestamps? = nil,
            diarize: Bool? = nil,
            speakers: Int? = nil,
            providerOptions: AISchema.ProviderOptions? = nil,
            headers: [String: String]? = nil,
            timeout: AISchema.RequestTimeout? = nil,
            http: AISchema.HttpOptions? = nil,
            fetch: (any HTTPTransport)? = nil
        ) {
            self.model = model
            self.audio = audio
            self.language = language
            self.prompt = prompt
            self.timestamps = timestamps
            self.diarize = diarize
            self.speakers = speakers
            self.providerOptions = providerOptions
            self.headers = headers
            self.timeout = timeout
            self.http = http
            self.fetch = fetch
        }
    }

    // parity: ai/src/transcription.ts#TranscriptionRequestInput [status=implemented hash=de88f557b0b8]
    public typealias TranscriptionRequestInput = TranscriptionRequest

    // parity: ai/src/transcription.ts#TranscriptionResponse [status=implemented hash=090f6c5f80b5]
    public struct TranscriptionResponse: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public let segments: [TranscriptionSegment]?
        public let words: [TranscriptionWord]?
        public let language: String?
        public let durationSeconds: Double?
        public let usage: AISchema.MediaUsage?
        public let providerMetadata: AISchema.ProviderMetadata?

        public init(
            text: String,
            segments: [TranscriptionSegment]? = nil,
            words: [TranscriptionWord]? = nil,
            language: String? = nil,
            durationSeconds: Double? = nil,
            usage: AISchema.MediaUsage? = nil,
            providerMetadata: AISchema.ProviderMetadata? = nil
        ) {
            self.text = text
            self.segments = segments
            self.words = words
            self.language = language
            self.durationSeconds = durationSeconds
            self.usage = usage
            self.providerMetadata = providerMetadata
        }
    }

    // parity: ai/src/transcription.ts#TranscriptionTextDeltaEvent [status=implemented hash=244382b1d602]
    public struct TranscriptionTextDeltaEvent: Equatable, Hashable, Sendable, Codable {
        public let delta: String
        public init(delta: String) { self.delta = delta }
        enum CodingKeys: String, CodingKey { case type, delta }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.delta = try c.decode(String.self, forKey: .delta)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("text-delta", forKey: .type)
            try c.encode(delta, forKey: .delta)
        }
    }

    // parity: ai/src/transcription.ts#TranscriptionSegmentEvent [status=implemented hash=6fb164b586d1]
    public struct TranscriptionSegmentEvent: Equatable, Hashable, Sendable, Codable {
        public let segment: TranscriptionSegment
        public init(segment: TranscriptionSegment) { self.segment = segment }
        enum CodingKeys: String, CodingKey { case type, segment }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.segment = try c.decode(TranscriptionSegment.self, forKey: .segment)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("segment", forKey: .type)
            try c.encode(segment, forKey: .segment)
        }
    }

    // parity: ai/src/transcription.ts#TranscriptionFinishEvent [status=implemented hash=39abc536b85f]
    public struct TranscriptionFinishEvent: Equatable, Hashable, Sendable, Codable {
        public let response: TranscriptionResponse
        public init(_ response: TranscriptionResponse) { self.response = response }
        enum CodingKeys: String, CodingKey { case type, text, segments, words, language, durationSeconds, usage, providerMetadata }
        public init(from decoder: Decoder) throws {
            self.response = try TranscriptionResponse(from: decoder)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("finish", forKey: .type)
            try c.encode(response.text, forKey: .text)
            try c.encodeIfPresent(response.segments, forKey: .segments)
            try c.encodeIfPresent(response.words, forKey: .words)
            try c.encodeIfPresent(response.language, forKey: .language)
            try c.encodeIfPresent(response.durationSeconds, forKey: .durationSeconds)
            try c.encodeIfPresent(response.usage, forKey: .usage)
            try c.encodeIfPresent(response.providerMetadata, forKey: .providerMetadata)
        }
    }

    // parity: ai/src/transcription.ts#TranscriptionEvent [status=implemented hash=b41e394b648b]
    public enum TranscriptionEvent: Equatable, Hashable, Sendable, Codable {
        case generationProgress(AIGeneration.ProgressEvent)
        case textDelta(TranscriptionTextDeltaEvent)
        case segment(TranscriptionSegmentEvent)
        case finish(TranscriptionFinishEvent)

        enum TagKeys: String, CodingKey { case type }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: TagKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "generation-progress": self = .generationProgress(try AIGeneration.ProgressEvent(from: decoder))
            case "text-delta": self = .textDelta(try TranscriptionTextDeltaEvent(from: decoder))
            case "segment": self = .segment(try TranscriptionSegmentEvent(from: decoder))
            case "finish": self = .finish(try TranscriptionFinishEvent(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown TranscriptionEvent type '\(type)'")
            }
        }
        public func encode(to encoder: Encoder) throws {
            switch self {
            case .generationProgress(let e): try e.encode(to: encoder)
            case .textDelta(let e): try e.encode(to: encoder)
            case .segment(let e): try e.encode(to: encoder)
            case .finish(let e): try e.encode(to: encoder)
            }
        }
    }

    private static func collectResponse(_ events: [TranscriptionEvent]) async throws -> TranscriptionResponse {
        for ev in events {
            if case .finish(let f) = ev { return f.response }
        }
        throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
            message: "The transcription stream completed without a finish event",
            classification: .incompleteStream
        )))
    }

    // parity: ai/src/transcription.ts#request [status=implemented hash=ee7232e16b89]
    public static func request(_ input: TranscriptionRequestInput) -> TranscriptionRequest { input }

    // parity: ai/src/transcription.ts#generate [status=implemented hash=af581f30f0b2]
    public static func generate(
        _ input: TranscriptionRequestInput,
        options: AIGeneration.AwaitOptions? = nil,
        client: TranscriptionClient.Service
    ) async throws -> TranscriptionResponse {
        try await client.operations.generate(request(input), options)
    }

    // parity: ai/src/transcription.ts#stream [status=implemented hash=2879a85db876]
    public static func stream(
        _ input: TranscriptionRequestInput,
        options: AIGeneration.AwaitOptions? = nil,
        client: TranscriptionClient.Service
    ) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await ev in client.operations.stream(request(input), options) {
                        switch ev {
                        case .observation(let obs): continuation.yield(.generationProgress(obs))
                        case .event(let e): continuation.yield(e)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // parity: ai/src/transcription.ts#start [status=implemented hash=8f3a99b93613]
    public static func start(
        _ input: TranscriptionRequestInput,
        client: TranscriptionClient.Service
    ) async throws -> AIGeneration.Generation<TranscriptionResponse> {
        try await client.operations.start(request(input))
    }

    // parity: ai/src/transcription.ts#resume [status=implemented hash=766b9353cfc4]
    public static func resume(
        model: TranscriptionModel,
        token: JSONValue,
        client: TranscriptionClient.Service
    ) async throws -> AIGeneration.Generation<TranscriptionResponse> {
        try await client.operations.resume(model.descriptor, model.route, token)
    }

    // parity: ai/src/transcription.ts#Transcription [status=implemented hash=fe9a75135796]
    public enum Transcription {
        public static func request(_ input: TranscriptionRequestInput) -> TranscriptionRequest {
            AITranscription.request(input)
        }
    }

    // MARK: - src/transcription-client.ts

    // parity: ai/src/transcription-client.ts#TranscriptionClient [status=implemented hash=ab7731708821]
    public enum TranscriptionClient {
        // parity: ai/src/transcription-client.ts#Interface [status=implemented hash=5379beb88d8c]
        public typealias Interface = AIMedia.MediaClient.Interface<TranscriptionRequest>

        // parity: ai/src/transcription-client.ts#TranscriptionClientService [status=implemented hash=5ef11c6f6fd7]
        public struct TranscriptionClientService: Sendable {
            public static let serviceID = "@opencode/TranscriptionClient"
            public let operations: Interface
            public init(operations: Interface) { self.operations = operations }
        }

        // parity: ai/src/transcription-client.ts#Service [status=implemented hash=39084b44c5a6]
        public typealias Service = TranscriptionClientService

        public static func layer(executor: AIRequestExecutor.RequestExecutorService) -> Service {
            let ops: Interface = AIMedia.MediaClient.make(
                executor: executor,
                input: AIMedia.MediaClient.Input<TranscriptionEvent, TranscriptionResponse>(modality: "transcription") { resp in
                    [.finish(TranscriptionFinishEvent(resp))]
                }
            )
            return Service(operations: ops)
        }
    }
}

/// Video generation models, duration parsing, queued jobs, status/result/cancel client.
/// Ports `packages/ai/src/{video,video-client}.ts`.
public enum AIVideo {
    // parity: ai/src/video.ts#VideoOptions [status=implemented hash=8ff1a7baadd9]
    public typealias VideoOptions = AISchema.ProviderOptions

    // parity: ai/src/video.ts#VideoRoute [status=implemented hash=c0be99ae225f]
    public typealias VideoRoute = AIRoute.MediaRoute.QueuedRoute<VideoRequest, VideoResponse>

    // parity: ai/src/video.ts#VideoAspectRatio [status=implemented hash=db6272e8ddea]
    public enum VideoAspectRatio: Equatable, Hashable, Sendable, Codable {
        case ratio(AIMedia.AspectRatio)
        case auto

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if s == "auto" { self = .auto; return }
            guard let ratio = AIMedia.AspectRatio(rawValue: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid VideoAspectRatio '\(s)'")
            }
            self = .ratio(ratio)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .ratio(let r): try c.encode(r.rawValue)
            case .auto: try c.encode("auto")
            }
        }
    }

    // parity: ai/src/video.ts#VideoResolution [status=implemented hash=bc1d3caa5ee7]
    public struct VideoResolution: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
        public let rawValue: String
        public static let res480p = VideoResolution(rawValue: "480p")
        public static let res720p = VideoResolution(rawValue: "720p")
        public static let res1080p = VideoResolution(rawValue: "1080p")
        public static let res4k = VideoResolution(rawValue: "4k")
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }
    }

    // parity: ai/src/video.ts#VideoDuration [status=implemented hash=f825dd79ba65]
    public struct VideoDuration: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String
        public let valueSeconds: Double

        public init?(rawValue: String) {
            guard let parsed = Self.parseSeconds(rawValue) else { return nil }
            self.rawValue = rawValue
            self.valueSeconds = parsed
        }

        public var description: String { rawValue }

        private static func parseSeconds(_ value: String) -> Double? {
            let parts = value.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[1] == "second" || parts[1] == "seconds" else { return nil }
            let numStr = String(parts[0])
            guard !numStr.isEmpty, let num = Double(numStr), num.isFinite, num >= 0 else { return nil }
            // Must strictly match /^\d+(?:\.\d+)?$/
            let segs = numStr.split(separator: ".", omittingEmptySubsequences: false)
            guard segs.count == 1 || segs.count == 2 else { return nil }
            guard segs.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) }) else { return nil }
            return num
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let parsed = Self.parseSeconds(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid Video.Duration '\(s)'")
            }
            self.rawValue = s
            self.valueSeconds = parsed
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
    }

    // parity: ai/src/video.ts#seconds [status=implemented hash=53f16e304400]
    public static func seconds(_ duration: VideoDuration) -> Double {
        duration.valueSeconds
    }

    // parity: ai/src/video.ts#VideoModel [status=implemented hash=ac8b3a924b40]
    public struct VideoModel: Sendable {
        public let id: AISchema.ModelID
        public let provider: AISchema.ProviderID
        public let route: VideoRoute
        public let transport: AISchema.TransportOptions?
        public let providerOptions: AISchema.ProviderOptions?

        public init(
            id: String,
            provider: String,
            route: VideoRoute,
            transport: AISchema.TransportOptions? = nil,
            providerOptions: AISchema.ProviderOptions? = nil
        ) {
            self.id = AISchema.ModelID.make(id)
            self.provider = AISchema.ProviderID.make(provider)
            self.route = route
            self.transport = transport
            self.providerOptions = providerOptions
        }

        public var descriptor: AIRoute.MediaRoute.ModelDescriptor {
            AIRoute.MediaRoute.ModelDescriptor(
                id: id.rawValue,
                provider: provider,
                transport: transport,
                providerOptions: providerOptions
            )
        }

        public static func fromRoute(
            _ routeInput: AIMedia.MediaModel<Void>.QueuedRouteInput<VideoRequest, VideoResponse, String>,
            input: AIRoute.MediaRoute.ModelInput
        ) -> VideoModel {
            VideoModel(
                id: input.id,
                provider: routeInput.wireProtocol.provider.rawValue,
                route: AIMedia.composeQueuedRoute(routeInput, input: input),
                transport: input.transport,
                providerOptions: input.providerOptions
            )
        }
    }

    // parity: ai/src/video.ts#VideoModelSchema [status=adapted hash=d33a3ca0b394]
    public static func VideoModelSchema(_ value: Any) -> VideoModel? { value as? VideoModel }

    // parity: ai/src/video.ts#VideoModelOptions [status=adapted hash=330e21821eca]
    public typealias VideoModelOptions = VideoOptions

    // parity: ai/src/video.ts#VideoRequest [status=implemented hash=b6f6ebaac22a]
    public struct VideoRequest: AIRoute.MediaRoute.MediaRequest, Sendable {
        public let model: VideoModel
        public let prompt: String
        public let start: AIMedia.ImageAsset?
        public let end: AIMedia.ImageAsset?
        public let references: [AIMedia.Asset]?
        public let duration: VideoDuration?
        public let aspect: VideoAspectRatio?
        public let resolution: VideoResolution?
        public let sound: Bool?
        public let providerOptions: AISchema.ProviderOptions?
        public let headers: [String: String]?
        public let timeout: AISchema.RequestTimeout?
        public let http: AISchema.HttpOptions?
        public let fetch: (any HTTPTransport)?

        public var modelDescriptor: AIRoute.MediaRoute.ModelDescriptor { model.descriptor }

        public init(
            model: VideoModel,
            prompt: String,
            start: AIMedia.ImageAsset? = nil,
            end: AIMedia.ImageAsset? = nil,
            references: [AIMedia.Asset]? = nil,
            duration: VideoDuration? = nil,
            aspect: VideoAspectRatio? = nil,
            resolution: VideoResolution? = nil,
            sound: Bool? = nil,
            providerOptions: AISchema.ProviderOptions? = nil,
            headers: [String: String]? = nil,
            timeout: AISchema.RequestTimeout? = nil,
            http: AISchema.HttpOptions? = nil,
            fetch: (any HTTPTransport)? = nil
        ) {
            self.model = model
            self.prompt = prompt
            self.start = start
            self.end = end
            self.references = references
            self.duration = duration
            self.aspect = aspect
            self.resolution = resolution
            self.sound = sound
            self.providerOptions = providerOptions
            self.headers = headers
            self.timeout = timeout
            self.http = http
            self.fetch = fetch
        }
    }

    // parity: ai/src/video.ts#VideoRequestInput [status=implemented hash=d7a4d095eb27]
    public struct VideoRequestInput: Sendable {
        public let model: VideoModel
        public let prompt: String
        public let start: AIMedia.Input?
        public let end: AIMedia.Input?
        public let references: [AIMedia.Input]?
        public let duration: VideoDuration?
        public let aspect: VideoAspectRatio?
        public let resolution: VideoResolution?
        public let sound: Bool?
        public let providerOptions: AISchema.ProviderOptions?
        public let headers: [String: String]?
        public let timeout: AISchema.RequestTimeout?
        public let http: AISchema.HttpOptions?
        public let fetch: (any HTTPTransport)?

        public init(
            model: VideoModel,
            prompt: String,
            start: AIMedia.Input? = nil,
            end: AIMedia.Input? = nil,
            references: [AIMedia.Input]? = nil,
            duration: VideoDuration? = nil,
            aspect: VideoAspectRatio? = nil,
            resolution: VideoResolution? = nil,
            sound: Bool? = nil,
            providerOptions: AISchema.ProviderOptions? = nil,
            headers: [String: String]? = nil,
            timeout: AISchema.RequestTimeout? = nil,
            http: AISchema.HttpOptions? = nil,
            fetch: (any HTTPTransport)? = nil
        ) {
            self.model = model
            self.prompt = prompt
            self.start = start
            self.end = end
            self.references = references
            self.duration = duration
            self.aspect = aspect
            self.resolution = resolution
            self.sound = sound
            self.providerOptions = providerOptions
            self.headers = headers
            self.timeout = timeout
            self.http = http
            self.fetch = fetch
        }
    }

    // parity: ai/src/video.ts#VideoJob [status=implemented hash=818531ad935c]
    public struct VideoJob: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public init(id: String) { self.id = id }
    }

    // parity: ai/src/video.ts#VideoStatus [status=implemented hash=083107b093dc]
    public struct VideoStatus: Equatable, Hashable, Sendable, Codable {
        public let status: AIGeneration.Status
        public let reason: AIGeneration.Reason?
        public let progress: Double?
        public init(status: AIGeneration.Status, reason: AIGeneration.Reason? = nil, progress: Double? = nil) {
            self.status = status
            self.reason = reason
            self.progress = progress
        }
    }

    // parity: ai/src/video.ts#VideoResponse [status=implemented hash=c20f7b39e595]
    public struct VideoResponse: Equatable, Sendable, Codable {
        public let videos: [AIMedia.Asset]
        public let usage: AISchema.MediaUsage?
        public let providerMetadata: AISchema.ProviderMetadata?
        public var video: AIMedia.Asset? { videos.first }
        public init(videos: [AIMedia.Asset], usage: AISchema.MediaUsage? = nil, providerMetadata: AISchema.ProviderMetadata? = nil) {
            self.videos = videos
            self.usage = usage
            self.providerMetadata = providerMetadata
        }
    }

    // parity: ai/src/video.ts#request [status=implemented hash=2bc9075336a9]
    public static func request(_ input: VideoRequestInput) throws(AISchema.AIError) -> VideoRequest {
        let startImg: AIMedia.ImageAsset? = if let s = input.start { try AIMedia.image(s) } else { nil }
        let endImg: AIMedia.ImageAsset? = if let e = input.end { try AIMedia.image(e) } else { nil }
        var refs: [AIMedia.Asset]? = nil
        if let rawRefs = input.references {
            var built: [AIMedia.Asset] = []
            built.reserveCapacity(rawRefs.count)
            for item in rawRefs { built.append(try AIMedia.make(item)) }
            refs = built
        }
        return VideoRequest(
            model: input.model,
            prompt: input.prompt,
            start: startImg,
            end: endImg,
            references: refs,
            duration: input.duration,
            aspect: input.aspect,
            resolution: input.resolution,
            sound: input.sound,
            providerOptions: input.providerOptions,
            headers: input.headers,
            timeout: input.timeout,
            http: input.http,
            fetch: input.fetch
        )
    }

    // parity: ai/src/video.ts#start [status=implemented hash=07bc031dcdb8]
    public static func start(_ input: VideoRequestInput, client: VideoClient.Service) async throws -> VideoJob {
        try await client.start(try request(input))
    }

    // parity: ai/src/video.ts#status [status=implemented hash=58e2890cefd4]
    public static func status(model: VideoModel, id: String, client: VideoClient.Service) async throws -> VideoStatus {
        try await client.status(model: model, id: id)
    }

    // parity: ai/src/video.ts#result [status=implemented hash=69e000680053]
    public static func result(model: VideoModel, id: String, client: VideoClient.Service) async throws -> VideoResponse {
        try await client.result(model: model, id: id)
    }

    // parity: ai/src/video.ts#cancel [status=implemented hash=71c35a2f9c1d]
    public static func cancel(model: VideoModel, id: String, client: VideoClient.Service) async throws {
        try await client.cancel(model: model, id: id)
    }

    // parity: ai/src/video.ts#Video [status=implemented hash=a0e824c593aa]
    public enum Video {
        public static func request(_ input: VideoRequestInput) throws(AISchema.AIError) -> VideoRequest {
            try AIVideo.request(input)
        }
    }

    // MARK: - src/video-client.ts

    // parity: ai/src/video-client.ts#VideoClient [status=implemented hash=373879cc22af]
    public enum VideoClient {
        // parity: ai/src/video-client.ts#Interface [status=implemented hash=9568c31bdfc3]
        public protocol Interface: Sendable {
            func start(_ request: VideoRequest) async throws -> VideoJob
            func status(model: VideoModel, id: String) async throws -> VideoStatus
            func result(model: VideoModel, id: String) async throws -> VideoResponse
            func cancel(model: VideoModel, id: String) async throws
        }

        // parity: ai/src/video-client.ts#VideoClientService [status=implemented hash=a8e7cce46a8f]
        public struct VideoClientService: Interface, Sendable {
            public static let serviceID = "@opencode/VideoClient"
            private let runStart: @Sendable (VideoRequest) async throws -> VideoJob
            private let runStatus: @Sendable (VideoModel, String) async throws -> VideoStatus
            private let runResult: @Sendable (VideoModel, String) async throws -> VideoResponse
            private let runCancel: @Sendable (VideoModel, String) async throws -> Void

            public init(
                start: @escaping @Sendable (VideoRequest) async throws -> VideoJob,
                status: @escaping @Sendable (VideoModel, String) async throws -> VideoStatus,
                result: @escaping @Sendable (VideoModel, String) async throws -> VideoResponse,
                cancel: @escaping @Sendable (VideoModel, String) async throws -> Void
            ) {
                self.runStart = start
                self.runStatus = status
                self.runResult = result
                self.runCancel = cancel
            }

            public func start(_ request: VideoRequest) async throws -> VideoJob { try await runStart(request) }
            public func status(model: VideoModel, id: String) async throws -> VideoStatus { try await runStatus(model, id) }
            public func result(model: VideoModel, id: String) async throws -> VideoResponse { try await runResult(model, id) }
            public func cancel(model: VideoModel, id: String) async throws { try await runCancel(model, id) }
        }

        // parity: ai/src/video-client.ts#Service [status=implemented hash=7eb3438ade39]
        public typealias Service = VideoClientService

        // parity: ai/src/video-client.ts#layer [status=implemented hash=d62bc1e88856]
        public static func layer(executor: AIRequestExecutor.RequestExecutorService) -> Service {
            let exec: AIRoute.MediaRoute.Execute = { req, mw in try await executor.execute(req, middleware: mw) }
            return Service(
                start: { req in
                    let gen = try await req.model.route.start(req, exec)
                    guard case .string(let id) = gen.token else {
                        throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                            message: "Expected string job ID token from video route"
                        )))
                    }
                    return VideoJob(id: id)
                },
                status: { model, id in
                    let route = try await model.route.attach(model.descriptor, .string(id), exec)
                    let snap = try await route.status()
                    return VideoStatus(status: snap.status, reason: snap.reason, progress: snap.progress)
                },
                result: { model, id in
                    let route = try await model.route.attach(model.descriptor, .string(id), exec)
                    return try await route.result()
                },
                cancel: { model, id in
                    let route = try await model.route.attach(model.descriptor, .string(id), exec)
                    guard let cancelOp = route.cancel else {
                        throw AISchema.AIError(reason: .unsupportedOperation(AISchema.UnsupportedOperationError(
                            message: "\(model.provider.rawValue)/\(model.route.id) has no way to cancel a video generation",
                            operation: "video.cancel",
                            provider: model.provider,
                            route: model.route.id
                        )))
                    }
                    try await cancelOp()
                }
            )
        }
    }
}

/// Experimental extraction, Cloudflare Run extraction, and realtime voice/WebRTC/WebSocket APIs.
/// Ports `packages/ai/src/experimental/{extraction,cloudflare-run-extraction,realtime}.ts`.
public enum AIExperimental {

    // MARK: - src/experimental/extraction.ts

    // parity: ai/src/experimental/extraction.ts#ExtractionAnswers [status=implemented hash=f433a9957dd9]
    public enum ExtractionAnswers {
        public struct Span: Equatable, Hashable, Sendable, Codable {
            public let start: Int
            public let end: Int
            public init(start: Int, end: Int) { self.start = start; self.end = end }

            public init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                self.start = try c.decode(Int.self)
                self.end = try c.decode(Int.self)
            }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.unkeyedContainer()
                try c.encode(start)
                try c.encode(end)
            }
        }

        public enum NumberOrDate: Equatable, Hashable, Sendable, Codable {
            case number(Double)
            case date(String)

            public init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let d = try? c.decode(Double.self) { self = .number(d); return }
                self = .date(try c.decode(String.self))
            }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.singleValueContainer()
                switch self {
                case .number(let d): try c.encode(d)
                case .date(let s): try c.encode(s)
                }
            }
        }

        public struct ValueAnswer<Value: Equatable & Hashable & Sendable & Codable>: Equatable, Hashable, Sendable, Codable {
            public let value: Value?
            public let guess: Value?
            public let nullProbability: Double?
            public let confidence: Double?
            public let span: Span?

            public init(
                value: Value?,
                guess: Value? = nil,
                nullProbability: Double? = nil,
                confidence: Double? = nil,
                span: Span? = nil
            ) {
                self.value = value
                self.guess = guess
                self.nullProbability = nullProbability
                self.confidence = confidence
                self.span = span
            }

            enum CodingKeys: String, CodingKey {
                case value, guess, nullProbability = "p_null", confidence, span
            }
        }

        public struct EstimateAnswer: Equatable, Hashable, Sendable, Codable {
            public let value: NumberOrDate
            public let mean: NumberOrDate?
            public let median: NumberOrDate
            public let p10: NumberOrDate
            public let p90: NumberOrDate
            public let belowProbability: Double?
            public let aboveProbability: Double?
            public let quantiles: [NumberOrDate]?

            public init(
                value: NumberOrDate,
                mean: NumberOrDate? = nil,
                median: NumberOrDate,
                p10: NumberOrDate,
                p90: NumberOrDate,
                belowProbability: Double? = nil,
                aboveProbability: Double? = nil,
                quantiles: [NumberOrDate]? = nil
            ) {
                self.value = value
                self.mean = mean
                self.median = median
                self.p10 = p10
                self.p90 = p90
                self.belowProbability = belowProbability
                self.aboveProbability = aboveProbability
                self.quantiles = quantiles
            }

            enum CodingKeys: String, CodingKey {
                case value, mean, median, p10, p90
                case belowProbability = "p_below"
                case aboveProbability = "p_above"
                case quantiles
            }
        }

        public enum ListItem: Equatable, Hashable, Sendable, Codable {
            case string(String)
            case number(Double)

            public init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let d = try? c.decode(Double.self) { self = .number(d); return }
                self = .string(try c.decode(String.self))
            }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.singleValueContainer()
                switch self {
                case .string(let s): try c.encode(s)
                case .number(let d): try c.encode(d)
                }
            }
        }

        public struct ListAnswer: Equatable, Hashable, Sendable, Codable {
            public let value: [ListItem]?
            public let spans: [Span]?
            public let confidence: Double?

            public init(value: [ListItem]?, spans: [Span]? = nil, confidence: Double? = nil) {
                self.value = value
                self.spans = spans
                self.confidence = confidence
            }
        }

        public struct ForecastAnswer: Equatable, Hashable, Sendable, Codable {
            public let value: [NumberOrDate]
            public let steps: [EstimateAnswer]

            public init(value: [NumberOrDate], steps: [EstimateAnswer]) {
                self.value = value
                self.steps = steps
            }
        }

        public static let knownFieldTypes: Set<String> = [
            "text", "number", "date", "time", "datetime", "duration", "list", "estimate", "forecast",
        ]

        /// Decodes a raw wire answer into canonical camelCase keys (`p_null` -> `nullProbability`, etc.).
        public static func decodeKnownAnswer(fieldType: String, raw: JSONValue) throws -> [String: JSONValue] {
            let data = try JSONEncoder().encode(raw)
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            func toObject<T: Encodable>(_ value: T) throws -> [String: JSONValue] {
                let encoded = try encoder.encode(value)
                guard case .object(let obj) = try decoder.decode(JSONValue.self, from: encoded) else { return [:] }
                return obj
            }
            switch fieldType {
            case "text", "date", "time", "datetime":
                let decoded = try decoder.decode(ValueAnswer<String>.self, from: data)
                var obj = try toObject(decoded)
                if let pNull = obj.removeValue(forKey: "p_null") { obj["nullProbability"] = pNull }
                return obj
            case "number", "duration":
                let decoded = try decoder.decode(ValueAnswer<Double>.self, from: data)
                var obj = try toObject(decoded)
                if let pNull = obj.removeValue(forKey: "p_null") { obj["nullProbability"] = pNull }
                return obj
            case "list":
                let decoded = try decoder.decode(ListAnswer.self, from: data)
                return try toObject(decoded)
            case "estimate":
                let decoded = try decoder.decode(EstimateAnswer.self, from: data)
                var obj = try toObject(decoded)
                if let v = obj.removeValue(forKey: "p_below") { obj["belowProbability"] = v }
                if let v = obj.removeValue(forKey: "p_above") { obj["aboveProbability"] = v }
                return obj
            case "forecast":
                let decoded = try decoder.decode(ForecastAnswer.self, from: data)
                return try toObject(decoded)
            default:
                if case .object(let obj) = raw { return obj }
                return ["value": raw]
            }
        }
    }

    // parity: ai/src/experimental/extraction.ts#ExtractionAnswerFor [status=adapted hash=0b4af6f302e6]
    public typealias ExtractionAnswerFor = [String: JSONValue]

    // parity: ai/src/experimental/extraction.ts#ExtractionAnswersFor [status=adapted hash=9b77a9d81b47]
    public typealias ExtractionAnswersFor = [String: [String: JSONValue]]

    // parity: ai/src/experimental/extraction.ts#ExtractionField [status=implemented hash=9e0e4113594e]
    public struct ExtractionField: Equatable, Hashable, Sendable, Codable {
        public let type: String
        public let instructions: String?
        public let nullThreshold: Double?
        public let extra: [String: JSONValue]

        public init(
            type: String,
            instructions: String? = nil,
            nullThreshold: Double? = nil,
            extra: [String: JSONValue] = [:]
        ) {
            self.type = type
            self.instructions = instructions
            self.nullThreshold = nullThreshold
            self.extra = extra
        }

        public func toWireObject() -> [String: JSONValue] {
            var out = extra
            out["type"] = .string(type)
            if let instructions { out["instructions"] = .string(instructions) }
            if let nullThreshold { out["null_threshold"] = .double(nullThreshold) }
            return out
        }
    }

    // parity: ai/src/experimental/extraction.ts#ExtractionFields [status=implemented hash=0f5cbeb7448d]
    public typealias ExtractionFields = [String: ExtractionField]

    // parity: ai/src/experimental/extraction.ts#ExtractionOptions [status=implemented hash=b63cc0241581]
    public typealias ExtractionOptions = AISchema.ProviderOptions

    // parity: ai/src/experimental/extraction.ts#ExtractionRoute [status=implemented hash=ffd16ac6324a]
    public typealias ExtractionRoute = AIRoute.MediaRoute.InlineRoute<ExtractionRequest, ExtractionResponse>

    // parity: ai/src/experimental/extraction.ts#ExtractionModel [status=implemented hash=50a8f3f6db2a]
    public struct ExtractionModel: Sendable {
        public let id: AISchema.ModelID
        public let provider: AISchema.ProviderID
        public let route: ExtractionRoute
        public let transport: AISchema.TransportOptions?
        public let providerOptions: AISchema.ProviderOptions?

        public init(
            id: String,
            provider: String,
            route: ExtractionRoute,
            transport: AISchema.TransportOptions? = nil,
            providerOptions: AISchema.ProviderOptions? = nil
        ) {
            self.id = AISchema.ModelID.make(id)
            self.provider = AISchema.ProviderID.make(provider)
            self.route = route
            self.transport = transport
            self.providerOptions = providerOptions
        }

        public var descriptor: AIRoute.MediaRoute.ModelDescriptor {
            AIRoute.MediaRoute.ModelDescriptor(
                id: id.rawValue,
                provider: provider,
                transport: transport,
                providerOptions: providerOptions
            )
        }
    }

    // parity: ai/src/experimental/extraction.ts#ExtractionModelOptions [status=adapted hash=55b4efa07e93]
    public typealias ExtractionModelOptions = ExtractionOptions

    // parity: ai/src/experimental/extraction.ts#ExtractionRequest [status=implemented hash=903feea4e460]
    public struct ExtractionRequest: AIRoute.MediaRoute.MediaRequest, Sendable {
        public let model: ExtractionModel
        public let input: String
        public let fields: ExtractionFields
        public let referenceDate: String?
        public let providerOptions: AISchema.ProviderOptions?
        public let headers: [String: String]?
        public let timeout: AISchema.RequestTimeout?
        public let http: AISchema.HttpOptions?
        public let fetch: (any HTTPTransport)?

        public var modelDescriptor: AIRoute.MediaRoute.ModelDescriptor { model.descriptor }

        public init(
            model: ExtractionModel,
            input: String,
            fields: ExtractionFields,
            referenceDate: String? = nil,
            providerOptions: AISchema.ProviderOptions? = nil,
            headers: [String: String]? = nil,
            timeout: AISchema.RequestTimeout? = nil,
            http: AISchema.HttpOptions? = nil,
            fetch: (any HTTPTransport)? = nil
        ) {
            self.model = model
            self.input = input
            self.fields = fields
            self.referenceDate = referenceDate
            self.providerOptions = providerOptions
            self.headers = headers
            self.timeout = timeout
            self.http = http
            self.fetch = fetch
        }
    }

    // parity: ai/src/experimental/extraction.ts#ExtractionRequestInput [status=implemented hash=3c48f0eeb4dc]
    public typealias ExtractionRequestInput = ExtractionRequest

    // parity: ai/src/experimental/extraction.ts#ExtractionResponse [status=implemented hash=edfc4b2f47d1]
    public struct ExtractionResponse: Equatable, Hashable, Sendable, Codable {
        public let answers: [String: [String: JSONValue]]
        public let usage: AISchema.Usage?
        public let providerMetadata: AISchema.ProviderMetadata?

        public init(
            answers: [String: [String: JSONValue]],
            usage: AISchema.Usage? = nil,
            providerMetadata: AISchema.ProviderMetadata? = nil
        ) {
            self.answers = answers
            self.usage = usage
            self.providerMetadata = providerMetadata
        }
    }

    // parity: ai/src/experimental/extraction.ts#ExtractionResponseFor [status=adapted hash=889e21a668c4]
    public typealias ExtractionResponseFor = ExtractionResponse

    // parity: ai/src/experimental/extraction.ts#request [status=implemented hash=bf28e4f41fea]
    public static func extractionRequest(_ input: ExtractionRequestInput) -> ExtractionRequest { input }

    // parity: ai/src/experimental/extraction.ts#generate [status=implemented hash=eedb16b42def]
    public static func extractionGenerate(
        _ input: ExtractionRequestInput,
        executor: AIRequestExecutor.RequestExecutorService
    ) async throws -> ExtractionResponse {
        let built = extractionRequest(input)
        guard !built.fields.isEmpty else {
            throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                message: "Extraction fields must not be empty"
            )))
        }
        return try await built.model.route.generate(built) { req, mw in
            try await executor.execute(req, middleware: mw)
        }
    }

    // parity: ai/src/experimental/extraction.ts#Extraction [status=implemented hash=849fd2324ac0]
    public enum Extraction {
        public static func request(_ input: ExtractionRequestInput) -> ExtractionRequest {
            AIExperimental.extractionRequest(input)
        }

        public static func generate(
            _ input: ExtractionRequestInput,
            executor: AIRequestExecutor.RequestExecutorService
        ) async throws -> ExtractionResponse {
            try await AIExperimental.extractionGenerate(input, executor: executor)
        }
    }

    // MARK: - src/experimental/cloudflare-run-extraction.ts

    // parity: ai/src/experimental/cloudflare-run-extraction.ts#CloudflareRunExtraction [status=implemented hash=3fe2788670f7]
    public enum CloudflareRunExtraction {
        private static let routeIdentity = AIRoute.MediaProtocol.identity(
            id: "cloudflare-run-extraction",
            name: "Cloudflare Run",
            provider: "cloudflare-workers-ai"
        )

        // parity: ai/src/experimental/cloudflare-run-extraction.ts#protocol [status=implemented hash=22cf7557a65a]
        public static let `protocol`: AIRoute.MediaProtocol.Inline<ExtractionRequest, ExtractionResponse> = AIRoute.MediaProtocol.inline(
            routeIdentity,
            bodyFrom: { (request: ExtractionRequest) in
                var body = AISchema.mergeJsonRecords(request.providerOptions, request.http?.body) ?? [:]
                body["model"] = .string(request.model.id.rawValue)
                body["state"] = .string(request.input)
                body["fields"] = .object(request.fields.mapValues { JSONValue.object($0.toWireObject()) })
                if let refDate = request.referenceDate {
                    body["reference_date"] = .string(refDate)
                }
                return AIRoute.MediaProtocol.json(body)
            },
            decodeResponse: { (response: AIRequestExecutor.ExecutorResponse, context: AIRoute.MediaProtocol.DecodeContext<ExtractionRequest>) -> ExtractionResponse in
                let output = try await routeIdentity.text(response)
                guard let parsed = try? AIUtils.decodeJson(output.body),
                      case .object(let root) = parsed,
                      case .object(let result) = root["result"],
                      case .string(let modelName) = result["model"],
                      case .object(let rawAnswers) = result["answers"]
                else {
                    throw output.invalid("\(routeIdentity.name) returned an invalid response")
                }

                var answers: [String: [String: JSONValue]] = [:]
                for (name, field) in context.request.fields {
                    guard let rawAns = rawAnswers[name] else {
                        throw output.invalid("\(routeIdentity.name) returned no answer for \(name)")
                    }
                    if ExtractionAnswers.knownFieldTypes.contains(field.type) {
                        do {
                            answers[name] = try ExtractionAnswers.decodeKnownAnswer(fieldType: field.type, raw: rawAns)
                        } catch {
                            throw output.invalid("\(routeIdentity.name) returned an invalid answer for \(name)", cause: String(describing: error))
                        }
                    } else if case .object(let obj) = rawAns {
                        answers[name] = obj
                    } else {
                        answers[name] = ["value": rawAns]
                    }
                }

                var usage: AISchema.Usage? = nil
                if case .object(let rawUsage) = result["usage"] {
                    let inTok: Double? = switch rawUsage["input_tokens"] {
                    case .double(let d): d
                    case .int(let i): Double(i)
                    default: nil
                    }
                    let outTok: Double? = switch rawUsage["output_tokens"] {
                    case .double(let d): d
                    case .int(let i): Double(i)
                    default: nil
                    }
                    let total: Double? = (inTok == nil && outTok == nil) ? nil : ((inTok ?? 0) + (outTok ?? 0))
                    usage = AISchema.Usage(
                        inputTokens: inTok,
                        outputTokens: outTok,
                        totalTokens: total,
                        providerMetadata: [routeIdentity.provider.rawValue: rawUsage]
                    )
                }

                var meta: [String: JSONValue] = ["model": .string(modelName)]
                if case .bool(let truncated) = result["truncated"] { meta["truncated"] = .bool(truncated) }
                if case .string(let stateText) = result["state_text"] { meta["stateText"] = .string(stateText) }

                return ExtractionResponse(
                    answers: answers,
                    usage: usage,
                    providerMetadata: [routeIdentity.provider.rawValue: meta]
                )
            }
        )

        // parity: ai/src/experimental/cloudflare-run-extraction.ts#model [status=implemented hash=785436246dd3]
        public static func model(_ input: AIRoute.MediaRoute.ModelInput) -> ExtractionModel {
            ExtractionModel(
                id: input.id,
                provider: routeIdentity.provider.rawValue,
                route: AIRoute.MediaRoute.inline(AIRoute.MediaRoute.InlineInput(
                    protocol: `protocol`,
                    endpoint: AIEndpoint.path(
                        .dynamic { epInput in "/\(epInput.request.model.id.rawValue)" },
                        baseURL: input.baseURL
                    ),
                    auth: input.auth
                )),
                transport: input.transport,
                providerOptions: input.providerOptions
            )
        }
    }

    // MARK: - src/experimental/realtime.ts

    // parity: ai/src/experimental/realtime.ts#RealtimeTransportType [status=implemented hash=c64a7568f0a5]
    public enum RealtimeTransportType: String, Equatable, Hashable, Sendable, Codable {
        case webrtc
        case websocket
    }

    // parity: ai/src/experimental/realtime.ts#RealtimeTransportInput [status=implemented hash=7883b46572f7]
    public enum RealtimeTransportInput: Equatable, Hashable, Sendable {
        case webrtc(sdp: String, dcid: Int? = nil)
        case websocket

        public var type: RealtimeTransportType {
            switch self {
            case .webrtc: .webrtc
            case .websocket: .websocket
            }
        }
    }

    // parity: ai/src/experimental/realtime.ts#RealtimeTransport [status=implemented hash=0adc916d0095]
    public enum RealtimeTransport: Equatable, Hashable, Sendable, Codable {
        case webrtc(sdp: String)
        case websocket(url: String, token: String, expiresAt: Double)
    }

    // parity: ai/src/experimental/realtime.ts#RealtimeSession [status=implemented hash=c3a14f5909c5]
    public typealias RealtimeSession = [String: JSONValue]

    // parity: ai/src/experimental/realtime.ts#RealtimeConnectInput [status=implemented hash=2c59b135cc85]
    public struct RealtimeConnectInput: Sendable {
        public let model: String
        public let apiKey: AIAuth.RedactedSecret
        public let baseURL: String?
        public let headers: [String: String]?
        public let timeout: AISchema.RequestTimeout?
        public let session: RealtimeSession?
        public let transport: RealtimeTransportInput

        public init(
            model: String,
            apiKey: AIAuth.RedactedSecret,
            baseURL: String? = nil,
            headers: [String: String]? = nil,
            timeout: AISchema.RequestTimeout? = nil,
            session: RealtimeSession? = nil,
            transport: RealtimeTransportInput
        ) {
            self.model = model
            self.apiKey = apiKey
            self.baseURL = baseURL
            self.headers = headers
            self.timeout = timeout
            self.session = session
            self.transport = transport
        }
    }

    public struct RealtimeEngineSpec: Equatable, Hashable, Sendable {
        public let family: String
        public let model: String
        public let id: String
        public let provider: String
        public let transports: [RealtimeTransportType]
    }

    // parity: ai/src/experimental/realtime.ts#engines [status=implemented hash=4812be659414]
    public static let engines: [RealtimeEngineSpec] = [
        RealtimeEngineSpec(family: "gpt-live", model: "gpt-live-1", id: "openai-live", provider: "openai", transports: [.webrtc]),
        RealtimeEngineSpec(family: "gpt-realtime", model: "gpt-realtime-2.1", id: "openai-realtime", provider: "openai", transports: [.webrtc, .websocket]),
        RealtimeEngineSpec(family: "grok-voice", model: "grok-voice-3.0", id: "xai-realtime", provider: "xai", transports: [.websocket]),
        RealtimeEngineSpec(family: "gemini-3.8-live", model: "gemini-3.8-live", id: "gemini-live", provider: "google", transports: [.websocket]),
    ]

    // parity: ai/src/experimental/realtime.ts#engine [status=implemented hash=bfd81fbf9bbb]
    public static func engine(_ model: String) -> RealtimeEngineSpec? {
        engines.first { model == $0.family || model.hasPrefix("\($0.family)-") }
    }

    private static let openaiRealtimeBase = "https://api.openai.com/v1"
    private static let xaiRealtimeBase = "https://api.x.ai/v1"
    private static let googleRealtimeBase = "https://generativelanguage.googleapis.com/v1beta"

    // parity: ai/src/experimental/realtime.ts#connect [status=implemented hash=ba5d05bc9768]
    public static func connect(
        _ input: RealtimeConnectInput,
        executor: AIRequestExecutor.RequestExecutorService,
        nowEpochMs: Double? = nil
    ) async throws -> RealtimeTransport {
        guard let resolved = engine(input.model) else {
            throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                message: "Unsupported voice model: \(input.model)"
            )))
        }
        guard resolved.transports.contains(input.transport.type) else {
            let allowed = resolved.transports.map(\.rawValue).joined(separator: ", ")
            throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                message: "\(input.model) only supports \(allowed) transport"
            )))
        }

        func postText(
            url: String,
            bodyBytes: [UInt8],
            contentType: String,
            authHeader: String? = nil,
            extraHeaders: [String: String]? = nil
        ) async throws -> (text: String, http: AISchema.HttpContext) {
            var headers: [String: String] = [:]
            if let extraHeaders {
                for (k, v) in extraHeaders { headers[k.lowercased()] = v }
            }
            if let authHeader {
                headers[authHeader.lowercased()] = input.apiKey.value
            } else {
                headers["authorization"] = "Bearer \(input.apiKey.value)"
            }
            headers["content-type"] = contentType
            let req = HTTPRequest(method: "POST", url: url, headers: headers, body: bodyBytes)
            let exec = AIRequestExecutor.withTimeout({ r, mw in try await executor.execute(r, middleware: mw) }, timeout: input.timeout)
            let resp = try await exec(req, nil as AIRequestExecutor.HttpMiddleware?)
            let http = AIRequestExecutor.responseHttp(resp)
            let text = try await AIRequestExecutor.responseText(resp)
            return (text, http)
        }

        func postJson(
            url: String,
            body: [String: JSONValue],
            authHeader: String? = nil,
            extraHeaders: [String: String]? = nil
        ) async throws -> (json: JSONValue, raw: String, http: AISchema.HttpContext) {
            let encoded: String
            do { encoded = try AIUtils.encodeJson(.object(body)) } catch {
                throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(message: "\(error)")))
            }
            let (raw, http) = try await postText(
                url: url,
                bodyBytes: Array(encoded.utf8),
                contentType: "application/json",
                authHeader: authHeader,
                extraHeaders: extraHeaders
            )
            guard let json = try? AIUtils.decodeJson(raw) else {
                throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                    message: "\(resolved.id) returned an invalid response",
                    body: raw,
                    http: http,
                    route: resolved.id
                )))
            }
            return (json, raw, http)
        }

        func requestClientSecret(baseURL: String, body: [String: JSONValue]) async throws -> RealtimeTransport {
            let (json, raw, http) = try await postJson(url: "\(baseURL)/realtime/client_secrets", body: body)
            guard case .object(let obj) = json,
                  case .string(let token) = obj["value"]
            else {
                throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                    message: "\(resolved.id) returned an invalid response",
                    body: raw,
                    http: http,
                    route: resolved.id
                )))
            }
            let expiresAt: Double
            switch obj["expires_at"] {
            case .double(let d): expiresAt = d
            case .int(let i): expiresAt = Double(i)
            default:
                throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                    message: "\(resolved.id) returned an invalid response",
                    body: raw,
                    http: http,
                    route: resolved.id
                )))
            }
            let wsBase = baseURL.hasPrefix("http") ? "ws" + baseURL.dropFirst(4) : baseURL
            let encodedModel = input.model.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input.model
            return .websocket(url: "\(wsBase)/realtime?model=\(encodedModel)", token: token, expiresAt: expiresAt)
        }

        var session = input.session ?? [:]
        session["model"] = .string(input.model)

        switch resolved.id {
        case "openai-live":
            guard case .webrtc(let sdp, let dcid) = input.transport else {
                throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(message: "Expected webrtc transport")))
            }
            var transportObj: [String: JSONValue] = ["type": .string("webrtc"), "sdp": .string(sdp)]
            if let dcid { transportObj["dcid"] = .int(Int64(dcid)) }
            let base = input.baseURL ?? openaiRealtimeBase
            let (json, raw, http) = try await postJson(
                url: "\(base)/live/sessions",
                body: ["session": .object(session), "transport": .object(transportObj)],
                extraHeaders: input.headers
            )
            guard case .object(let obj) = json,
                  case .object(let tObj) = obj["transport"],
                  case .string(let answerSdp) = tObj["sdp"]
            else {
                throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                    message: "\(resolved.id) returned an invalid response",
                    body: raw,
                    http: http,
                    route: resolved.id
                )))
            }
            return .webrtc(sdp: answerSdp)

        case "openai-realtime":
            switch input.transport {
            case .websocket:
                return try await requestClientSecret(
                    baseURL: openaiRealtimeBase,
                    body: [
                        "expires_after": .object(["anchor": .string("created_at"), "seconds": .int(60)]),
                        "session": .object(session),
                    ]
                )
            case .webrtc(let sdp, let dcid):
                var form = AIRoute.MultipartFormData()
                form.append("sdp", value: sdp)
                let sessionJson = (try? AIUtils.encodeJson(.object(session))) ?? "{}"
                form.append("session", value: sessionJson)
                let encoded = form.encode()
                let query = dcid.map { "?dcid=\($0)" } ?? ""
                let (answerSdp, _) = try await postText(
                    url: "\(openaiRealtimeBase)/realtime/calls\(query)",
                    bodyBytes: encoded.body,
                    contentType: encoded.contentType
                )
                return .webrtc(sdp: answerSdp)
            }

        case "xai-realtime":
            return try await requestClientSecret(
                baseURL: xaiRealtimeBase,
                body: ["expires_after": .object(["seconds": .int(60)])]
            )

        case "gemini-live":
            let now = nowEpochMs ?? (Date().timeIntervalSince1970 * 1000.0)
            let expiresAt = now + 60_000
            var setup = input.session ?? [:]
            setup["model"] = .string("models/\(input.model)")
            let isoExpire = iso8601Timestamp(epochMs: now + 30 * 60_000)
            let isoNewSession = iso8601Timestamp(epochMs: expiresAt)
            let (json, raw, http) = try await postJson(
                url: "\(googleRealtimeBase)/auth_tokens",
                body: [
                    "uses": .int(1),
                    "expireTime": .string(isoExpire),
                    "newSessionExpireTime": .string(isoNewSession),
                    "bidiGenerateContentSetup": .object(setup),
                ],
                authHeader: "x-goog-api-key"
            )
            guard case .object(let obj) = json, case .string(let name) = obj["name"] else {
                throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                    message: "\(resolved.id) returned an invalid response",
                    body: raw,
                    http: http,
                    route: resolved.id
                )))
            }
            return .websocket(
                url: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained",
                token: name,
                expiresAt: floor(expiresAt / 1000.0)
            )

        default:
            throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                message: "Unsupported voice model: \(input.model)"
            )))
        }
    }

    private static func iso8601Timestamp(epochMs: Double) -> String {
        let totalMillis = Int64(epochMs.rounded())
        let totalSecs = totalMillis >= 0 ? totalMillis / 1000 : (totalMillis - 999) / 1000
        let ms = Int(totalMillis - totalSecs * 1000)
        let days = totalSecs >= 0 ? totalSecs / 86_400 : (totalSecs - 86_399) / 86_400
        let secOfDay = Int(totalSecs - days * 86_400)
        let hour = secOfDay / 3600
        let minute = (secOfDay % 3600) / 60
        let second = secOfDay % 60
        // Howard Hinnant civil_from_days
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        let year = y + (m <= 2 ? 1 : 0)
        func pad(_ v: Int, width: Int) -> String {
            let s = String(v)
            return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
        }
        return "\(pad(Int(year), width: 4))-\(pad(Int(m), width: 2))-\(pad(Int(d), width: 2))T\(pad(hour, width: 2)):\(pad(minute, width: 2)):\(pad(second, width: 2)).\(pad(ms, width: 3))Z"
    }

    // parity: ai/src/experimental/realtime.ts#Realtime [status=implemented hash=5fa49a35758f]
    public enum Realtime {
        public static var engines: [RealtimeEngineSpec] { AIExperimental.engines }
        public static func engine(_ model: String) -> RealtimeEngineSpec? { AIExperimental.engine(model) }
        public static func connect(
            _ input: RealtimeConnectInput,
            executor: AIRequestExecutor.RequestExecutorService,
            nowEpochMs: Double? = nil
        ) async throws -> RealtimeTransport {
            try await AIExperimental.connect(input, executor: executor, nowEpochMs: nowEpochMs)
        }
    }
}

/// Composed multi-modality AI client runtime and top-level `ai` entrypoint.
/// Ports `packages/ai/src/{ai-client,effect,index}.ts`.
public enum AIClient {
    // parity: ai/src/ai-client.ts#Services [status=implemented hash=11fea534eac2]
    public struct Services: Sendable {
        public let executor: AIRequestExecutor.RequestExecutorService
        public let llm: AIRoute.LLMClientService
        public let image: AIImage.ImageClient.Service
        public let video: AIVideo.VideoClient.Service
        public let speech: AISpeech.SpeechClient.Service
        public let transcription: AITranscription.TranscriptionClient.Service
        public let decision: AIDecision.DecisionClient.Service
        public let embedding: AIEmbedding.EmbeddingClient.Service

        public init(
            executor: AIRequestExecutor.RequestExecutorService,
            llm: AIRoute.LLMClientService,
            image: AIImage.ImageClient.Service,
            video: AIVideo.VideoClient.Service,
            speech: AISpeech.SpeechClient.Service,
            transcription: AITranscription.TranscriptionClient.Service,
            decision: AIDecision.DecisionClient.Service,
            embedding: AIEmbedding.EmbeddingClient.Service
        ) {
            self.executor = executor
            self.llm = llm
            self.image = image
            self.video = video
            self.speech = speech
            self.transcription = transcription
            self.decision = decision
            self.embedding = embedding
        }
    }

    // parity: ai/src/ai-client.ts#layerWith [status=implemented hash=9390cff1165c]
    public static func layerWith(_ executor: AIRequestExecutor.RequestExecutorService) -> Services {
        Services(
            executor: executor,
            llm: AIRoute.layer(executor: executor),
            image: AIImage.ImageClient.layer(executor: executor),
            video: AIVideo.VideoClient.layer(executor: executor),
            speech: AISpeech.SpeechClient.layer(executor: executor),
            transcription: AITranscription.TranscriptionClient.layer(executor: executor),
            decision: AIDecision.DecisionClient.layer(executor: executor),
            embedding: AIEmbedding.EmbeddingClient.layer(executor: executor)
        )
    }

    // parity: ai/src/ai-client.ts#layer [status=adapted hash=50b517bebf4f]
    public static func layer(transport: any HTTPTransport) -> Services {
        layerWith(AIRequestExecutor.fetchLayer(transport: transport))
    }

    // MARK: - src/index.ts & src/effect.ts

    // parity: ai/src/index.ts#Options [status=implemented hash=dc723ae9c06c]
    public struct Options: Sendable {
        public let executor: AIRequestExecutor.RequestExecutorService
        public let fileSystem: any OpenCodeFileSystem

        public init(
            executor: AIRequestExecutor.RequestExecutorService,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
        ) {
            self.executor = executor
            self.fileSystem = fileSystem
        }

        public init(
            transport: any HTTPTransport,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
        ) {
            self.executor = AIRequestExecutor.layer(transport: transport)
            self.fileSystem = fileSystem
        }
    }

    // parity: ai/src/index.ts#RunOptions [status=implemented hash=79cc343e3a7c]
    public struct RunOptions: Sendable {
        public let signal: AbortSignal?
        public let http: AIRequestExecutor.HttpMiddleware?

        public init(signal: AbortSignal? = nil, http: AIRequestExecutor.HttpMiddleware? = nil) {
            self.signal = signal
            self.http = http
        }
    }

    // parity: ai/src/index.ts#AssetRunOptions [status=implemented hash=946291a0bc70]
    public struct AssetRunOptions: Sendable {
        public let signal: AbortSignal?

        public init(signal: AbortSignal? = nil) {
            self.signal = signal
        }
    }

    // parity: ai/src/index.ts#Services [status=implemented hash=813d0d3ffa3d]
    public typealias ClientServices = Services

    // parity: ai/src/index.ts#GenerationHandle [status=implemented hash=52a38201bf90]
    public struct GenerationHandle<Response: Sendable>: Sendable {
        public let snapshot: AIGeneration.Snapshot
        public let terminal: Bool
        public let token: JSONValue
        private let generation: AIGeneration.Generation<Response>
        private let baseMiddleware: AIRequestExecutor.HttpMiddleware?

        public var id: String { snapshot.id }
        public var status: AIGeneration.Status { snapshot.status }
        public var reason: AIGeneration.Reason? { snapshot.reason }
        public var progress: Double? { snapshot.progress }

        public init(generation: AIGeneration.Generation<Response>, http: AIRequestExecutor.HttpMiddleware? = nil) {
            self.snapshot = generation.snapshot
            self.terminal = generation.terminal
            self.token = generation.token
            self.generation = generation
            self.baseMiddleware = http
        }

        public func `await`(
            options: AIGeneration.AwaitOptions? = nil,
            run: RunOptions? = nil
        ) async throws -> Response {
            let mw = run?.http ?? baseMiddleware
            return try await AIClient.runScoped(middleware: mw, signal: run?.signal) {
                try await generation.await(options)
            }
        }

        public func events(
            options: AIGeneration.AwaitOptions? = nil,
            run: RunOptions? = nil
        ) -> AsyncThrowingStream<AIGeneration.Event, Error> {
            let mw = run?.http ?? baseMiddleware
            return AIClient.streamScoped(middleware: mw, signal: run?.signal) {
                generation.events(options)
            }
        }

        public func result(run: RunOptions? = nil) async throws -> Response {
            let mw = run?.http ?? baseMiddleware
            return try await AIClient.runScoped(middleware: mw, signal: run?.signal) {
                try await generation.result()
            }
        }

        public func refresh(run: RunOptions? = nil) async throws -> GenerationHandle<Response> {
            let mw = run?.http ?? baseMiddleware
            let next = try await AIClient.runScoped(middleware: mw, signal: run?.signal) {
                try await generation.refresh()
            }
            return GenerationHandle(generation: next, http: mw)
        }

        public func cancel(run: RunOptions? = nil) async throws {
            let mw = run?.http ?? baseMiddleware
            try await AIClient.runScoped(middleware: mw, signal: run?.signal) {
                try await generation.cancel()
            }
        }
    }

    internal static func runScoped<T: Sendable>(
        middleware: AIRequestExecutor.HttpMiddleware?,
        signal: AbortSignal?,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        if let signal, signal.isAborted {
            throw signal.reason ?? AbortError.sharedReason
        }
        if let middleware {
            return try await AIRequestExecutor.withMiddleware(middleware, operation: operation)
        }
        return try await operation()
    }

    internal static func streamScoped<T: Sendable>(
        middleware: AIRequestExecutor.HttpMiddleware?,
        signal: AbortSignal?,
        build: @escaping @Sendable () -> AsyncThrowingStream<T, Error>
    ) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let signal, signal.isAborted {
                        throw signal.reason ?? AbortError.sharedReason
                    }
                    let runStream: @Sendable () async throws -> Void = {
                        for try await item in build() {
                            if let signal, signal.isAborted {
                                throw signal.reason ?? AbortError.sharedReason
                            }
                            continuation.yield(item)
                        }
                    }
                    if let middleware {
                        try await AIRequestExecutor.withMiddleware(middleware, operation: runStream)
                    } else {
                        try await runStream()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let removeListener = signal?.onAbort {
                task.cancel()
            }
            continuation.onTermination = { _ in
                removeListener?()
                task.cancel()
            }
        }
    }

    // parity: ai/src/index.ts#Client [status=implemented hash=86e5c75c47ff]
    public struct Client: Sendable {
        public let services: Services
        public let fileSystem: any OpenCodeFileSystem

        public init(services: Services, fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared) {
            self.services = services
            self.fileSystem = fileSystem
        }

        public func bytes(_ asset: AIMedia.Asset, options: AssetRunOptions? = nil) async throws -> [UInt8] {
            try await AIClient.runScoped(middleware: nil, signal: options?.signal) {
                try await asset.bytes(executor: services.executor)
            }
        }

        public func base64(_ asset: AIMedia.Asset, options: AssetRunOptions? = nil) async throws -> String {
            try await AIClient.runScoped(middleware: nil, signal: options?.signal) {
                try await asset.base64(executor: services.executor)
            }
        }

        public func materialize(_ asset: AIMedia.Asset, options: AssetRunOptions? = nil) async throws -> AIMedia.Asset {
            try await AIClient.runScoped(middleware: nil, signal: options?.signal) {
                try await asset.materialize(executor: services.executor)
            }
        }

        public func file(_ path: String, options: AIMedia.AssetOptions? = nil, run: AssetRunOptions? = nil) async throws -> AIMedia.Asset {
            try await AIClient.runScoped(middleware: nil, signal: run?.signal) {
                try await AIMedia.file(path, options: options, fileSystem: fileSystem)
            }
        }

        public func write(_ asset: AIMedia.Asset, to path: String, options: AssetRunOptions? = nil) async throws {
            try await AIClient.runScoped(middleware: nil, signal: options?.signal) {
                try await AIMedia.write(asset, to: path, executor: services.executor, fileSystem: fileSystem)
            }
        }

        public func request(_ input: AILLM.LLMRequestInput) throws(AISchema.AIError) -> AISchema.LLMRequest {
            try AILLM.request(input)
        }

        public func generate(
            _ input: AILLM.LLMRequestInput,
            options: AIRoute.StreamOptions? = nil,
            run: RunOptions? = nil
        ) async throws -> AISchema.LLMResponse {
            let streamOpts = options.map { AIRoute.StreamOptions(http: nil, webSocket: $0.webSocket) }
            return try await AIClient.runScoped(middleware: run?.http, signal: run?.signal) {
                try await AILLM.generate(input, options: streamOpts, client: services.llm)
            }
        }

        public func stream(
            _ input: AILLM.LLMRequestInput,
            options: AIRoute.StreamOptions? = nil,
            run: RunOptions? = nil
        ) -> AsyncThrowingStream<AISchema.LLMEvent, Error> {
            let streamOpts = options.map { AIRoute.StreamOptions(http: nil, webSocket: $0.webSocket) }
            return AIClient.streamScoped(middleware: run?.http, signal: run?.signal) {
                AILLM.stream(input, options: streamOpts, client: services.llm)
            }
        }

        public func loop(
            _ input: AILLM.LLMLoopInput,
            options: AIRoute.StreamOptions? = nil,
            run: RunOptions? = nil
        ) -> AsyncThrowingStream<AISchema.LLMEvent, Error> {
            let streamOpts = options.map { AIRoute.StreamOptions(http: nil, webSocket: $0.webSocket) }
            return AIClient.streamScoped(middleware: run?.http, signal: run?.signal) {
                AILLM.loop(input, options: streamOpts, client: services.llm)
            }
        }

        public func collect(
            _ events: AsyncThrowingStream<AISchema.LLMEvent, Error>,
            run: RunOptions? = nil
        ) async throws -> AILoop.Collected {
            try await AIClient.runScoped(middleware: run?.http, signal: run?.signal) {
                try await AILoop.collect(events)
            }
        }

        public func compact(
            _ input: AILLM.LLMRequestInput,
            options: AIRoute.CompactOptions = .endpoint(nil),
            run: RunOptions? = nil
        ) async throws -> AIRoute.CompactionResult {
            try await AIClient.runScoped(middleware: run?.http, signal: run?.signal) {
                try await AILLM.compact(input, options: options, client: services.llm)
            }
        }

        public func canCompact(_ model: AISchema.LanguageModel, mechanism: String? = nil) -> Bool {
            AIRoute.canCompact(model, mechanism: mechanism)
        }

        public func generateDecision(_ input: AIDecision.DecisionRequestInput, run: RunOptions? = nil) async throws -> AIDecision.DecisionResponse {
            try await AIClient.runScoped(middleware: run?.http, signal: run?.signal) {
                try await AIDecision.generate(input, client: services.decision)
            }
        }

        public func generateEmbedding(_ input: AIEmbedding.EmbeddingRequestInput, run: RunOptions? = nil) async throws -> AIEmbedding.EmbeddingResponse {
            try await AIClient.runScoped(middleware: run?.http, signal: run?.signal) {
                try await AIEmbedding.generate(input, client: services.embedding)
            }
        }

        public func generateImage(
            _ input: AIImage.ImageRequestInput,
            options: AIGeneration.AwaitOptions? = nil,
            run: RunOptions? = nil
        ) async throws -> AIImage.ImageResponse {
            try await AIClient.runScoped(middleware: run?.http, signal: run?.signal) {
                try await AIImage.generate(input, options: options, client: services.image)
            }
        }

        public func generateSpeech(_ input: AISpeech.SpeechRequestInput, run: RunOptions? = nil) async throws -> AISpeech.SpeechResponse {
            try await AIClient.runScoped(middleware: run?.http, signal: run?.signal) {
                try await AISpeech.generate(input, client: services.speech)
            }
        }

        public func generateTranscription(
            _ input: AITranscription.TranscriptionRequestInput,
            options: AIGeneration.AwaitOptions? = nil,
            run: RunOptions? = nil
        ) async throws -> AITranscription.TranscriptionResponse {
            try await AIClient.runScoped(middleware: run?.http, signal: run?.signal) {
                try await AITranscription.generate(input, options: options, client: services.transcription)
            }
        }

        public func startVideo(_ input: AIVideo.VideoRequestInput, run: RunOptions? = nil) async throws -> AIVideo.VideoJob {
            try await AIClient.runScoped(middleware: run?.http, signal: run?.signal) {
                try await AIVideo.start(input, client: services.video)
            }
        }
    }

    // parity: ai/src/index.ts#make [status=implemented hash=758af99bc4cc]
    public static func make(_ options: Options) -> Client {
        Client(services: layerWith(options.executor), fileSystem: options.fileSystem)
    }

    /// Construct a tool whose `execute` throws arbitrary errors mapped to `ToolFailure`.
    // parity: ai/src/index.ts#tool [status=implemented hash=bc00c1d82a29]
    public static func tool(_ config: AITool.ToolOptions) throws(AISchema.AIError) -> AITool.Tool {
        let wrappedExecute: AITool.ToolExecute?
        if let exec = config.execute {
            wrappedExecute = { input, ctx in
                do {
                    return try await exec(input, ctx)
                } catch let failure as AISchema.ToolFailure {
                    throw failure
                } catch {
                    throw AISchema.ToolFailure(message: String(describing: error))
                }
            }
        } else {
            wrappedExecute = nil
        }
        return try AITool.build(config, execute: wrappedExecute)
    }

    /// Effect-style facade namespace mirroring `packages/ai/src/effect.ts#ai`.
    // parity: ai/src/effect.ts#ai [status=adapted hash=081794c9e2fc]
    public enum effectAPI {
        public static func request(_ input: AILLM.LLMRequestInput) throws(AISchema.AIError) -> AISchema.LLMRequest {
            try AILLM.request(input)
        }
        public static func generate(_ input: AILLM.LLMRequestInput, options: AIRoute.StreamOptions? = nil, client: any AIRoute.Interface) async throws -> AISchema.LLMResponse {
            try await AILLM.generate(input, options: options, client: client)
        }
        public static func stream(_ input: AILLM.LLMRequestInput, options: AIRoute.StreamOptions? = nil, client: any AIRoute.Interface) -> AsyncThrowingStream<AISchema.LLMEvent, Error> {
            AILLM.stream(input, options: options, client: client)
        }
        public static func loop(_ input: AILLM.LLMLoopInput, options: AIRoute.StreamOptions? = nil, client: any AIRoute.Interface) -> AsyncThrowingStream<AISchema.LLMEvent, Error> {
            AILLM.loop(input, options: options, client: client)
        }
        public static func collect(_ events: AsyncThrowingStream<AISchema.LLMEvent, Error>) async throws -> AILoop.Collected {
            try await AILoop.collect(events)
        }
        public static func compact(_ input: AILLM.LLMRequestInput, options: AIRoute.CompactOptions = .endpoint(nil), client: any AIRoute.Interface) async throws -> AIRoute.CompactionResult {
            try await AILLM.compact(input, options: options, client: client)
        }
        public static func canCompact(_ model: AISchema.LanguageModel, mechanism: String? = nil) -> Bool {
            AIRoute.canCompact(model, mechanism: mechanism)
        }
    }

    /// Default facade entrypoint mirroring `packages/ai/src/index.ts#ai`.
    // parity: ai/src/index.ts#ai [status=adapted hash=0d71f5ad7f48]
    public enum ai {
        public static func client(transport: any HTTPTransport, fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared) -> Client {
            make(Options(transport: transport, fileSystem: fileSystem))
        }
    }
}

/// Programmable mock `LLMClient` for deterministic unit and integration testing of streams,
/// tool loops, compaction, errors, request recording, and concurrency gates.
///
/// Ports `packages/ai/src/testing.ts`.
public enum AITesting {
    // parity: ai/src/testing.ts#Response [status=implemented hash=6a34c199e8ef]
    public enum Response: Sendable {
        case events([AISchema.LLMEvent])
        case stream(AsyncThrowingStream<AISchema.LLMEvent, Error>)
        case compaction(AISchema.CompactionResponse)
        case checkpoint(AISchema.CompactionCheckpointResponse)
    }

    // parity: ai/src/testing.ts#Gate [status=implemented hash=99d8a2caadde]
    public struct Gate: Sendable {
        public let started: @Sendable () async -> Void
        public let release: @Sendable () async -> Void

        public init(started: @escaping @Sendable () async -> Void, release: @escaping @Sendable () async -> Void) {
            self.started = started
            self.release = release
        }
    }

    // parity: ai/src/testing.ts#Responder [status=implemented hash=ff8c3ccc8e85]
    public typealias Responder = @Sendable (AISchema.LLMRequest) -> Response

    // parity: ai/src/testing.ts#LayerOptions [status=implemented hash=9b1724e6af83]
    public struct LayerOptions: Sendable {
        public let transformRequest: (@Sendable (AISchema.LLMRequest) -> AISchema.LLMRequest)?
        public let fallback: Response?

        public init(
            transformRequest: (@Sendable (AISchema.LLMRequest) -> AISchema.LLMRequest)? = nil,
            fallback: Response? = nil
        ) {
            self.transformRequest = transformRequest
            self.fallback = fallback
        }
    }

    // parity: ai/src/testing.ts#TestInterface [status=implemented hash=d2f69898fbe9]
    public protocol TestInterface: AIRoute.Interface {
        func requests() async -> [AISchema.LLMRequest]
        func push(_ responses: Response...) async
        func push(_ responses: [Response]) async
        func always(_ response: Response) async
        func serve(_ responder: @escaping Responder) async
        func wait(count: Int) async
        func gate() async -> Gate
    }

    // parity: ai/src/testing.ts#complete [status=implemented hash=aa13e36d0c79]
    public static func complete(
        reason: AISchema.FinishReasonDetails,
        usage: AISchema.UsageInput? = nil,
        providerMetadata: AISchema.ProviderMetadata? = nil,
        events: [AISchema.LLMEvent] = []
    ) -> [AISchema.LLMEvent] {
        var out: [AISchema.LLMEvent] = [.stepStart(AISchema.StepStart(index: 0))]
        out.append(contentsOf: events)
        out.append(.stepFinish(AISchema.StepFinish(
            index: 0,
            reason: reason,
            usage: usage,
            providerMetadata: providerMetadata
        )))
        out.append(.finish(AISchema.Finish(
            reason: reason,
            providerMetadata: providerMetadata
        )))
        return out
    }

    // parity: ai/src/testing.ts#stop [status=implemented hash=af5fb6bf8bda]
    public static func stop(_ events: AISchema.LLMEvent...) -> [AISchema.LLMEvent] {
        complete(reason: AISchema.FinishReasonDetails(normalized: .stop), events: events)
    }

    // parity: ai/src/testing.ts#toolCalls [status=implemented hash=f4584a73ee19]
    public static func toolCalls(_ events: AISchema.LLMEvent...) -> [AISchema.LLMEvent] {
        complete(reason: AISchema.FinishReasonDetails(normalized: .toolCalls), events: events)
    }

    private static func textEvents(_ value: String, id: String) -> [AISchema.LLMEvent] {
        [
            .textStart(AISchema.TextStart(id: id)),
            .textDelta(AISchema.TextDelta(id: id, text: value)),
            .textEnd(AISchema.TextEnd(id: id)),
        ]
    }

    // parity: ai/src/testing.ts#text [status=implemented hash=51edae81e33b]
    public static func text(_ value: String, id: String = "text-0") -> [AISchema.LLMEvent] {
        complete(reason: AISchema.FinishReasonDetails(normalized: .stop), events: textEvents(value, id: id))
    }

    // parity: ai/src/testing.ts#textWithUsage [status=implemented hash=7af3fbcd52eb]
    public static func textWithUsage(_ value: String, id: String = "text-0", inputTokens: Double) -> [AISchema.LLMEvent] {
        complete(
            reason: AISchema.FinishReasonDetails(normalized: .stop),
            usage: AISchema.Usage(inputTokens: inputTokens, nonCachedInputTokens: inputTokens),
            events: textEvents(value, id: id)
        )
    }

    // parity: ai/src/testing.ts#toolCall [status=implemented hash=e6139a2b5fe4]
    public static func toolCall(id: String, name: String, input: JSONValue) -> [AISchema.LLMEvent] {
        toolCalls(.toolCall(AISchema.ToolCall(id: id, name: name, input: input)))
    }

    // parity: ai/src/testing.ts#failAfter [status=implemented hash=15d9a4fca0ce]
    public static func failAfter(_ error: AISchema.AIError, events: [AISchema.LLMEvent] = []) -> AsyncThrowingStream<AISchema.LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            for ev in events { continuation.yield(ev) }
            continuation.finish(throwing: error)
        }
    }

    // parity: ai/src/testing.ts#hangAfter [status=implemented hash=17cc4233c284]
    public static func hangAfter(_ events: [AISchema.LLMEvent] = []) -> AsyncThrowingStream<AISchema.LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            for ev in events { continuation.yield(ev) }
            let task = Task {
                try? await Task.sleep(for: .seconds(3600))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private actor ActiveGate {
        var startedCount = 0
        var startedWaiters: [CheckedContinuation<Void, Never>] = []
        var released = false
        var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markStarted() {
            if !startedWaiters.isEmpty {
                let w = startedWaiters.removeFirst()
                w.resume()
            } else {
                startedCount += 1
            }
        }

        func awaitStarted() async {
            if startedCount > 0 {
                startedCount -= 1
                return
            }
            await withCheckedContinuation { cont in
                startedWaiters.append(cont)
            }
        }

        func awaitRelease() async {
            if released { return }
            await withCheckedContinuation { cont in
                releaseWaiters.append(cont)
            }
        }

        func open() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for w in waiters { w.resume() }
        }
    }

    // parity: ai/src/testing.ts#Test [status=implemented hash=a78737e3ac90]
    public actor Test: TestInterface {
        public static let serviceID = "@opencode/ai/TestLLM/Test"

        private let transformRequest: (@Sendable (AISchema.LLMRequest) -> AISchema.LLMRequest)?
        private var recordedRequests: [AISchema.LLMRequest] = []
        private var queue: [Response] = []
        private var fallbackResponder: Responder?
        private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var activeGate: ActiveGate?

        public init(options: LayerOptions = LayerOptions()) {
            self.transformRequest = options.transformRequest
            if let fb = options.fallback {
                self.fallbackResponder = { _ in fb }
            }
        }

        public func requests() async -> [AISchema.LLMRequest] {
            recordedRequests
        }

        public func push(_ responses: Response...) async {
            queue.append(contentsOf: responses)
        }

        public func push(_ responses: [Response]) async {
            queue.append(contentsOf: responses)
        }

        public func always(_ response: Response) async {
            fallbackResponder = { _ in response }
        }

        public func serve(_ responder: @escaping Responder) async {
            fallbackResponder = responder
        }

        public func wait(count: Int) async {
            if recordedRequests.count >= count { return }
            await withCheckedContinuation { cont in
                waiters.append((count, cont))
            }
        }

        public func gate() async -> Gate {
            let g = ActiveGate()
            activeGate = g
            return Gate(
                started: { await g.awaitStarted() },
                release: { [weak self] in
                    await self?.clearGate(g)
                    await g.open()
                }
            )
        }

        private func clearGate(_ gate: ActiveGate) {
            if activeGate === gate { activeGate = nil }
        }

        private func take(_ request: AISchema.LLMRequest) async throws -> Response {
            let stored = transformRequest?(request) ?? request
            recordedRequests.append(stored)
            let currentCount = recordedRequests.count
            let ready = waiters.filter { currentCount >= $0.count }
            waiters.removeAll { currentCount >= $0.count }
            for w in ready { w.continuation.resume() }

            let nextResponse: Response?
            if !queue.isEmpty {
                nextResponse = queue.removeFirst()
            } else {
                nextResponse = fallbackResponder?(request)
            }
            guard let response = nextResponse else {
                throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                    message: "TestLLM has no response for request \(currentCount)"
                )))
            }
            if let gate = activeGate {
                await gate.markStarted()
                await gate.awaitRelease()
            }
            return response
        }

        nonisolated public func stream(
            _ request: AISchema.LLMRequest,
            options: AIRoute.StreamOptions? = nil
        ) -> AsyncThrowingStream<AISchema.LLMEvent, Error> {
            _ = options
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let response = try await self.take(request)
                        switch response {
                        case .events(let list):
                            for ev in list { continuation.yield(ev) }
                            continuation.finish()
                        case .stream(let s):
                            for try await ev in s { continuation.yield(ev) }
                            continuation.finish()
                        case .compaction, .checkpoint:
                            throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                                message: "TestLLM generation requires an event response"
                            )))
                        }
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        nonisolated public func generate(
            _ request: AISchema.LLMRequest,
            options: AIRoute.StreamOptions? = nil
        ) async throws -> AISchema.LLMResponse {
            try await AIRoute.generateWith { req, opts in
                self.stream(req, options: opts)
            }(request, options)
        }

        nonisolated public func compact(
            _ request: AISchema.LLMRequest,
            options: AIRoute.CompactOptions = .endpoint(nil)
        ) async throws -> AIRoute.CompactionResult {
            let response = try await self.take(request)
            switch options {
            case .trigger:
                guard case .checkpoint(let cp) = response else {
                    throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                        message: "TestLLM trigger compaction requires a CompactionCheckpointResponse"
                    )))
                }
                return .trigger(cp)
            case .endpoint, .custom:
                guard case .compaction(let cr) = response else {
                    throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                        message: "TestLLM compaction requires a CompactionResponse"
                    )))
                }
                return .endpoint(cr)
            }
        }
    }

    // parity: ai/src/testing.ts#testLayer [status=implemented hash=1148de5f09a0]
    public static func testLayer(_ options: LayerOptions = LayerOptions()) -> Test {
        Test(options: options)
    }
}



