import Synchronization

/// Pure-Swift Tree-sitter client, parser registry, query/asset loader abstraction,
/// incremental buffer & streaming copy manager, and default parser definitions matching
/// `packages/core/src/lib/tree-sitter/*`.
///
/// Defaults cleanly to OpenTUI's zero-dependency `BuiltInSyntaxHighlighter` so highlighting
/// works out of the box on every Swift platform (including iOS and WASI), while allowing
/// external/custom parsers and injectable asset fetchers to plug in seamlessly.

// MARK: - Core Tree-Sitter Types (`core/src/lib/tree-sitter/types.ts`)

/// Line-indexed highlight diff payload emitted by `TreeSitterClient` for managed buffers.
// parity: core/src/lib/tree-sitter/types.ts#HighlightResponse [status=implemented hash=c3c65a6f4687]
public struct HighlightResponse: Equatable, Hashable, Sendable, Codable {
    public var line: Int
    public var highlights: [HighlightRange]
    public var droppedHighlights: [HighlightRange]

    public init(line: Int, highlights: [HighlightRange] = [], droppedHighlights: [HighlightRange] = []) {
        self.line = line
        self.highlights = highlights
        self.droppedHighlights = droppedHighlights
    }
}

/// Language-injection mapping rules for embedded languages (such as Markdown fenced code blocks).
// parity: core/src/lib/tree-sitter/types.ts#InjectionMapping [status=implemented hash=e9d26e0e7376]
public struct InjectionMapping: Equatable, Hashable, Sendable, Codable {
    public var nodeTypes: [String: String]?
    public var infoStringMap: [String: String]?

    public init(nodeTypes: [String: String]? = nil, infoStringMap: [String: String]? = nil) {
        self.nodeTypes = nodeTypes
        self.infoStringMap = infoStringMap
    }
}

/// Query source lists for a filetype parser.
public struct FiletypeParserQueries: Equatable, Hashable, Sendable, Codable {
    public var highlights: [String]
    public var injections: [String]?

    public init(highlights: [String], injections: [String]? = nil) {
        self.highlights = highlights
        self.injections = injections
    }
}

/// Configuration describing a tree-sitter filetype parser, its aliases, query files, and grammar asset.
// parity: core/src/lib/tree-sitter/types.ts#FiletypeParserOptions [status=implemented hash=2b539e8ca621]
public struct FiletypeParserOptions: Equatable, Hashable, Sendable, Codable {
    public var filetype: String
    public var aliases: [String]?
    public var queries: FiletypeParserQueries
    public var wasm: String
    public var injectionMapping: InjectionMapping?

    public init(
        filetype: String,
        aliases: [String]? = nil,
        queries: FiletypeParserQueries,
        wasm: String,
        injectionMapping: InjectionMapping? = nil
    ) {
        self.filetype = filetype
        self.aliases = aliases
        self.queries = queries
        self.wasm = wasm
        self.injectionMapping = injectionMapping
    }
}

/// Tracked document buffer state held by `TreeSitterClient`.
// parity: core/src/lib/tree-sitter/types.ts#BufferState [status=implemented hash=49b40d37932f]
public struct BufferState: Equatable, Hashable, Sendable, Codable {
    public var id: Int
    public var version: Int
    public var content: String
    public var filetype: String
    public var hasParser: Bool

    public init(id: Int, version: Int, content: String, filetype: String, hasParser: Bool) {
        self.id = id
        self.version = version
        self.content = content
        self.filetype = filetype
        self.hasParser = hasParser
    }
}

/// Buffer state guaranteed to have an initialized parser (`hasParser == true`).
// parity: core/src/lib/tree-sitter/types.ts#ParsedBuffer [status=implemented hash=84faa96e6133]
public struct ParsedBuffer: Equatable, Hashable, Sendable, Codable {
    public var id: Int
    public var version: Int
    public var content: String
    public var filetype: String
    public var hasParser: Bool { true }

    public init(id: Int, version: Int, content: String, filetype: String) {
        self.id = id
        self.version = version
        self.content = content
        self.filetype = filetype
    }

    public init?(from state: BufferState) {
        guard state.hasParser else { return nil }
        self.id = state.id
        self.version = state.version
        self.content = state.content
        self.filetype = state.filetype
    }
}

/// Log severity level emitted by tree-sitter workers.
// parity: core/src/lib/tree-sitter/types.ts#TreeSitterWorkerLogType [status=implemented hash=f1c7ca24651e]
public enum TreeSitterWorkerLogType: String, Equatable, Hashable, Sendable, Codable {
    case log
    case error
    case warn
}

/// Zero-based row/column point used in tree-sitter incremental edits.
public struct TreeSitterPoint: Equatable, Hashable, Sendable, Codable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

/// Incremental document edit descriptor matching `core/src/lib/tree-sitter/types.ts#Edit`.
// parity: core/src/lib/tree-sitter/types.ts#Edit [status=implemented hash=d22503754aa3]
public struct Edit: Equatable, Hashable, Sendable, Codable {
    public var startIndex: Int
    public var oldEndIndex: Int
    public var newEndIndex: Int
    public var startPosition: TreeSitterPoint
    public var oldEndPosition: TreeSitterPoint
    public var newEndPosition: TreeSitterPoint

    public init(
        startIndex: Int,
        oldEndIndex: Int,
        newEndIndex: Int,
        startPosition: TreeSitterPoint,
        oldEndPosition: TreeSitterPoint,
        newEndPosition: TreeSitterPoint
    ) {
        self.startIndex = startIndex
        self.oldEndIndex = oldEndIndex
        self.newEndIndex = newEndIndex
        self.startPosition = startPosition
        self.oldEndPosition = oldEndPosition
        self.newEndPosition = newEndPosition
    }
}

/// Recorded parse and query timing statistics returned by `TreeSitterClient.getPerformance()`.
// parity: core/src/lib/tree-sitter/types.ts#PerformanceStats [status=implemented hash=ccac08cc7689]
public struct PerformanceStats: Equatable, Hashable, Sendable, Codable {
    public var averageParseTime: Double
    public var parseTimes: [Double]
    public var averageQueryTime: Double
    public var queryTimes: [Double]

    public init(
        averageParseTime: Double = 0,
        parseTimes: [Double] = [],
        averageQueryTime: Double = 0,
        queryTimes: [Double] = []
    ) {
        self.averageParseTime = averageParseTime
        self.parseTimes = parseTimes
        self.averageQueryTime = averageQueryTime
        self.queryTimes = queryTimes
    }
}

/// Worker request protocol messages matching `core/src/lib/tree-sitter/types.ts#TreeSitterWorkerRequest`.
// parity: core/src/lib/tree-sitter/types.ts#TreeSitterWorkerRequest [status=implemented hash=aa4fd77b0a30]
public enum TreeSitterWorkerRequest: Equatable, Hashable, Sendable, Codable {
    case `init`(dataPath: String, treeSitterWasmPath: String?)
    case addFiletypeParser(filetypeParser: FiletypeParserOptions)
    case preloadParser(filetype: String, messageId: String)
    case initializeParser(bufferId: Int, version: Int, content: String, filetype: String, messageId: String)
    case handleEdits(bufferId: Int, version: Int, content: String, edits: [Edit])
    case getPerformance(messageId: String)
    case resetBuffer(bufferId: Int, version: Int, content: String, edits: [Edit])
    case disposeBuffer(bufferId: Int)
    case oneshotHighlight(content: String, filetype: String, messageId: String)
    case appendHighlight(copyId: Int, offset: Int, text: String, filetype: String, messageId: String)
    case disposeCopy(copyId: Int)
    case updateDataPath(dataPath: String, messageId: String)
    case clearCache(messageId: String)
}

/// Worker response protocol messages matching `core/src/lib/tree-sitter/types.ts#TreeSitterWorkerResponse`.
// parity: core/src/lib/tree-sitter/types.ts#TreeSitterWorkerResponse [status=implemented hash=d42d67a28697]
public enum TreeSitterWorkerResponse: Equatable, Hashable, Sendable, Codable {
    case initResponse(error: String?)
    case parserInitResponse(bufferId: Int, messageId: String, hasParser: Bool, warning: String?, error: String?)
    case highlightResponse(bufferId: Int, version: Int, highlights: [HighlightResponse])
    case preloadParserResponse(messageId: String, hasParser: Bool)
    case bufferDisposed(bufferId: Int)
    case performanceResponse(performance: PerformanceStats, messageId: String)
    case oneshotHighlightResponse(
        messageId: String,
        hasParser: Bool,
        highlights: [SimpleHighlight]?,
        warning: String?,
        error: String?
    )
    case updateDataPathResponse(messageId: String, error: String?)
    case clearCacheResponse(messageId: String, error: String?)
    case warning(bufferId: Int?, warning: String)
    case error(bufferId: Int?, messageId: String?, error: String)
    case workerLog(logType: TreeSitterWorkerLogType, data: [String])
}

