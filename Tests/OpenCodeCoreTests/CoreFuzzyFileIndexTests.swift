import Testing
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil
import Synchronization

@Suite("CoreFuzzyFileIndex")
struct CoreFuzzyFileIndexTests {
    // MARK: - Helpers (Pure Swift, no Foundation)

    private func utf8(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    private static func extractUTF16MatchedString(_ text: String, indices: [Int]) -> String {
        let units = Array(text.utf16)
        let selected = indices.compactMap { idx -> UInt16? in
            guard idx >= 0 && idx < units.count else { return nil }
            return units[idx]
        }
        return String(decoding: selected, as: UTF16.self)
    }

    private final class AdjustableClock: Sendable {
        private let value: Mutex<Int64>

        init(_ initial: Int64) {
            self.value = Mutex(initial)
        }

        func now() -> Int64 {
            value.withLock { $0 }
        }

        func set(_ newValue: Int64) {
            value.withLock { $0 = newValue }
        }

        func advance(by deltaMs: Int64) {
            value.withLock { $0 += deltaMs }
        }
    }

    // MARK: - 1. .gitignore & .ignore Walker Tests

    @Test("Walker skips default ignored directories and respects root .gitignore patterns")
    func gitignoreRootAndDefaults() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/repo/.gitignore": utf8("""
                # Comments and blank lines should be ignored
                *.log
                !important.log
                /root-only.txt
                dist/
                /top-dir/
                docs/gen/*.html
                temp?.txt
                item[0-9].dat
                \\#escaped.txt
                \\!bang.txt
                trailing-space   
                """),
            // Default ignored dirs must never be indexed
            "/repo/.git/HEAD": utf8("ref: refs/heads/main\n"),
            "/repo/.git/config": utf8("[core]\n"),
            "/repo/node_modules/pkg/index.js": utf8("export {}\n"),
            "/repo/.build/debug/App": utf8("bin"),
            // Regular and hidden files
            "/repo/Sources/App.swift": utf8("struct App {}\n"),
            "/repo/.github/workflows/ci.yml": utf8("name: CI\n"),
            // Negation rule
            "/repo/debug.log": utf8("ignore me"),
            "/repo/Sources/trace.log": utf8("ignore me too"),
            "/repo/important.log": utf8("keep root"),
            "/repo/Sources/important.log": utf8("keep nested"),
            // Anchored leading slash
            "/repo/root-only.txt": utf8("ignored at root"),
            "/repo/sub/root-only.txt": utf8("kept in sub"),
            // Directory-only trailing slash (unanchored) vs regular file of same name
            "/repo/dist/bundle.js": utf8("ignored dir"),
            "/repo/packages/web/dist/app.js": utf8("ignored nested dir"),
            "/repo/Sources/dist": utf8("regular file named dist is NOT ignored"),
            // Anchored directory-only trailing slash
            "/repo/top-dir/a.txt": utf8("ignored at root"),
            "/repo/nested/top-dir/a.txt": utf8("kept when nested"),
            // Middle slash anchored rule
            "/repo/docs/gen/index.html": utf8("ignored"),
            "/repo/other/docs/gen/index.html": utf8("kept"),
            // Wildcards `?` and `[0-9]`
            "/repo/temp1.txt": utf8("ignored"),
            "/repo/temp12.txt": utf8("kept"),
            "/repo/item5.dat": utf8("ignored"),
            "/repo/itemX.dat": utf8("kept"),
            // Escaped `#` and `!` and trailing whitespace stripping
            "/repo/#escaped.txt": utf8("ignored"),
            "/repo/!bang.txt": utf8("ignored"),
            "/repo/trailing-space": utf8("ignored"),
        ])

        let index = CoreFuzzyFileIndex(fileSystem: fs)
        let count = try await index.warm(root: "/repo")
        #expect(count > 0)

        let allFiles = await index.search(
            root: "/repo",
            query: "",
            options: .init(kind: .file, limit: 200)
        )
        let paths = Set(allFiles.map(\.relativePath))

        // Included files
        #expect(paths.contains("Sources/App.swift"))
        #expect(paths.contains(".github/workflows/ci.yml"))
        #expect(paths.contains("important.log"))
        #expect(paths.contains("Sources/important.log"))
        #expect(paths.contains("sub/root-only.txt"))
        #expect(paths.contains("Sources/dist"))
        #expect(paths.contains("nested/top-dir/a.txt"))
        #expect(paths.contains("other/docs/gen/index.html"))
        #expect(paths.contains("temp12.txt"))
        #expect(paths.contains("itemX.dat"))

        // Excluded by default ignored dirs
        #expect(!paths.contains(".git/HEAD"))
        #expect(!paths.contains(".git/config"))
        #expect(!paths.contains("node_modules/pkg/index.js"))
        #expect(!paths.contains(".build/debug/App"))

        // Excluded by .gitignore rules
        #expect(!paths.contains("debug.log"))
        #expect(!paths.contains("Sources/trace.log"))
        #expect(!paths.contains("root-only.txt"))
        #expect(!paths.contains("dist/bundle.js"))
        #expect(!paths.contains("packages/web/dist/app.js"))
        #expect(!paths.contains("top-dir/a.txt"))
        #expect(!paths.contains("docs/gen/index.html"))
        #expect(!paths.contains("temp1.txt"))
        #expect(!paths.contains("item5.dat"))
        #expect(!paths.contains("#escaped.txt"))
        #expect(!paths.contains("!bang.txt"))
        #expect(!paths.contains("trailing-space"))
    }

    @Test("Nested .gitignore, .ignore override, and double-star glob rules")
    func nestedGitignoreAndDoubleStar() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/repo/.gitignore": utf8("""
                *.tmp
                generated/**
                !generated/keep.swift
                a/**/target.txt
                **/cache/
                secret.env
                """),
            "/repo/.ignore": utf8("""
                !secret.env
                """),
            "/repo/packages/special/.gitignore": utf8("""
                !keep.tmp
                local-only.txt
                """),
            "/repo/root.tmp": utf8("ignored"),
            "/repo/packages/other/drop.tmp": utf8("ignored"),
            "/repo/packages/special/drop.tmp": utf8("ignored"),
            "/repo/packages/special/keep.tmp": utf8("re-included by nested .gitignore"),
            "/repo/packages/special/local-only.txt": utf8("ignored by nested .gitignore"),
            "/repo/packages/other/local-only.txt": utf8("not affected by sibling .gitignore"),
            "/repo/generated/auto.swift": utf8("ignored by generated/**"),
            "/repo/generated/sub/deep.swift": utf8("ignored by generated/**"),
            "/repo/generated/keep.swift": utf8("negated back in"),
            "/repo/a/target.txt": utf8("ignored by a/**/target.txt (0 segments)"),
            "/repo/a/x/target.txt": utf8("ignored by a/**/target.txt (1 segment)"),
            "/repo/a/x/y/target.txt": utf8("ignored by a/**/target.txt (2 segments)"),
            "/repo/a/x/other.txt": utf8("kept"),
            "/repo/cache/entry.bin": utf8("ignored by **/cache/"),
            "/repo/deep/nested/cache/entry.bin": utf8("ignored by **/cache/"),
            "/repo/secret.env": utf8("re-included by .ignore overriding .gitignore"),
        ])

        let index = CoreFuzzyFileIndex(fileSystem: fs)
        try await index.warm(root: "/repo")

        let allFiles = await index.search(root: "/repo", query: "", options: .init(kind: .file, limit: 200))
        let paths = Set(allFiles.map(\.relativePath))

        #expect(!paths.contains("root.tmp"))
        #expect(!paths.contains("packages/other/drop.tmp"))
        #expect(!paths.contains("packages/special/drop.tmp"))
        #expect(paths.contains("packages/special/keep.tmp"))
        #expect(!paths.contains("packages/special/local-only.txt"))
        #expect(paths.contains("packages/other/local-only.txt"))

        #expect(!paths.contains("generated/auto.swift"))
        #expect(!paths.contains("generated/sub/deep.swift"))
        #expect(paths.contains("generated/keep.swift"))

        #expect(!paths.contains("a/target.txt"))
        #expect(!paths.contains("a/x/target.txt"))
        #expect(!paths.contains("a/x/y/target.txt"))
        #expect(paths.contains("a/x/other.txt"))

        #expect(!paths.contains("cache/entry.bin"))
        #expect(!paths.contains("deep/nested/cache/entry.bin"))
        #expect(paths.contains("secret.env"))
    }

    @Test("Walker works on real disk LocalFileSystem with .gitignore")
    func realDiskLocalFileSystemWalk() async throws {
        let tmp = try ToolsConfigRuntimeHelper.makeTempDirectory(prefix: "fuzzy-index-disk")
        defer { ToolsConfigRuntimeHelper.removeTempDirectory(tmp) }

        let fs = LocalFileSystem.shared
        try await fs.writeFile(utf8("*.bak\nignored_dir/\n"), to: "\(tmp)/.gitignore", createDirectories: true)
        try await fs.writeFile(utf8("struct Main {}\n"), to: "\(tmp)/Sources/Main.swift", createDirectories: true)
        try await fs.writeFile(utf8("old"), to: "\(tmp)/Sources/Main.swift.bak", createDirectories: true)
        try await fs.writeFile(utf8("skip"), to: "\(tmp)/ignored_dir/secret.txt", createDirectories: true)
        try await fs.writeFile(utf8("skip"), to: "\(tmp)/.git/HEAD", createDirectories: true)

        let index = CoreFuzzyFileIndex(fileSystem: fs)
        try await index.warm(root: tmp)

        let results = await index.search(root: tmp, query: "main", options: .init(kind: .file, limit: 20))
        #expect(results.map(\.relativePath) == ["Sources/Main.swift"])

        let all = await index.search(root: tmp, query: "", options: .init(kind: .file, limit: 50))
        let allPaths = Set(all.map(\.relativePath))
        #expect(allPaths.contains("Sources/Main.swift"))
        #expect(!allPaths.contains("Sources/Main.swift.bak"))
        #expect(!allPaths.contains("ignored_dir/secret.txt"))
        #expect(!allPaths.contains(".git/HEAD"))
    }

    // MARK: - 2. Fuzzy Ranking Quality Tests

    @Test("Fuzzy ranking strictly orders exact > exact stem > prefix > camelCase boundary > scattered")
    func fuzzyRankingQualityOrder() async {
        let index = CoreFuzzyFileIndex(fileSystem: InMemoryFileSystem())
        index.seed(root: "/repo", entries: [
            ("Sources/craft_stuff.swift", .file),        // scattered non-boundary c..f..f
            ("Sources/CoreFuzzyFile.swift", .file),      // camelCase boundaries C-F-F
            ("Sources/cff_helper.swift", .file),         // basename prefix cff_
            ("Sources/cff.swift", .file),                // exact basename stem cff
            ("Sources/cff", .file),                      // exact basename match cff
        ])

        let results = await index.search(root: "/repo", query: "cff", options: .init(kind: .file, limit: 10))
        let ranked = results.map(\.relativePath)

        #expect(ranked == [
            "Sources/cff",
            "Sources/cff.swift",
            "Sources/cff_helper.swift",
            "Sources/CoreFuzzyFile.swift",
            "Sources/craft_stuff.swift",
        ])

        // Verify strictly descending scores across every tier.
        for i in 0..<(results.count - 1) {
            #expect(results[i].fuzzyScore > results[i + 1].fuzzyScore)
        }
    }

    @Test("Fuzzy ranking honors snake_case, kebab-case, path-separator, consecutive, and shorter-path bonuses")
    func fuzzyBoundariesAndTieBreaking() async throws {
        let index = CoreFuzzyFileIndex(fileSystem: InMemoryFileSystem())
        index.seed(root: "/repo", entries: [
            ("src/deep/nested/folder/App.swift", .file),
            ("src/App.swift", .file),
            ("src/foo_bar_baz.swift", .file),
            ("src/kebab-case-router.ts", .file),
            ("src/f_a_o_b_o_c/foo.swift", .file),
            ("src/f_o_o_scattered.swift", .file),
        ])

        // Shorter path wins ties for identical basename.
        let appResults = await index.search(root: "/repo", query: "App", options: .init(kind: .file, limit: 10))
        #expect(appResults.first?.relativePath == "src/App.swift")
        #expect(appResults.count == 2)
        #expect(appResults[0].fuzzyScore > appResults[1].fuzzyScore)

        // Consecutive match after path separator beats scattered earlier match.
        let fooResults = await index.search(root: "/repo", query: "foo", options: .init(kind: .file, limit: 10))
        let fooExactIdx = fooResults.firstIndex(where: { $0.relativePath == "src/f_a_o_b_o_c/foo.swift" })
        let fooScatteredIdx = fooResults.firstIndex(where: { $0.relativePath == "src/f_o_o_scattered.swift" })
        #expect(fooExactIdx != nil && fooScatteredIdx != nil)
        if let e = fooExactIdx, let s = fooScatteredIdx {
            #expect(e < s)
        }

        // snake_case & kebab-case boundary matching
        let snake = try #require(CoreFuzzyFileIndex.Matcher.score(query: "fbb", candidate: "src/foo_bar_baz.swift"))
        #expect(snake.matchedIndices == [4, 8, 12])

        let kebab = try #require(CoreFuzzyFileIndex.Matcher.score(query: "kcr", candidate: "src/kebab-case-router.ts"))
        #expect(kebab.matchedIndices == [4, 10, 15])
    }

    @Test("Multi-token space-separated queries match across path segments and produce sorted unique indices")
    func multiTokenQuery() async {
        let index = CoreFuzzyFileIndex(fileSystem: InMemoryFileSystem())
        index.seed(root: "/repo", entries: [
            ("Sources/OpenCodeCore/Runtime/CoreFuzzyFileIndex.swift", .file),
            ("Sources/OpenCodeUtil/Encode.swift", .file),
        ])

        let results = await index.search(root: "/repo", query: "runtime index", options: .init(kind: .file, limit: 10))
        #expect(results.count == 1)
        let match = results[0]
        #expect(match.relativePath == "Sources/OpenCodeCore/Runtime/CoreFuzzyFileIndex.swift")
        // Verify strictly increasing, unique highlight positions.
        for i in 0..<(match.matchedIndices.count - 1) {
            #expect(match.matchedIndices[i] < match.matchedIndices[i + 1])
        }
        let highlighted = Self.extractUTF16MatchedString(match.relativePath, indices: match.matchedIndices)
        #expect(highlighted.lowercased() == "runtimeindex")
    }

    // MARK: - 3. Match Highlight UTF-16 Index Accuracy (ASCII & Unicode / Emoji)

    @Test("Matched UTF-16 character index positions are exact for ASCII, accented, CJK, and emoji surrogate pairs")
    func utf16HighlightIndices() throws {
        // ASCII camelCase highlight indices
        let asciiPath = "Sources/CoreFuzzyFileIndex.swift"
        let asciiMatch = try #require(CoreFuzzyFileIndex.Matcher.score(query: "cff", candidate: asciiPath))
        // C=8, F=12, F=17
        #expect(asciiMatch.matchedIndices == [8, 12, 17])
        #expect(Self.extractUTF16MatchedString(asciiPath, indices: asciiMatch.matchedIndices) == "CFF")

        // Single character match picks basename start over earlier lowercase occurrence
        let singleMatch = try #require(CoreFuzzyFileIndex.Matcher.score(query: "r", candidate: "src/Router.swift"))
        #expect(singleMatch.matchedIndices == [4])
        #expect(Self.extractUTF16MatchedString("src/Router.swift", indices: singleMatch.matchedIndices) == "R")

        // Accented BMP + emoji surrogate pair (🚀 occupies 2 UTF-16 code units: indices 10 and 11)
        let emojiPath = "docs/café_🚀_guide.md"
        // d(0)o(1)c(2)s(3)/(4)c(5)a(6)f(7)é(8)_(9)🚀(10,11)_(12)g(13)u(14)i(15)d(16)e(17).(18)m(19)d(20)
        let guideMatch = try #require(CoreFuzzyFileIndex.Matcher.score(query: "guide", candidate: emojiPath))
        #expect(guideMatch.matchedIndices == [13, 14, 15, 16, 17])
        #expect(Self.extractUTF16MatchedString(emojiPath, indices: guideMatch.matchedIndices) == "guide")

        let accentMatch = try #require(CoreFuzzyFileIndex.Matcher.score(query: "É", candidate: emojiPath))
        #expect(accentMatch.matchedIndices == [8])
        #expect(Self.extractUTF16MatchedString(emojiPath, indices: accentMatch.matchedIndices) == "é")

        let rocketMatch = try #require(CoreFuzzyFileIndex.Matcher.score(query: "🚀", candidate: emojiPath))
        #expect(rocketMatch.matchedIndices == [10, 11])
        #expect(Self.extractUTF16MatchedString(emojiPath, indices: rocketMatch.matchedIndices) == "🚀")

        // CJK path
        let cjkPath = "i18n/日本語_messages.json"
        let cjkMatch = try #require(CoreFuzzyFileIndex.Matcher.score(query: "日本語", candidate: cjkPath))
        #expect(cjkMatch.matchedIndices == [5, 6, 7])
        #expect(Self.extractUTF16MatchedString(cjkPath, indices: cjkMatch.matchedIndices) == "日本語")
    }

    // MARK: - 4. Frecency Decay & TUI-Compatible JSONL Persistence

    @Test("Frecency exponential time-decay boosts recently and frequently accessed files")
    func frecencyBoostsAndExponentialDecay() async {
        let dayMs: Int64 = 86_400_000
        let baseNow: Int64 = 1_750_000_000_000
        let clock = AdjustableClock(baseNow)

        let index = CoreFuzzyFileIndex(
            fileSystem: InMemoryFileSystem(),
            configuration: .init(frecencyHalfLifeDays: 7.0, frecencyBoostScale: 45.0),
            nowMs: { clock.now() }
        )

        index.seed(root: "/repo", entries: [
            ("Sources/Alpha/Router.swift", .file),
            ("Sources/Bravo/Router.swift", .file),
            ("Sources/Delta/Router.swift", .file),
        ])

        // Record 5 accesses on Bravo 14 days ago (2 half-lives -> decayed score = 5 * 0.25 = 1.25)
        for _ in 0..<5 {
            index.recordAccess(path: "/repo/Sources/Bravo/Router.swift", at: baseNow - 14 * dayMs)
        }
        // Record 5 accesses on Delta right now (0 days -> decayed score = 5.0)
        for _ in 0..<5 {
            index.recordAccess(path: "Sources/Delta/Router.swift", at: baseNow, root: "/repo")
        }

        // Verify exact exponential half-life decay calculation.
        let deltaScore = index.frecencyScore(for: "Sources/Delta/Router.swift", at: baseNow, root: "/repo")
        let bravoScore = index.frecencyScore(for: "Sources/Bravo/Router.swift", at: baseNow, root: "/repo")
        let deltaAfterOneHalfLife = index.frecencyScore(for: "Sources/Delta/Router.swift", at: baseNow + 7 * dayMs, root: "/repo")
        #expect(abs(deltaScore - 5.0) < 1e-9)
        #expect(abs(bravoScore - 1.25) < 1e-9)
        #expect(abs(deltaAfterOneHalfLife - 2.5) < 1e-9)

        // All 3 paths have identical fuzzy scores for "Router"; frecency must rank Delta > Bravo > Alpha.
        let fuzzyResults = await index.search(root: "/repo", query: "Router", options: .init(kind: .file, limit: 10))
        #expect(fuzzyResults.map(\.relativePath) == [
            "Sources/Delta/Router.swift",
            "Sources/Bravo/Router.swift",
            "Sources/Alpha/Router.swift",
        ])
        #expect(fuzzyResults[0].frecencyBoost > fuzzyResults[1].frecencyBoost)
        #expect(fuzzyResults[1].frecencyBoost > 0)
        #expect(fuzzyResults[2].frecencyBoost == 0)

        // Empty query ranks purely by decayed frecency.
        let emptyResults = await index.search(root: "/repo", query: "", options: .init(kind: .file, limit: 10))
        #expect(emptyResults.map(\.relativePath) == [
            "Sources/Delta/Router.swift",
            "Sources/Bravo/Router.swift",
            "Sources/Alpha/Router.swift",
        ])
    }

    @Test("Frecency JSONL save/load round-trips cleanly and matches TUI JSONL schema")
    func frecencyJSONLPersistence() async throws {
        let now: Int64 = 1_750_000_000_000
        let fs = InMemoryFileSystem()

        // Seed TUI-format JSONL with duplicate lines (last line wins) and a malformed line.
        let tuiJSONL = """
            {"path":"/repo/Sources/Hot.swift","frequency":1,"lastOpen":\(now - 10_000)}
            not-valid-json
            {"path":"/repo/Sources/Hot.swift","frequency":4,"lastOpen":\(now)}
            {"path":"/repo/Sources/Warm.swift","frequency":2,"lastOpen":\(now - 5_000)}
            """
        try await fs.writeFile(utf8(tuiJSONL), to: "/state/frecency.jsonl", createDirectories: true)

        let indexA = CoreFuzzyFileIndex(fileSystem: fs, nowMs: { now })
        let loaded = try await indexA.loadFrecency(from: "/state/frecency.jsonl")
        #expect(loaded == 2)
        #expect(abs(indexA.frecencyScore(for: "/repo/Sources/Hot.swift", at: now) - 4.0) < 1e-9)
        #expect(abs(indexA.frecencyScore(for: "/repo/Sources/Warm.swift", at: now - 5_000) - 2.0) < 1e-9)
        let warmNow = indexA.frecencyScore(for: "/repo/Sources/Warm.swift", at: now)
        #expect(warmNow < 2.0 && warmNow > 1.999)

        // Increment Hot and persist to a new JSONL file.
        indexA.recordAccess(path: "/repo/Sources/Hot.swift", at: now + 1_000)
        try await indexA.saveFrecency(to: "/state/frecency-saved.jsonl")

        // Reload in a fresh index and verify exact persistence.
        let indexB = CoreFuzzyFileIndex(fileSystem: fs, nowMs: { now + 1_000 })
        let reloaded = try await indexB.loadFrecency(from: "/state/frecency-saved.jsonl")
        #expect(reloaded == 2)
        #expect(abs(indexB.frecencyScore(for: "/repo/Sources/Hot.swift", at: now + 1_000) - 5.0) < 1e-9)

        // Missing file returns 0 gracefully.
        let missing = try await indexB.loadFrecency(from: "/state/does-not-exist.jsonl")
        #expect(missing == 0)
    }

    // MARK: - 5. Incremental Updates, Invalidation & Stale-While-Revalidate

    @Test("Incremental applyChange handles add, remove, and rename without full rescan")
    func incrementalUpdatesWithoutRescan() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/repo/.gitignore": utf8("*.log\n"),
            "/repo/Sources/Old.swift": utf8("struct Old {}\n"),
            "/repo/Sources/Feature/A.swift": utf8("struct A {}\n"),
            "/repo/Sources/Feature/B.swift": utf8("struct B {}\n"),
        ])

        let index = CoreFuzzyFileIndex(
            fileSystem: fs,
            configuration: .init(staleAfterMs: 60_000)
        )
        try await index.warm(root: "/repo")

        // Add single entry NOT present on fs — proves no rescan occurs.
        index.applyChange(path: "/repo/Sources/BrandNew/Widget.swift", kind: .add(kind: .file))
        // Add an ignored file — must respect cached .gitignore rules.
        index.applyChange(path: "/repo/Sources/debug.log", kind: .add(kind: .file))

        let addedSearch = await index.search(root: "/repo", query: "Widget", options: .init(kind: .file, limit: 10))
        #expect(addedSearch.map(\.relativePath) == ["Sources/BrandNew/Widget.swift"])
        let addedDir = await index.search(root: "/repo", query: "BrandNew", options: .init(kind: .directory, limit: 10))
        #expect(addedDir.map(\.relativePath) == ["Sources/BrandNew"])
        let ignoredSearch = await index.search(root: "/repo", query: "debug.log", options: .init(kind: .file, limit: 10))
        #expect(ignoredSearch.isEmpty)

        // Rename single file.
        index.applyChange(path: "Sources/Old.swift", kind: .rename(to: "Sources/Modern.swift"), root: "/repo")
        let oldAfterRename = await index.search(root: "/repo", query: "Old.swift", options: .init(kind: .file, limit: 10))
        #expect(oldAfterRename.isEmpty)
        let modernAfterRename = await index.search(root: "/repo", query: "Modern.swift", options: .init(kind: .file, limit: 10))
        #expect(modernAfterRename.map(\.relativePath) == ["Sources/Modern.swift"])

        // Rename directory moves all descendants.
        index.applyChange(path: "Sources/Feature", kind: .rename(to: "Sources/Module"), root: "/repo")
        let movedA = await index.search(root: "/repo", query: "Module/A.swift", options: .init(kind: .file, limit: 10))
        #expect(movedA.map(\.relativePath) == ["Sources/Module/A.swift"])
        let oldFeature = await index.search(root: "/repo", query: "Feature", options: .init(limit: 10))
        #expect(oldFeature.isEmpty)

        // Remove directory drops directory and all descendants.
        index.applyChange(path: "Sources/Module", kind: .remove, root: "/repo")
        let afterDirRemove = await index.search(root: "/repo", query: "Module", options: .init(limit: 10))
        #expect(afterDirRemove.isEmpty)
    }

    @Test("invalidate(root:) forces fresh rescan while stale-while-revalidate refreshes in background")
    func invalidationAndStaleWhileRevalidate() async throws {
        let clock = AdjustableClock(1_000_000)
        let fs = InMemoryFileSystem(initialFiles: [
            "/repo/Sources/Alpha.swift": utf8("struct Alpha {}\n"),
        ])

        let index = CoreFuzzyFileIndex(
            fileSystem: fs,
            configuration: .init(staleAfterMs: 5_000),
            nowMs: { clock.now() }
        )

        try await index.warm(root: "/repo")
        #expect(index.entryCount(root: "/repo") == 2) // Sources + Sources/Alpha.swift

        // Write a new file directly to fs while cache is stale.
        try await fs.writeFile(utf8("struct Beta {}\n"), to: "/repo/Sources/Beta.swift", createDirectories: true)
        clock.advance(by: 10_000) // exceeds staleAfterMs (5_000)

        // Stale-while-revalidate serves the cached snapshot immediately and kicks off background refresh.
        let staleResponse = await index.search(
            root: "/repo",
            query: "Beta",
            options: .init(kind: .file, limit: 10, staleWhileRevalidate: true)
        )
        #expect(staleResponse.isEmpty)

        // Wait for background revalidation to finish — next search sees Beta.swift!
        await index.waitForBackgroundRefresh(root: "/repo")
        let refreshedResponse = await index.search(
            root: "/repo",
            query: "Beta",
            options: .init(kind: .file, limit: 10, staleWhileRevalidate: true)
        )
        #expect(refreshedResponse.map(\.relativePath) == ["Sources/Beta.swift"])

        // Explicit invalidate drops snapshot so next search rescans synchronously before returning.
        try await fs.writeFile(utf8("struct Gamma {}\n"), to: "/repo/Sources/Gamma.swift", createDirectories: true)
        index.invalidate(root: "/repo")
        #expect(index.entryCount(root: "/repo") == 0)

        let afterInvalidate = await index.search(root: "/repo", query: "Gamma", options: .init(kind: .file, limit: 10))
        #expect(afterInvalidate.map(\.relativePath) == ["Sources/Gamma.swift"])
    }

    // MARK: - 6. CoreFilesystem.Search & CoreFilesystem.Fff Wiring

    @Test("CoreFilesystem.Search.FuzzyIndexedService, fuzzyIndexNode, and native Fff.Picker work end-to-end")
    func coreFilesystemSearchAndFffWiring() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/repo/.gitignore": utf8("*.log\n"),
            "/repo/Sources/Router.swift": utf8("struct Router {}\n"),
            "/repo/Sources/App.swift": utf8("struct App {}\n"),
            "/repo/Sources/debug.log": utf8("ignored"),
        ])

        // Direct FuzzyIndexedService (conforms to CoreFilesystem.Search.Interface)
        let searchService: any CoreFilesystem.Search.Interface = CoreFilesystem.Search.FuzzyIndexedService(
            directory: "/repo",
            fileSystem: fs
        )
        let files = await searchService.find(FileSystemSchema.FindInput(query: "rtr", type: .file))
        #expect(files.map(\.path.rawValue) == ["Sources/Router.swift"])
        #expect(files.map(\.type) == [.file])

        let dirs = await searchService.find(FileSystemSchema.FindInput(query: "src", type: .directory))
        #expect(dirs.map(\.path.rawValue) == ["Sources/"])
        #expect(dirs.map(\.type) == [.directory])

        let ignored = await searchService.find(FileSystemSchema.FindInput(query: "debug.log"))
        #expect(ignored.isEmpty)

        // LayerNode wiring via fuzzyIndexLayer
        let deps = LayerNode.Output([
            "@opencode/Location.directory": "/repo",
            FSUtil.Service.serviceKey: FSUtil.Service(fileSystem: fs),
        ])
        let out = try await CoreFilesystem.Search.fuzzyIndexLayer().build(deps, LayerNode.ResourceScope())
        let resolved = try #require(out.get(CoreFilesystem.Search.Service.serviceKey, as: (any CoreFilesystem.Search.Interface).self))
        let layerHits = await resolved.find(FileSystemSchema.FindInput(query: "app", type: .file))
        #expect(layerHits.map(\.path.rawValue) == ["Sources/App.swift"])

        // Native Fff.Backend & Fff.Picker wiring
        let sharedIndex = CoreFuzzyFileIndex(fileSystem: fs)
        try await sharedIndex.warm(root: "/repo")
        let adapter = CoreFilesystem.Fff.nativeAdapter(fileSystem: fs, index: sharedIndex)
        #expect(adapter.available() == true)
        guard case .ok(let picker) = adapter.create(CoreFilesystem.Fff.Init(basePath: "/repo")) else {
            Issue.record("Expected CoreFilesystem.Fff.nativeAdapter to create a picker")
            return
        }
        guard case .ok(let fileSearchRes) = picker.fileSearch("rtr", options: CoreFilesystem.Fff.SearchOptions(pageIndex: 0, pageSize: 10)) else {
            Issue.record("Expected picker.fileSearch to succeed")
            return
        }
        #expect(fileSearchRes.items.map(\.relativePath) == ["Sources/Router.swift"])
        #expect(fileSearchRes.scores.count == 1 && fileSearchRes.scores[0].total > 0)

        guard case .ok(let mixedRes) = picker.mixedSearch("", options: CoreFilesystem.Fff.SearchOptions(pageIndex: 0, pageSize: 10)) else {
            Issue.record("Expected picker.mixedSearch to succeed")
            return
        }
        #expect(mixedRes.items.count >= 3)

        // Also test nativeFffLayer via makeFffLayer
        let fffLayerOut = try await CoreFilesystem.Search.nativeFffLayer(fileSystem: fs, index: sharedIndex)
            .build(deps, LayerNode.ResourceScope())
        let fffResolved = try #require(
            fffLayerOut.get(CoreFilesystem.Search.Service.serviceKey, as: (any CoreFilesystem.Search.Interface).self)
        )
        let fffHits = await fffResolved.find(FileSystemSchema.FindInput(query: "rtr", type: .file))
        #expect(fffHits.map(\.path.rawValue) == ["Sources/Router.swift"])

        picker.destroy()
        if case .ok = picker.fileSearch("rtr", options: nil) {
            Issue.record("Expected destroyed picker to return error")
        }
    }

    // MARK: - 7. 10,000+ Path Performance Benchmark

    @Test("Scoring across 12,000 indexed paths completes cleanly in milliseconds with accurate ranking")
    func tenThousandPlusPerformance() async {
        let index = CoreFuzzyFileIndex(fileSystem: InMemoryFileSystem())

        var entries: [(path: String, kind: CoreFuzzyFileIndex.EntryKind)] = []
        entries.reserveCapacity(12_004)

        let modules = ["Core", "Server", "Client", "Platform", "Schema", "Protocol", "TUI", "CLI", "AI", "Util"]
        let layers = ["Runtime", "Handlers", "Models", "Services", "Store", "Transport"]
        for i in 0..<12_000 {
            let mod = modules[i % modules.count]
            let layer = layers[(i / modules.count) % layers.count]
            let bucket = i / 60
            let path = "Packages/OpenCode\(mod)/Sources/\(layer)/Group\(bucket)/Feature\(i)Controller.swift"
            entries.append((path, .file))
        }
        // Inject specific ranking targets among the 12,000 paths.
        entries.append(("Sources/OpenCodeCore/Runtime/CoreFuzzyFileIndex.swift", .file))
        entries.append(("Sources/cff.swift", .file))
        entries.append(("Sources/cff_bridge.swift", .file))
        entries.append(("Sources/craft_alpha_foo_beta_file.swift", .file))

        index.seed(root: "/mega-repo", entries: entries)
        #expect(index.entryCount(root: "/mega-repo") == 12_004)

        let clock = ContinuousClock()

        // Query 1: Specific camelCase query across 12,004 entries.
        let t1 = clock.now
        let fuzzyIndexResults = await index.search(
            root: "/mega-repo",
            query: "cffix",
            options: .init(kind: .file, limit: 25)
        )
        let elapsed1 = clock.now - t1

        #expect(fuzzyIndexResults.first?.relativePath == "Sources/OpenCodeCore/Runtime/CoreFuzzyFileIndex.swift")
        #expect(fuzzyIndexResults.first?.matchedIndices.count == 5)

        // Query 2: Ranking across 12,004 entries where many paths share letters 'c', 'f', 'f'.
        let t2 = clock.now
        let cffResults = await index.search(
            root: "/mega-repo",
            query: "cff",
            options: .init(kind: .file, limit: 25)
        )
        let elapsed2 = clock.now - t2

        #expect(cffResults.count >= 3)
        #expect(cffResults[0].relativePath == "Sources/cff.swift")
        #expect(cffResults[1].relativePath == "Sources/cff_bridge.swift")

        // Query 3: Specific numbered target out of 12,000 entries.
        let t3 = clock.now
        let numResults = await index.search(
            root: "/mega-repo",
            query: "f9876c",
            options: .init(kind: .file, limit: 10)
        )
        let elapsed3 = clock.now - t3

        #expect(numResults.first?.relativePath.hasSuffix("Feature9876Controller.swift") == true)

        // Assert sub-second (millisecond-class even under unoptimized debug test builds).
        let ms1 = Double(elapsed1.components.seconds) * 1_000.0 + Double(elapsed1.components.attoseconds) / 1e15
        let ms2 = Double(elapsed2.components.seconds) * 1_000.0 + Double(elapsed2.components.attoseconds) / 1e15
        let ms3 = Double(elapsed3.components.seconds) * 1_000.0 + Double(elapsed3.components.attoseconds) / 1e15
        #expect(ms1 < 250.0, "Query 'cffix' across 12,004 entries took \(ms1) ms")
        #expect(ms2 < 250.0, "Query 'cff' across 12,004 entries took \(ms2) ms")
        #expect(ms3 < 250.0, "Query 'f9876c' across 12,004 entries took \(ms3) ms")
    }

    // MARK: - 8. Concurrency, Hidden Policy, Pagination & Edge Cases

    @Test("includeHidden=false excludes dotfiles and IgnoreMatcher evaluates directory ancestors directly")
    func hiddenPolicyAndDirectIgnoreMatcher() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/repo/.env": utf8("SECRET=1\n"),
            "/repo/.github/ci.yml": utf8("name: CI\n"),
            "/repo/Sources/Visible.swift": utf8("struct Visible {}\n"),
        ])

        let index = CoreFuzzyFileIndex(
            fileSystem: fs,
            configuration: .init(includeHidden: false)
        )
        try await index.warm(root: "/repo")
        let files = await index.search(root: "/repo", query: "", options: .init(kind: .file, limit: 20))
        #expect(files.map(\.relativePath) == ["Sources/Visible.swift"])

        // Direct IgnoreMatcher checks ancestor directory rules and escaped trailing spaces.
        let rules = CoreFuzzyFileIndex.IgnoreMatcher.parse("build/\nspaced\\ \n")
        let matcher = CoreFuzzyFileIndex.IgnoreMatcher(rules: rules)
        #expect(matcher.isIgnored("build", isDirectory: true) == true)
        #expect(matcher.isIgnored("build", isDirectory: false) == false)
        #expect(matcher.isIgnored("build/nested/out.o", isDirectory: false) == true)
        #expect(matcher.isIgnored("spaced ", isDirectory: false) == true)
        #expect(matcher.isIgnored("spaced", isDirectory: false) == false)
    }

    @Test("Concurrent warm coalescing, concurrent searches, and synchronous revalidation option")
    func concurrentWarmAndSearches() async throws {
        let clock = AdjustableClock(1_000_000)
        let fs = InMemoryFileSystem(initialFiles: [
            "/repo/Sources/Alpha.swift": utf8("struct Alpha {}\n"),
            "/repo/Sources/Beta.swift": utf8("struct Beta {}\n"),
            "/repo/Sources/Gamma.swift": utf8("struct Gamma {}\n"),
        ])

        let index = CoreFuzzyFileIndex(
            fileSystem: fs,
            configuration: .init(staleAfterMs: 1_000),
            nowMs: { clock.now() }
        )

        // Coalesce 8 concurrent warm calls.
        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await index.warm(root: "/repo")
                }
            }
            var out: [Int] = []
            for try await c in group { out.append(c) }
            return out
        }
        #expect(counts.count == 8)
        #expect(counts.allSatisfy { $0 == 4 }) // Sources + 3 files

        // Run 16 concurrent searches safely.
        let queries = ["Alpha", "Beta", "Gamma", "swift"]
        let allHitCounts = await withTaskGroup(of: Int.self) { group in
            for i in 0..<16 {
                let q = queries[i % queries.count]
                group.addTask {
                    let res = await index.search(root: "/repo", query: q, options: .init(kind: .file, limit: 10))
                    return res.count
                }
            }
            var out: [Int] = []
            for await c in group { out.append(c) }
            return out
        }
        #expect(allHitCounts.allSatisfy { $0 >= 1 })

        // staleWhileRevalidate: false awaits fresh scan immediately when expired.
        try await fs.writeFile(utf8("struct Delta {}\n"), to: "/repo/Sources/Delta.swift", createDirectories: true)
        clock.advance(by: 5_000)
        let immediate = await index.search(
            root: "/repo",
            query: "Delta",
            options: .init(kind: .file, limit: 10, staleWhileRevalidate: false)
        )
        #expect(immediate.map(\.relativePath) == ["Sources/Delta.swift"])
    }

    @Test("Native Fff.Picker supports directorySearch and pageIndex/pageSize pagination")
    func nativeFffPickerPaginationAndDirectories() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/repo/Alpha/One.swift": utf8("1"),
            "/repo/Beta/Two.swift": utf8("2"),
            "/repo/Gamma/Three.swift": utf8("3"),
            "/repo/Delta/Four.swift": utf8("4"),
            "/repo/Epsilon/Five.swift": utf8("5"),
        ])

        let index = CoreFuzzyFileIndex(fileSystem: fs)
        try await index.warm(root: "/repo")

        let picker = CoreFilesystem.Fff.NativePicker(basePath: "/repo", index: index, ownsIndex: false)
        await picker.waitUntilReady()
        #expect(picker.isScanning() == false)

        guard case .ok(let page0) = picker.fileSearch("swift", options: CoreFilesystem.Fff.SearchOptions(pageIndex: 0, pageSize: 2)),
              case .ok(let page1) = picker.fileSearch("swift", options: CoreFilesystem.Fff.SearchOptions(pageIndex: 1, pageSize: 2)),
              case .ok(let page2) = picker.fileSearch("swift", options: CoreFilesystem.Fff.SearchOptions(pageIndex: 2, pageSize: 2))
        else {
            Issue.record("Expected paged fileSearch calls to succeed")
            return
        }

        #expect(page0.items.count == 2)
        #expect(page1.items.count == 2)
        #expect(page2.items.count == 1)
        let combined = Set((page0.items + page1.items + page2.items).map(\.relativePath))
        #expect(combined.count == 5)

        guard case .ok(let dirRes) = picker.directorySearch("ep", options: CoreFilesystem.Fff.SearchOptions(pageIndex: 0, pageSize: 5)) else {
            Issue.record("Expected directorySearch to succeed")
            return
        }
        #expect(dirRes.items.map(\.relativePath) == ["Epsilon"])

        // Verify fuzzyIndexNode provider metadata is a drop-in replacement for CoreFilesystem.Search.node.
        let node = CoreFilesystem.Search.fuzzyIndexNode(index: index)
        #expect(node.name == CoreFilesystem.Search.Service.serviceKey)
        let replacement = try CoreFilesystem.Search.node.replace(with: node)
        #expect(replacement.target.name == CoreFilesystem.Search.Service.serviceKey)
    }
}
