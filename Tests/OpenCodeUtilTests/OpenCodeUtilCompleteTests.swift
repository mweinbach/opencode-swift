import Synchronization
import Testing
import OpenCodeUtil

private struct TestCausalError: CausalError, Equatable, Sendable, CustomStringConvertible {
    let message: String
    let errorCode: String?
    let underlyingCause: (any Error)?

    init(_ message: String, code: String? = nil, cause: (any Error)? = nil) {
        self.message = message
        self.errorCode = code
        self.underlyingCause = cause
    }

    var description: String { message }

    static func == (lhs: TestCausalError, rhs: TestCausalError) -> Bool {
        lhs.message == rhs.message && lhs.errorCode == rhs.errorCode
    }
}

@Suite("OpenCodeUtil Complete Unit Tests")
struct OpenCodeUtilCompleteTests {

    // MARK: - Abort

    @Test("AbortController, AbortSignal, and abort() contract")
    func abortControllerAndSignal() {
        // abort(nil) is a safe no-op
        abort(nil)

        let controller = AbortController()
        #expect(!controller.signal.isAborted)
        #expect(controller.signal.reason == nil)

        let fired = Mutex<[Int]>([])
        controller.signal.onAbort { fired.withLock { $0.append(1) } }
        let removeSecond = controller.signal.onAbort { fired.withLock { $0.append(2) } }
        controller.signal.onAbort { fired.withLock { $0.append(3) } }
        removeSecond()

        abort(controller)
        #expect(controller.signal.isAborted)
        let reason = controller.signal.reason as? AbortError
        #expect(reason == AbortError.sharedReason)
        #expect(reason?.name == "AbortError")
        #expect(fired.withLock { $0 } == [1, 3])

        // Repeated aborts are idempotent and do not re-fire listeners
        controller.abort(reason: TestCausalError("later"))
        #expect(fired.withLock { $0 } == [1, 3])
        #expect((controller.signal.reason as? AbortError) == AbortError.sharedReason)

        // Listener registered after abort fires immediately
        controller.signal.onAbort { fired.withLock { $0.append(4) } }
        #expect(fired.withLock { $0 } == [1, 3, 4])

        // AbortSignal.aborted factory preserves custom reason
        let custom = TestCausalError("cancelled by user")
        let preAborted = AbortSignal.aborted(reason: custom)
        #expect(preAborted.isAborted)
        #expect((preAborted.reason as? TestCausalError) == custom)
    }

    // MARK: - Glob