/// Event identifiers emitted by `TreeSitterClient`.
// parity: core/src/lib/tree-sitter/types.ts#TreeSitterClientEvents [status=implemented hash=c531718283a9]
public enum TreeSitterClientEvents: String, Equatable, Hashable, Sendable {
    case highlightsResponse = "highlights:response"
    case bufferInitialized = "buffer:initialized"
    case bufferDisposed = "buffer:disposed"
    case workerLog = "worker:log"
    case error = "error"
    case warning = "warning"
}

/// Result returned by `TreeSitterClient.highlightOnce(_:filetype:)` and `highlightAppend(...)`.
public struct TreeSitterHighlightOutcome: Equatable, Hashable, Sendable, Codable {
    public var highlights: [SimpleHighlight]?
    public var warning: String?
    public var error: String?

    public init(highlights: [SimpleHighlight]? = nil, warning: String? = nil, error: String? = nil) {
        self.highlights = highlights
        self.warning = warning
        self.error = error
    }
}

/// Errors thrown by `TreeSitterClient` lifecycle operations.
public enum TreeSitterClientError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case bufferAlreadyExists(Int)
    case notInitialized(String)
    case destroyed(String)
    case unknownDefaultAsset(String)
    case invalidConfiguration(String)

    public var description: String {
        switch self {
        case .bufferAlreadyExists(let id):
            return "Buffer with id \(id) already exists"
        case .notInitialized(let message),
             .destroyed(let message),
             .unknownDefaultAsset(let message),
             .invalidConfiguration(let message):
            return message
        }
    }
}

// MARK: - Injectable Asset Fetcher & Download Utilities (`download-utils.ts`)

/// Outcome of downloading or loading a parser WASM or `.scm` query asset.
// parity: core/src/lib/tree-sitter/download-utils.ts#DownloadResult [status=implemented hash=4d9f58bc40c0]
public struct DownloadResult: Equatable, Hashable, Sendable {
    public var content: [UInt8]?
    public var filePath: String?
    public var error: String?

    public init(content: [UInt8]? = nil, filePath: String? = nil, error: String? = nil) {
        self.content = content
        self.filePath = filePath
        self.error = error
    }
}

/// Pure-Swift injectable asset fetcher/cache protocol used by `DownloadUtils` and `TreeSitterClient`.
public protocol TreeSitterAssetLoader: Sendable {
    func readLocalFile(at path: String) async throws -> [UInt8]
    func writeLocalFile(_ bytes: [UInt8], to path: String) async throws
    func fetchRemoteURL(_ url: String) async throws -> [UInt8]
}

/// Thread-safe in-memory `TreeSitterAssetLoader` for pure-Swift/WASI/test execution without OS filesystem or network I/O.
public final class InMemoryTreeSitterAssetLoader: TreeSitterAssetLoader, Sendable {
    private struct State: Sendable {
        var files: [String: [UInt8]] = [:]
        var remoteURLs: [String: [UInt8]] = [:]
        var remoteFetchCount: Int = 0
    }

    private let state: Mutex<State>

    public init(files: [String: [UInt8]] = [:], remoteURLs: [String: [UInt8]] = [:]) {
        self.state = Mutex(State(files: files, remoteURLs: remoteURLs))
    }

    public func setLocalFile(_ bytes: [UInt8], at path: String) {
        state.withLock { $0.files[path] = bytes }
    }

    public func setRemoteResource(_ bytes: [UInt8], for url: String) {
        state.withLock { $0.remoteURLs[url] = bytes }
    }

    public var remoteFetchCount: Int {
        state.withLock { $0.remoteFetchCount }
    }

    public func cachedFile(at path: String) -> [UInt8]? {
        state.withLock { $0.files[path] }
    }

    public func readLocalFile(at path: String) async throws -> [UInt8] {
        guard let bytes = state.withLock({ $0.files[path] }) else {
            throw RuntimeAssetError.missingAsset(key: path, path: path)
        }
        return bytes
    }

    public func writeLocalFile(_ bytes: [UInt8], to path: String) async throws {
        state.withLock { $0.files[path] = bytes }
    }

    public func fetchRemoteURL(_ url: String) async throws -> [UInt8] {
        let bytes = state.withLock { s -> [UInt8]? in
            s.remoteFetchCount += 1
            return s.remoteURLs[url]
        }
        guard let bytes else {
            throw RuntimeAssetError.missingAsset(key: url, path: url)
        }
        return bytes
    }
}

/// Pure-Swift parser/query download & cache utilities matching `core/src/lib/tree-sitter/download-utils.ts`.
// parity: core/src/lib/tree-sitter/download-utils.ts#DownloadUtils [status=adapted hash=f84131b536f1]
public enum DownloadUtils {
    /// Deterministic JavaScript-compatible 32-bit URL hash matching `DownloadUtils.hashUrl`.
    public static func hashUrl(_ url: String) -> String {
        var hash: Int32 = 0
        for unit in url.utf16 {
            hash = ((hash &<< 5) &- hash) &+ Int32(unit)
        }
        let magnitude: UInt32
        if hash == Int32.min {
            magnitude = UInt32(bitPattern: Int32.min)
        } else {
            magnitude = UInt32(abs(hash))
        }
        return String(magnitude, radix: 16)
    }

    /// Loads a parser or query asset from a remote URL (with local cache lookup/population) or local path.
    // parity: core/src/lib/tree-sitter/download-utils.ts#DownloadUtils.downloadOrLoad [status=adapted hash=5490ba168797]
    public static func downloadOrLoad(
        source: String,
        cacheDir: String,
        cacheSubdir: String,
        fileExtension: String,
        useHashForCache: Bool = true,
        filetype: String? = nil,
        loader: any TreeSitterAssetLoader = InMemoryTreeSitterAssetLoader()
    ) async -> DownloadResult {
        let isUrl = source.hasPrefix("http://") || source.hasPrefix("https://")
        if isUrl {
            let cacheFileName: String
            if useHashForCache {
                let hash = hashUrl(source)
                cacheFileName = filetype.map { "\($0)-\(hash)\(fileExtension)" } ?? "\(hash)\(fileExtension)"
            } else {
                cacheFileName = portableBasename(source)
            }
            let cacheFile = joinPortablePath(joinPortablePath(cacheDir, cacheSubdir), cacheFileName)

            if let cached = try? await loader.readLocalFile(at: cacheFile), !cached.isEmpty {
                return DownloadResult(content: cached, filePath: cacheFile)
            }

            do {
                let content = try await loader.fetchRemoteURL(source)
                try? await loader.writeLocalFile(content, to: cacheFile)
                return DownloadResult(content: content, filePath: cacheFile)
            } catch {
                return DownloadResult(error: "Error downloading from \(source): \(error)")
            }
        } else {
            do {
                let content = try await loader.readLocalFile(at: source)
                return DownloadResult(content: content, filePath: source)
            } catch {
                return DownloadResult(error: "Error loading from local path \(source): \(error)")
            }
        }
    }

    /// Downloads (or copies) an asset to an explicit `targetPath`.
    // parity: core/src/lib/tree-sitter/download-utils.ts#DownloadUtils.downloadToPath [status=adapted hash=1bea31365c0b]
    public static func downloadToPath(
        source: String,
        targetPath: String,
        loader: any TreeSitterAssetLoader = InMemoryTreeSitterAssetLoader()
    ) async -> DownloadResult {
        let isUrl = source.hasPrefix("http://") || source.hasPrefix("https://")
        if isUrl {
            do {
                let content = try await loader.fetchRemoteURL(source)
                try await loader.writeLocalFile(content, to: targetPath)
                return DownloadResult(content: content, filePath: targetPath)
            } catch {
                return DownloadResult(error: "Error downloading from \(source): \(error)")
            }
        } else {
            do {
                let content = try await loader.readLocalFile(at: source)
                try await loader.writeLocalFile(content, to: targetPath)
                return DownloadResult(content: content, filePath: targetPath)
            } catch {
                return DownloadResult(error: "Error copying from local path \(source): \(error)")
            }
        }
    }

    /// Fetches and concatenates multiple `.scm` highlight query sources separated by newlines.
    // parity: core/src/lib/tree-sitter/download-utils.ts#DownloadUtils.fetchHighlightQueries [status=adapted hash=b7f0572b1cfc]
    public static func fetchHighlightQueries(
        sources: [String],
        cacheDir: String,
        filetype: String,
        loader: any TreeSitterAssetLoader = InMemoryTreeSitterAssetLoader()
    ) async -> String {
        var validQueries: [String] = []
        validQueries.reserveCapacity(sources.count)
        for source in sources {
            let result = await downloadOrLoad(
                source: source,
                cacheDir: cacheDir,
                cacheSubdir: "queries",
                fileExtension: ".scm",
                useHashForCache: true,
                filetype: filetype,
                loader: loader
            )
            if let bytes = result.content {
                let decoded = String(decoding: bytes, as: UTF8.self)
                if decoded.contains(where: { !$0.isWhitespace }) {
                    validQueries.append(decoded)
                }
            }
        }
        return validQueries.joined(separator: "\n")
    }
}

