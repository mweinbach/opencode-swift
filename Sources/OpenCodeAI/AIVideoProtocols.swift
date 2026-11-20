/// Live queued video generation wire protocols (`MiniMaxVideo`, `XAIVideo`, `OpenRouterVideo`,
/// `SeedanceVideo`, `GoogleInteractionsVideo`) and video provider model factory (`AIProviders.makeVideoModel`).
///
/// Strictly PORTABLE tier: zero OS imports, all HTTP via `OpenCodePlatform.HTTPTransport`
/// and environment lookups via `OpenCodePlatform.EnvironmentProviding`.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

extension AIRoute.MediaRoute.MediaRequest {
    public func withMerged(
        providerOptions: AISchema.ProviderOptions?,
        http: AISchema.HttpOptions?
    ) -> Self {
        self
    }
}

// MARK: - Shared Video Protocol Helpers

private enum VideoProtocolHelpers {
    static let hourMs: Double = 3_600_000
    static let dayMs: Double = 24 * 3_600_000

    static let officeDocumentMimeTypes: Set<String> = [
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/msword",
        "application/vnd.ms-excel",
        "application/vnd.ms-powerpoint",
    ]

    enum MediaRefKind {
        case dataUrl
        case url
        case ref
    }

    struct MediaRef {
        let kind: MediaRefKind
        let value: String
    }

