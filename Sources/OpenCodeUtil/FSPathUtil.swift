/// Pure-Swift path, MIME, and directory-containment helpers matching `packages/util/src/fs-util.ts`.
public enum FSPathUtil {
    // parity: util/src/fs-util.ts#FSUtil.FileSystemError [status=implemented hash=81fb24d92e0b]
    public struct FileSystemError: Error, Equatable, Sendable, CustomStringConvertible {
        public let method: String
        public let detail: String?

        public init(method: String, detail: String? = nil) {
            self.method = method
            self.detail = detail
        }

        public var message: String {
            if let detail, !detail.isEmpty {
                return "Filesystem operation failed: \(method): \(detail)"
            }
            return "Filesystem operation failed: \(method)"
        }

        public var description: String { message }
    }

    public enum UpMode: String, Equatable, Hashable, Sendable, Codable {
        case all
        case first
    }

    public enum UpEntryType: String, Equatable, Hashable, Sendable, Codable {
        case file
        case directory
    }

    // parity: util/src/fs-util.ts#FSUtil.UpOptions [status=implemented hash=a7214da65487]
    public struct UpOptions: Equatable, Hashable, Sendable, Codable {
        public let targets: [String]
        public let start: String
        public let stop: String?
        public let mode: UpMode?
        public let type: UpEntryType?

        public init(
            targets: [String],
            start: String,
            stop: String? = nil,
            mode: UpMode? = nil,
            type: UpEntryType? = nil
        ) {
            self.targets = targets
            self.start = start
            self.stop = stop
            self.mode = mode
            self.type = type
        }
    }

    // parity: util/src/fs-util.ts#FSUtil.ignoredDirectories [status=implemented hash=d8f78139eb76]
    public static let ignoredDirectories: [String] = [
        "node_modules", ".git", ".venv", "venv", "__pycache__",
    ]

    // parity: util/src/fs-util.ts#FSUtil.ignoreGlobs [status=implemented hash=a8cef7f31e58]
    public static let ignoreGlobs: [String] =
        ignoredDirectories + ["**/{\(ignoredDirectories.joined(separator: ","))}/**"]

    private static let mimeTable: [String: String] = [
        "txt": "text/plain",
        "log": "text/plain",
        "md": "text/markdown",
        "markdown": "text/markdown",
        "mdx": "text/mdx",
        "html": "text/html",
        "htm": "text/html",
        "css": "text/css",
        "csv": "text/csv",
        "tsv": "text/tab-separated-values",
        "xml": "application/xml",
        "json": "application/json",
        "jsonc": "application/json",
        "jsonl": "application/json",
        "js": "text/javascript",
        "mjs": "text/javascript",
        "cjs": "text/javascript",
        "jsx": "text/jsx",
        "ts": "video/mp2t",
        "tsx": "text/tsx",
        "yaml": "text/yaml",
        "yml": "text/yaml",
        "toml": "application/toml",
        "wasm": "application/wasm",
        "pdf": "application/pdf",
        "zip": "application/zip",
        "gz": "application/gzip",
        "tar": "application/x-tar",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "avif": "image/avif",
        "bmp": "image/bmp",
        "ico": "image/vnd.microsoft.icon",
        "tif": "image/tiff",
        "tiff": "image/tiff",
        "heic": "image/heic",
        "svg": "image/svg+xml",
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "ogg": "audio/ogg",
        "oga": "audio/ogg",
        "m4a": "audio/mp4",
        "aac": "audio/aac",
        "flac": "audio/flac",
        "opus": "audio/ogg",
        "weba": "audio/webm",
        "mp4": "video/mp4",
        "m4v": "video/x-m4v",
        "webm": "video/webm",
        "mov": "video/quicktime",
        "ogv": "video/ogg",
        "mkv": "video/x-matroska",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "swift": "text/x-swift",
        "rs": "text/x-rust",
        "py": "text/x-python",
        "go": "text/x-go",
        "c": "text/x-c",
        "h": "text/x-c",
        "cpp": "text/x-c",
        "sh": "application/x-sh",
    ]

    /// MIME type lookup by file extension, defaulting to `application/octet-stream`.
    // parity: util/src/fs-util.ts#FSUtil.mimeType [status=implemented hash=7cb23319bfe0]
    public static func mimeType(_ path: String) -> String {
        let base = path.split { $0 == "/" || $0 == "\\" }.last.map(String.init) ?? ""
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else {
            return "application/octet-stream"
        }
        let ext = String(base[base.index(after: dot)...]).lowercased()
        return mimeTable[ext] ?? "application/octet-stream"
    }