// MARK: - Default Parsers & Asset Update CLI (`default-parsers.ts`, `default-parser-assets.bun.ts`, `assets/update.ts`)

/// Package-relative asset paths shipped with OpenTUI's built-in tree-sitter parser set.
// parity: core/src/lib/tree-sitter/default-parsers.ts#defaultParserAssetPaths [status=implemented hash=75d904e2c040]
public let defaultParserAssetPaths: [String] = [
    "assets/javascript/highlights.scm",
    "assets/javascript/tree-sitter-javascript.wasm",
    "assets/typescript/highlights.scm",
    "assets/typescript/tree-sitter-typescript.wasm",
    "assets/typescriptreact/highlights.scm",
    "assets/typescriptreact/tree-sitter-tsx.wasm",
    "assets/markdown/highlights.scm",
    "assets/markdown/tree-sitter-markdown.wasm",
    "assets/markdown/injections.scm",
    "assets/markdown_inline/highlights.scm",
    "assets/markdown_inline/tree-sitter-markdown_inline.wasm",
    "assets/zig/highlights.scm",
    "assets/zig/tree-sitter-zig.wasm",
]

private let defaultParserAssetSet: Set<String> = Set(defaultParserAssetPaths)

private let builtInDefaultParserDescriptors: [FiletypeParserOptions] = [
    FiletypeParserOptions(
        filetype: "javascript",
        aliases: ["javascriptreact"],
        queries: FiletypeParserQueries(highlights: ["assets/javascript/highlights.scm"]),
        wasm: "assets/javascript/tree-sitter-javascript.wasm"
    ),
    FiletypeParserOptions(
        filetype: "typescript",
        queries: FiletypeParserQueries(highlights: ["assets/typescript/highlights.scm"]),
        wasm: "assets/typescript/tree-sitter-typescript.wasm"
    ),
    FiletypeParserOptions(
        filetype: "typescriptreact",
        queries: FiletypeParserQueries(highlights: ["assets/typescriptreact/highlights.scm"]),
        wasm: "assets/typescriptreact/tree-sitter-tsx.wasm"
    ),
    FiletypeParserOptions(
        filetype: "markdown",
        queries: FiletypeParserQueries(
            highlights: ["assets/markdown/highlights.scm"],
            injections: ["assets/markdown/injections.scm"]
        ),
        wasm: "assets/markdown/tree-sitter-markdown.wasm",
        injectionMapping: InjectionMapping(
            nodeTypes: ["inline": "markdown_inline", "pipe_table_cell": "markdown_inline"],
            infoStringMap: [
                "javascript": "javascript",
                "js": "javascript",
                "jsx": "javascriptreact",
                "javascriptreact": "javascriptreact",
                "typescript": "typescript",
                "ts": "typescript",
                "tsx": "typescriptreact",
                "typescriptreact": "typescriptreact",
                "markdown": "markdown",
                "md": "markdown",
            ]
        )
    ),
    FiletypeParserOptions(
        filetype: "markdown_inline",
        queries: FiletypeParserQueries(highlights: ["assets/markdown_inline/highlights.scm"]),
        wasm: "assets/markdown_inline/tree-sitter-markdown_inline.wasm"
    ),
    FiletypeParserOptions(
        filetype: "zig",
        queries: FiletypeParserQueries(highlights: ["assets/zig/highlights.scm"]),
        wasm: "assets/zig/tree-sitter-zig.wasm"
    ),
]

/// Validates and resolves a bundled default parser asset path matching `default-parser-assets.bun.ts`.
// parity: core/src/lib/tree-sitter/default-parser-assets.bun.ts#resolveBundledDefaultParserAsset [status=adapted hash=3b4929fbd8ce]
public func resolveBundledDefaultParserAsset(
    _ relativePath: String,
    fallbackPath: String? = nil,
    environment: [String: String] = [:],
    registry: RuntimeAssetRegistry = .shared
) async throws -> String {
    guard defaultParserAssetSet.contains(relativePath) else {
        throw TreeSitterClientError.unknownDefaultAsset("Unknown OpenTUI default parser asset: \"\(relativePath)\"")
    }
    return try await resolveDefaultParserAsset(
        relativePath: relativePath,
        fallbackPath: fallbackPath ?? relativePath,
        environment: environment,
        registry: registry
    )
}

/// Returns the default built-in `FiletypeParserOptions` set with resolved asset paths.
// parity: core/src/lib/tree-sitter/default-parsers.ts#getParsers [status=implemented hash=c3e56d8deae9]
public func getParsers(
    environment: [String: String] = [:],
    registry: RuntimeAssetRegistry = .shared
) async -> [FiletypeParserOptions] {
    var resolved: [FiletypeParserOptions] = []
    resolved.reserveCapacity(builtInDefaultParserDescriptors.count)
    for descriptor in builtInDefaultParserDescriptors {
        var resolvedHighlights: [String] = []
        for h in descriptor.queries.highlights {
            let p = (try? await resolveBundledDefaultParserAsset(h, environment: environment, registry: registry)) ?? h
            resolvedHighlights.append(p)
        }
        var resolvedInjections: [String]? = nil
        if let injections = descriptor.queries.injections {
            var arr: [String] = []
            for inj in injections {
                let p = (try? await resolveBundledDefaultParserAsset(inj, environment: environment, registry: registry)) ?? inj
                arr.append(p)
            }
            resolvedInjections = arr
        }
        let resolvedWasm =
            (try? await resolveBundledDefaultParserAsset(descriptor.wasm, environment: environment, registry: registry))
            ?? descriptor.wasm
        resolved.append(
            FiletypeParserOptions(
                filetype: descriptor.filetype,
                aliases: descriptor.aliases,
                queries: FiletypeParserQueries(highlights: resolvedHighlights, injections: resolvedInjections),
                wasm: resolvedWasm,
                injectionMapping: descriptor.injectionMapping
            )
        )
    }
    return resolved
}

/// Synchronous convenience accessor returning the default parser definitions (including any `addDefaultParsers` overrides).
public func getDefaultParsers() -> [FiletypeParserOptions] {
    let overrides = defaultParserOverridesStore.withLock { $0 }
    let overridden = Set(overrides.map(\.filetype))
    return builtInDefaultParserDescriptors.filter { !overridden.contains($0.filetype) } + overrides
}

/// Configuration object matching `core/src/lib/tree-sitter/parsers-config.ts#default`.
public struct DefaultParsersConfig: Equatable, Hashable, Sendable, Codable {
    public var parsers: [FiletypeParserOptions]

    public init(parsers: [FiletypeParserOptions]) {
        self.parsers = parsers
    }
}

/// Default upstream tree-sitter parser source definitions matching `core/src/lib/tree-sitter/parsers-config.ts`.
// parity: core/src/lib/tree-sitter/parsers-config.ts#default [status=implemented hash=9ff6beec2724]
public let defaultParsersConfig = DefaultParsersConfig(
    parsers: [
        FiletypeParserOptions(
            filetype: "javascript",
            aliases: ["javascriptreact"],
            queries: FiletypeParserQueries(
                highlights: [
                    "https://raw.githubusercontent.com/tree-sitter/tree-sitter-javascript/refs/heads/master/queries/highlights.scm",
                ]
            ),
            wasm: "https://github.com/tree-sitter/tree-sitter-javascript/releases/download/v0.25.0/tree-sitter-javascript.wasm"
        ),
        FiletypeParserOptions(
            filetype: "typescript",
            queries: FiletypeParserQueries(
                highlights: [
                    "https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/ecma/highlights.scm",
                    "https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/typescript/highlights.scm",
                ]
            ),
            wasm: "https://github.com/tree-sitter/tree-sitter-typescript/releases/download/v0.23.2/tree-sitter-typescript.wasm"
        ),
        FiletypeParserOptions(
            filetype: "typescriptreact",
            queries: FiletypeParserQueries(
                highlights: [
                    "https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/ecma/highlights.scm",
                    "https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/typescript/highlights.scm",
                    "https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/a8c082b4f5b3b70bde2ffb08cc112dfd7e515fb3/queries/jsx/highlights.scm",
                ]
            ),
            wasm: "https://github.com/tree-sitter/tree-sitter-typescript/releases/download/v0.23.2/tree-sitter-tsx.wasm"
        ),
        FiletypeParserOptions(
            filetype: "markdown",
            queries: FiletypeParserQueries(
                highlights: [
                    "./assets/markdown/highlights.scm",
                ],
                injections: [
                    "https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/markdown/injections.scm",
                ]
            ),
            wasm: "https://github.com/tree-sitter-grammars/tree-sitter-markdown/releases/download/v0.5.1/tree-sitter-markdown.wasm",
            injectionMapping: InjectionMapping(
                nodeTypes: [
                    "inline": "markdown_inline",
                    "pipe_table_cell": "markdown_inline",
                ],
                infoStringMap: [
                    "javascript": "javascript",
                    "js": "javascript",
                    "jsx": "javascriptreact",
                    "javascriptreact": "javascriptreact",
                    "typescript": "typescript",
                    "ts": "typescript",
                    "tsx": "typescriptreact",
                    "typescriptreact": "typescriptreact",
                    "markdown": "markdown",
                    "md": "markdown",
                ]
            )
        ),
        FiletypeParserOptions(
            filetype: "markdown_inline",
            queries: FiletypeParserQueries(
                highlights: [
                    "./assets/markdown_inline/highlights.scm",
                ]
            ),
            wasm: "https://github.com/tree-sitter-grammars/tree-sitter-markdown/releases/download/v0.5.1/tree-sitter-markdown_inline.wasm"
        ),
        FiletypeParserOptions(
            filetype: "zig",
            queries: FiletypeParserQueries(
                highlights: [
                    "https://github.com/nvim-treesitter/nvim-treesitter/raw/refs/heads/master/queries/zig/highlights.scm",
                ]
            ),
            wasm: "https://github.com/tree-sitter-grammars/tree-sitter-zig/releases/download/v1.1.2/tree-sitter-zig.wasm"
        ),
    ]
)