    static func invalidRequest(_ message: String) -> AISchema.AIError {
        AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(message: message)))
    }

    static func mediaUrl(_ asset: AIMedia.Asset) -> String? {
        guard case .url(let raw, _, _) = asset.source else { return nil }
        let lower = raw.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        return raw
    }

    static func mediaReference(
        asset: AIMedia.Asset,
        provider: String?,
        label: String
    ) throws(AISchema.AIError) -> MediaRef {
        if let inline = asset.inline() {
            return MediaRef(kind: .dataUrl, value: inline.dataUrl)
        }
        if let url = mediaUrl(asset) {
            return MediaRef(kind: .url, value: url)
        }
        if let provider, case .ref(let refProvider, let id, _) = asset.source, refProvider.rawValue == provider {
            return MediaRef(kind: .ref, value: id)
        }
        let accepted = provider.map { ", and \($0) references" } ?? ""
        let got: String
        if case .ref(let refProvider, let id, _) = asset.source {
            got = "; got \(refProvider.rawValue):\(id)"
        } else {
            got = ""
        }
        throw invalidRequest("\(label) accepts inline bytes, data URLs, http(s) URLs\(accepted)\(got)")
    }

    static func googleMediaContent(_ asset: AIMedia.Asset) throws(AISchema.AIError) -> [String: JSONValue] {
        let kind = asset.kind
        guard kind == .image || kind == .audio || kind == .video || asset.mediaType == "application/pdf"
            || asset.mediaType == "text/csv" || officeDocumentMimeTypes.contains(asset.mediaType)
        else {
            throw invalidRequest("Google Interactions does not support \(asset.mediaType) document input")
        }
        let typeStr: String = (kind == .image || kind == .audio || kind == .video) ? kind.rawValue : "document"
        let uri: String?
        if kind == .video, let url = mediaUrl(asset) {
            uri = url
        } else if case .ref(let refProvider, let id, _) = asset.source, refProvider.rawValue == "google" {
            uri = id
        } else {
            uri = nil
        }
        if let uri {
            return ["type": .string(typeStr), "uri": .string(uri), "mime_type": .string(asset.mediaType)]
        }
        guard let inline = asset.inline() else {
            throw invalidRequest("Google Interactions requires inline data or a google reference for \(asset.mediaType)")
        }
        return ["type": .string(typeStr), "data": .string(inline.base64), "mime_type": .string(inline.mime)]
    }

    static func jsonNumber(_ value: Double) -> JSONValue {
        if value.isFinite,
           value.rounded(.towardZero) == value,
           value >= Double(Int64.min),
           value <= Double(Int64.max)
        {
            return .int(Int64(value))
        }
        return .double(value)
    }

    static func formatSeconds(_ value: Double) -> String {
        if value.isFinite,
           value.rounded(.towardZero) == value,
           value >= Double(Int64.min),
           value <= Double(Int64.max)
        {
            return "\(Int64(value))s"
        }
        return "\(value)s"
    }

    static func doubleValue(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    static func aspectString(_ aspect: AIVideo.VideoAspectRatio?) -> String? {
        guard let aspect else { return nil }
        switch aspect {
        case .ratio(let r): return r.rawValue
        case .auto: return "auto"
        }
    }

    static func mergeJsonRecords(_ records: [String: JSONValue]?...) -> [String: JSONValue] {
        var acc: [String: JSONValue] = [:]
        for record in records {
            guard let record else { continue }
            acc = mergeTwo(acc, record)
        }
        return acc
    }

    private static func mergeTwo(_ base: [String: JSONValue], _ overlay: [String: JSONValue]) -> [String: JSONValue] {
        var result = base
        for (key, value) in overlay {
            if case .object(let existingObj) = result[key], case .object(let overlayObj) = value {
                result[key] = .object(mergeTwo(existingObj, overlayObj))
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// Percent-encodes a single URI component matching JavaScript `encodeURIComponent`.
    static func encodeURIComponent(_ value: String) -> String {
        let hex: [UInt8] = Array("0123456789ABCDEF".utf8)
        var out = ""
        out.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            let isUnreserved =
                (byte >= 0x41 && byte <= 0x5A) // A-Z
                || (byte >= 0x61 && byte <= 0x7A) // a-z
                || (byte >= 0x30 && byte <= 0x39) // 0-9
                || byte == 0x2D // -
                || byte == 0x5F // _
                || byte == 0x2E // .
                || byte == 0x21 // !
                || byte == 0x7E // ~
                || byte == 0x2A // *
                || byte == 0x27 // '
                || byte == 0x28 // (
                || byte == 0x29 // )
            if isUnreserved {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out.append("%")
                out.append(Character(UnicodeScalar(hex[Int(byte >> 4)])))
                out.append(Character(UnicodeScalar(hex[Int(byte & 0x0F)])))
            }
        }
        return out
    }

    static func pruneNil(_ entries: [String: JSONValue?]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        out.reserveCapacity(entries.count)
        for (k, v) in entries {
            if let v { out[k] = v }
        }
        return out
    }

    /// Strips trailing `/v1` and slashes from a MiniMax base URL (`baseURL.replace(/(\/v1)?\/*$/, "")`).
    static func stripMiniMaxVideoBaseURL(_ raw: String?) -> String? {
        guard var s = raw else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/v1") {
            s.removeLast(3)
            while s.hasSuffix("/") { s.removeLast() }
        }
        return s
    }

    enum StringOrNumber: Decodable, Sendable {
        case string(String)
        case number(Double)

        var stringValue: String {
            switch self {
            case .string(let s): return s
            case .number(let n):
                if n.isFinite, n.rounded(.towardZero) == n, n >= Double(Int64.min), n <= Double(Int64.max) {
                    return String(Int64(n))
                }
                return String(n)
            }
        }

        var numericValue: Double? {
            switch self {
            case .number(let n): return n
            case .string(let s): return Double(s)
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                self = .string(s)
                return
            }
            if let n = try? c.decode(Double.self) {
                self = .number(n)
                return
            }
            throw DecodingError.typeMismatch(
                StringOrNumber.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected string or number")
            )
        }
    }
}

// MARK: - 1. MiniMaxVideo (packages/ai/src/protocols/minimax-video.ts)

extension AIProtocols.MiniMaxVideo {
    private static let h3Identity = AIRoute.MediaProtocol.identity(
        id: "minimax-video",
        name: "MiniMax Video",
        provider: "minimax"
    )
    private static let hailuoIdentity = AIRoute.MediaProtocol.identity(
        id: "minimax-hailuo-video",
        name: "MiniMax Hailuo Video",
        provider: "minimax"
    )

    private static let h3StatusTable: [String: AIRoute.MediaProtocol.State] = [
        "queued": .running,
        "running": .running,
        "succeeded": .completed,
        "failed": .error(.failed),
        "cancelled": .error(.cancelled),
    ]

    private static let hailuoStatusTable: [String: AIRoute.MediaProtocol.State] = [
        "Preparing": .running,
        "Queueing": .running,
        "Processing": .running,
        "Success": .completed,
        "Fail": .error(.failed),
    ]

    private static let failureTable: [String: AIRoute.MediaProtocol.Failure] = [
        "1002": .rateLimit,
        "1004": .authentication,
        "1039": .rateLimit,
        "2013": .invalidRequest,
        "2049": .authentication,
    ]
    private static let insufficientBalanceCode: Double = 1008
    private static let contentPolicyCodes: Set<String> = ["1026", "1027"]

    private struct BaseRespPayload: Decodable, Sendable {
        let status_code: Double
        let status_msg: String?
    }

    private struct H3StartPayload: Decodable, Sendable {
        let task_id: String
    }

    private struct H3TaskErrorPayload: Decodable, Sendable {
        let code: VideoProtocolHelpers.StringOrNumber?
        let message: String?
    }

    private struct H3TaskContentPayload: Decodable, Sendable {
        let url: String?
    }

    private struct H3TaskPayload: Decodable, Sendable {
        let id: String?
        let model: String?
        let status: String?
        let error: H3TaskErrorPayload?
        let content: H3TaskContentPayload?
        let resolution: String?
        let duration: Double?
        let ratio: String?
        let usage: [String: JSONValue]?
    }

    private struct H3TaskResponsePayload: Decodable, Sendable {
        let id: String?
        let model: String?
        let status: String?
        let error: H3TaskErrorPayload?
        let content: H3TaskContentPayload?
        let resolution: String?
        let duration: Double?
        let ratio: String?
        let usage: [String: JSONValue]?
        let task: H3TaskPayload?

        var resolvedTask: H3TaskPayload {
            task ?? H3TaskPayload(
                id: id,
                model: model,
                status: status,
                error: error,
                content: content,
                resolution: resolution,
                duration: duration,
                ratio: ratio,
                usage: usage
            )
        }
    }

    private struct HailuoStartPayload: Decodable, Sendable {
        let task_id: String?
        let base_resp: BaseRespPayload?
    }

    private struct HailuoTaskPayload: Decodable, Sendable {
        let status: String?
        let file_id: String?
        let video_width: Double?
        let video_height: Double?
        let base_resp: BaseRespPayload?
    }

    private struct HailuoFilePayload: Decodable, Sendable {
        struct FileInner: Decodable, Sendable {
            let download_url: String?
        }
        let file: FileInner?
        let base_resp: BaseRespPayload?
    }

    private static func failedError(
        output: AIRoute.MediaProtocol.TextOutput,
        name: String,
        code: String?,
        numericCode: Double?,
        detail: String?
    ) -> AISchema.AIError {
        let codePart = code.map { " (\($0))" } ?? ""
        let detailPart = detail.map { ": \($0)" } ?? ""
        let message = "\(name) generation failed\(codePart)\(detailPart)"
        if let code, contentPolicyCodes.contains(code) {
            return output.contentPolicy(message)
        }
        if let numericCode, numericCode == insufficientBalanceCode {
            return AISchema.AIError(reason: .quotaExceeded(AISchema.QuotaExceededError(
                message: message,
                body: output.body,
                http: output.http
            )))
        }
        return output.ended(reason: .failed, message: message, failure: AIRoute.MediaProtocol.failure(failureTable, code: code))
    }

    private static func baseError(
        output: AIRoute.MediaProtocol.TextOutput,
        base: BaseRespPayload?
    ) -> AISchema.AIError? {
        guard let base, base.status_code != 0 else { return nil }
        let codeStr = VideoProtocolHelpers.StringOrNumber.number(base.status_code).stringValue
        return failedError(
            output: output,
            name: hailuoIdentity.name,
            code: codeStr,
            numericCode: base.status_code,
            detail: base.status_msg
        )
    }

    private static func h3MediaUrl(_ asset: AIMedia.Asset) throws(AISchema.AIError) -> String {
        let ref = try VideoProtocolHelpers.mediaReference(asset: asset, provider: h3Identity.provider.rawValue, label: h3Identity.name)
        return ref.kind == .ref ? "mm_file://\(ref.value)" : ref.value
    }

    private static func h3Item(_ asset: AIMedia.Asset, role: String) throws(AISchema.AIError) -> JSONValue {
        let url = try h3MediaUrl(asset)
        let type = asset.kind == .video ? "video_url" : (asset.kind == .audio ? "audio_url" : "image_url")
        return .object([
            "type": .string(type),
            type: .object(["url": .string(url)]),
            "role": .string(role),
        ])
    }

    private static func h3Reference(_ asset: AIMedia.Asset) throws(AISchema.AIError) -> JSONValue {
        let role: String = switch asset.kind {
        case .video: "reference_video"
        case .audio: "reference_audio"
        default: "reference_image"
        }
        return try h3Item(asset, role: role)
    }

    private static func h3FromRequest(_ request: AIVideo.VideoRequest) throws(AISchema.AIError) -> AIRoute.MediaProtocol.Body {
        var content: [JSONValue] = [
            .object(["type": .string("text"), "text": .string(request.prompt)]),
        ]
        if let start = request.start {
            content.append(try h3Item(start.asset, role: "first_frame"))
        }
        if let end = request.end {
            content.append(try h3Item(end.asset, role: "last_frame"))
        }
        for ref in request.references ?? [] {
            content.append(try h3Reference(ref))
        }
        let ratio: String?
        if content.count == 1 && (request.aspect == nil || request.aspect == .auto) {
            ratio = "16:9"
        } else if request.aspect == .auto {
            ratio = "adaptive"
        } else {
            ratio = VideoProtocolHelpers.aspectString(request.aspect)
        }
        var base: [String: JSONValue] = [
            "model": .string(request.model.id.rawValue),
            "content": .array(content),
        ]
        if let res = request.resolution?.rawValue.uppercased() {
            base["resolution"] = .string(res)
        }
        if let dur = request.duration {
            base["duration"] = VideoProtocolHelpers.jsonNumber(AIVideo.seconds(dur))
        }
        if let ratio {
            base["ratio"] = .string(ratio)
        }
        return AIRoute.MediaProtocol.json(VideoProtocolHelpers.mergeJsonRecords(
            base,
            request.providerOptions,
            request.http?.body
        ))
    }

    private static func hailuoUrl(_ asset: AIMedia.Asset) throws(AISchema.AIError) -> String {
        let ref = try VideoProtocolHelpers.mediaReference(asset: asset, provider: nil, label: hailuoIdentity.name)
        return ref.value
    }

    private static func hailuoFromRequest(_ request: AIVideo.VideoRequest) throws(AISchema.AIError) -> AIRoute.MediaProtocol.Body {
        let references = request.references ?? []
        if references.contains(where: { $0.kind == .video || $0.kind == .audio }) {
            throw hailuoIdentity.unsupported(
                operation: "video.references",
                message: "\(hailuoIdentity.name) takes only image (subject) references"
            )
        }
        if let aspect = request.aspect, aspect != .auto {
            throw hailuoIdentity.unsupported(
                operation: "video.aspect",
                message: "\(hailuoIdentity.name) has no aspect ratio input"
            )
        }
        var subjects: [JSONValue] = []
        subjects.reserveCapacity(references.count)
        for asset in references {
            let url = try hailuoUrl(asset)
            subjects.append(.object([
                "type": .string("character"),
                "image": .array([.string(url)]),
            ]))
        }
        var base: [String: JSONValue] = [
            "model": .string(request.model.id.rawValue),
            "prompt": .string(request.prompt),
        ]
        if let start = request.start {
            base["first_frame_image"] = .string(try hailuoUrl(start.asset))
        }
        if let end = request.end {
            base["last_frame_image"] = .string(try hailuoUrl(end.asset))
        }
        if !subjects.isEmpty {
            base["subject_reference"] = .array(subjects)
        }
        if let dur = request.duration {
            base["duration"] = VideoProtocolHelpers.jsonNumber(AIVideo.seconds(dur))
        }
        if let res = request.resolution?.rawValue.uppercased() {
            base["resolution"] = .string(res)
        }
        return AIRoute.MediaProtocol.json(VideoProtocolHelpers.mergeJsonRecords(
            base,
            request.providerOptions,
            request.http?.body
        ))
    }

    /// Live queued wire protocol for MiniMax H3 (v2 API).
    public static let queuedProtocol: AIRoute.MediaProtocol.Queued<AIVideo.VideoRequest, AIVideo.VideoResponse, String> =
        AIRoute.MediaProtocol.queued(
            h3Identity,
            startBodyFrom: { request in try h3FromRequest(request) },
            startDecode: { response, _ in
                try await h3Identity.decodeStarted(H3StartPayload.self, from: response) { value in
                    AIRoute.MediaProtocol.Started(
                        token: value.task_id,
                        snapshot: AIGeneration.Snapshot(id: value.task_id, status: .running)
                    )
                }
            },
            statusPath: { token in "\(STATUS_PATH)/\(VideoProtocolHelpers.encodeURIComponent(token))" },
            statusDecode: { response, context in
                let decoded = try await h3Identity.decodeJson(H3TaskResponsePayload.self, from: response)
                let task = decoded.value.resolvedTask
                let st = AIRoute.MediaProtocol.status(h3StatusTable, raw: task.status ?? "")
                return AIGeneration.Snapshot(id: context.token, status: st.status, reason: st.reason)
            },
            resultPath: { token in "\(STATUS_PATH)/\(VideoProtocolHelpers.encodeURIComponent(token))" },
            resultDecode: { response, context in
                let decoded = try await h3Identity.decodeJson(H3TaskResponsePayload.self, from: response)
                let output = decoded.output
                let task = decoded.value.resolvedTask
                let state = AIRoute.MediaProtocol.state(h3StatusTable, raw: task.status ?? "")
                switch state {
                case .running:
                    throw output.pending(id: context.token)
                case .error(.failed):
                    throw failedError(
                        output: output,
                        name: h3Identity.name,
                        code: task.error?.code?.stringValue,
                        numericCode: task.error?.code?.numericValue,
                        detail: task.error?.message
                    )
                case .error:
                    throw output.ended(reason: .cancelled, message: "\(h3Identity.name) task \(context.token) was cancelled")
                case .completed:
                    guard let url = task.content?.url else {
                        throw output.invalid("\(h3Identity.name) completed without a video URL")
                    }
                    let info = task.duration.map { AIMedia.Info(durationSeconds: $0) }
                    let usage: AISchema.MediaUsage? = VideoProtocolHelpers.doubleValue(task.usage?["total_seconds"]).map { .seconds($0) }
                    let meta = VideoProtocolHelpers.pruneNil([
                        "taskId": .string(context.token),
                        "model": task.model.map { .string($0) },
                        "resolution": task.resolution.map { .string($0) },
                        "ratio": task.ratio.map { .string($0) },
                        "usage": task.usage.map { .object($0) },
                    ])
                    return AIVideo.VideoResponse(
                        videos: [AIMedia.url(url, mediaType: "video/mp4", options: AIMedia.AssetOptions(info: info))],
                        usage: usage,
                        providerMetadata: ["minimax": meta]
                    )
                }
            },
            cancel: .init(method: .DELETE, path: { token in "\(PATH)/\(VideoProtocolHelpers.encodeURIComponent(token))" })
        )

    /// Live queued wire protocol for MiniMax Hailuo (v1 API).
    public static let hailuoQueuedProtocol: AIRoute.MediaProtocol.Queued<AIVideo.VideoRequest, AIVideo.VideoResponse, String> =
        AIRoute.MediaProtocol.queued(
            hailuoIdentity,
            startBodyFrom: { request in try hailuoFromRequest(request) },
            startDecode: { response, _ in
                let decoded = try await hailuoIdentity.decodeJson(HailuoStartPayload.self, from: response)
                if let err = baseError(output: decoded.output, base: decoded.value.base_resp) {
                    throw err
                }
                let taskID = decoded.value.task_id ?? ""
                guard !taskID.isEmpty else {
                    throw decoded.output.invalid("\(hailuoIdentity.name) returned no task_id")
                }
                return AIRoute.MediaProtocol.Started(
                    token: taskID,
                    snapshot: AIGeneration.Snapshot(id: taskID, status: .running)
                )
            },
            statusPath: { token in "\(HAILUO_STATUS_PATH)?task_id=\(VideoProtocolHelpers.encodeURIComponent(token))" },
            statusDecode: { response, context in
                let decoded = try await hailuoIdentity.decodeJson(HailuoTaskPayload.self, from: response)
                let st = AIRoute.MediaProtocol.status(hailuoStatusTable, raw: decoded.value.status ?? "")
                if st.reason != .failed, let err = baseError(output: decoded.output, base: decoded.value.base_resp) {
                    throw err
                }
                return AIGeneration.Snapshot(id: context.token, status: st.status, reason: st.reason)
            },
            resultPath: { token in "\(HAILUO_STATUS_PATH)?task_id=\(VideoProtocolHelpers.encodeURIComponent(token))" },
            resultDecode: { response, context in
                let decoded = try await hailuoIdentity.decodeJson(HailuoTaskPayload.self, from: response)
                let output = decoded.output
                let task = decoded.value
                let state = AIRoute.MediaProtocol.state(hailuoStatusTable, raw: task.status ?? "")
                let err = baseError(output: output, base: task.base_resp)
                if case .error(.failed) = state {
                    throw err ?? failedError(output: output, name: hailuoIdentity.name, code: nil, numericCode: nil, detail: nil)
                }
                if let err { throw err }
                guard state == .completed else {
                    throw output.pending(id: context.token)
                }
                let fileID = task.file_id ?? ""
                guard !fileID.isEmpty else {
                    throw output.invalid("\(hailuoIdentity.name) completed without a file_id")
                }
                let fileResp = try await context.get("\(FILE_PATH)?file_id=\(VideoProtocolHelpers.encodeURIComponent(fileID))")
                let fileDecoded = try await hailuoIdentity.decodeJson(HailuoFilePayload.self, from: fileResp)
                if let fileErr = baseError(output: fileDecoded.output, base: fileDecoded.value.base_resp) {
                    throw fileErr
                }
                guard let url = fileDecoded.value.file?.download_url else {
                    throw fileDecoded.output.invalid("\(hailuoIdentity.name) returned no download_url for \(fileID)")
                }
                let info: AIMedia.Info? = (task.video_width == nil && task.video_height == nil)
                    ? nil
                    : AIMedia.Info(width: task.video_width, height: task.video_height)
                let asset = AIRoute.MediaProtocol.expiringUrl(
                    url,
                    retentionMs: VideoProtocolHelpers.hourMs,
                    mediaType: "video/mp4",
                    options: AIMedia.AssetOptions(info: info)
                )
                return AIVideo.VideoResponse(
                    videos: [asset],
                    providerMetadata: ["minimax": ["taskId": .string(context.token), "fileId": .string(fileID)]]
                )
            }
        )

    /// Live `AIVideo.VideoModel` for MiniMax H3 (v2 API).
    public static func h3VideoModel(_ input: AIRoute.MediaRoute.ModelInput) -> AIVideo.VideoModel {
        AIVideo.VideoModel.fromRoute(
            .init(protocol: queuedProtocol, path: .literal(PATH), baseURL: DEFAULT_BASE_URL),
            input: input
        )
    }

    /// Live `AIVideo.VideoModel` for MiniMax Hailuo (v1 API).
    public static func hailuoVideoModel(_ input: AIRoute.MediaRoute.ModelInput) -> AIVideo.VideoModel {
        AIVideo.VideoModel.fromRoute(
            .init(protocol: hailuoQueuedProtocol, path: .literal(HAILUO_PATH), baseURL: DEFAULT_BASE_URL),
            input: input
        )
    }

    /// Picks MiniMax H3 (v2) or Hailuo (v1) by model ID family.
    public static func videoModel(_ input: AIRoute.MediaRoute.ModelInput) -> AIVideo.VideoModel {
        isHailuo(input.id) ? hailuoVideoModel(input) : h3VideoModel(input)
    }
}

// MARK: - 2. XAIVideo (packages/ai/src/protocols/xai-video.ts)

extension AIProtocols.XAIVideo {
    private static let identity = AIRoute.MediaProtocol.identity(
        id: "xai-video",
        name: "xAI Video",
        provider: "xai"
    )

    private static let statusTable: [String: AIRoute.MediaProtocol.State] = [
        "pending": .running,
        "done": .completed,
        "failed": .error(.failed),
        "expired": .error(.expired),
    ]

    private static let failureTable: [String: AIRoute.MediaProtocol.Failure] = [
        "invalid_argument": .invalidRequest,
        "failed_precondition": .invalidRequest,
        "permission_denied": .authentication,
    ]

    private struct StartPayload: Decodable, Sendable {
        let request_id: String
    }

    private struct VideoStatusPayload: Decodable, Sendable {
        struct VideoInner: Decodable, Sendable {
            let url: String?
            let duration: Double?
            let respect_moderation: Bool?
        }
        struct ErrorInner: Decodable, Sendable {
            let code: String?
            let message: String?
        }
        let status: String
        let progress: Double?
        let video: VideoInner?
        let error: ErrorInner?
        let model: String?
    }

    private static func mediaInput(_ asset: AIMedia.Asset) throws(AISchema.AIError) -> JSONValue {
        let ref = try VideoProtocolHelpers.mediaReference(asset: asset, provider: identity.provider.rawValue, label: identity.name)
        if ref.kind == .ref {
            return .object(["file_id": .string(ref.value)])
        }
        return .object(["url": .string(ref.value)])
    }

    private static func nativeOptions(_ options: AISchema.ProviderOptions?) -> [String: JSONValue]? {
        guard var copy = options else { return nil }
        copy.removeValue(forKey: "mode")
        return copy
    }

    private static func fromRequest(_ request: AIVideo.VideoRequest) throws(AISchema.AIError) -> AIRoute.MediaProtocol.Body {
        let references = request.references ?? []
        if references.contains(where: { $0.kind == .video }) {
            throw identity.unsupported(
                operation: "video.references",
                message: "\(identity.name) has no reference video input"
            )
        }
        var base: [String: JSONValue] = [
            "model": .string(request.model.id.rawValue),
            "prompt": .string(request.prompt),
        ]
        if let start = request.start {
            base["image"] = try mediaInput(start.asset)
        }
        if let end = request.end {
            base["last_frame"] = try mediaInput(end.asset)
        }
        var images: [JSONValue] = []
        var audios: [JSONValue] = []
        for asset in references {
            if asset.kind == .audio {
                let ref = try VideoProtocolHelpers.mediaReference(asset: asset, provider: identity.provider.rawValue, label: identity.name)
                audios.append(.object(["url": .string(ref.value)]))
            } else {
                images.append(try mediaInput(asset))
            }
        }
        if !images.isEmpty { base["reference_images"] = .array(images) }
        if !audios.isEmpty { base["reference_audios"] = .array(audios) }
        if let dur = request.duration {
            base["duration"] = VideoProtocolHelpers.jsonNumber(AIVideo.seconds(dur))
        }
        if let aspect = request.aspect, !(aspect == .auto && request.start != nil) {
            if let aspectStr = VideoProtocolHelpers.aspectString(aspect) {
                base["aspect_ratio"] = .string(aspectStr)
            }
        }
        if let res = request.resolution?.rawValue {
            base["resolution"] = .string(res)
        }
        if let sound = request.sound {
            base["generate_audio"] = .bool(sound)
        }
        return AIRoute.MediaProtocol.json(VideoProtocolHelpers.mergeJsonRecords(
            base,
            nativeOptions(request.providerOptions),
            request.http?.body
        ))
    }

    private static func progressFraction(_ value: Double?) -> Double? {
        guard let value, value >= 0, value <= 100 else { return nil }
        return value / 100.0
    }

    private static func startPath(for request: AIVideo.VideoRequest) -> String {
        if case .string(let mode) = request.providerOptions?["mode"] {
            if mode == "edit" { return EDIT_PATH }
            if mode == "extend" { return EXTEND_PATH }
        }
        return PATH
    }

    /// Live queued wire protocol for xAI Video.
    public static let queuedProtocol: AIRoute.MediaProtocol.Queued<AIVideo.VideoRequest, AIVideo.VideoResponse, String> =
        AIRoute.MediaProtocol.queued(
            identity,
            startBodyFrom: { request in try fromRequest(request) },
            startDecode: { response, _ in
                try await identity.decodeStarted(StartPayload.self, from: response) { value in
                    AIRoute.MediaProtocol.Started(
                        token: value.request_id,
                        snapshot: AIGeneration.Snapshot(id: value.request_id, status: .running)
                    )
                }
            },
            statusPath: { token in "\(STATUS_PATH)/\(VideoProtocolHelpers.encodeURIComponent(token))" },
            statusDecode: { response, context in
                let decoded = try await identity.decodeJson(VideoStatusPayload.self, from: response)
                let st = AIRoute.MediaProtocol.status(statusTable, raw: decoded.value.status)
                return AIGeneration.Snapshot(
                    id: context.token,
                    status: st.status,
                    reason: st.reason,
                    progress: progressFraction(decoded.value.progress)
                )
            },
            resultPath: { token in "\(STATUS_PATH)/\(VideoProtocolHelpers.encodeURIComponent(token))" },
            resultDecode: { response, context in
                let decoded = try await identity.decodeJson(VideoStatusPayload.self, from: response)
                let output = decoded.output
                let payload = decoded.value
                let state = AIRoute.MediaProtocol.state(statusTable, raw: payload.status)
                switch state {
                case .running:
                    throw output.pending(id: context.token)
                case .error(.failed):
                    let code = payload.error?.code
                    let detail = payload.error?.message
                    let codePart = code.map { " (\($0))" } ?? ""
                    let detailPart = detail.map { ": \($0)" } ?? ""
                    throw output.ended(
                        reason: .failed,
                        message: "\(identity.name) generation failed\(codePart)\(detailPart)",
                        failure: AIRoute.MediaProtocol.failure(failureTable, code: code)
                    )
                case .error:
                    throw output.ended(reason: .expired, message: "\(identity.name) request \(context.token) expired")
                case .completed:
                    let moderated = payload.video?.respect_moderation == false
                    guard let url = payload.video?.url else {
                        if moderated {
                            throw output.contentPolicy("\(identity.name) withheld the video for moderation")
                        }
                        throw output.invalid("\(identity.name) completed without a video URL")
                    }
                    let info = payload.video?.duration.map { AIMedia.Info(durationSeconds: $0) }
                    let meta = VideoProtocolHelpers.pruneNil([
                        "requestId": .string(context.token),
                        "model": payload.model.map { .string($0) },
                        "respectModeration": payload.video?.respect_moderation.map { .bool($0) },
                    ])
                    return AIVideo.VideoResponse(
                        videos: [AIMedia.url(url, mediaType: "video/mp4", options: AIMedia.AssetOptions(info: info))],
                        providerMetadata: ["xai": meta]
                    )
                }
            }
        )

    /// Live `AIVideo.VideoModel` for xAI Video (supports `mode: "edit" | "extend"` dynamic endpoint path).
    public static func videoModel(_ input: AIRoute.MediaRoute.ModelInput) -> AIVideo.VideoModel {
        AIVideo.VideoModel.fromRoute(
            .init(
                protocol: queuedProtocol,
                path: .dynamic { endpointInput in startPath(for: endpointInput.request) },
                baseURL: DEFAULT_BASE_URL
            ),
            input: input
        )
    }
}

// MARK: - 3. OpenRouterVideo (packages/ai/src/protocols/openrouter-video.ts)

extension AIProtocols.OpenRouterVideo {
    private static let identity = AIRoute.MediaProtocol.identity(
        id: "openrouter-video",
        name: "OpenRouter Video",
        provider: "openrouter"
    )

    private static let statusTable: [String: AIRoute.MediaProtocol.State] = [
        "pending": .running,
        "in_progress": .running,
        "completed": .completed,
        "failed": .error(.failed),
        "cancelled": .error(.cancelled),
        "expired": .error(.expired),
    ]

    private struct StartPayload: Decodable, Sendable {
        let id: String
        let status: String?
    }

    private struct JobPayload: Decodable, Sendable {
        struct UsageInner: Decodable, Sendable {
            let cost: Double?
            let is_byok: Bool?
        }
        let id: String?
        let generation_id: String?
        let status: String
        let unsigned_urls: [String]?
        let expires_at: Double?
        let error: String?
        let usage: UsageInner?
    }

    private static func imagePart(_ asset: AIMedia.Asset, frameType: String) throws(AISchema.AIError) -> JSONValue {
        let ref = try VideoProtocolHelpers.mediaReference(asset: asset, provider: nil, label: identity.name)
        return .object([
            "type": .string("image_url"),
            "image_url": .object(["url": .string(ref.value)]),
            "frame_type": .string(frameType),
        ])
    }

    private static func referencePart(_ asset: AIMedia.Asset) throws(AISchema.AIError) -> JSONValue {
        if (asset.kind == .video || asset.kind == .audio) {
            if case .url = asset.source {
                // Allowed
            } else {
                throw identity.unsupported(
                    operation: "video.references",
                    message: "\(identity.name) only takes reference \(asset.kind.rawValue) as http(s) URLs"
                )
            }
        }
        let ref = try VideoProtocolHelpers.mediaReference(asset: asset, provider: nil, label: identity.name)
        if asset.kind == .video {
            return .object(["type": .string("video_url"), "video_url": .object(["url": .string(ref.value)])])
        }
        if asset.kind == .audio {
            return .object(["type": .string("audio_url"), "audio_url": .object(["url": .string(ref.value)])])
        }
        return .object(["type": .string("image_url"), "image_url": .object(["url": .string(ref.value)])])
    }

    private static func resolutionString(_ value: String) -> String {
        let bytes = Array(value.utf8)
        if bytes.count == 2 && bytes[0] >= 0x30 && bytes[0] <= 0x39 && bytes[1] == 0x6B {
            return value.uppercased()
        }
        return value
    }

    private static func isModerationMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("content policy") || lower.contains("moderat")
    }

    private static func fromRequest(_ request: AIVideo.VideoRequest) throws(AISchema.AIError) -> AIRoute.MediaProtocol.Body {
        var frames: [JSONValue] = []
        if let start = request.start {
            frames.append(try imagePart(start.asset, frameType: "first_frame"))
        }
        if let end = request.end {
            frames.append(try imagePart(end.asset, frameType: "last_frame"))
        }
        var inputReferences: [JSONValue] = []
        for ref in request.references ?? [] {
            inputReferences.append(try referencePart(ref))
        }
        var base: [String: JSONValue] = [
            "model": .string(request.model.id.rawValue),
            "prompt": .string(request.prompt),
        ]
        if !frames.isEmpty { base["frame_images"] = .array(frames) }
        if !inputReferences.isEmpty { base["input_references"] = .array(inputReferences) }
        if let dur = request.duration {
            base["duration"] = VideoProtocolHelpers.jsonNumber(AIVideo.seconds(dur))
        }
        if let aspect = request.aspect, aspect != .auto, let aspectStr = VideoProtocolHelpers.aspectString(aspect) {
            base["aspect_ratio"] = .string(aspectStr)
        }
        if let res = request.resolution?.rawValue {
            base["resolution"] = .string(resolutionString(res))
        }
        if let sound = request.sound {
            base["generate_audio"] = .bool(sound)
        }
        return AIRoute.MediaProtocol.json(VideoProtocolHelpers.mergeJsonRecords(
            base,
            request.providerOptions,
            request.http?.body
        ))
    }

    /// Live queued wire protocol for OpenRouter Video.
    public static let queuedProtocol: AIRoute.MediaProtocol.Queued<AIVideo.VideoRequest, AIVideo.VideoResponse, String> =
        AIRoute.MediaProtocol.queued(
            identity,
            startBodyFrom: { request in try fromRequest(request) },
            startDecode: { response, _ in
                try await identity.decodeStarted(StartPayload.self, from: response) { value in
                    let st = AIRoute.MediaProtocol.status(statusTable, raw: value.status ?? "pending")
                    return AIRoute.MediaProtocol.Started(
                        token: value.id,
                        snapshot: AIGeneration.Snapshot(id: value.id, status: st.status, reason: st.reason)
                    )
                }
            },
            statusPath: { token in "\(PATH)/\(VideoProtocolHelpers.encodeURIComponent(token))" },
            statusDecode: { response, context in
                let decoded = try await identity.decodeJson(JobPayload.self, from: response)
                let st = AIRoute.MediaProtocol.status(statusTable, raw: decoded.value.status)
                return AIGeneration.Snapshot(id: context.token, status: st.status, reason: st.reason)
            },
            resultPath: { token in "\(PATH)/\(VideoProtocolHelpers.encodeURIComponent(token))" },
            resultDecode: { response, context in
                let decoded = try await identity.decodeJson(JobPayload.self, from: response)
                let output = decoded.output
                let job = decoded.value
                let state = AIRoute.MediaProtocol.state(statusTable, raw: job.status)
                switch state {
                case .running:
                    throw output.pending(id: context.token)
                case .error(.failed):
                    let detail = job.error.flatMap { $0.isEmpty ? nil : ": \($0)" } ?? ""
                    let message = "\(identity.name) generation failed\(detail)"
                    if let errText = job.error, isModerationMessage(errText) {
                        throw output.contentPolicy(message)
                    }
                    throw output.ended(reason: .failed, message: message)
                case .error(let reason):
                    let detail = job.error.flatMap { $0.isEmpty ? nil : ": \($0)" } ?? ""
                    throw output.ended(
                        reason: reason,
                        message: "\(identity.name) job \(context.token) \(reason.rawValue)\(detail)"
                    )
                case .completed:
                    let urls = job.unsigned_urls ?? []
                    guard !urls.isEmpty else {
                        throw output.invalid("\(identity.name) completed without a video URL")
                    }
                    var videos: [AIMedia.Asset] = []
                    videos.reserveCapacity(urls.count)
                    let expiresAt = job.expires_at.map { $0 * 1000.0 }
                    for url in urls {
                        let creds = try await context.credentials(url)
                        videos.append(AIMedia.url(
                            url,
                            mediaType: "video/mp4",
                            expiresAt: expiresAt,
                            options: AIMedia.AssetOptions(headers: creds.headers, middleware: creds.middleware)
                        ))
                    }
                    let meta = VideoProtocolHelpers.pruneNil([
                        "id": .string(context.token),
                        "generationId": job.generation_id.map { .string($0) },
                        "cost": job.usage?.cost.map { .double($0) },
                        "isByok": job.usage?.is_byok.map { .bool($0) },
                    ])
                    return AIVideo.VideoResponse(videos: videos, providerMetadata: ["openrouter": meta])
                }
            }
        )

    /// Live `AIVideo.VideoModel` for OpenRouter Video.
    public static func videoModel(_ input: AIRoute.MediaRoute.ModelInput) -> AIVideo.VideoModel {
        AIVideo.VideoModel.fromRoute(
            .init(protocol: queuedProtocol, path: .literal(PATH), baseURL: DEFAULT_BASE_URL),
            input: input
        )
    }
}

