import Testing
import OpenCodeSchema
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

    private static func evaluate(_ fn: String, args: [SnapshotJSON]) throws -> SnapshotJSON {
        switch fn {
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
            return .string(Identifier.create(descending: args[0].bool!, timestamp: args[1].int64!))
        case "schema/src/identifier.ts#ascending":
            return .string(Identifier.ascending())
        case "schema/src/identifier.ts#descending":
            return .string(Identifier.descending())
        default:
            throw SnapshotError.unknownFunction(fn)
        }
    }

    @Test("All golden upstream oracle snapshots pass identically in Swift")
    func verifyAllGoldenSnapshots() throws {
        let snapshots = try SnapshotLoader.load(relativeTo: #filePath)
        #expect(snapshots.cases.count == snapshots.vectorCount)
        #expect(!snapshots.cases.isEmpty)

        for tc in snapshots.cases {
            if tc.compare == "expect_error" {
                #expect(!tc.expectedOk)
                #expect(throws: (any Error).self, "Expected error for [\(tc.fn)] \(tc.name)") {
                    _ = try Self.evaluate(tc.fn, args: tc.args)
                }
                continue
            }

            let actual = try Self.evaluate(tc.fn, args: tc.args)
            switch tc.compare {
            case "exact":
                #expect(actual == tc.expectedValue, "Mismatch for [\(tc.fn)] \(tc.name)")
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
}