/// Result of running `updateAssets` for a single parser entry.
public struct GeneratedParserAsset: Equatable, Hashable, Sendable, Codable {
    public var filetype: String
    public var aliases: [String]?
    public var languagePath: String
    public var highlightsPath: String
    public var injectionsPath: String?
    public var injectionMapping: InjectionMapping?

    public init(
        filetype: String,
        aliases: [String]? = nil,
        languagePath: String,
        highlightsPath: String,
        injectionsPath: String? = nil,
        injectionMapping: InjectionMapping? = nil
    ) {
        self.filetype = filetype
        self.aliases = aliases
        self.languagePath = languagePath
        self.highlightsPath = highlightsPath
        self.injectionsPath = injectionsPath
        self.injectionMapping = injectionMapping
    }
}

/// Options for updating/generating bundled tree-sitter parser assets (`assets/update.ts`).
// parity: core/src/lib/tree-sitter/assets/update.ts#UpdateOptions [status=implemented hash=5cb405539dad]
public struct UpdateOptions: Equatable, Hashable, Sendable, Codable {
    public var configPath: String
    public var assetsDir: String
    public var outputPath: String

    public init(configPath: String, assetsDir: String, outputPath: String) {
        self.configPath = configPath
        self.assetsDir = assetsDir
        self.outputPath = outputPath
    }
}

private func portableRelativeAssetPath(from baseDir: String, to targetPath: String) -> String {
    let baseParts = baseDir.split(separator: "/").map(String.init)
    let targetParts = targetPath.split(separator: "/").map(String.init)
    var common = 0
    while common < baseParts.count && common < targetParts.count && baseParts[common] == targetParts[common] {
        common += 1
    }
    let up = Array(repeating: "..", count: baseParts.count - common)
    let down = Array(targetParts[common...])
    let joined = (up + down).joined(separator: "/")
    return joined.hasPrefix(".") ? joined : "./" + joined
}

private func downloadAndCombineQueries(
    filetype: String,
    queryUrls: [String],
    assetsDir: String,
    outputPath: String,
    queryType: String,
    configPath: String,
    loader: any TreeSitterAssetLoader
) async throws -> String {
    let queriesDir = joinPortablePath(assetsDir, filetype)
    let queryPath = joinPortablePath(queriesDir, "\(queryType).scm")
    var queryContents: [String] = []
    let configDir = portableDirname(configPath)

    for queryUrl in queryUrls {
        if queryUrl.hasPrefix("./") {
            let trimmed = String(queryUrl.dropFirst(2))
            let localPath = joinPortablePath(configDir, trimmed)
            if let bytes = try? await loader.readLocalFile(at: localPath) {
                let text = String(decoding: bytes, as: UTF8.self)
                if text.contains(where: { !$0.isWhitespace }) {
                    queryContents.append(text)
                }
            }
        } else {
            let result = await DownloadUtils.downloadToPath(
                source: queryUrl,
                targetPath: joinPortablePath(queriesDir, portableBasename(queryUrl)),
                loader: loader
            )
            if let bytes = result.content {
                let text = String(decoding: bytes, as: UTF8.self)
                if text.contains(where: { !$0.isWhitespace }) {
                    queryContents.append("; Query from: \(queryUrl)\n\(text)")
                }
            }
        }
    }

    let combined = queryContents.joined(separator: "\n\n")
    try await loader.writeLocalFile(Array(combined.utf8), to: queryPath)
    return portableRelativeAssetPath(from: portableDirname(outputPath), to: queryPath)
}

/// Downloads parser WASM binaries and combines highlight/injection `.scm` queries for each configured
/// parser, writing the generated descriptor output via the injectable `TreeSitterAssetLoader`.
/// Matches `core/src/lib/tree-sitter/assets/update.ts#updateAssets` (`main`).
// parity: core/src/lib/tree-sitter/assets/update.ts#updateAssets [status=adapted hash=a1de0c2ee4e2]
@discardableResult
public func updateAssets(
    options: UpdateOptions,
    parsers: [FiletypeParserOptions] = defaultParsersConfig.parsers,
    loader: any TreeSitterAssetLoader = InMemoryTreeSitterAssetLoader()
) async throws -> [GeneratedParserAsset] {
    var generated: [GeneratedParserAsset] = []
    generated.reserveCapacity(parsers.count)

    for parser in parsers {
        let languageDir = joinPortablePath(options.assetsDir, parser.filetype)
        let languageTarget = joinPortablePath(languageDir, portableBasename(parser.wasm))
        let langResult = await DownloadUtils.downloadToPath(
            source: parser.wasm,
            targetPath: languageTarget,
            loader: loader
        )
        if let err = langResult.error {
            throw TreeSitterClientError.unknownDefaultAsset("Failed to download language for \(parser.filetype): \(err)")
        }
        let languagePath = portableRelativeAssetPath(from: portableDirname(options.outputPath), to: languageTarget)

        let highlightsPath = try await downloadAndCombineQueries(
            filetype: parser.filetype,
            queryUrls: parser.queries.highlights,
            assetsDir: options.assetsDir,
            outputPath: options.outputPath,
            queryType: "highlights",
            configPath: options.configPath,
            loader: loader
        )

        var injectionsPath: String? = nil
        if let injections = parser.queries.injections, !injections.isEmpty {
            injectionsPath = try await downloadAndCombineQueries(
                filetype: parser.filetype,
                queryUrls: injections,
                assetsDir: options.assetsDir,
                outputPath: options.outputPath,
                queryType: "injections",
                configPath: options.configPath,
                loader: loader
            )
        }

        generated.append(
            GeneratedParserAsset(
                filetype: parser.filetype,
                aliases: parser.aliases,
                languagePath: languagePath,
                highlightsPath: highlightsPath,
                injectionsPath: injectionsPath,
                injectionMapping: parser.injectionMapping
            )
        )
    }

    let manifestLines = generated.map { entry -> String in
        var fields = [
            "filetype=\(entry.filetype)",
            "wasm=\(entry.languagePath)",
            "highlights=\(entry.highlightsPath)",
        ]
        if let inj = entry.injectionsPath {
            fields.append("injections=\(inj)")
        }
        return fields.joined(separator: ";")
    }
    let outputContent = "// Generated by updateAssets\n" + manifestLines.joined(separator: "\n") + "\n"
    try await loader.writeLocalFile(Array(outputContent.utf8), to: options.outputPath)
    return generated
}