    @Test("Glob.match handles wildcards, double-star, braces, char classes, extglobs, dot, and negation")
    func globMatchComprehensive() {
        // Basic & empty
        #expect(Glob.match("", filepath: ""))
        #expect(!Glob.match("", filepath: "a"))
        #expect(Glob.match("*.ts", filepath: "index.ts"))
        #expect(!Glob.match("*.ts", filepath: "src/index.ts"))
        #expect(Glob.match("file?.ts", filepath: "file1.ts"))
        #expect(!Glob.match("file?.ts", filepath: "file10.ts"))

        // Double-star globstar
        #expect(Glob.match("**/*.ts", filepath: "index.ts"))
        #expect(Glob.match("**/*.ts", filepath: "a/b/c/index.ts"))
        #expect(Glob.match("src/**/test/*.swift", filepath: "src/test/a.swift"))
        #expect(Glob.match("src/**/test/*.swift", filepath: "src/x/y/test/a.swift"))
        #expect(Glob.match("**/{node_modules,.git}/**", filepath: "a/node_modules/pkg/index.js"))
        #expect(Glob.match("**/{node_modules,.git}/**", filepath: ".git/config"))

        // Braces (top-level, nested, and literal single)
        #expect(Glob.match("src/*.{ts,tsx}", filepath: "src/app.tsx"))
        #expect(!Glob.match("src/*.{ts,tsx}", filepath: "src/app.js"))
        #expect(Glob.match("{a,{b,c}}.txt", filepath: "c.txt"))
        #expect(Glob.match("{single}.txt", filepath: "{single}.txt"))

        // Character classes & negated ranges
        #expect(Glob.match("file[0-9].txt", filepath: "file5.txt"))
        #expect(!Glob.match("file[0-9].txt", filepath: "filea.txt"))
        #expect(Glob.match("file[!0-9].txt", filepath: "filea.txt"))
        #expect(!Glob.match("file[!0-9].txt", filepath: "file5.txt"))
        #expect(Glob.match("file[^a-z].txt", filepath: "file9.txt"))

        // Extglobs: @(...), ?(...), *(...), +(...), !(...)
        #expect(Glob.match("@(foo|bar).ts", filepath: "foo.ts"))
        #expect(Glob.match("@(foo|bar).ts", filepath: "bar.ts"))
        #expect(!Glob.match("@(foo|bar).ts", filepath: "baz.ts"))

        #expect(Glob.match("a?(foo|bar)b", filepath: "ab"))
        #expect(Glob.match("a?(foo|bar)b", filepath: "afoob"))
        #expect(!Glob.match("a?(foo|bar)b", filepath: "afoobarb"))

        #expect(Glob.match("*(foo|bar)", filepath: ""))
        #expect(Glob.match("*(foo|bar)", filepath: "foobarfoo"))
        #expect(!Glob.match("*(foo|bar)b", filepath: ""))
        #expect(Glob.match("*(a)b", filepath: "aaab"))

        #expect(!Glob.match("+(foo|bar)", filepath: ""))
        #expect(Glob.match("+(foo|bar)", filepath: "foo"))
        #expect(Glob.match("+(foo|bar)", filepath: "barfoo"))
        #expect(!Glob.match("+(foo|bar)", filepath: "baz"))

        #expect(Glob.match("!(foo|bar).ts", filepath: "baz.ts"))
        #expect(!Glob.match("!(foo|bar).ts", filepath: "foo.ts"))

        // Dotfile handling
        #expect(Glob.match("*", filepath: ".env", dot: true))
        #expect(!Glob.match("*", filepath: ".env", dot: false))
        #expect(Glob.match(".*", filepath: ".env", dot: false))
        #expect(!Glob.match("**/*.json", filepath: ".hidden/a.json", dot: false))
        #expect(Glob.match("**/*.json", filepath: ".hidden/a.json", dot: true))

        // Pattern negation & normalization
        #expect(Glob.match("!*.md", filepath: "src/app.ts"))
        #expect(!Glob.match("!*.md", filepath: "README.md"))
        #expect(Glob.match("!!*.md", filepath: "README.md"))
        #expect(Glob.match("src/*.ts", filepath: "./src\\app.ts"))
        #expect(Glob.match("a\\*b", filepath: "a*b"))
        #expect(!Glob.match("a\\*b", filepath: "axb"))
    }

    @Test("Glob.scan filters directories, dotfiles, ignores, and returns relative or absolute paths")
    func globScanFiltering() async throws {
        let entries: [GlobFileEntry] = [
            GlobFileEntry(relativePath: "src", absolutePath: "/repo/src", isDirectory: true),
            GlobFileEntry(relativePath: "src/a.ts", absolutePath: "/repo/src/a.ts", isDirectory: false),
            GlobFileEntry(relativePath: "src/.secret.ts", absolutePath: "/repo/src/.secret.ts", isDirectory: false),
            GlobFileEntry(relativePath: "node_modules/pkg/index.ts", absolutePath: "/repo/node_modules/pkg/index.ts", isDirectory: false),
            GlobFileEntry(relativePath: "README.md", absolutePath: "/repo/README.md", isDirectory: false),
        ]

        let defaultFiles = try await Glob.scan("**/*.ts", options: Glob.Options(ignore: ["node_modules/**"])) { _ in entries }
        #expect(defaultFiles == ["src/a.ts"])

        let withDotAndAbs = try await Glob.scan(
            "**/*.ts",
            options: Glob.Options(absolute: true, dot: true, ignore: ["node_modules/**"])
        ) { _ in entries }
        #expect(withDotAndAbs == ["/repo/src/a.ts", "/repo/src/.secret.ts"])

        let withDirs = try await Glob.scan("*", options: Glob.Options(include: .all)) { _ in entries }
        #expect(withDirs == ["src", "README.md"])
    }

    // MARK: - NpmSpec

