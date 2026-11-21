import Testing
import OpenCodeAI
import OpenCodeCLIKit
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer
import OpenCodeTUI
import OpenCodeUtil

/// Offline golden parity verification suite using Swift Testing.
/// Executes every upstream-recorded oracle snapshot (`Fixtures/oracle-snapshots.json`) directly
/// inside `swift test`, enabling Bun-free parity CI across macOS, Linux, Windows, Android, iOS, and WASI.
@Suite("Offline Upstream Oracle Parity Snapshots")
struct ParitySnapshotTests {
    enum SnapshotError: Error {
        case unknownFunction(String)
    }

    private static func snapshotNumber(_ d: Double) -> SnapshotJSON {
        if d.isFinite && d.rounded(.towardZero) == d && abs(d) < 9_007_199_254_740_992.0 {
            return .int(Int64(d))
        }
        return .double(d)
    }

    private static func toSchemaJSON(_ value: SnapshotJSON) -> OpenCodeSchema.JSONValue {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .int(i)
        case .double(let d): return .double(d)
        case .string(let s): return .string(s)
        case .array(let arr): return .array(arr.map(toSchemaJSON))
        case .object(let obj): return .object(obj.mapValues(toSchemaJSON))
        }
    }

    private static func fromSchemaJSON(_ value: OpenCodeSchema.JSONValue) -> SnapshotJSON {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .int(i)
        case .double(let d): return snapshotNumber(d)
        case .string(let s): return .string(s)
        case .array(let arr): return .array(arr.map(fromSchemaJSON))
        case .object(let obj): return .object(obj.mapValues(fromSchemaJSON))
        }
    }

    private static func toPureJSON(_ value: SnapshotJSON) -> PureJSONValue {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .number(Double(i))
        case .double(let d): return .number(d)
        case .string(let s): return .string(s)
        case .array(let arr): return .array(arr.map(toPureJSON))
        case .object(let obj):
            return .object(obj.keys.sorted().map { ($0, toPureJSON(obj[$0]!)) })
        }
    }

    private static func fromPureJSON(_ value: PureJSONValue) -> SnapshotJSON {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let d): return snapshotNumber(d)
        case .string(let s): return .string(s)
        case .array(let arr): return .array(arr.map(fromPureJSON))
        case .object(let entries):
            var dict: [String: SnapshotJSON] = [:]
            for (k, v) in entries {
                dict[k] = fromPureJSON(v)
            }
            return .object(dict)
        }
    }

    private static func decodeJSONCFormattingOptions(_ obj: [String: SnapshotJSON]?) -> JSONC.FormattingOptions? {
        guard let obj else { return nil }
        return JSONC.FormattingOptions(
            tabSize: obj["tabSize"]?.int,
            insertSpaces: obj["insertSpaces"]?.bool,
            eol: obj["eol"]?.str,
            insertFinalNewline: obj["insertFinalNewline"]?.bool,
            keepLines: obj["keepLines"]?.bool
        )
    }

    private static func decodeStringMap(_ value: SnapshotJSON) -> [String: String] {
        var out: [String: String] = [:]
        if let obj = value.obj {
            for (k, v) in obj {
                if let s = v.str { out[k] = s }
            }
        }
        return out
    }

    private static func decodeCorsOptions(_ args: [SnapshotJSON], _ idx: Int) -> CorsOptions? {
        guard idx < args.count, let o = args[idx].obj, let arr = o["cors"]?.arr else { return nil }
        return CorsOptions(cors: arr.compactMap(\.str))
    }

    private static func decodePlatformOS(_ raw: String) -> PlatformOS {
        switch raw {
        case "darwin": return .macOS
        case "win32": return .windows
        case "linux": return .linux
        default: return .unknown
        }
    }

    private static func decodeSessionTurnMessage(_ value: SnapshotJSON) -> SessionTurn.Message {
        let o = value.obj!
        let timeObj = o["time"]!.obj!
        let time = SessionTurn.Time(
            created: timeObj["created"]!.dbl!,
            firstToken: timeObj["firstToken"]?.dbl,
            streamed: timeObj["streamed"]?.dbl,
            completed: timeObj["completed"]?.dbl
        )
        let tokens: SessionTurn.Tokens?
        if let tok = o["tokens"]?.obj, let out = tok["output"]?.dbl, let reas = tok["reasoning"]?.dbl {
            tokens = SessionTurn.Tokens(output: out, reasoning: reas)
        } else {
            tokens = nil
        }
        return SessionTurn.Message(id: o["id"]!.str!, type: o["type"]!.str!, time: time, tokens: tokens)
    }

    private static func decodeSessionTurnOptions(_ args: [SnapshotJSON], _ idx: Int) -> SessionTurn.Options {
        guard idx < args.count, let o = args[idx].obj else { return SessionTurn.Options() }
        return SessionTurn.Options(index: o["index"]?.int, legacy: o["legacy"]?.bool)
    }

    private static func decodeUpdateChunks(_ value: SnapshotJSON) -> [Patch.UpdateFileChunk] {
        value.arr!.map { item in
            let o = item.obj!
            return Patch.UpdateFileChunk(
                oldLines: o["oldLines"]!.arr!.compactMap(\.str),
                newLines: o["newLines"]!.arr!.compactMap(\.str),
                changeContext: o["changeContext"]?.str,
                endOfFile: o["endOfFile"]?.bool
            )
        }
    }

    private static func evaluate(
        _ fn: String,
        args: [SnapshotJSON],
        idGenerator: inout Identifier.Generator
    ) throws -> SnapshotJSON {
        switch fn {
        // MARK: - packages/util & schema/identifier
        case "util/src/activity-calendar.ts#activityCalendar":
            let o = args[0].obj!
            let activity = o["activity"]!.arr!.map { item -> ActivityDayInput in
                let d = item.obj!
                return ActivityDayInput(date: d["date"]!.str!, steps: d["steps"]!.int!)
            }
            let res = activityCalendar(
                ActivityCalendarInput(
                    activity: activity,
                    from: o["from"]!.int64!,
                    to: o["to"]!.int64!,
                    maxWeeks: o["maxWeeks"]!.dbl!
                )
            )
            return .object([
                "clipped": .bool(res.clipped),
                "months": .array(res.months.map {
                    .object(["label": .string($0.label), "span": .int(Int64($0.span)), "week": .int(Int64($0.week))])
                }),
                "weeks": .array(res.weeks.map { week in
                    .array(week.map { cell in
                        .object(["date": .string(cell.date), "level": .int(Int64(cell.level)), "steps": .int(Int64(cell.steps))])
                    })
                }),
            ])
        case "util/src/artifact.ts#artifactMime":
            return artifactMime(args[0].str!).map { .string($0) } ?? .null
        case "util/src/artifact.ts#artifactKind":
            return .string(artifactKind(args[0].str!).rawValue)
        case "util/src/base64.ts#bytesToBase64":
            return .string(bytesToBase64(args[0].bytes!))
        case "util/src/base64.ts#base64ToBytes":
            return .array(try base64ToBytes(args[0].str!).map { .int(Int64($0)) })
        case "util/src/binary.ts#Binary.search":
            let r = Binary.search(args[0].arr!.compactMap(\.str), id: args[1].str!) { $0 }
            return .object(["found": .bool(r.found), "index": .int(Int64(r.index))])
        case "util/src/binary.ts#Binary.insert":
            let r = Binary.insert(args[0].arr!.compactMap(\.str), item: args[1].str!) { $0 }
            return .array(r.map { .string($0) })
        case "util/src/bom.ts#split":
            let r = Bom.split(args[0].str!)
            return .object(["bom": .bool(r.bom), "text": .string(r.text)])
        case "util/src/bom.ts#join":
            return .string(Bom.join(args[0].str!, bom: args[1].bool!))
        case "util/src/bom.ts#has":
            return .bool(Bom.has(args[0].bytes!))
        case "util/src/bom.ts#decodeBytes":
            let r = Bom.decodeBytes(args[0].bytes!)
            return .object(["bom": .bool(r.bom), "text": .string(r.text)])
        case "util/src/bom.ts#syncBytes":
            let r = Bom.syncBytes(args[0].bytes!, bom: args[1].bool!)
            return .object(["text": .string(r.text), "bytes": r.bytes.map { .array($0.map { .int(Int64($0)) }) } ?? .null])
        case "util/src/duration.ts#duration":
            return .string(duration(args[0].dbl!))
        case "util/src/encode.ts#base64Encode":
            return .string(base64Encode(args[0].str!))
        case "util/src/encode.ts#base64Decode":
            return .string(try base64Decode(args[0].str!))
        case "util/src/encode.ts#checksum":
            return checksum(args[0].str!).map { .string($0) } ?? .null
        case "util/src/encode.ts#sampledChecksum":
            let lim = args.count > 1 ? (args[1].int ?? 500_000) : 500_000
            return sampledChecksum(args[0].str!, limit: lim).map { .string($0) } ?? .null
        case "util/src/execute-output.ts#formatExecuteOutput":
            let r = formatExecuteOutput(args[0].str!)
            return .object([
                "json": r.json.map { .string($0) } ?? .null,
                "rest": r.rest.map { .string($0) } ?? .null,
                "text": .string(r.text),
            ])
        case "util/src/fs-util.ts#FSUtil.windowsPath":
            return .string(FSPathUtil.windowsPath(args[0].str!))
        case "util/src/fs-util.ts#FSUtil.contains":
            return .bool(FSPathUtil.contains(parent: args[0].str!, child: args[1].str!))
        case "util/src/fs-util.ts#FSUtil.overlaps":
            return .bool(FSPathUtil.overlaps(args[0].str!, args[1].str!))
        case "util/src/hash.ts#Hash.fast":
            return .string(Hash.fast(args[0].str!))
        case "util/src/hash.ts#Hash.sha256":
            return .string(Hash.sha256(args[0].str!))
        case "util/src/npm.ts#sanitize":
            return .string(NpmSpec.sanitize(args[0].str!))
        case "util/src/patch.ts#parse":
            switch Patch.parse(args[0].str!) {
            case .success(let hunks):
                return .object([
                    "ok": .bool(true),
                    "hunks": .array(hunks.map { hunk in
                        switch hunk {
                        case let .add(path, contents):
                            return .object(["type": .string("add"), "path": .string(path), "contents": .string(contents)])
                        case let .delete(path):
                            return .object(["type": .string("delete"), "path": .string(path)])
                        case let .update(path, movePath, chunks):
                            return .object([
                                "type": .string("update"),
                                "path": .string(path),
                                "movePath": movePath.map { .string($0) } ?? .null,
                                "chunks": .array(chunks.map { c in
                                    .object([
                                        "oldLines": .array(c.oldLines.map { .string($0) }),
                                        "newLines": .array(c.newLines.map { .string($0) }),
                                        "changeContext": c.changeContext.map { .string($0) } ?? .null,
                                        "endOfFile": c.endOfFile.map { .bool($0) } ?? .null,
                                    ])
                                }),
                            ])
                        }
                    }),
                ])
            case .failure(let err):
                let tag: String
                switch err {
                case .boundary: tag = "Patch.BoundaryError"
                case .invalidHunk: tag = "Patch.InvalidHunkError"
                }
                return .object(["ok": .bool(false), "tag": .string(tag), "message": .string(err.message)])
            }
        case "util/src/patch.ts#derive":
            let r = try Patch.derive(path: args[0].str!, chunks: decodeUpdateChunks(args[1]), original: args[2].str!)
            return .object(["content": .string(r.content), "bom": .bool(r.bom)])
        case "util/src/patch.ts#joinBom":
            return .string(Patch.joinBom(args[0].str!, bom: args[1].bool!))
        case "util/src/path.ts#getFilename":
            return .string(getFilename(args[0].str))
        case "util/src/path.ts#getDirectory":
            return .string(getDirectory(args[0].str))
        case "util/src/path.ts#getFilenameTruncated":
            let maxLen = args.count > 1 ? (args[1].int ?? 20) : 20
            return .string(getFilenameTruncated(args[0].str, maxLength: maxLen))
        case "util/src/path.ts#truncateMiddle":
            let maxLen = args.count > 1 ? (args[1].int ?? 20) : 20
            return .string(truncateMiddle(args[0].str!, maxLength: maxLen))
        case "util/src/path.ts#comparablePath":
            return .string(comparablePath(args[0].str!))
        case "util/src/path.ts#containsDirectory":
            return .bool(containsDirectory(args[0].str!, args[1].str!))
        case "util/src/path.ts#sameDirectory":
            return .bool(sameDirectory(args[0].str!, args[1].str!))
        case "util/src/path.ts#encodeFilePath":
            return .string(encodeFilePath(args[0].str!))
        case "util/src/path.ts#isLineRangeHash":
            return .bool(isLineRangeHash(args[0].str!))
        case "util/src/path.ts#parsePathLineSuffix":
            let p = parsePathLineSuffix(args[0].str!)
            let sel: SnapshotJSON = p.selection.map { .object(["start": .int(Int64($0.start)), "end": .int(Int64($0.end))]) } ?? .null
            return .object(["path": .string(p.path), "selection": sel])
        case "util/src/qr.ts#encode":
            let matrix = try QR.encode(args[0].str!)
            return .array(matrix.map { row in .array(row.map { .bool($0) }) })
        case "util/src/qr.ts#renderSVG":
            let opts = args.count > 1 ? args[1].obj : nil
            return .string(
                try QR.renderSVG(
                    args[0].str!,
                    border: opts?["border"]?.int ?? 1,
                    blackColor: opts?["blackColor"]?.str ?? "black",
                    whiteColor: opts?["whiteColor"]?.str ?? "white"
                )
            )
        case "util/src/qr.ts#renderUnicodeCompact":
            let opts = args.count > 1 ? args[1].obj : nil
            return .string(try QR.renderUnicodeCompact(args[0].str!, border: opts?["border"]?.int ?? 1))
        case "util/src/session-mention.ts#sessionMentions":
            return .array(sessionMentions(args[0].str!).map {
                .object(["id": .string($0.id), "text": .string($0.text), "start": .int(Int64($0.start)), "end": .int(Int64($0.end))])
            })
        case "util/src/session-mention.ts#parseSessionMention":
            return parseSessionMention(args[0].str!).map { .object(["id": .string($0.id)]) } ?? .null
        case "util/src/session-mention.ts#serializeSessionMention":
            return .string(serializeSessionMention(SessionMention(id: args[0].obj!["id"]!.str!)))
        case "util/src/session-title-fallback.ts#withTimestampedFallback":
            let o = args[0].obj!
            let info = SessionTitleFallback.Info(
                title: o["title"]?.str,
                parentID: o["parentID"]?.str,
                time: .init(created: o["time"]!.obj!["created"]!.int64!)
            )
            return .string(SessionTitleFallback.withTimestampedFallback(info))
        case "util/src/session-title-fallback.ts#displayLabel":
            let o = args[0].obj!
            return .string(SessionTitleFallback.displayLabel(title: o["title"]?.str, parentID: o["parentID"]?.str))
        case "util/src/session-title-fallback.ts#isFallbackTitle":
            return .bool(SessionTitleFallback.isFallbackTitle(args[0].str))
        case "util/src/session-title-fallback.ts#isExactRootFallback":
            let o = args[0].obj!
            return .bool(SessionTitleFallback.isExactRootFallback(title: o["title"]?.str, created: o["time"]!.obj!["created"]!.int64!))
        case "util/src/session-turn.ts#duration":
            let messages = args[0].arr!.map(decodeSessionTurnMessage)
            let message = decodeSessionTurnMessage(args[1])
            let opts = decodeSessionTurnOptions(args, 2)
            return snapshotNumber(SessionTurn.duration(messages, message: message, options: opts))
        case "util/src/session-turn.ts#tokensPerSecond":
            let messages = args[0].arr!.map(decodeSessionTurnMessage)
            let message = decodeSessionTurnMessage(args[1])
            let opts = decodeSessionTurnOptions(args, 2)
            return SessionTurn.tokensPerSecond(messages, message: message, options: opts).map(snapshotNumber) ?? .null
        case "util/src/session-turn.ts#legacy":
            let messages = args[0].arr!.map(decodeSessionTurnMessage)
            return .bool(SessionTurn.legacy(messages))
        case "util/src/text-boundary.ts#head":
            return .string(TextBoundary.head(args[0].str!, limit: args[1].int!))
        case "util/src/text-boundary.ts#tail":
            return .string(TextBoundary.tail(args[0].str!, limit: args[1].int!))
        case "util/src/text-boundary.ts#utf8Tail":
            return .string(TextBoundary.utf8Tail(args[0].bytes!, limit: args[1].int!))
        case "util/src/uuid.ts#uuid":
            return .string(uuid())
        case "schema/src/identifier.ts#create":
            return .string(idGenerator.create(descending: args[0].bool!, timestamp: args[1].int64!))
        case "schema/src/identifier.ts#ascending":
            return .string(idGenerator.create(descending: false))
        case "schema/src/identifier.ts#descending":
            return .string(idGenerator.create(descending: true))

        // MARK: - packages/theme & packages/tui color
        case "theme/src/tui/color.ts#oklchToHex":
            let o = args[0].obj!
            return .string(OpenCodeTUI.oklchToHex(OklchColor(l: o["l"]!.dbl!, c: o["c"]!.dbl!, h: o["h"]!.dbl!)))
        case "theme/src/tui/color.ts#rgbToOklch":
            let r = OpenCodeTUI.rgbToOklch(args[0].dbl!, args[1].dbl!, args[2].dbl!)
            return .object(["l": snapshotNumber(r.l), "c": snapshotNumber(r.c), "h": snapshotNumber(r.h)])
        case "theme/src/tui/expand.ts#mergeTheme":
            return fromSchemaJSON(.object(OpenCodeTUI.mergeTheme(args.map(toSchemaJSON))))
        case "theme/src/tui/v1-migrate.ts#byte":
            return .string(OpenCodeTUI.byte(args[0].int!))
        case "tui/src/theme/color.ts#ansiToRgba":
            return .string(OpenCodeTUI.hex(TUIThemeBridge.ansiToRgba(args[0].int!)))
        case "tui/src/theme/color.ts#tint":
            let base = TUIThemeBridge.ansiToRgba(args[0].int!)
            let overlay = TUIThemeBridge.ansiToRgba(args[1].int!)
            return .string(OpenCodeTUI.hex(TUIThemeBridge.tint(base, overlay: overlay, alpha: args[2].dbl!)))

        // MARK: - packages/patchmark
        case "patchmark/src/entities.ts#decodeCodePoint":
            return .string(OpenCodeTUI.decodeCodePoint(args[0].int!))
        case "patchmark/src/entities.ts#decodeEntity":
            return .string(OpenCodeTUI.decodeEntity(args[0].str!))
        case "patchmark/src/entities.ts#unescapeString":
            return .string(OpenCodeTUI.unescapeString(args[0].str!))
        case "patchmark/src/entities.ts#normalizeURI":
            return .string(OpenCodeTUI.normalizeURI(args[0].str!))
        case "patchmark/src/heal.ts#computeTailHeal":
            let h = OpenCodeTUI.computeTailHeal(args[0].str!)
            return .object(["strip": .int(Int64(h.strip)), "append": .string(h.append)])
        case "patchmark/src/heal.ts#healStreamingInline":
            return .string(OpenCodeTUI.healStreamingInline(args[0].str!))
        case "patchmark/src/html.ts#escapeHtml":
            return .string(OpenCodeTUI.escapeHtml(args[0].str!))
        case "patchmark/src/html.ts#filterDisallowedRawHtml":
            return .string(OpenCodeTUI.filterDisallowedRawHtml(args[0].str!))
        case "patchmark/src/stream.ts#splitPendingMarker":
            let s = OpenCodeTUI.splitPendingMarker(args[0].str!)
            return .object(["visible": .string(s.visible), "held": .string(s.held)])
        case "patchmark/src/html.ts#renderBlocksToHtml":
            let opts = args.count > 1 ? args[1].obj : nil
            let gfm = opts?["gfm"]?.bool ?? true
            let math = opts?["math"]?.bool ?? false
            let stream = PatchmarkStream(StreamOptions(gfm: gfm, math: math))
            stream.update(args[0].str!, streaming: false)
            return .string(OpenCodeTUI.renderBlocksToHtml(stream.getBlocks(), options: HtmlRenderOptions(gfm: gfm, math: math)))

        // MARK: - packages/ai
        case "ai/src/protocols/utils/mistral-tool-id.ts#valid":
            return .bool(AIProtocolUtils.MistralToolID.valid(args[0].str!))
        case "ai/src/protocols/utils/mistral-tool-id.ts#hash":
            return .string(AIProtocolUtils.MistralToolID.hash(args[0].str!))
        case "ai/src/protocols/utils/claude-model.ts#claudeVersion":
            if let v = AIProtocolUtils.ClaudeModel.claudeVersion(args[0].str!) {
                return .object(["family": .string(v.family), "major": .int(Int64(v.major)), "minor": .int(Int64(v.minor))])
            }
            return .null
        case "ai/src/protocols/utils/claude-model.ts#supportsThinkingBlockBinding":
            let o = args[0].obj!
            let compat = o["supportsThinkingBlockBinding"]?.bool.map {
                AIProtocolUtils.ModelCompatibility(supportsThinkingBlockBinding: $0)
            }
            let desc = AIProtocolUtils.ModelDescriptor(id: o["id"]!.str!, provider: "anthropic", compatibility: compat)
            return .bool(AIProtocolUtils.ClaudeModel.supportsThinkingBlockBinding(desc))
        case "ai/src/protocols/utils/image-sizing.ts#tier":
            return AIProtocolUtils.ImageSizing.tier(args[0].str!).map(snapshotNumber) ?? .null
        case "ai/src/protocols/utils/image-sizing.ts#fit":
            let sObj = args[0].obj!
            let lObj = args[1].obj!
            let shape = AIProtocolUtils.ImageSizing.Shape(aspect: sObj["aspect"]?.str, resolution: sObj["resolution"]?.str)
            let limits = AIProtocolUtils.ImageSizing.Limits(
                multiple: lObj["multiple"]!.int!,
                minEdge: lObj["minEdge"]?.int,
                maxEdge: lObj["maxEdge"]?.int,
                minPixels: lObj["minPixels"]?.int,
                maxPixels: lObj["maxPixels"]?.int,
                maxRatio: lObj["maxRatio"]?.dbl
            )
            let res = AIProtocolUtils.ImageSizing.fit(shape, limits: limits)
            return .object(["width": .int(Int64(res.width)), "height": .int(Int64(res.height))])
        case "ai/src/protocols/utils/image-sizing.ts#nearest":
            let sObj = args[0].obj!
            let shape = AIProtocolUtils.ImageSizing.Shape(aspect: sObj["aspect"]?.str, resolution: sObj["resolution"]?.str)
            let sizes = args[1].arr!.map { item -> AIProtocolUtils.ImageSizing.Size in
                let o = item.obj!
                return AIProtocolUtils.ImageSizing.Size(width: o["width"]!.int!, height: o["height"]!.int!)
            }
            let res = AIProtocolUtils.ImageSizing.nearest(shape, sizes: sizes)
            return .object(["width": .int(Int64(res.width)), "height": .int(Int64(res.height))])
        case "ai/src/protocols/utils/gemini-json-schema.ts#normalize":
            let dict = args[0].obj!.mapValues(toSchemaJSON)
            return fromSchemaJSON(.object(AIProtocolUtils.GeminiJsonSchema.normalize(dict)))
        case "ai/src/protocols/utils/cache.ts#openAIRequestTTL":
            return fromSchemaJSON(.object(AIProtocolUtils.Cache.openAIRequestTTL(args[0].str)))
        case "ai/src/protocols/utils/partial-json.ts#parseJSON":
            let parsed: OpenCodeSchema.JSONValue
            if args.count > 1, let allow = args[1].int {
                parsed = try AIProtocolUtils.PartialJSONParser.parseJSON(args[0].str!, allowPartial: allow)
            } else {
                parsed = try AIProtocolUtils.PartialJSONParser.parseJSON(args[0].str!)
            }
            return fromSchemaJSON(parsed)
        case "ai/src/utils/media-type.ts#detectMediaType":
            return AIUtils.detectMediaType(args[0].bytes!).map { .string($0) } ?? .null
        case "ai/src/utils/media-type.ts#fileMediaType":
            return AIUtils.fileMediaType(args[0].bytes!, path: args[1].str!).map { .string($0) } ?? .null
        case "ai/src/utils/media-type.ts#mediaTypeExtension":
            return AIUtils.mediaTypeExtension(args[0].str!).map { .string($0) } ?? .null
        case "ai/src/utils/provider-codes.ts#awsErrorType":
            return .array(AIUtils.awsErrorType(args[0].str).map { .string($0) })
        case "ai/src/utils/provider-codes.ts#providerCodes":
            return .array(AIUtils.providerCodes(toSchemaJSON(args[0])).map { .string($0) })
        case "ai/src/route/endpoint.ts#trimBaseUrl":
            return .string(AIEndpoint.trimBaseUrl(args[0].str!))
        case "ai/src/protocols/shared.ts#wrapSystemUpdate":
            let parts = args[0].arr!.compactMap(\.str).map { AIProtocolUtils.TextPart(text: $0) }
            return .string(AIProtocolUtils.ProviderShared.wrapSystemUpdate(parts))
        case "ai/src/protocols/shared.ts#fitThinkingBudget":
            let maxTok = args.count > 1 ? args[1].int : nil
            let minVal = args.count > 2 ? (args[2].int ?? 1) : 1
            return .int(Int64(AIProtocolUtils.ProviderShared.fitThinkingBudget(args[0].int!, maxTokens: maxTok, minimum: minVal)))
        case "ai/src/protocols/shared.ts#promptCacheKey":
            let o = args[0].obj!
            let cacheSetting: AIProtocolUtils.CacheSetting = o["cache"]?.str == "none" ? .none : .auto
            let caps = o["capabilityPromptCacheKey"]?.bool.map { AIProtocolUtils.ModelCapabilities(promptCacheKey: $0) }
            let req = AIProtocolUtils.LLMRequest(
                model: AIProtocolUtils.ModelDescriptor(id: "gpt-5", provider: "openai", capabilities: caps),
                cache: cacheSetting,
                promptCacheKey: o["promptCacheKey"]?.str
            )
            return AIProtocolUtils.ProviderShared.promptCacheKey(req).map { .string($0) } ?? .null
        case "ai/src/provider-error.ts#isContextOverflow":
            return .bool(AIErrorClassifier.isContextOverflow(args[0].str!))
        case "ai/src/protocols/shared.ts#flattenToolRequest":
            let o = args[0].obj!
            func decodeTool(_ v: SnapshotJSON) -> AIProtocolUtils.ToolEntry {
                let to = v.obj!
                let name = to["name"]!.str!
                if to["type"]?.str == "namespace" {
                    return .namespace(name: name, description: nil, tools: (to["tools"]?.arr ?? []).map(decodeTool))
                }
                return .tool(AIProtocolUtils.ToolDefinition(name: name, description: "", inputSchema: [:]))
            }
            let tools = o["tools"]!.arr!.map(decodeTool)
            let messages: [AIProtocolUtils.Message] = o["messages"]!.arr!.map { mv in
                let mo = mv.obj!
                let role: AIProtocolUtils.MessageRole = mo["role"]!.str! == "tool" ? .tool : .assistant
                let parts: [AIProtocolUtils.ContentPart] = mo["parts"]!.arr!.map { pv in
                    let po = pv.obj!
                    let pid = po["id"]!.str!
                    let pname = po["name"]!.str!
                    let ns = po["namespace"]?.str
                    if po["type"]?.str == "tool-result" {
                        return .toolResult(AIProtocolUtils.ToolResultPart(id: pid, name: pname, namespace: ns, result: .text("ok")))
                    }
                    return .toolCall(AIProtocolUtils.ToolCallPart(id: pid, name: pname, namespace: ns, input: .object([:])))
                }
                return AIProtocolUtils.Message(role: role, content: parts)
            }
            let req = AIProtocolUtils.LLMRequest(
                model: AIProtocolUtils.ModelDescriptor(id: "gpt-5", provider: "openai"),
                messages: messages,
                tools: tools
            )
            let flattened = AIProtocolUtils.ProviderShared.flattenToolRequest(req)
            return .object([
                "tools": .array(flattened.tools.map { .string($0.name) }),
                "messages": .array(flattened.request.messages.map { m in
                    .object([
                        "role": .string(m.role.rawValue),
                        "parts": .array(m.content.compactMap { part -> SnapshotJSON? in
                            switch part {
                            case .toolCall(let c):
                                return .object([
                                    "type": .string("tool-call"),
                                    "id": .string(c.id),
                                    "name": .string(c.name),
                                    "namespace": c.namespace.map { .string($0) } ?? .null,
                                ])
                            case .toolResult(let r):
                                return .object([
                                    "type": .string("tool-result"),
                                    "id": .string(r.id),
                                    "name": .string(r.name),
                                    "namespace": r.namespace.map { .string($0) } ?? .null,
                                ])
                            default:
                                return nil
                            }
                        }),
                    ])
                }),
            ])

        // MARK: - packages/core
        case "core/src/util/wildcard.ts#match":
            let ignoreCase = args.count > 2 ? (args[2].bool ?? false) : false
            return .bool(CoreSubsystems.Util.Wildcard.match(args[0].str!, pattern: args[1].str!, ignoreCase: ignoreCase, platform: .linux))
        case "core/src/util/canonical-json.ts#canonicalJson":
            return .string(CoreSubsystems.Util.canonicalJson(toSchemaJSON(args[0])))
        case "core/src/util/token.ts#estimate":
            return .int(Int64(CoreSubsystems.Util.Token.estimate(args[0].str!)))
        case "core/src/mime.ts#detect":
            return .string(CoreFilesystem.Mime.detect(args[0].bytes!))
        case "core/src/mime.ts#detectMedia":
            return CoreFilesystem.Mime.detectMedia(args[0].bytes!).map { .string($0) } ?? .null
        case "core/src/mime.ts#isTextual":
            return .bool(CoreFilesystem.Mime.isTextual(args[0].str!))
        case "core/src/config/markdown.ts#sanitize":
            return .string(CoreConfigMarkdown.sanitize(args[0].str!))
        case "core/src/managed-policy.ts#decision":
            let policies = args[0].arr!.map { item -> ConfigPolicySchema.Info in
                let o = item.obj!
                return ConfigPolicySchema.Info(
                    action: ConfigPolicySchema.Action(rawValue: o["action"]!.str!)!,
                    resource: o["resource"]!.str!,
                    effect: ConfigPolicySchema.Effect(rawValue: o["effect"]!.str!)!
                )
            }
            let act = ConfigPolicySchema.Action(rawValue: args[1].str!)!
            return .string(CoreManagedPolicy.decision(policies, action: act, resource: args[2].str!).rawValue)
        case "core/src/flag.ts#resolve":
            let o = args[0].obj!
            let entries: [CoreConfigEntry] = o["entries"]!.arr!.map { entryVal in
                let expObj = entryVal.obj?["experimental"]?.obj
                let exp = expObj.map { e in
                    ConfigExperimentalSchema.Info(
                        allFlags: e["all_flags"]?.bool,
                        todo: e["todo"]?.bool,
                        mediaBlob: e["media_blob"]?.bool,
                        artifacts: e["artifacts"]?.bool,
                        videoGenerate: e["video_generate"]?.bool.map { .enabled($0) },
                        consoleWatches: e["console_watches"]?.bool,
                        mcpEvents: e["mcp_events"]?.bool,
                        recommendedApi: e["recommended_api"]?.bool,
                        fullCodemode: e["full_codemode"]?.bool,
                        machines: e["machines"]?.bool,
                        homeMemory: e["home_memory"]?.bool,
                        projectOverlay: e["project_overlay"]?.bool,
                        sqliteFts: e["sqlite_fts"]?.bool
                    )
                }
                return .document(ConfigSchema.Document(info: ConfigSchema.Info(experimental: exp)))
            }
            let resolved = CoreFlag.resolve(CoreFlag.ResolveInput(
                entries: entries,
                channel: o["channel"]!.str!,
                overrides: o["overrides"]?.str
            ))
            var out: [String: SnapshotJSON] = [:]
            for (key, state) in resolved {
                out[key.rawValue] = .object(["enabled": .bool(state.enabled), "source": .string(state.source.rawValue)])
            }
            return .object(out)
        case "core/src/permission.ts#evaluate":
            let rulesets: [PermissionSchema.Ruleset] = args[2].arr!.map { rs in
                rs.arr!.map { ruleVal in
                    let o = ruleVal.obj!
                    return PermissionSchema.Rule(
                        action: o["action"]!.str!,
                        resource: o["resource"]!.str!,
                        effect: PermissionSchema.Effect(rawValue: o["effect"]!.str!)!
                    )
                }
            }
            let r = CorePermission.evaluate(action: args[0].str!, resource: args[1].str!, rulesets: rulesets)
            return .object(["action": .string(r.action), "resource": .string(r.resource), "effect": .string(r.effect.rawValue)])

        // MARK: - packages/server
        case "server/src/range.ts#parse":
            switch ByteRange.parse(args[0].str, size: args[1].int!) {
            case nil: return .null
            case .unsatisfiable: return .string("unsatisfiable")
            case .range(let s): return .object(["start": .int(Int64(s.start)), "end": .int(Int64(s.end))])
            }
        case "server/src/content-headers.ts#disposition":
            return .string(ContentHeaders.disposition(args[0].str!))
        case "server/src/content-headers.ts#download":
            let o = args[0].obj!
            let headers = ContentHeaders.download(path: o["path"]?.str, mime: o["mime"]!.str!)
            return .object(headers.mapValues { .string($0) })
        case "server/src/cors.ts#isAllowedCorsOrigin":
            return .bool(isAllowedCorsOrigin(args[0].str, opts: decodeCorsOptions(args, 1)))
        case "server/src/cors.ts#isAllowedRequestOrigin":
            return .bool(isAllowedRequestOrigin(args[0].str, host: args[1].str, opts: decodeCorsOptions(args, 2)))
        case "server/src/media-uri.ts#wantsMediaRefs":
            return .bool(wantsMediaRefs(ServerHTTPRequest(method: "GET", url: "http://localhost/", headers: decodeStringMap(args[0]))))
        case "server/src/request-site.ts#rejected":
            let o = args[0].obj!
            let req = ServerHTTPRequest(method: "GET", url: o["url"]!.str!, headers: decodeStringMap(o["headers"]!))
            return .bool(RequestSite.rejected(req, options: decodeCorsOptions(args, 1)))

        // MARK: - packages/schema & packages/protocol
        case "schema/src/token-usage.ts#total":
            let o = args[0].obj!
            let c = o["cache"]!.obj!
            return snapshotNumber(TokenUsageSchema.total(TokenUsageSchema.Info(
                input: o["input"]!.dbl!,
                output: o["output"]!.dbl!,
                reasoning: o["reasoning"]!.dbl!,
                cache: TokenUsageSchema.Cache(read: c["read"]!.dbl!, write: c["write"]!.dbl!)
            )))
        case "schema/src/event.ts#versionedType":
            return .string(EventSchema.versionedType(args[0].str!, version: args[1].int!))
        case "schema/src/event-manifest.ts#isServer":
            return .bool(EventManifestSchema.isServer(type: args[0].str!))
        case "protocol/src/groups/event.ts#isOpenCodeEvent":
            return .bool(isOpenCodeEvent(type: args[0].str!))
        case "protocol/src/groups/server.ts#isPairingConnectURL":
            return .bool(isPairingConnectURL(args[0].str!))
        case "protocol/src/groups/pty.ts#hasPtyConnectTicketURL":
            return .bool(hasPtyConnectTicketURL(args[0].str!))
        case "protocol/src/groups/persistent-pty.ts#hasPersistentPtyConnectTicketURL":
            return .bool(hasPersistentPtyConnectTicketURL(args[0].str!))
        case "protocol/src/groups/mcp.ts#hasMcpClientTicketURL":
            return .bool(hasMcpClientTicketURL(args[0].str!))
        case "protocol/src/groups/machine.ts#isWebSocketUpgrade":
            let o = args[0].obj!
            return .bool(isWebSocketUpgrade(method: o["method"]!.str!, headers: decodeStringMap(o["headers"]!)))
        case "protocol/src/groups/machine.ts#isMachineLinkUpgrade":
            let o = args[0].obj!
            return .bool(isMachineLinkUpgrade(method: o["method"]!.str!, url: o["url"]!.str!, headers: decodeStringMap(o["headers"]!)))

        // MARK: - packages/cli
        case "cli/src/database-path.ts#databasePath":
            let envMap = args.count > 1 ? decodeStringMap(args[1]) : [:]
            return .string(CLIUtil.databasePath(args[0].str!, channel: "local", environment: DictionaryEnvironment(variables: envMap)))
        case "cli/src/services/updater-action.ts#parseReleaseVersion":
            if let v = CLIServices.UpdaterAction.parseReleaseVersion(args[0].str!) {
                return .object([
                    "major": .string(v.major),
                    "core": .string(v.core),
                    "prerelease": .array(v.prerelease.map { .string($0) }),
                ])
            }
            return .null
        case "cli/src/services/updater-action.ts#action":
            let pol = CLIServices.UpdaterAction.Policy(rawValue: args[2].str!)!
            return .string(CLIServices.UpdaterAction.action(current: args[0].str!, latest: args[1].str!, policy: pol).rawValue)
        case "cli/src/services/service-config.ts#filename":
            return .string(CLIServices.ServiceConfig.filename(channel: args[0].str!))
        case "cli/src/services/service-config.ts#defaultPort":
            return .int(Int64(CLIServices.ServiceConfig.defaultPort(channel: args[0].str!, platform: decodePlatformOS(args[1].str!))))
        case "cli/src/services/service-config.ts#legacyFilename":
            return CLIServices.ServiceConfig.legacyFilename(channel: args[0].str!).map { .string($0) } ?? .null
        case "cli/src/services/service-config.ts#versionBelongsToChannel":
            return .bool(CLIServices.ServiceConfig.versionBelongsToChannel(args[0].str, channel: args[1].str!, installedVersion: args[2].str!))
        case "cli/src/services/service-urls.ts#parseServerURL":
            return .string(try CLIServiceURLs.parseServerURL(args[0].str!))
        case "cli/src/services/service-urls.ts#isLoopback":
            return .bool(CLIServiceURLs.isLoopback(args[0].str!))
        case "cli/src/node/target.ts#nodeTarget":
            let t = try CLIUtil.Node.nodeTarget(platform: args[0].str!, arch: args[1].str!)
            return .object([
                "platform": .string(t.platform),
                "arch": .string(t.arch),
                "nodePtyPackage": .string(t.nodePtyPackage),
                "nodePtyEntryAsset": .string(t.nodePtyEntryAsset),
                "parcelWatcherPackage": .string(t.parcelWatcherPackage),
                "parcelWatcherAsset": .string(t.parcelWatcherAsset),
                "fffPackage": .string(t.fffPackage),
                "fffAsset": .string(t.fffAsset),
                "fffFfiPackage": .string(t.fffFfiPackage),
                "fffFfiAsset": .string(t.fffFfiAsset),
                "opencodePtyAsset": .string(t.opencodePtyAsset),
            ])

        // MARK: - packages/latex
        case "latex/src/render.ts#renderLatexToString":
            var latexOpts = RenderLatexOptions()
            if args.count > 1, let o = args[1].obj {
                if let dm = o["displayMode"]?.bool { latexOpts.displayMode = dm }
                if let st = o["strict"]?.bool { latexOpts.strict = st }
            }
            return .string(try renderLatexToString(args[0].str!, options: latexOpts))
        case "latex/src/parser.ts#expandLatexMacros":
            return .string(try expandLatexMacros(args[0].str!, options: ParseOptions(macros: decodeStringMap(args[1]))))

        // MARK: - packages/merman
        case "merman/src/detect.ts#detectMermaidDiagram":
            return Merman.detectMermaidDiagram(args[0].str!).map { .string($0.rawValue) } ?? .null
        case "merman/src/flowchart/render.ts#renderFlowchartDiagram":
            return .string(try Merman.renderFlowchartDiagram(args[0].str!))
        case "merman/src/sequence/diagram.ts#renderSequenceDiagram":
            return .string(try Merman.renderSequenceDiagram(args[0].str!))
        case "merman/src/state/diagram.ts#renderStateDiagram":
            return .string(try Merman.renderStateDiagram(args[0].str!))
        case "merman/src/timeline/diagram.ts#renderTimelineDiagram":
            return .string(try Merman.renderTimelineDiagram(args[0].str!))
        case "merman/src/gitgraph/diagram.ts#renderGitGraphDiagram":
            return .string(try Merman.renderGitGraphDiagram(args[0].str!))
        case "merman/src/gantt/diagram.ts#renderGanttDiagram":
            return .string(try Merman.renderGanttDiagram(args[0].str!))

        // MARK: - packages/core/src/shell/scan.ts
        case "core/src/shell/scan.ts#scan":
            let dialect: CoreShell.Scan.Dialect = (args.count > 1 ? args[1].str.flatMap(CoreShell.Scan.Dialect.init(rawValue:)) : nil) ?? .posix
            switch CoreShell.Scan.scan(args[0].str!, dialect: dialect) {
            case .opaque(let reason):
                return .object(["kind": .string("opaque"), "reason": .string(reason.rawValue)])
            case .scanned(let commands):
                return .object([
                    "kind": .string("scanned"),
                    "commands": .array(commands.map { c in
                        .object([
                            "resource": .string(c.resource),
                            "words": .array(c.words.map { .string($0) }),
                            "rawWords": .array(c.rawWords.map { .string($0) }),
                        ])
                    }),
                ])
            }
        case "core/src/shell/scan.ts#scanPowerShell":
            switch CoreShell.Scan.scanPowerShell(args[0].str!) {
            case .opaque(let reason):
                return .object(["kind": .string("opaque"), "reason": .string(reason.rawValue)])
            case .scanned(let commands):
                return .object([
                    "kind": .string("scanned"),
                    "commands": .array(commands.map { c in
                        .object([
                            "resource": .string(c.resource),
                            "words": .array(c.words.map { .string($0) }),
                            "rawWords": .array(c.rawWords.map { .string($0) }),
                        ])
                    }),
                ])
            }

        // MARK: - jsonc-parser@3.3.1
        case "jsonc-parser#modifyAndApply":
            let text = args[0].str!
            let path: [JSONC.PathSegment] = args[1].arr!.map { seg in
                if let s = seg.str { return .key(s) }
                return .index(seg.int!)
            }
            let spec = args[2].obj!
            let value: PureJSONValue?
            if spec["remove"]?.bool == true {
                value = nil
            } else if let rawJson = spec["valueJson"]?.str {
                value = PureJSON.parse(rawJson)!
            } else if let v = spec["value"] {
                value = toPureJSON(v)
            } else {
                value = nil
            }
            var modOpts = JSONC.ModificationOptions()
            if args.count > 3, let rawOpts = args[3].obj {
                modOpts.formattingOptions = decodeJSONCFormattingOptions(rawOpts["formattingOptions"]?.obj)
                if let isIns = rawOpts["isArrayInsertion"]?.bool {
                    modOpts.isArrayInsertion = isIns
                }
                if let idx = rawOpts["insertionIndex"]?.int {
                    modOpts.getInsertionIndex = { _ in idx }
                }
            }
            let edits = try JSONC.modify(text, path: path, value: value, options: modOpts)
            let applied = try JSONC.applyEdits(text, edits: edits)
            return .object([
                "edits": .array(edits.map {
                    .object([
                        "offset": .int(Int64($0.offset)),
                        "length": .int(Int64($0.length)),
                        "content": .string($0.content),
                    ])
                }),
                "result": .string(applied),
            ])

        case "jsonc-parser#parse":
            let text = args[0].str!
            var parseOpts = JSONC.ParseOptions()
            if args.count > 1, let rawOpts = args[1].obj {
                if let v = rawOpts["allowTrailingComma"]?.bool { parseOpts.allowTrailingComma = v }
                if let v = rawOpts["disallowComments"]?.bool { parseOpts.disallowComments = v }
                if let v = rawOpts["allowEmptyContent"]?.bool { parseOpts.allowEmptyContent = v }
            }
            var errors: [JSONC.ParseError] = []
            let parsed = JSONC.parse(text, errors: &errors, options: parseOpts)
            return .object([
                "value": parsed.map(fromPureJSON) ?? .null,
                "errors": .array(errors.map {
                    .object([
                        "error": .int(Int64($0.error.rawValue)),
                        "offset": .int(Int64($0.offset)),
                        "length": .int(Int64($0.length)),
                    ])
                }),
            ])

        case "jsonc-parser#format":
            let text = args[0].str!
            let range: JSONC.Range? = args.count > 1 ? args[1].obj.flatMap { rObj in
                guard let offset = rObj["offset"]?.int, let length = rObj["length"]?.int else { return nil }
                return JSONC.Range(offset: offset, length: length)
            } : nil
            let fmtOpts = (args.count > 2 ? decodeJSONCFormattingOptions(args[2].obj) : nil) ?? JSONC.FormattingOptions()
            let edits = JSONC.format(text, range: range, options: fmtOpts)
            let applied = try JSONC.applyEdits(text, edits: edits)
            return .object([
                "edits": .array(edits.map {
                    .object([
                        "offset": .int(Int64($0.offset)),
                        "length": .int(Int64($0.length)),
                        "content": .string($0.content),
                    ])
                }),
                "result": .string(applied),
            ])

        default:
            throw SnapshotError.unknownFunction(fn)
        }
    }

    @Test("All golden upstream oracle snapshots pass identically in Swift")
    func verifyAllGoldenSnapshots() throws {
        let snapshots = try SnapshotLoader.load(relativeTo: #filePath)
        #expect(snapshots.cases.count == snapshots.vectorCount)
        #expect(!snapshots.cases.isEmpty)

        var idGenerator = Identifier.Generator()
        for tc in snapshots.cases {
            // psychoscript programs run on the async Code Mode runtime; see `verifyPsychoscriptSnapshots`.
            if tc.fn == PsychoscriptParity.executeFunction { continue }
            if tc.compare == "expect_error" {
                #expect(!tc.expectedOk)
                #expect(throws: (any Error).self, "Expected error for [\(tc.fn)] \(tc.name)") {
                    _ = try Self.evaluate(tc.fn, args: tc.args, idGenerator: &idGenerator)
                }
                continue
            }

            let actual = try Self.evaluate(tc.fn, args: tc.args, idGenerator: &idGenerator)
            switch tc.compare {
            case "exact":
                if tc.fn == "theme/src/tui/color.ts#rgbToOklch" {
                    #expect(actual.matches(tc.expectedValue, floatTolerance: 1e-6), "Mismatch for [\(tc.fn)] \(tc.name)")
                } else {
                    #expect(actual == tc.expectedValue, "Mismatch for [\(tc.fn)] \(tc.name)")
                }
            case "uuid_v4":
                #expect(actual.str?.count == 36, "Invalid UUID length")
            case "identifier_prefix_12":
                let actualStr = actual.str ?? ""
                let expectedStr = tc.expectedValue.str ?? ""
                #expect(actualStr.count == 26)
                #expect(actualStr.prefix(12) == expectedStr.prefix(12), "Prefix mismatch for [\(tc.fn)] \(tc.name)")
            case "identifier_shape":
                #expect(actual.str?.count == 26)
            default:
                Issue.record("Unknown compare mode: \(tc.compare)")
            }
        }
    }

    /// The psychoscript (Code Mode language) corpus, `parity/vectors/psychoscript.json`: each program's canonical
    /// outcome from the Swift `CodemodeLanguage` runtime must equal the one upstream `Runtime.make(...).execute`
    /// recorded.
    @Test("psychoscript program corpus matches upstream Runtime.execute outcomes")
    func verifyPsychoscriptSnapshots() async throws {
        let snapshots = try SnapshotLoader.load(relativeTo: #filePath)
        let cases = snapshots.cases.filter { $0.fn == PsychoscriptParity.executeFunction }
        for tc in cases {
            #expect(tc.compare == "exact", "Unsupported compare mode \(tc.compare) for [\(tc.fn)] \(tc.name)")
            #expect(tc.expectedOk, "Upstream oracle failed for [\(tc.fn)] \(tc.name)")
            guard let program = tc.args.first?.str else {
                Issue.record("Missing program for [\(tc.fn)] \(tc.name)")
                continue
            }
            let options = tc.args.count > 1 ? Self.toSchemaJSON(tc.args[1]) : nil
            let outcome = try await PsychoscriptParity.execute(program, options: options)
            #expect(Self.fromSchemaJSON(outcome) == tc.expectedValue, "Mismatch for [\(tc.fn)] \(tc.name)")
        }
    }
}