/// Portable Swift adaptation of `assets/update.ts#runUpdateAssetsCli` using an injectable `TreeSitterAssetLoader`.
// parity: core/src/lib/tree-sitter/assets/update.ts#runUpdateAssetsCli [status=adapted hash=7672499bde59]
@discardableResult
public func runUpdateAssetsCli(
    parsers: [FiletypeParserOptions] = getDefaultParsers(),
    options: UpdateOptions,
    loader: any TreeSitterAssetLoader = InMemoryTreeSitterAssetLoader()
) async -> [DownloadResult] {
    var results: [DownloadResult] = []
    for parser in parsers {
        let langDir = joinPortablePath(options.assetsDir, parser.filetype)
        let langTarget = joinPortablePath(langDir, portableBasename(parser.wasm))
        results.append(await DownloadUtils.downloadToPath(source: parser.wasm, targetPath: langTarget, loader: loader))
        for query in parser.queries.highlights {
            let queryTarget = joinPortablePath(langDir, "highlights.scm")
            results.append(await DownloadUtils.downloadToPath(source: query, targetPath: queryTarget, loader: loader))
        }
        if let injections = parser.queries.injections {
            for query in injections {
                let queryTarget = joinPortablePath(langDir, "injections.scm")
                results.append(await DownloadUtils.downloadToPath(source: query, targetPath: queryTarget, loader: loader))
            }
        }
    }
    return results
}

// MARK: - Default Parser Override Registry

private let defaultParserOverridesStore = Mutex<[FiletypeParserOptions]>([])

/// Registers additional or replacement default filetype parsers applied to newly initialized `TreeSitterClient`s.
// parity: core/src/lib/tree-sitter/client.ts#addDefaultParsers [status=implemented hash=858eafc68e86]
public func addDefaultParsers(_ parsers: [FiletypeParserOptions]) {
    defaultParserOverridesStore.withLock { store in
        for parser in parsers {
            store.removeAll { $0.filetype == parser.filetype }
            store.append(parser)
        }
    }
}

/// Resets global overrides added via `addDefaultParsers(_:)` (useful for isolated tests).
public func resetDefaultParserOverrides() {
    defaultParserOverridesStore.withLock { $0.removeAll() }
}

// MARK: - TreeSitterClientOptions

/// Configuration options for constructing a `TreeSitterClient`.
// parity: core/src/lib/tree-sitter/types.ts#TreeSitterClientOptions [status=adapted hash=624ed2b889f0]
public struct TreeSitterClientOptions: Sendable {
    public var dataPath: String
    public var workerPath: String?
    public var initTimeout: Double?
    public var highlighter: (any SyntaxHighlighter)?
    public var assetLoader: (any TreeSitterAssetLoader)?
    public var maxCacheEntries: Int

    public init(
        dataPath: String,
        workerPath: String? = nil,
        initTimeout: Double? = nil,
        highlighter: (any SyntaxHighlighter)? = nil,
        assetLoader: (any TreeSitterAssetLoader)? = nil,
        maxCacheEntries: Int = 256
    ) {
        self.dataPath = dataPath
        self.workerPath = workerPath
        self.initTimeout = initTimeout
        self.highlighter = highlighter
        self.assetLoader = assetLoader
        self.maxCacheEntries = max(0, maxCacheEntries)
    }
}

// MARK: - Line-Split Helper (SimpleHighlight -> [HighlightResponse])

private func convertHighlightsToLineResponses(content: String, highlights: [SimpleHighlight]) -> [HighlightResponse] {
    guard !highlights.isEmpty else { return [] }
    let units = Array(content.utf16)
    var lineStarts: [Int] = [0]
    for (idx, u) in units.enumerated() where u == 0x0A {
        lineStarts.append(idx + 1)
    }
    let lineCount = lineStarts.count

    func lineIndex(for offset: Int) -> Int {
        var lo = 0
        var hi = lineCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }

    var perLine: [Int: [HighlightRange]] = [:]
    for h in highlights {
        guard h.end > h.start else { continue }
        let startLine = lineIndex(for: max(0, min(h.start, units.count)))
        let endLine = lineIndex(for: max(0, min(h.end - 1, units.count)))
        for line in startLine...endLine {
            let lineStart = lineStarts[line]
            let lineEnd = (line + 1 < lineCount) ? max(lineStart, lineStarts[line + 1] - 1) : units.count
            let colStart = max(0, h.start - lineStart)
            let colEnd = min(lineEnd - lineStart, h.end - lineStart)
            if colEnd > colStart {
                perLine[line, default: []].append(HighlightRange(startCol: colStart, endCol: colEnd, group: h.group))
            }
        }
    }

    return perLine.keys.sorted().map { line in
        HighlightResponse(line: line, highlights: perLine[line] ?? [], droppedHighlights: [])
    }
}

// MARK: - TreeSitterClient (`core/src/lib/tree-sitter/client.ts`)

/// Subscription token returned by `TreeSitterClient` listener registration methods.
public struct TreeSitterListenerToken: Equatable, Hashable, Sendable {
    fileprivate let id: UInt64
}

/// Pure-Swift Tree-sitter client managing parser configurations, aliases, query registries,
/// highlight caching, incremental buffers, streaming append copies, and performance metrics.
///
/// Conforms to `SyntaxHighlighter` and defaults to `BuiltInSyntaxHighlighter.shared` so every
/// supported language highlights out of the box on every Swift platform.
// parity: core/src/lib/tree-sitter/client.ts#TreeSitterClient [status=adapted hash=fcdc5a9378e5]
public final class TreeSitterClient: SyntaxHighlighter, Sendable {
    private struct CacheKey: Hashable, Sendable {
        let filetype: String
        let content: String
    }

    private struct StreamingCopy: Sendable {
        var filetype: String
        var content: String
        var utf16Length: Int
    }

    private struct State: Sendable {
        var options: TreeSitterClientOptions
        var initialized: Bool = false
        var destroyed: Bool = false
        var lifecycleGeneration: UInt64 = 0

        var parsersByFiletype: [String: FiletypeParserOptions] = [:]
        var aliasToFiletype: [String: String] = [:]
        var customHighlighters: [String: any SyntaxHighlighter] = [:]
        var loadedQueries: [String: String] = [:]

        var buffers: [Int: BufferState] = [:]
        var streamingCopies: [Int: StreamingCopy] = [:]

        var highlightCache: [CacheKey: TreeSitterHighlightOutcome] = [:]
        var cacheOrder: [CacheKey] = []

        var parseTimes: [Double] = []
        var queryTimes: [Double] = []

        var nextListenerId: UInt64 = 1
        var destroyCallbacks: [(id: UInt64, handler: @Sendable () -> Void)] = []
        var highlightsListeners: [(id: UInt64, handler: @Sendable (Int, Int, [HighlightResponse]) -> Void)] = []
        var bufferInitListeners: [(id: UInt64, handler: @Sendable (Int, Bool) -> Void)] = []
        var bufferDisposedListeners: [(id: UInt64, handler: @Sendable (Int) -> Void)] = []
        var warningListeners: [(id: UInt64, handler: @Sendable (String, Int?) -> Void)] = []
        var errorListeners: [(id: UInt64, handler: @Sendable (String, Int?) -> Void)] = []
        var workerLogListeners: [(id: UInt64, handler: @Sendable (TreeSitterWorkerLogType, String) -> Void)] = []
    }

    private let state: Mutex<State>
    private let defaultHighlighter: any SyntaxHighlighter
    private let assetLoader: any TreeSitterAssetLoader

    public init(options: TreeSitterClientOptions = TreeSitterClientOptions(dataPath: getDataPaths().globalDataPath)) {
        self.defaultHighlighter = options.highlighter ?? BuiltInSyntaxHighlighter.shared
        self.assetLoader = options.assetLoader ?? InMemoryTreeSitterAssetLoader()
        self.state = Mutex(State(options: options))
    }

    public var dataPath: String {
        state.withLock { $0.options.dataPath }
    }

    public var cacheCount: Int {
        state.withLock { $0.highlightCache.count }
    }

    /// Returns all currently registered filetype parser configurations.
    public func registeredParsers() -> [FiletypeParserOptions] {
        state.withLock { Array($0.parsersByFiletype.values).sorted { $0.filetype < $1.filetype } }
    }

    /// Registers a custom pure-Swift `SyntaxHighlighter` for a specific `filetype` (and optional aliases).
    public func registerCustomHighlighter(
        _ highlighter: any SyntaxHighlighter,
        forFiletype filetype: String,
        aliases: [String] = []
    ) {
        let canonical = filetype.lowercased()
        state.withLock { s in
            s.customHighlighters[canonical] = highlighter
            for alias in aliases where alias.lowercased() != canonical {
                s.aliasToFiletype[alias.lowercased()] = canonical
            }
            s.highlightCache.removeAll(keepingCapacity: true)
            s.cacheOrder.removeAll(keepingCapacity: true)
        }
    }

    /// Registers or fetches the concatenated highlight query text stored for `filetype`.
    public func registerQuery(_ querySource: String, forFiletype filetype: String) {
        state.withLock { $0.loadedQueries[filetype.lowercased()] = querySource }
    }

    public func query(forFiletype filetype: String) -> String? {
        state.withLock { s in
            let canonical = s.aliasToFiletype[filetype.lowercased()] ?? filetype.lowercased()
            return s.loadedQueries[canonical]
        }
    }

    // MARK: - Event Listeners