// MARK: - 4. SeedanceVideo (packages/ai/src/protocols/seedance-video.ts)

extension AIProtocols.SeedanceVideo {
    private static let statusTable: [String: AIRoute.MediaProtocol.State] = [
        "queued": .running,
        "running": .running,
        "succeeded": .completed,
        "failed": .error(.failed),
        "cancelled": .error(.cancelled),
        "expired": .error(.expired),
    ]

    private static let failureTable: [String: AIRoute.MediaProtocol.Failure] = [
        "InvalidParameter": .invalidRequest,
        "MissingParameter": .invalidRequest,
        "InvalidArgumentError": .invalidRequest,
        "InvalidImageURL": .invalidRequest,
        "AuthenticationError": .authentication,
        "AccessDenied": .authentication,
        "QuotaExceeded": .rateLimit,
        "RateLimitExceeded": .rateLimit,
    ]

    private struct StartPayload: Decodable, Sendable {
        let id: String
    }

    private struct TaskPayload: Decodable, Sendable {
        struct ContentInner: Decodable, Sendable {
            let video_url: String?
            let last_frame_url: String?
        }
        struct ErrorInner: Decodable, Sendable {
            let code: String?
            let message: String?
        }
        struct UsageInner: Decodable, Sendable {
            let completion_tokens: Double?
            let total_tokens: Double?
        }
        let id: String?
        let model: String?
        let status: String
        let content: ContentInner?
        let error: ErrorInner?
        let usage: UsageInner?
        let updated_at: Double?
        let seed: Double?
        let resolution: String?
        let ratio: String?
        let duration: Double?
        let frames: Double?
        let framespersecond: Double?
        let generate_audio: Bool?
        let output_format: String?
        let draft: Bool?
        let service_tier: String?
    }