    /// Normalizes Git Bash / Cygwin / WSL drive prefixes (`/c/...`, `/c:/...`, `/cygdrive/c/...`, `/mnt/c/...`)
    /// into canonical Windows drive paths (`C:/...`) when running on Windows.
    // parity: util/src/fs-util.ts#FSUtil.windowsPath [status=implemented hash=af049433819b]
    public static func windowsPath(_ path: String, isWindows: Bool? = nil) -> String {
        guard isWindows ?? defaultIsWindows else { return path }
        let chars = Array(path)
        func isASCIIAlpha(_ c: Character) -> Bool {
            guard let v = c.asciiValue else { return false }
            return (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
        }
        // 1. ^/([a-zA-Z]):(?:/|\\|$)
        if chars.count >= 3, chars[0] == "/", isASCIIAlpha(chars[1]), chars[2] == ":" {
            if chars.count == 3 {
                return "\(String(chars[1]).uppercased()):/"
            }
            if chars[3] == "/" || chars[3] == "\\" {
                return "\(String(chars[1]).uppercased()):/" + String(chars[4...])
            }
        }
        // 2. ^/([a-zA-Z])(?:/|$)
        if chars.count >= 2, chars[0] == "/", isASCIIAlpha(chars[1]) {
            if chars.count == 2 {
                return "\(String(chars[1]).uppercased()):/"
            }
            if chars[2] == "/" {
                return "\(String(chars[1]).uppercased()):/" + String(chars[3...])
            }
        }
        // 3. ^/cygdrive/([a-zA-Z])(?:/|$)
        if path.hasPrefix("/cygdrive/") {
            let rest = Array(path.dropFirst("/cygdrive/".count))
            if !rest.isEmpty && isASCIIAlpha(rest[0]) {
                if rest.count == 1 {
                    return "\(String(rest[0]).uppercased()):/"
                }
                if rest[1] == "/" {
                    return "\(String(rest[0]).uppercased()):/" + String(rest[2...])
                }
            }
        }
        // 4. ^/mnt/([a-zA-Z])(?:/|$)
        if path.hasPrefix("/mnt/") {
            let rest = Array(path.dropFirst("/mnt/".count))
            if !rest.isEmpty && isASCIIAlpha(rest[0]) {
                if rest.count == 1 {
                    return "\(String(rest[0]).uppercased()):/"
                }
                if rest[1] == "/" {
                    return "\(String(rest[0]).uppercased()):/" + String(rest[2...])
                }
            }
        }
        return path
    }

    /// Returns `true` if `parent` equals or contains `child`, or `child` equals or contains `parent`.
    // parity: util/src/fs-util.ts#FSUtil.overlaps [status=implemented hash=83073e3c05c5]
    public static func overlaps(_ a: String, _ b: String) -> Bool {
        contains(parent: a, child: b) || contains(parent: b, child: a)
    }

    /// Returns `true` if `child` is `parent` itself or inside `parent` using POSIX relative path semantics.
    // parity: util/src/fs-util.ts#FSUtil.contains [status=implemented hash=cfb3e1ed8297]
    public static func contains(parent: String, child: String) -> Bool {
        let rel = posixRelative(from: parent, to: child)
        return rel.isEmpty || (!rel.hasPrefix("/") && rel != ".." && !rel.hasPrefix("../"))
    }

    /// Pure-Swift POSIX `path.relative(from, to)` implementation.
    public static func posixRelative(from: String, to: String) -> String {
        let fromParts = normalizePOSIX(from)
        let toParts = normalizePOSIX(to)
        var common = 0
        let minCount = min(fromParts.count, toParts.count)
        while common < minCount && fromParts[common] == toParts[common] {
            common += 1
        }
        var out: [String] = []
        for _ in common..<fromParts.count {
            out.append("..")
        }
        for i in common..<toParts.count {
            out.append(toParts[i])
        }
        return out.joined(separator: "/")
    }

    private static func normalizePOSIX(_ path: String) -> [String] {
        var stack: [String] = []
        for seg in path.split(separator: "/") {
            if seg == "." || seg.isEmpty { continue }
            if seg == ".." {
                if !stack.isEmpty { stack.removeLast() }
            } else {
                stack.append(String(seg))
            }
        }
        return stack
    }

    private static var defaultIsWindows: Bool {
        #if os(Windows)
        return true
        #else
        return false
        #endif
    }
}