    @Test("NpmSpec sanitize, isRegistryPackage, isInstallablePackage, parse, cacheKey, and InstallFailedError")
    func npmSpecComprehensive() {
        // sanitize: POSIX vs Windows
        let gitSpec = "acme@git+https://github.com/opencode/acme.git"
        #expect(NpmSpec.sanitize(gitSpec, isWindows: false) == gitSpec)
        #expect(NpmSpec.sanitize(gitSpec, isWindows: true) == "acme@git+https_//github.com/opencode/acme.git")
        #expect(NpmSpec.sanitize("a<b>c:d\"e|f?g*h\u{01}\u{1F}", isWindows: true) == "a_b_c_d_e_f_g_h__")

        // isRegistryPackage
        #expect(NpmSpec.isRegistryPackage("plugin"))
        #expect(NpmSpec.isRegistryPackage("@acme/plugin@beta"))
        #expect(NpmSpec.isRegistryPackage("plugin@^1.2.0"))
        #expect(NpmSpec.isRegistryPackage("@opencode/acme@1.0.0"))
        #expect(!NpmSpec.isRegistryPackage("./plugin"))
        #expect(!NpmSpec.isRegistryPackage("file:./plugin"))
        #expect(!NpmSpec.isRegistryPackage("github:acme/plugin"))
        #expect(!NpmSpec.isRegistryPackage("alias@npm:plugin@1.0.0"))
        #expect(!NpmSpec.isRegistryPackage("https://example.com/plugin.tgz"))
        #expect(!NpmSpec.isRegistryPackage(""))
        #expect(!NpmSpec.isRegistryPackage("  plugin  "))

        // isInstallablePackage
        #expect(NpmSpec.isInstallablePackage("plugin@^1.2.0"))
        #expect(NpmSpec.isInstallablePackage("github:acme/plugin#main"))
        #expect(NpmSpec.isInstallablePackage("git+ssh://git@github.com/acme/plugin.git#main"))
        #expect(NpmSpec.isInstallablePackage("git@github.com:acme/plugin.git"))
        #expect(NpmSpec.isInstallablePackage("git+https://github.com/acme/plugins.git#0123456789abcdef0123456789abcdef01234567"))
        #expect(NpmSpec.isInstallablePackage("acme/plugin"))
        #expect(NpmSpec.isInstallablePackage("https://github.com/acme/plugin"))
        #expect(!NpmSpec.isInstallablePackage("./plugin"))
        #expect(!NpmSpec.isInstallablePackage("https://example.com/plugin.tgz"))
        #expect(!NpmSpec.isInstallablePackage("alias@npm:plugin@1.0.0"))

        // parse mutability semantics
        #expect(NpmSpec.parse("@opencode/acme@1.0.0") == .registry(name: "@opencode/acme", spec: "1.0.0", mutable: false))
        #expect(NpmSpec.parse("@opencode/acme@^1.0.0") == .registry(name: "@opencode/acme", spec: "^1.0.0", mutable: true))
        #expect(NpmSpec.parse("plugin") == .registry(name: "plugin", spec: "latest", mutable: true))
        #expect(
            NpmSpec.parse("github:acme/plugin#0123456789abcdef")
                == .git(name: nil, slug: "plugin", mutable: false)
        )
        #expect(
            NpmSpec.parse("my-pkg@github:acme/plugin#main")
                == .git(name: "my-pkg", slug: "plugin", mutable: true)
        )

        // cacheKey for registry + git specs
        #expect(NpmSpec.cacheKey("@opencode/acme@1.0.0", isWindows: false) == "@opencode/acme@1.0.0")
        #expect(NpmSpec.cacheKey("plugin", isWindows: false) == "plugin@latest")
        #expect(NpmSpec.cacheKey("@opencode/acme", isWindows: false) == "@opencode/acme@latest")

        let sshSpec = "git+ssh://git@github.com/acme/plugin.git#main"
        let expectedDigest = String(Hash.sha256(sshSpec).prefix(12))
        #expect(NpmSpec.cacheKey(sshSpec) == "git-plugin-\(expectedDigest)")
        #expect(NpmSpec.cacheKey("\(sshSpec)-other") != NpmSpec.cacheKey(sshSpec))
        #expect(NpmSpec.gitSlug("https://example.com/my%20repo.git#v1") == "my-repo")
        #expect(NpmSpec.gitSlug("https://example.com/---.git") == "repository")

        // InstallFailedError message formatting
        let errNoCause = NpmSpec.InstallFailedError(add: ["a", "b"], dir: "/cache")
        #expect(errNoCause.message == "Failed to install a, b")
        let errDirFallback = NpmSpec.InstallFailedError(add: nil, dir: "/cache", causeMessage: "boom")
        #expect(errDirFallback.message == "Failed to install /cache: boom")
        let errStderr = NpmSpec.InstallFailedError(add: ["pkg"], dir: "/cache", causeMessage: "git failed", causeStderr: "  fatal: repo not found \n")
        #expect(errStderr.message == "Failed to install pkg: git failed\nfatal: repo not found")
    }

    // MARK: - Retry

    @Test("Retry backs off exponentially, traverses transient cause chain up to depth 5, and stops on non-transient errors")
    func retryBehavior() async throws {
        // Exponential backoff capped at maxDelay
        let delays = Mutex<[Int]>([])
        let attempts = Mutex(0)
        let result = try await retry(
            options: RetryOptions(attempts: 4, delay: 100, factor: 2.0, maxDelay: 250),
            sleep: { ms in delays.withLock { $0.append(ms) } }
        ) {
            let n = attempts.withLock { count -> Int in
                count += 1
                return count
            }
            if n < 4 {
                throw TestCausalError("Failed to fetch")
            }
            return "ready"
        }
        #expect(result == "ready")
        #expect(attempts.withLock { $0 } == 4)
        #expect(delays.withLock { $0 } == [100, 200, 250])

        // Transient cause chain depth: depth 5 succeeds, depth 6 does not
        let leaf = TestCausalError("inner", code: "ECONNRESET")
        let d1 = TestCausalError("w1", cause: leaf)
        let d2 = TestCausalError("w2", cause: d1)
        let d3 = TestCausalError("w3", cause: d2)
        let d4 = TestCausalError("w4", cause: d3)
        let d5 = TestCausalError("w5", cause: d4)
        let d6 = TestCausalError("w6", cause: d5)
        #expect(isTransientError(leaf))
        #expect(isTransientError(d5))
        #expect(!isTransientError(d6))
        #expect(!isTransientError(nil))

        // Non-transient error fails immediately on attempt 1
        let nonTransientCalls = Mutex(0)
        await #expect(throws: TestCausalError.self) {
            _ = try await retry(
                options: RetryOptions(attempts: 3, delay: 10),
                sleep: { _ in }
            ) { () async throws -> String in
                nonTransientCalls.withLock { $0 += 1 }
                throw TestCausalError("Transport", cause: TestCausalError("invalid response"))
            }
        }
        #expect(nonTransientCalls.withLock { $0 } == 1)

        // Custom retryIf overrides default transient check
        let customCalls = Mutex(0)
        await #expect(throws: TestCausalError.self) {
            _ = try await retry(
                options: RetryOptions(attempts: 2, delay: 0, retryIf: { _ in true }),
                sleep: { _ in }
            ) { () async throws -> String in
                customCalls.withLock { $0 += 1 }
                throw TestCausalError("retry me")
            }
        }
        #expect(customCalls.withLock { $0 } == 2)
    }

    // MARK: - Record

    @Test("isRecord narrows dictionaries and JSON objects while excluding primitives, arrays, and nil")
    func recordNarrowing() {
        #expect(isRecord(["a": 1] as [String: Any]))
        #expect(isRecord(["a": AnySendableValue.int(1)]))
        #expect(isRecord(PureJSONValue.object([("k", .string("v"))])))
        #expect(!isRecord(nil))
        #expect(!isRecord([1, 2, 3]))
        #expect(!isRecord("hello"))
        #expect(!isRecord(42))
        #expect(!isRecord(true))
        #expect(!isRecord(PureJSONValue.array([])))
        #expect(!isRecord(PureJSONValue.null))
        #expect(!isRecord(PureJSONValue.string("x")))
        #expect(!isRecord(PureJSONValue.number(1)))

        #expect(AnySendableValue.object(["x": .bool(true)]).isRecordValue)
        #expect(!AnySendableValue.array([]).isRecordValue)
        #expect(!AnySendableValue.null.isRecordValue)
    }

    // MARK: - ActivityCalendar TimeZone + FSPathUtil Windows + Patch Errors

    @Test("ActivityCalendar supports caller timezone offsets and FSPathUtil converts Windows drive prefixes")
    func calendarTimeZoneAndWindowsPaths() {
        // 2026-06-15T01:00:00Z is 2026-06-14 in UTC-5 (-18000s)
        let utcMs: Int64 = 1_781_485_200_000
        let res = activityCalendar(
            ActivityCalendarInput(
                activity: [ActivityDayInput(date: "2026-06-14", steps: 3)],
                from: utcMs,
                to: utcMs + 1_000,
                maxWeeks: 53
            ),
            timeZoneOffsetSeconds: { _ in -5 * 3600 }
        )
        #expect(res.weeks.count == 1)
        let active = res.weeks[0].filter { $0.level >= 0 }
        #expect(active == [ActivityCalendarCell(date: "2026-06-14", steps: 3, level: 4)])

        // FSPathUtil.windowsPath on Windows vs POSIX
        #expect(FSPathUtil.windowsPath("/c/Users/dev", isWindows: true) == "C:/Users/dev")
        #expect(FSPathUtil.windowsPath("/c", isWindows: true) == "C:/")
        #expect(FSPathUtil.windowsPath("/d:/work/repo", isWindows: true) == "D:/work/repo")
        #expect(FSPathUtil.windowsPath("/d:\\work\\repo", isWindows: true) == "D:/work\\repo")
        #expect(FSPathUtil.windowsPath("/d:", isWindows: true) == "D:/")
        #expect(FSPathUtil.windowsPath("/cygdrive/e/proj", isWindows: true) == "E:/proj")
        #expect(FSPathUtil.windowsPath("/cygdrive/e", isWindows: true) == "E:/")
        #expect(FSPathUtil.windowsPath("/mnt/f/code", isWindows: true) == "F:/code")
        #expect(FSPathUtil.windowsPath("/mnt/f", isWindows: true) == "F:/")
        #expect(FSPathUtil.windowsPath("/usr/local/bin", isWindows: true) == "/usr/local/bin")
        #expect(FSPathUtil.windowsPath("/c/Users/dev", isWindows: false) == "/c/Users/dev")

        // FSPathUtil mimeType, ignoreGlobs, FileSystemError
        #expect(FSPathUtil.mimeType("dir/file.json") == "application/json")
        #expect(FSPathUtil.mimeType("dir/photo.PNG") == "image/png")
        #expect(FSPathUtil.mimeType(".gitignore") == "application/octet-stream")
        #expect(FSPathUtil.mimeType("unknown.xyz123") == "application/octet-stream")
        #expect(FSPathUtil.ignoredDirectories == ["node_modules", ".git", ".venv", "venv", "__pycache__"])
        #expect(FSPathUtil.ignoreGlobs.last == "**/{node_modules,.git,.venv,venv,__pycache__}/**")
        #expect(FSPathUtil.FileSystemError(method: "readJson", detail: "bad json").message == "Filesystem operation failed: readJson: bad json")
        #expect(FSPathUtil.FileSystemError(method: "stat").message == "Filesystem operation failed: stat")

        // Patch.derive exact error messages
        do {
            _ = try Patch.derive(path: "u.txt", chunks: [Patch.UpdateFileChunk(oldLines: ["", ""], newLines: ["x"])], original: "a\n")
            Issue.record("Expected DeriveError")
        } catch let err as Patch.DeriveError {
            #expect(err.message == "Failed to find 2 consecutive blank lines in u.txt")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // PureJSON compact stringify & invalid JSON rejection
        #expect(PureJSON.stringifyCompact(.object([("b", .number(1)), ("0", .string("z"))])) == "{\"0\":\"z\",\"b\":1}")
        #expect(PureJSON.parse("{\"a\":1} trailing") == nil)
        #expect(PureJSON.parse("\"unterminated") == nil)
    }
}