    private static func nativeOptions(_ options: AISchema.ProviderOptions?) -> [String: JSONValue]? {
        guard var copy = options else { return nil }
        copy.removeValue(forKey: "draft_task")
        return copy
    }

    private static func durationSeconds(_ task: TaskPayload) -> Double? {
        if let frames = task.frames, let fps = task.framespersecond, fps != 0 {
            return frames / fps
        }
        return task.duration
    }

    private static func isModerated(_ code: String?) -> Bool {
        guard let code else { return false }
        return code.contains("SensitiveContentDetected")
    }

    /// Live queued wire protocol for Seedance Video (`volcengine` or `byteplus`).
    public static func queuedProtocol(
        for provider: Provider
    ) -> AIRoute.MediaProtocol.Queued<AIVideo.VideoRequest, AIVideo.VideoResponse, String> {
        let identity = AIRoute.MediaProtocol.identity(
            id: "seedance-video",
            name: "Seedance Video",
            provider: provider.rawValue
        )

        @Sendable func item(_ asset: AIMedia.Asset, type: String, role: String) throws(AISchema.AIError) -> JSONValue {
            let ref = try VideoProtocolHelpers.mediaReference(asset: asset, provider: identity.provider.rawValue, label: identity.name)
            let url = ref.kind == .ref ? "asset://\(ref.value)" : ref.value
            return .object([
                "type": .string(type),
                type: .object(["url": .string(url)]),
                "role": .string(role),
            ])
        }

        @Sendable func referenceItem(_ asset: AIMedia.Asset) throws(AISchema.AIError) -> JSONValue {
            switch asset.kind {
            case .video: return try item(asset, type: "video_url", role: "reference_video")
            case .audio: return try item(asset, type: "audio_url", role: "reference_audio")
            default: return try item(asset, type: "image_url", role: "reference_image")
            }
        }

        let taskPath: @Sendable (String) -> String = { token in
            "\(PATH)/\(VideoProtocolHelpers.encodeURIComponent(token))"
        }

        return AIRoute.MediaProtocol.queued(
            identity,
            startBodyFrom: { request in
                var content: [JSONValue] = []
                if !request.prompt.isEmpty {
                    content.append(.object(["type": .string("text"), "text": .string(request.prompt)]))
                }
                if let start = request.start {
                    content.append(try item(start.asset, type: "image_url", role: "first_frame"))
                }
                if let end = request.end {
                    content.append(try item(end.asset, type: "image_url", role: "last_frame"))
                }
                for ref in request.references ?? [] {
                    content.append(try referenceItem(ref))
                }
                if let draftTask = request.providerOptions?["draft_task"] {
                    content.append(.object(["type": .string("draft_task"), "draft_task": draftTask]))
                }
                var base: [String: JSONValue] = [
                    "model": .string(request.model.id.rawValue),
                    "content": .array(content),
                ]
                if let dur = request.duration {
                    base["duration"] = VideoProtocolHelpers.jsonNumber(AIVideo.seconds(dur))
                }
                if let aspect = request.aspect {
                    base["ratio"] = .string(aspect == .auto ? "adaptive" : (VideoProtocolHelpers.aspectString(aspect) ?? "adaptive"))
                }
                if let res = request.resolution?.rawValue {
                    base["resolution"] = .string(res)
                }
                if let sound = request.sound {
                    base["generate_audio"] = .bool(sound)
                }
                return AIRoute.MediaProtocol.json(VideoProtocolHelpers.mergeJsonRecords(
                    base,
                    nativeOptions(request.providerOptions),
                    request.http?.body
                ))
            },
            startDecode: { response, _ in
                try await identity.decodeStarted(StartPayload.self, from: response) { value in
                    AIRoute.MediaProtocol.Started(
                        token: value.id,
                        snapshot: AIGeneration.Snapshot(id: value.id, status: .running)
                    )
                }
            },
            statusPath: taskPath,
            statusDecode: { response, context in
                let decoded = try await identity.decodeJson(TaskPayload.self, from: response)
                let st = AIRoute.MediaProtocol.status(statusTable, raw: decoded.value.status)
                return AIGeneration.Snapshot(id: context.token, status: st.status, reason: st.reason)
            },
            resultPath: taskPath,
            resultDecode: { response, context in
                let decoded = try await identity.decodeJson(TaskPayload.self, from: response)
                let output = decoded.output
                let task = decoded.value
                let state = AIRoute.MediaProtocol.state(statusTable, raw: task.status)
                switch state {
                case .running:
                    throw output.pending(id: context.token)
                case .error(.failed):
                    let code = task.error?.code
                    let detail = task.error?.message
                    let codePart = code.map { " (\($0))" } ?? ""
                    let detailPart = detail.map { ": \($0)" } ?? ""
                    let message = "\(identity.name) generation failed\(codePart)\(detailPart)"
                    if isModerated(code) {
                        throw output.contentPolicy(message)
                    }
                    let category = code?.split(separator: ".", maxSplits: 1).first.map(String.init)
                    throw output.ended(
                        reason: .failed,
                        message: message,
                        failure: AIRoute.MediaProtocol.failure(failureTable, code: category)
                    )
                case .error(.cancelled):
                    throw output.ended(reason: .cancelled, message: "\(identity.name) task \(context.token) was cancelled")
                case .error(.expired):
                    throw output.ended(reason: .expired, message: "\(identity.name) task \(context.token) expired")
                case .completed:
                    guard let videoURL = task.content?.video_url else {
                        throw output.invalid("\(identity.name) completed without a video URL")
                    }
                    let duration = durationSeconds(task)
                    let mediaType = task.output_format == "mov" ? "video/quicktime" : "video/mp4"
                    let opts = AIMedia.AssetOptions(info: duration.map { AIMedia.Info(durationSeconds: $0) })
                    let asset: AIMedia.Asset
                    if let updatedAt = task.updated_at {
                        asset = AIMedia.url(
                            videoURL,
                            mediaType: mediaType,
                            expiresAt: updatedAt * 1000.0 + VideoProtocolHelpers.dayMs,
                            options: opts
                        )
                    } else {
                        asset = AIRoute.MediaProtocol.expiringUrl(
                            videoURL,
                            retentionMs: VideoProtocolHelpers.dayMs,
                            mediaType: mediaType,
                            options: opts
                        )
                    }
                    let usage: AISchema.MediaUsage? = task.usage?.completion_tokens.map { completion in
                        .tokens(input: nil, output: completion, total: task.usage?.total_tokens, details: nil)
                    }
                    let meta = VideoProtocolHelpers.pruneNil([
                        "taskId": .string(context.token),
                        "model": task.model.map { .string($0) },
                        "seed": task.seed.map { VideoProtocolHelpers.jsonNumber($0) },
                        "ratio": task.ratio.map { .string($0) },
                        "resolution": task.resolution.map { .string($0) },
                        "duration": task.duration.map { VideoProtocolHelpers.jsonNumber($0) },
                        "frames": task.frames.map { VideoProtocolHelpers.jsonNumber($0) },
                        "framesPerSecond": task.framespersecond.map { VideoProtocolHelpers.jsonNumber($0) },
                        "generateAudio": task.generate_audio.map { .bool($0) },
                        "outputFormat": task.output_format.map { .string($0) },
                        "draft": task.draft.map { .bool($0) },
                        "serviceTier": task.service_tier.map { .string($0) },
                        "lastFrameUrl": task.content?.last_frame_url.map { .string($0) },
                    ])
                    return AIVideo.VideoResponse(
                        videos: [asset],
                        usage: usage,
                        providerMetadata: [provider.rawValue: meta]
                    )
                }
            },
            cancel: .init(method: .DELETE, path: taskPath)
        )
    }