    @discardableResult
    public func onHighlightsResponse(
        _ handler: @escaping @Sendable (Int, Int, [HighlightResponse]) -> Void
    ) -> TreeSitterListenerToken {
        state.withLock { s in
            let id = s.nextListenerId
            s.nextListenerId &+= 1
            s.highlightsListeners.append((id: id, handler: handler))
            return TreeSitterListenerToken(id: id)
        }
    }

    @discardableResult
    public func onBufferInitialized(
        _ handler: @escaping @Sendable (Int, Bool) -> Void
    ) -> TreeSitterListenerToken {
        state.withLock { s in
            let id = s.nextListenerId
            s.nextListenerId &+= 1
            s.bufferInitListeners.append((id: id, handler: handler))
            return TreeSitterListenerToken(id: id)
        }
    }

    @discardableResult
    public func onBufferDisposed(_ handler: @escaping @Sendable (Int) -> Void) -> TreeSitterListenerToken {
        state.withLock { s in
            let id = s.nextListenerId
            s.nextListenerId &+= 1
            s.bufferDisposedListeners.append((id: id, handler: handler))
            return TreeSitterListenerToken(id: id)
        }
    }

    @discardableResult
    public func onWarning(_ handler: @escaping @Sendable (String, Int?) -> Void) -> TreeSitterListenerToken {
        state.withLock { s in
            let id = s.nextListenerId
            s.nextListenerId &+= 1
            s.warningListeners.append((id: id, handler: handler))
            return TreeSitterListenerToken(id: id)
        }
    }

    @discardableResult
    public func onError(_ handler: @escaping @Sendable (String, Int?) -> Void) -> TreeSitterListenerToken {
        state.withLock { s in
            let id = s.nextListenerId
            s.nextListenerId &+= 1
            s.errorListeners.append((id: id, handler: handler))
            return TreeSitterListenerToken(id: id)
        }
    }

    @discardableResult
    public func onWorkerLog(
        _ handler: @escaping @Sendable (TreeSitterWorkerLogType, String) -> Void
    ) -> TreeSitterListenerToken {
        state.withLock { s in
            let id = s.nextListenerId
            s.nextListenerId &+= 1
            s.workerLogListeners.append((id: id, handler: handler))
            return TreeSitterListenerToken(id: id)
        }
    }

    public func removeListener(_ token: TreeSitterListenerToken) {
        state.withLock { s in
            s.highlightsListeners.removeAll { $0.id == token.id }
            s.bufferInitListeners.removeAll { $0.id == token.id }
            s.bufferDisposedListeners.removeAll { $0.id == token.id }
            s.warningListeners.removeAll { $0.id == token.id }
            s.errorListeners.removeAll { $0.id == token.id }
            s.workerLogListeners.removeAll { $0.id == token.id }
        }
    }

    // MARK: - Lifecycle (`onDestroy`, `initialize`, `destroy`, `isInitialized`)

    /// Registers a teardown callback invoked when `destroy()` runs, returning an unsubscribe closure.
    // parity: core/src/lib/tree-sitter/client.ts#TreeSitterClient.onDestroy [status=implemented hash=38adf0a9727e]
    @discardableResult
    public func onDestroy(_ callback: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = state.withLock { s -> UInt64 in
            let id = s.nextListenerId
            s.nextListenerId &+= 1
            s.destroyCallbacks.append((id: id, handler: callback))
            return id
        }
        return { [weak self] in
            self?.state.withLock { s in
                s.destroyCallbacks.removeAll { $0.id == id }
            }
        }
    }

    /// Initializes the client and registers default parsers (plus any `addDefaultParsers` overrides).
    // parity: core/src/lib/tree-sitter/client.ts#TreeSitterClient.initialize [status=adapted hash=ccdcf7bee1f8]
    public func initialize() async throws {
        let alreadyReady: Bool = try state.withLock { s throws -> Bool in
            if s.destroyed {
                throw TreeSitterClientError.destroyed("Cannot initialize while client is destroyed")
            }
            return s.initialized
        }
        if alreadyReady { return }

        let defaults = await getParsers()
        let overrides = defaultParserOverridesStore.withLock { $0 }
        let overriddenSet = Set(overrides.map(\.filetype))
        let merged = defaults.filter { !overriddenSet.contains($0.filetype) } + overrides

        state.withLock { s in
            guard !s.destroyed else { return }
            for parser in merged {
                Self.installParserLocked(Self.normalizeParserOptions(parser), into: &s)
            }
            s.initialized = true
        }
    }

    /// Reports whether `initialize()` has completed and the client has not been destroyed.
    // parity: core/src/lib/tree-sitter/client.ts#TreeSitterClient.isInitialized [status=implemented hash=ca96bd7fb481]
    public func isInitialized() -> Bool {
        state.withLock { $0.initialized && !$0.destroyed }
    }

    /// Destroys the client, clears buffers/caches/copies, and invokes all `onDestroy` callbacks.
    // parity: core/src/lib/tree-sitter/client.ts#TreeSitterClient.destroy [status=adapted hash=cb50ecccf5fd]
    public func destroy() async {
        let callbacks: [@Sendable () -> Void] = state.withLock { s in
            s.destroyed = true
            s.initialized = false
            s.lifecycleGeneration &+= 1
            s.buffers.removeAll()
            s.streamingCopies.removeAll()
            s.highlightCache.removeAll()
            s.cacheOrder.removeAll()
            let cbs = s.destroyCallbacks.map(\.handler)
            s.destroyCallbacks.removeAll()
            return cbs
        }
        for cb in callbacks {
            cb()
        }
    }

    // MARK: - Parser Registration & Preloading

    /// Registers a filetype parser configuration and its aliases (resolving BunFS/relative paths).
    // parity: core/src/lib/tree-sitter/client.ts#TreeSitterClient.addFiletypeParser [status=implemented hash=bbdda62f74fc]
    public func addFiletypeParser(_ filetypeParser: FiletypeParserOptions) {
        let normalized = Self.normalizeParserOptions(filetypeParser)
        state.withLock { s in
            Self.installParserLocked(normalized, into: &s)
            s.highlightCache.removeAll(keepingCapacity: true)
            s.cacheOrder.removeAll(keepingCapacity: true)
        }
    }

    /// Checks whether a parser or built-in syntax highlighter is available for `filetype` and preloads any registered query sources.
    // parity: core/src/lib/tree-sitter/client.ts#TreeSitterClient.preloadParser [status=adapted hash=85b58d5069f5]
    public func preloadParser(_ filetype: String) async -> Bool {
        if !isInitialized() {
            try? await initialize()
        }
        let (canonical, parser, cacheDir) = state.withLock { s -> (String, FiletypeParserOptions?, String) in
            let canon = Self.resolveCanonicalFiletypeLocked(filetype, state: s)
            return (canon, s.parsersByFiletype[canon], s.options.dataPath)
        }
        if let parser, !parser.queries.highlights.isEmpty {
            let queryText = await DownloadUtils.fetchHighlightQueries(
                sources: parser.queries.highlights,
                cacheDir: cacheDir,
                filetype: canonical,
                loader: assetLoader
            )
            if !queryText.isEmpty {
                state.withLock { $0.loadedQueries[canonical] = queryText }
            }
        }
        return hasParser(for: canonical)
    }

    // MARK: - Highlighting (`SyntaxHighlighter` + `highlightOnce` + `highlightAppend` + `removeCopy`)

    /// Synchronously highlights `content` for `filetype` (satisfying `SyntaxHighlighter`).
    public func highlight(content: String, filetype: String) -> SyntaxHighlightResult {
        let outcome = evaluateHighlight(content: content, filetype: filetype)
        return SyntaxHighlightResult(
            highlights: outcome.highlights ?? [],
            warning: outcome.warning ?? outcome.error
        )
    }

    /// Asynchronously highlights `content` once for `filetype` (`SyntaxHighlighter` conformance).
    public func highlightOnce(content: String, filetype: String) async -> SyntaxHighlightResult {
        let outcome = await highlightOnce(content, filetype: filetype)
        return SyntaxHighlightResult(
            highlights: outcome.highlights ?? [],
            warning: outcome.warning ?? outcome.error
        )
    }

    /// One-shot highlighting with automatic initialization and result caching, matching `TreeSitterClient.highlightOnce`.
    // parity: core/src/lib/tree-sitter/client.ts#TreeSitterClient.highlightOnce [status=adapted hash=171100f6e364]
    public func highlightOnce(_ content: String, filetype: String) async -> TreeSitterHighlightOutcome {
        if !isInitialized() {
            do {
                try await initialize()
            } catch {
                return TreeSitterHighlightOutcome(error: "Could not highlight because of initialization error")
            }
        }
        return evaluateHighlight(content: content, filetype: filetype)
    }