// MARK: - Serialized Suites for Process-Global State (Teardown, LayerNode, ObservabilityShared)

@Suite("OpenCodeUtil Stateful Runtime Tests", .serialized)
struct OpenCodeUtilStatefulTests {

    @Test("Teardown tracks pending entries oldest-first and settles them cleanly")
    func teardownTracking() {
        let prefix = "teardown-unit:"
        let settleA = Teardown.track("\(prefix)first", now: 1_000)
        let settleB = Teardown.track("\(prefix)second", now: 1_250)
        let settleC = Teardown.track("\(prefix)first", now: 1_400)

        let snap1 = Teardown.pending(now: 2_000).filter { $0.label.hasPrefix(prefix) }
        #expect(snap1 == [
            Teardown.PendingEntry(label: "\(prefix)first", ms: 1_000),
            Teardown.PendingEntry(label: "\(prefix)second", ms: 750),
            Teardown.PendingEntry(label: "\(prefix)first", ms: 600),
        ])

        settleA()
        settleA() // idempotent
        let snap2 = Teardown.pending(now: 2_000).filter { $0.label.hasPrefix(prefix) }
        #expect(snap2 == [
            Teardown.PendingEntry(label: "\(prefix)second", ms: 750),
            Teardown.PendingEntry(label: "\(prefix)first", ms: 600),
        ])

        settleB()
        settleC()
        let snap3 = Teardown.pending(now: 2_000).filter { $0.label.hasPrefix(prefix) }
        #expect(snap3.isEmpty)
    }

    @Test("ObservabilityShared.runID lazily generates, caches, and resets an 8-char UUID prefix")
    func observabilitySharedRunID() {
        ObservabilityShared.resetRunID()
        let first = ObservabilityShared.runID()
        let second = ObservabilityShared.runID()
        #expect(first.count == 8)
        #expect(first == second)
        #expect(first.allSatisfy { ch in
            (ch >= "0" && ch <= "9") || (ch >= "a" && ch <= "f")
        })

        ObservabilityShared.resetRunID()
        let next = ObservabilityShared.runID()
        #expect(next.count == 8)
    }

    @Test("LayerNode tags, replacements, mapLayer, cycles, unbound errors, shared vs local memoization, and Teardown tracking")
    func layerNodeComprehensive() async throws {
        let tags = LayerNode.tags(["location": ["global"], "global": []])
        let makeGlobal = tags.make("global")
        let makeLocation = tags.make("location")

        let globalBuilds = Mutex(0)
        let locationBuilds = Mutex(0)

        let globalNode = makeGlobal(
            "GlobalConfig",
            LayerNode.ExecutableLayer { _, _ in
                let count = globalBuilds.withLock { c -> Int in c += 1; return c }
                return LayerNode.Output(["config": "v\(count)"])
            },
            []
        )

        let locationNode = makeLocation(
            "LocationService",
            LayerNode.ExecutableLayer { deps, _ in
                let count = locationBuilds.withLock { c -> Int in c += 1; return c }
                let cfg = deps.get("config", as: String.self) ?? "missing"
                return LayerNode.Output(["loc": "\(cfg)#\(count)"])
            },
            [globalNode]
        )

        // Shared vs local memoization across two builds with the same MemoMap
        let compiled = try LayerNode.compile(
            LayerNode.group([locationNode]),
            options: LayerNode.CompileOptions(shared: tags.values["global"])
        )
        let sharedMemo = LayerNode.MemoMap()
        let out1 = try await compiled.build(memoMap: sharedMemo)
        let out2 = try await compiled.build(memoMap: sharedMemo)
        #expect(out1.get("loc", as: String.self) == "v1#1")
        #expect(out2.get("loc", as: String.self) == "v1#2")
        // Transitive dependency is hidden from root output
        #expect(out1.get("config", as: String.self) == nil)
        #expect(globalBuilds.withLock { $0 } == 1)
        #expect(locationBuilds.withLock { $0 } == 2)

        // Replacement with ExecutableLayer and replacement chains
        let replaced = try LayerNode.compile(
            locationNode,
            options: LayerNode.CompileOptions(replacements: [
                globalNode.replace(with: LayerNode.ExecutableLayer.succeed(key: "config", value: "override")),
            ])
        )
        let replacedOut = try await replaced.build()
        #expect(replacedOut.get("loc", as: String.self) == "override#3")

        // Cross-tag replacement throws
        #expect(throws: LayerNode.GraphError("Cannot replace GlobalConfig across tags")) {
            _ = try globalNode.replace(with: locationNode)
        }

        // mapLayer preserves dependency wiring and tag
        let decorated = try locationNode.mapLayer { inner in
            LayerNode.ExecutableLayer { deps, scope in
                let base = try await inner.build(deps, scope)
                let orig = base.get("loc", as: String.self) ?? ""
                return LayerNode.Output(["loc": "decorated:\(orig)"])
            }
        }
        #expect(decorated.tag == tags.values["location"])
        let decOut = try await LayerNode.compile(
            decorated,
            options: LayerNode.CompileOptions(replacements: [
                globalNode.replace(with: LayerNode.ExecutableLayer.succeed(key: "config", value: "cfg")),
            ])
        ).build()
        #expect(decOut.get("loc", as: String.self) == "decorated:cfg#4")

        // Unbound node fails compilation unless replaced
        let unboundNode = LayerNode.unbound(name: "SecretStore", tag: tags.values["global"]!)
        let consumer = makeLocation(
            "Consumer",
            LayerNode.ExecutableLayer { deps, _ in
                LayerNode.Output(["secret": deps.get("secret", as: String.self) ?? ""])
            },
            [unboundNode]
        )
        #expect(throws: LayerNode.GraphError("Unbound layer node: SecretStore")) {
            _ = try LayerNode.compile(consumer)
        }
        let boundOut = try await LayerNode.compile(
            consumer,
            options: LayerNode.CompileOptions(replacements: [
                unboundNode.replace(with: LayerNode.ExecutableLayer.succeed(key: "secret", value: "shh")),
            ])
        ).build()
        #expect(boundOut.get("secret", as: String.self) == "shh")

        // Cycle detection in replacements
        let nodeA = makeGlobal("NodeA", LayerNode.ExecutableLayer.empty, [])
        let nodeB = makeGlobal("NodeB", LayerNode.ExecutableLayer.empty, [])
        do {
            _ = try LayerNode.compile(
                nodeA,
                options: LayerNode.CompileOptions(replacements: [
                    try nodeA.replace(with: nodeB),
                    try nodeB.replace(with: nodeA),
                ])
            )
            Issue.record("Expected cycle error")
        } catch let err as LayerNode.GraphError {
            #expect(err.message.contains("Cycle detected in layer graph"))
        }

        // Duplicate implementation wired to different dependencies throws
        let sharedImpl = LayerNode.ExecutableLayer.empty
        let dep1 = LayerNode.make(name: "Dep1", layer: LayerNode.ExecutableLayer.empty)
        let dep2 = LayerNode.make(name: "Dep2", layer: LayerNode.ExecutableLayer.empty)
        let dup1 = LayerNode.make(name: "Dup", layer: sharedImpl, deps: [dep1])
        let dup2 = LayerNode.make(name: "Dup", layer: sharedImpl, deps: [dep2])
        do {
            _ = try LayerNode.compile(LayerNode.group([dup1, dup2]))
            Issue.record("Expected mismatched-dependencies error")
        } catch let err as LayerNode.GraphError {
            #expect(err.message.contains("wired to different dependencies"))
        }

        // Teardown tracking brackets node finalizer execution on scope.close()
        let seenDuringClose = Mutex<[String]>([])
        let trackedNode = LayerNode.make(
            name: "TrackedResource",
            layer: LayerNode.ExecutableLayer { _, scope in
                scope.addFinalizer {
                    let labels = Teardown.pending().map(\.label)
                    seenDuringClose.withLock { $0 = labels }
                }
                return LayerNode.Output(["ok": true])
            }
        )
        let scope = LayerNode.ResourceScope()
        _ = try await LayerNode.compile(trackedNode).build(scope: scope)
        await scope.close()
        #expect(seenDuringClose.withLock { $0 }.contains("layer TrackedResource releasing"))
        #expect(!Teardown.pending().map(\.label).contains("layer TrackedResource releasing"))
    }
}