    /// Live `AIVideo.VideoModel` for Seedance Video (`volcengine` or `byteplus`).
    public static func videoModel(_ input: AIRoute.MediaRoute.ModelInput, provider: Provider) -> AIVideo.VideoModel {
        AIVideo.VideoModel.fromRoute(
            .init(
                protocol: queuedProtocol(for: provider),
                path: .literal(PATH),
                baseURL: provider.defaultBaseURL
            ),
            input: input
        )
    }
}

// MARK: - 5. GoogleInteractionsVideo (packages/ai/src/protocols/google-interactions-video.ts)

extension AIProtocols.GoogleInteractionsVideo {
    private static let identity = AIRoute.MediaProtocol.identity(
        id: "google-interactions-video",
        name: "Google Interactions Video",
        provider: "google"
    )

    private static let statusTable: [String: AIRoute.MediaProtocol.State] = [
        "in_progress": .running,
        "completed": .completed,
        "incomplete": .completed,
        "failed": .error(.failed),
        "cancelled": .error(.cancelled),
    ]

    private static let failureTable: [String: AIRoute.MediaProtocol.Failure] = [
        "INVALID_ARGUMENT": .invalidRequest,
        "FAILED_PRECONDITION": .invalidRequest,
        "OUT_OF_RANGE": .invalidRequest,
        "PERMISSION_DENIED": .authentication,
        "UNAUTHENTICATED": .authentication,
        "RESOURCE_EXHAUSTED": .rateLimit,
    ]