    /// Streaming append highlighting: appends `text` at UTF-16 `offset` of copy `copyId` and highlights the accumulated copy.
    // parity: core/src/lib/tree-sitter/client.ts#TreeSitterClient.highlightAppend [status=adapted hash=badc74d2d78c]
    public func highlightAppend(
        copyId: Int,
        offset: Int,
        text: String,
        filetype: String
    ) async -> TreeSitterHighlightOutcome {
        if !isInitialized() {
            do {
                try await initialize()
            } catch {
                return TreeSitterHighlightOutcome(error: "Could not highlight because of initialization error")
            }
        }

        let updateResult: Result<String, TreeSitterClientError> = state.withLock { s in
            if var existing = s.streamingCopies[copyId] {
                guard offset == existing.utf16Length else {
                    return .failure(
                        .invalidConfiguration(
                            "Append offset \(offset) does not match copy \(copyId) length \(existing.utf16Length)"
                        )
                    )
                }
                existing.content += text
                existing.utf16Length += text.utf16.count
                existing.filetype = filetype
                s.streamingCopies[copyId] = existing
                return .success(existing.content)
            } else {
                guard offset == 0 else {
                    return .failure(
                        .invalidConfiguration(
                            "Initial append offset for copy \(copyId) must be 0, got \(offset)"
                        )
                    )
                }
                s.streamingCopies[copyId] = StreamingCopy(
                    filetype: filetype,
                    content: text,
                    utf16Length: text.utf16.count
                )
                return .success(text)
            }
        }

        switch updateResult {
        case .failure(let error):
            return TreeSitterHighlightOutcome(error: error.description)
        case .success(let accumulated):
            return evaluateHighlight(content: accumulated, filetype: filetype)
        }
    }

    /// Disposes a streaming append copy previously created by `highlightAppend`.
    // parity: core/src/lib/tree-sitter/client.ts#TreeSitterClient.removeCopy [status=implemented hash=a08ba96c50f9]
    public func removeCopy(_ copyId: Int) async {
        _ = state.withLock { $0.streamingCopies.removeValue(forKey: copyId) }
    }

    // MARK: - Incremental Buffer Lifecycle

    /// Creates and initializes a managed document buffer, emitting `"buffer:initialized"` and initial highlights.
    // parity: core/src/lib/tree-sitter/client.ts#TreeSitterClient.createBuffer [status=adapted hash=d86e16d9700b]
    public func createBuffer(
        id: Int,
        content: String,
        filetype: String,
        version: Int = 1,
        autoInitialize: Bool = true
    ) async throws -> Bool {
        if !isInitialized() && !autoInitialize {
            emitError("Could not create buffer because client is not initialized", bufferId: nil)
            return false
        }

        let exists = state.withLock { $0.buffers[id] != nil }
        if exists {
            throw TreeSitterClientError.bufferAlreadyExists(id)
        }

        let placeholder = BufferState(id: id, version: version, content: content, filetype: filetype, hasParser: false)
        state.withLock { $0.buffers[id] = placeholder }

        if !isInitialized() {
            do {
                try await initialize()
            } catch {
                state.withLock { s in
                    if s.buffers[id] == placeholder {
                        s.buffers.removeValue(forKey: id)
                    }
                }
                emitError("Could not create buffer because of initialization error", bufferId: nil)
                return false
            }
            let stillPresent = state.withLock { $0.buffers[id] == placeholder }
            if !stillPresent { return false }
        }

        let supported = hasParser(for: filetype)
        if !supported {
            emitBufferInitialized(bufferId: id, hasParser: false)
            if filetype.lowercased() != "plaintext" {
                emitWarning("No parser available for filetype: \(filetype)", bufferId: id)
            }
            return false
        }

        state.withLock { s in
            if s.buffers[id] != nil {
                s.buffers[id] = BufferState(id: id, version: version, content: content, filetype: filetype, hasParser: true)
            }
        }
        emitBufferInitialized(bufferId: id, hasParser: true)

        let outcome = evaluateHighlight(content: content, filetype: filetype)
        let responses = convertHighlightsToLineResponses(content: content, highlights: outcome.highlights ?? [])
        emitHighlightsResponse(bufferId: id, version: version, highlights: responses)
        return true
    }

    /// Updates an existing managed buffer with edits and new content, emitting fresh line highlights.
    // parity: core/src/lib/tree-sitter/client.ts#TreeSitterClient.updateBuffer [status=adapted hash=d3640391b01a]
    public func updateBuffer(id: Int, edits: [Edit], newContent: String, version: Int) async {
        guard isInitialized() else { return }
        let updated: BufferState? = state.withLock { s in
            guard var buffer = s.buffers[id], buffer.hasParser else { return nil }
            buffer.content = newContent
            buffer.version = version
            s.buffers[id] = buffer
            return buffer
        }
        guard let buffer = updated else { return }
        let outcome = evaluateHighlight(content: buffer.content, filetype: buffer.filetype)
        let responses = convertHighlightsToLineResponses(content: buffer.content, highlights: outcome.highlights ?? [])
        emitHighlightsResponse(bufferId: id, version: version, highlights: responses)
    }

    /// Resets a managed buffer's content and version and re-highlights from scratch.
    // parity: core/src/lib/tree-sitter/client.ts#TreeSitterClient.resetBuffer [status=adapted hash=a5560c8b74cd]
    public func resetBuffer(bufferId: Int, version: Int, content: String) async {
        guard isInitialized() else { return }
        let updated: BufferState? = state.withLock { s in
            guard var buffer = s.buffers[bufferId], buffer.hasParser else { return nil }
            buffer.content = content
            buffer.version = version
            s.buffers[bufferId] = buffer
            return buffer
        }
        guard let buffer = updated else {
            emitError("Cannot reset buffer with no parser", bufferId: bufferId)
            return
        }
        let outcome = evaluateHighlight(content: buffer.content, filetype: buffer.filetype)
        let responses = convertHighlightsToLineResponses(content: buffer.content, highlights: outcome.highlights ?? [])
        emitHighlightsResponse(bufferId: bufferId, version: version, highlights: responses)
    }

    /// Removes a managed buffer and emits `"buffer:disposed"`.
    // parity: core/src/lib/tree-sitter/client.ts#TreeSitterClient.removeBuffer [status=implemented hash=e4dce071f7d9]
    public func removeBuffer(_ bufferId: Int) async {
        let wasInitialized = state.withLock { s -> Bool in
            s.buffers.removeValue(forKey: bufferId)
            return s.initialized
        }
        if wasInitialized {
            emitBufferDisposed(bufferId: bufferId)
        }
    }

    /// Returns the tracked `BufferState` for `bufferId`, if any.
    // parity: core/src/lib/tree-sitter/client.ts#TreeSitterClient.getBuffer [status=implemented hash=39b184759bf4]
    public func getBuffer(_ bufferId: Int) -> BufferState? {
        state.withLock { $0.buffers[bufferId] }
    }

    /// Returns snapshots of all currently managed buffers.
    // parity: core/src/lib/tree-sitter/client.ts#TreeSitterClient.getAllBuffers [status=implemented hash=805135ad3612]
    public func getAllBuffers() -> [BufferState] {
        state.withLock { Array($0.buffers.values) }
    }

    // MARK: - Performance, Data Path & Cache Control

    /// Returns aggregate parse and query timing statistics collected by this client.
    // parity: core/src/lib/tree-sitter/client.ts#TreeSitterClient.getPerformance [status=implemented hash=f25951dbb206]
    public func getPerformance() async -> PerformanceStats {
        state.withLock { s in
            let avgParse = s.parseTimes.isEmpty ? 0 : s.parseTimes.reduce(0, +) / Double(s.parseTimes.count)
            let avgQuery = s.queryTimes.isEmpty ? 0 : s.queryTimes.reduce(0, +) / Double(s.queryTimes.count)
            return PerformanceStats(
                averageParseTime: avgParse,
                parseTimes: s.parseTimes,
                averageQueryTime: avgQuery,
                queryTimes: s.queryTimes
            )
        }
    }

    /// Updates the client's cache/data directory path.
    // parity: core/src/lib/tree-sitter/client.ts#TreeSitterClient.setDataPath [status=implemented hash=3d1130556914]
    public func setDataPath(_ dataPath: String) async {
        state.withLock { s in
            guard s.options.dataPath != dataPath else { return }
            s.options.dataPath = dataPath
        }
    }