    private struct ContentPayload: Decodable, Sendable {
        let type: String
        let data: String?
        let uri: String?
        let mime_type: String?
        let text: String?
    }

    private struct StepPayload: Decodable, Sendable {
        let type: String
        let content: [ContentPayload]?
    }

    private struct ErrorPayload: Decodable, Sendable {
        let code: String?
        let message: String?
    }

    private struct InteractionPayload: Decodable, Sendable {
        let id: String
        let status: String
        let model: String?
        let steps: [StepPayload]?
        let usage: [String: JSONValue]?
        let errors: [ErrorPayload]?
    }

    private static func normalizeErrorCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let last = raw.split(separator: "/").last.map(String.init) ?? raw
        let normalized = last
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
        return normalized.isEmpty ? nil : normalized
    }

    private static func videoTask(for request: AIVideo.VideoRequest) -> String? {
        let hasFrames = request.start != nil || request.end != nil
        let hasReferences = !(request.references ?? []).isEmpty
        if hasFrames && !hasReferences { return "image_to_video" }
        if hasReferences && !hasFrames { return "reference_to_video" }
        return nil
    }

    private static func fromRequest(_ request: AIVideo.VideoRequest) throws(AISchema.AIError) -> AIRoute.MediaProtocol.Body {
        if request.end != nil && request.start == nil {
            throw identity.unsupported(
                operation: "video.end",
                message: "\(identity.name) reads a lone image as the start frame; send start too"
            )
        }
        var mediaAssets: [AIMedia.Asset] = []
        if let start = request.start { mediaAssets.append(start.asset) }
        if let end = request.end { mediaAssets.append(end.asset) }
        if let refs = request.references { mediaAssets.append(contentsOf: refs) }

        var inputs: [JSONValue] = []
        inputs.reserveCapacity(mediaAssets.count + 1)
        for asset in mediaAssets {
            inputs.append(.object(try VideoProtocolHelpers.googleMediaContent(asset)))
        }
        inputs.append(.object(["type": .string("text"), "text": .string(request.prompt)]))

        var responseFormat: [String: JSONValue] = [:]
        if let aspect = request.aspect, aspect != .auto, let aspectStr = VideoProtocolHelpers.aspectString(aspect) {
            responseFormat["aspect_ratio"] = .string(aspectStr)
        }
        if let res = request.resolution?.rawValue.lowercased() {
            responseFormat["resolution"] = .string(res)
        }
        if let dur = request.duration {
            responseFormat["duration"] = .string(VideoProtocolHelpers.formatSeconds(AIVideo.seconds(dur)))
        }

        var base: [String: JSONValue] = [
            "model": .string(request.model.id.rawValue),
            "input": .array(inputs),
            "background": .bool(true),
        ]
        if !responseFormat.isEmpty {
            responseFormat["type"] = .string("video")
            base["response_format"] = .object(responseFormat)
        }
        if let task = videoTask(for: request) {
            base["generation_config"] = .object([
                "video_config": .object(["task": .string(task)]),
            ])
        }
        return AIRoute.MediaProtocol.json(VideoProtocolHelpers.mergeJsonRecords(
            base,
            request.providerOptions,
            request.http?.body
        ))
    }

    private static func isContentBlocked(_ codes: [String]) -> Bool {
        codes.contains { $0 == "CONTENT_BLOCKED" || AIProtocolUtils.GeminiGenerateContent.contentFiltered($0) }
    }

    /// Live queued wire protocol for Google Interactions Video.
    public static let queuedProtocol: AIRoute.MediaProtocol.Queued<AIVideo.VideoRequest, AIVideo.VideoResponse, String> = {
        let interactionPath: @Sendable (String) -> String = { token in
            "\(PATH)/\(VideoProtocolHelpers.encodeURIComponent(token))"
        }
        return AIRoute.MediaProtocol.queued(
            identity,
            startBodyFrom: { request in try fromRequest(request) },
            startDecode: { response, _ in
                try await identity.decodeStarted(InteractionPayload.self, from: response) { value in
                    let st = AIRoute.MediaProtocol.status(statusTable, raw: value.status)
                    return AIRoute.MediaProtocol.Started(
                        token: value.id,
                        snapshot: AIGeneration.Snapshot(id: value.id, status: st.status, reason: st.reason)
                    )
                }
            },
            statusPath: interactionPath,
            statusDecode: { response, context in
                let decoded = try await identity.decodeJson(InteractionPayload.self, from: response)
                let st = AIRoute.MediaProtocol.status(statusTable, raw: decoded.value.status)
                return AIGeneration.Snapshot(id: context.token, status: st.status, reason: st.reason)
            },
            resultPath: interactionPath,
            resultDecode: { response, context in
                let decoded = try await identity.decodeJson(InteractionPayload.self, from: response)
                let output = decoded.output
                let payload = decoded.value
                let state = AIRoute.MediaProtocol.state(statusTable, raw: payload.status)
                if state == .running {
                    throw output.pending(id: context.token)
                }
                let errors = payload.errors ?? []
                let codes = errors.compactMap { normalizeErrorCode($0.code) }
                let messages = errors.compactMap { err -> String? in
                    let trimmed = err.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return trimmed.isEmpty ? nil : trimmed
                }
                if case .error(.cancelled) = state {
                    throw output.ended(reason: .cancelled, message: "\(identity.name) interaction \(context.token) was cancelled")
                }
                if case .error(.failed) = state {
                    let codePart = codes.isEmpty ? "" : " (\(codes.joined(separator: ", ")))"
                    let msgPart = messages.isEmpty ? "" : ": \(messages.joined(separator: "\n"))"
                    let message = "\(identity.name) generation failed\(codePart)\(msgPart)"
                    if isContentBlocked(codes) {
                        throw output.contentPolicy(message)
                    }
                    throw output.ended(
                        reason: .failed,
                        message: message,
                        failure: AIRoute.MediaProtocol.failure(failureTable, code: codes.first)
                    )
                }

                let contents = (payload.steps ?? []).flatMap { step in
                    step.type == "model_output" ? (step.content ?? []) : []
                }
                var videos: [AIMedia.Asset] = []
                for (index, content) in contents.filter({ $0.type == "video" }).enumerated() {
                    if let dataStr = content.data, !dataStr.isEmpty {
                        guard let raw = Data(base64Encoded: dataStr, options: [.ignoreUnknownCharacters]) else {
                            throw output.invalid("\(identity.name) video \(index) contains invalid base64")
                        }
                        let bytes = Array(raw)
                        let mime = content.mime_type ?? AIUtils.detectMediaType(bytes) ?? "application/octet-stream"
                        videos.append(AIMedia.bytes(bytes, mediaType: mime))
                    } else if let uri = content.uri, !uri.isEmpty {
                        videos.append(AIMedia.ref(provider: identity.provider.rawValue, id: uri, mediaType: content.mime_type))
                    } else {
                        throw output.invalid("\(identity.name) returned a video without data or a URI")
                    }
                }
                if videos.isEmpty {
                    if isContentBlocked(codes) {
                        let msgPart = messages.isEmpty ? "" : ": \(messages.joined(separator: "\n"))"
                        throw output.contentPolicy("\(identity.name) withheld the video\(msgPart)")
                    }
                    throw output.invalid("\(identity.name) \(payload.status) without a video")
                }

                let usage: AISchema.MediaUsage?
                if let rawUsage = payload.usage {
                    let details = VideoProtocolHelpers.pruneNil([
                        "reasoningTokens": rawUsage["total_thought_tokens"],
                        "google": .object(rawUsage),
                    ])
                    usage = AISchema.tokenUsage(
                        input: VideoProtocolHelpers.doubleValue(rawUsage["total_input_tokens"]),
                        output: VideoProtocolHelpers.doubleValue(rawUsage["total_output_tokens"]),
                        total: VideoProtocolHelpers.doubleValue(rawUsage["total_tokens"]),
                        details: details.isEmpty ? nil : details
                    )
                } else {
                    usage = nil
                }

                let meta = VideoProtocolHelpers.pruneNil([
                    "interactionId": .string(payload.id),
                    "model": payload.model.map { .string($0) },
                    "status": .string(payload.status),
                ])
                return AIVideo.VideoResponse(videos: videos, usage: usage, providerMetadata: ["google": meta])
            },
            cancel: .init(method: .POST, path: { token in "\(interactionPath(token))/cancel" })
        )
    }()

    /// Live `AIVideo.VideoModel` for Google Interactions Video.
    public static func videoModel(_ input: AIRoute.MediaRoute.ModelInput) -> AIVideo.VideoModel {
        AIVideo.VideoModel.fromRoute(
            .init(protocol: queuedProtocol, path: .literal(PATH), baseURL: DEFAULT_BASE_URL),
            input: input
        )
    }
}

// MARK: - AIProviders Video Model Factory

extension AIProviders {
    private static func mediaAuth(
        config: ProviderConfig,
        envVar: String,
        headerName: String? = nil,
        environment: any EnvironmentProviding
    ) -> AIAuth.Definition {
        switch config.apiKey {
        case .disabled:
            return AIAuth.none
        case .explicit(let key):
            let cred = AIAuth.value(key, source: "apiKey")
            return headerName.map { cred.header($0) } ?? cred.bearer()
        case .inherited:
            let cred = AIAuth.config(envVar, environment: environment)
            return headerName.map { cred.header($0) } ?? cred.bearer()
        }
    }

    /// Instantiates a live, runnable `AIVideo.VideoModel` for any supported video provider package specifier
    /// (`@opencode/ai/providers/{minimax,xai,openrouter,volcengine,byteplus,google}/videos` and bare provider IDs).
    public static func makeVideoModel(
        package: String,
        modelID: String,
        options: ProviderConfig = ProviderConfig(),
        headers: [String: String]? = nil,
        body: [String: JSONValue]? = nil,
        timeout: AISchema.RequestTimeout? = nil,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) throws(ProviderConfigurationError) -> AIVideo.VideoModel {
        var mergedHeaders = options.headers ?? [:]
        if let headers {
            for (k, v) in headers { mergedHeaders[k] = v }
        }
        let mergedBody: [String: JSONValue]? = (options.body == nil && body == nil)
            ? nil
            : AIProtocolUtils.JSONCodec.mergeObjects(options.body, body)
        let httpOpts: AISchema.HttpOptions? = (options.queryParams != nil || mergedBody != nil)
            ? AISchema.HttpOptions(query: options.queryParams, body: mergedBody)
            : nil
        let transport: AISchema.TransportOptions? = (!mergedHeaders.isEmpty || timeout != nil || httpOpts != nil)
            ? AISchema.TransportOptions(
                headers: mergedHeaders.isEmpty ? nil : mergedHeaders,
                timeout: timeout,
                http: httpOpts
            )
            : nil

        let normalized = package.trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized {
        case "@opencode/ai/providers/minimax/videos", "@opencode/ai/providers/minimax", "minimax":
            let auth = mediaAuth(config: options, envVar: "MINIMAX_API_KEY", environment: environment)
            let baseURL = VideoProtocolHelpers.stripMiniMaxVideoBaseURL(options.baseURL)
            return AIProtocols.MiniMaxVideo.videoModel(AIRoute.MediaRoute.ModelInput(
                id: modelID,
                auth: auth,
                baseURL: baseURL,
                transport: transport,
                providerOptions: options.providerOptions
            ))

        case "@opencode/ai/providers/xai/videos", "@opencode/ai/providers/xai", "xai":
            let auth = mediaAuth(config: options, envVar: "XAI_API_KEY", environment: environment)
            return AIProtocols.XAIVideo.videoModel(AIRoute.MediaRoute.ModelInput(
                id: modelID,
                auth: auth,
                baseURL: options.baseURL,
                transport: transport,
                providerOptions: options.providerOptions
            ))

        case "@opencode/ai/providers/openrouter/videos", "@opencode/ai/providers/openrouter", "openrouter":
            let auth = mediaAuth(config: options, envVar: "OPENROUTER_API_KEY", environment: environment)
            return AIProtocols.OpenRouterVideo.videoModel(AIRoute.MediaRoute.ModelInput(
                id: modelID,
                auth: auth,
                baseURL: options.baseURL,
                transport: transport,
                providerOptions: options.providerOptions
            ))

        case "@opencode/ai/providers/volcengine/videos", "@opencode/ai/providers/volcengine", "volcengine":
            let auth = mediaAuth(config: options, envVar: "ARK_API_KEY", environment: environment)
            return AIProtocols.SeedanceVideo.videoModel(
                AIRoute.MediaRoute.ModelInput(
                    id: modelID,
                    auth: auth,
                    baseURL: options.baseURL,
                    transport: transport,
                    providerOptions: options.providerOptions
                ),
                provider: .volcengine
            )

        case "@opencode/ai/providers/byteplus/videos", "@opencode/ai/providers/byteplus", "byteplus":
            let auth = mediaAuth(config: options, envVar: "BYTEPLUS_API_KEY", environment: environment)
            return AIProtocols.SeedanceVideo.videoModel(
                AIRoute.MediaRoute.ModelInput(
                    id: modelID,
                    auth: auth,
                    baseURL: options.baseURL,
                    transport: transport,
                    providerOptions: options.providerOptions
                ),
                provider: .byteplus
            )

        case "@opencode/ai/providers/google/videos", "@opencode/ai/providers/google", "google":
            let auth = mediaAuth(
                config: options,
                envVar: "GOOGLE_GENERATIVE_AI_API_KEY",
                headerName: "x-goog-api-key",
                environment: environment
            )
            return AIProtocols.GoogleInteractionsVideo.videoModel(AIRoute.MediaRoute.ModelInput(
                id: modelID,
                auth: auth,
                baseURL: options.baseURL,
                transport: transport,
                providerOptions: options.providerOptions
            ))

        default:
            throw ProviderConfigurationError(
                provider: package,
                message: "Unsupported AI video provider package specifier: \(package)"
            )
        }
    }

    /// Convenience overload constructing a live `AIVideo.VideoModel` from an untyped settings dictionary
    /// (e.g. from `CoreModel.Resolver.ResolvedModelDescriptor`).
    public static func makeVideoModel(
        package: String,
        modelID: String,
        settings: [String: JSONValue],
        headers: [String: String]? = nil,
        body: [String: JSONValue]? = nil,
        timeout: AISchema.RequestTimeout? = nil,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) throws(ProviderConfigurationError) -> AIVideo.VideoModel {
        let config = ProviderConfig.from(settings: settings, headers: headers, body: body)
        return try makeVideoModel(
            package: package,
            modelID: modelID,
            options: config,
            timeout: timeout,
            environment: environment
        )
    }
}