    /// Clears cached highlight outcomes and loaded query strings (throws if not initialized).
    // parity: core/src/lib/tree-sitter/client.ts#TreeSitterClient.clearCache [status=implemented hash=1b700ce27905]
    public func clearCache() async throws {
        try state.withLock { s throws in
            guard s.initialized && !s.destroyed else {
                throw TreeSitterClientError.notInitialized("Cannot clear cache: client is not initialized")
            }
            s.highlightCache.removeAll(keepingCapacity: true)
            s.cacheOrder.removeAll(keepingCapacity: true)
            s.loadedQueries.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - Internal Evaluation & Helpers

    private func hasParser(for filetype: String) -> Bool {
        let lower = filetype.lowercased()
        if lower == "plaintext" { return false }
        let (canonical, hasRegistered, hasCustom) = state.withLock { s -> (String, Bool, Bool) in
            let canon = Self.resolveCanonicalFiletypeLocked(lower, state: s)
            return (canon, s.parsersByFiletype[canon] != nil, s.customHighlighters[canon] != nil)
        }
        if hasCustom || hasRegistered {
            return true
        }
        if BuiltInSyntaxHighlighter.supportedFiletypes.contains(canonical) {
            return true
        }
        if let resolved = resolveFiletype(filetype), BuiltInSyntaxHighlighter.supportedFiletypes.contains(resolved) {
            return true
        }
        return false
    }

    private func evaluateHighlight(content: String, filetype: String) -> TreeSitterHighlightOutcome {
        let (canonical, cached, customHighlighter) = state.withLock { s -> (String, TreeSitterHighlightOutcome?, (any SyntaxHighlighter)?) in
            let canon = Self.resolveCanonicalFiletypeLocked(filetype, state: s)
            let key = CacheKey(filetype: canon, content: content)
            return (canon, s.highlightCache[key], s.customHighlighters[canon])
        }

        if let cached {
            return cached
        }

        let start = ContinuousClock.now
        let result: SyntaxHighlightResult
        if let customHighlighter {
            result = customHighlighter.highlight(content: content, filetype: canonical)
        } else {
            result = defaultHighlighter.highlight(content: content, filetype: canonical)
        }
        let elapsed = start.duration(to: ContinuousClock.now)
        let (sec, atto) = elapsed.components
        let elapsedMs = Double(sec) * 1_000.0 + Double(atto) / 1_000_000_000_000_000.0

        let outcome = TreeSitterHighlightOutcome(
            highlights: result.highlights,
            warning: result.warning
        )

        state.withLock { s in
            s.parseTimes.append(elapsedMs)
            s.queryTimes.append(elapsedMs)
            if s.parseTimes.count > 100 { s.parseTimes.removeFirst(s.parseTimes.count - 100) }
            if s.queryTimes.count > 100 { s.queryTimes.removeFirst(s.queryTimes.count - 100) }

            let maxEntries = s.options.maxCacheEntries
            if maxEntries > 0 {
                let key = CacheKey(filetype: canonical, content: content)
                if s.highlightCache[key] == nil {
                    s.cacheOrder.append(key)
                    if s.cacheOrder.count > maxEntries {
                        let evicted = s.cacheOrder.removeFirst()
                        s.highlightCache.removeValue(forKey: evicted)
                    }
                }
                s.highlightCache[key] = outcome
            }
        }

        return outcome
    }

    private static func resolveAssetPathForParser(_ path: String) -> String {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return path
        }
        if isBunfsPath(path) {
            return normalizeBunfsPath(portableBasename(path))
        }
        return path
    }

    private static func normalizeParserOptions(_ parser: FiletypeParserOptions) -> FiletypeParserOptions {
        let dedupedAliases: [String]? = parser.aliases.map { aliases in
            var seen: Set<String> = [parser.filetype]
            var out: [String] = []
            for alias in aliases where seen.insert(alias).inserted {
                out.append(alias)
            }
            return out
        }
        return FiletypeParserOptions(
            filetype: parser.filetype,
            aliases: dedupedAliases,
            queries: FiletypeParserQueries(
                highlights: parser.queries.highlights.map(resolveAssetPathForParser),
                injections: parser.queries.injections?.map(resolveAssetPathForParser)
            ),
            wasm: resolveAssetPathForParser(parser.wasm),
            injectionMapping: parser.injectionMapping
        )
    }

    private static func installParserLocked(_ parser: FiletypeParserOptions, into state: inout State) {
        let key = parser.filetype.lowercased()
        state.parsersByFiletype[key] = parser
        if let aliases = parser.aliases {
            for alias in aliases {
                let lowerAlias = alias.lowercased()
                if lowerAlias != key {
                    state.aliasToFiletype[lowerAlias] = key
                }
            }
        }
    }

    private static func resolveCanonicalFiletypeLocked(_ raw: String, state: State) -> String {
        let lower = raw.lowercased()
        if let aliased = state.aliasToFiletype[lower] {
            return aliased
        }
        if state.parsersByFiletype[lower] != nil || state.customHighlighters[lower] != nil {
            return lower
        }
        if let resolved = resolveFiletype(raw) {
            let resolvedLower = resolved.lowercased()
            if let aliased = state.aliasToFiletype[resolvedLower] {
                return aliased
            }
            return resolvedLower
        }
        return lower
    }

    private func emitHighlightsResponse(bufferId: Int, version: Int, highlights: [HighlightResponse]) {
        let handlers = state.withLock { $0.highlightsListeners.map(\.handler) }
        for handler in handlers {
            handler(bufferId, version, highlights)
        }
    }

    private func emitBufferInitialized(bufferId: Int, hasParser: Bool) {
        let handlers = state.withLock { $0.bufferInitListeners.map(\.handler) }
        for handler in handlers {
            handler(bufferId, hasParser)
        }
    }

    private func emitBufferDisposed(bufferId: Int) {
        let handlers = state.withLock { $0.bufferDisposedListeners.map(\.handler) }
        for handler in handlers {
            handler(bufferId)
        }
    }

    private func emitWarning(_ warning: String, bufferId: Int?) {
        let handlers = state.withLock { $0.warningListeners.map(\.handler) }
        for handler in handlers {
            handler(warning, bufferId)
        }
    }

    private func emitError(_ error: String, bufferId: Int?) {
        let handlers = state.withLock { $0.errorListeners.map(\.handler) }
        for handler in handlers {
            handler(error, bufferId)
        }
    }
}

// MARK: - Default TreeSitterClient Singleton (`core/src/lib/tree-sitter/index.ts`)

private let treeSitterClientSingletonKey = "tree-sitter-client"
private let treeSitterClientListenerTokenStore = Mutex<DataPathsListenerToken?>(nil)

/// Returns the shared process-wide `TreeSitterClient` singleton, automatically tracking `getDataPaths()` updates.
// parity: core/src/lib/tree-sitter/index.ts#getTreeSitterClient [status=implemented hash=6d40d576112b]
public func getTreeSitterClient() -> TreeSitterClient {
    if let existing: TreeSitterClient = getSingleton(treeSitterClientSingletonKey) {
        return existing
    }

    let dataPathsManager = getDataPaths()
    return singleton(treeSitterClientSingletonKey) {
        let client = TreeSitterClient(
            options: TreeSitterClientOptions(dataPath: dataPathsManager.globalDataPath)
        )
        let token = dataPathsManager.onPathsChanged { paths in
            Task {
                await client.setDataPath(paths.globalDataPath)
            }
        }
        treeSitterClientListenerTokenStore.withLock { $0 = token }
        client.onDestroy {
            let currentToken = treeSitterClientListenerTokenStore.withLock { t -> DataPathsListenerToken? in
                let prev = t
                t = nil
                return prev
            }
            if let currentToken {
                dataPathsManager.offPathsChanged(currentToken)
            }
            if let current: TreeSitterClient = getSingleton(treeSitterClientSingletonKey), current === client {
                destroySingleton(treeSitterClientSingletonKey)
            }
        }
        return client
    }
}

/// Replaces (or clears when `nil`) the default `TreeSitterClient` returned by `getTreeSitterClient()`.
public func setDefaultTreeSitterClient(_ client: TreeSitterClient?) {
    let dataPathsManager = getDataPaths()
    if let oldToken = treeSitterClientListenerTokenStore.withLock({ t -> DataPathsListenerToken? in
        let prev = t
        t = nil
        return prev
    }) {
        dataPathsManager.offPathsChanged(oldToken)
    }
    destroySingleton(treeSitterClientSingletonKey)
    if let client {
        _ = singleton(treeSitterClientSingletonKey) { client }
    }
}

/// Destroys and removes the shared `TreeSitterClient` singleton, if present.
// parity: core/src/lib/tree-sitter/index.ts#destroyTreeSitterClient [status=implemented hash=869de1c7b706]
public func destroyTreeSitterClient() async {
    let existing: TreeSitterClient? = getSingleton(treeSitterClientSingletonKey)
    destroySingleton(treeSitterClientSingletonKey)
    if let token = treeSitterClientListenerTokenStore.withLock({ t -> DataPathsListenerToken? in
        let prev = t
        t = nil
        return prev
    }) {
        getDataPaths().offPathsChanged(token)
    }
    if let existing {
        await existing.destroy()
    }
}
