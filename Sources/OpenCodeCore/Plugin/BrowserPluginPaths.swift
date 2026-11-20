import OpenCodePlatform
import OpenCodeUtil

// MARK: - plugin-browser/src/wildcard.ts, workspace.ts, preview-path.ts

/// POSIX `node:path` helpers shared by the browser plugin's workspace, preview and file-transfer code.
///
/// The browser plugin resolves server-local paths the way Node's `path.posix` does. These helpers are pure string
/// operations: they never touch the disk.
enum BrowserPOSIXPath {
    /// Collapses `.`/`..` segments and duplicate separators, keeping a leading `/` for absolute paths.
    static func normalize(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var stack: [Substring] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            if segment == "." { continue }
            if segment == ".." {
                if let last = stack.last, last != ".." {
                    stack.removeLast()
                } else if !absolute {
                    stack.append(segment)
                }
                continue
            }
            stack.append(segment)
        }
        let joined = stack.joined(separator: "/")
        if absolute { return "/" + joined }
        return joined.isEmpty ? "." : joined
    }

    /// `path.resolve(base, path)`: an absolute `path` wins, otherwise it is joined onto `base`.
    static func resolve(_ base: String, _ path: String) -> String {
        if path.hasPrefix("/") { return normalize(path) }
        if path.isEmpty { return normalize(base) }
        return normalize(base + "/" + path)
    }

    /// `path.join(parts...)`.
    static func join(_ parts: String...) -> String {
        normalize(parts.filter { !$0.isEmpty }.joined(separator: "/"))
    }

    /// `path.relative(from, to)` for two paths resolved against `/`.
    static func relative(_ from: String, _ to: String) -> String {
        let fromParts = resolve("/", from).split(separator: "/")
        let toParts = resolve("/", to).split(separator: "/")
        var common = 0
        while common < fromParts.count, common < toParts.count, fromParts[common] == toParts[common] {
            common += 1
        }
        let up = Array(repeating: "..", count: fromParts.count - common)
        let down = toParts[common...].map(String.init)
        return (up + down).joined(separator: "/")
    }

    /// `path.dirname(path)`.
    static func dirname(_ path: String) -> String {
        guard !path.isEmpty else { return "." }
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return "." }
        if slash == trimmed.startIndex { return "/" }
        var head = trimmed[..<slash]
        while head.count > 1, head.hasSuffix("/") { head = head.dropLast() }
        return String(head)
    }

    /// `path.basename(path)`, treating both separators as Node does on the server's platform (`/` and `\`).
    static func basename(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        if let slash = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            return String(trimmed[trimmed.index(after: slash)...])
        }
        return String(trimmed)
    }

    /// `path.extname(path)`: the last `.suffix` of the base name, empty for dotfiles and names without a dot.
    static func extname(_ path: String) -> String {
        let name = basename(path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[dot...])
    }

    /// `path.isAbsolute(path)`.
    static func isAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/")
    }
}

extension BrowserPlugin {
    // MARK: wildcard.ts

    /// Private copy of core's permission wildcard matcher (`packages/core/src/util/wildcard.ts#match`).
    ///
    /// The browser plugin cannot import core, and the rule it picks for a browser call must be the rule core would
    /// pick. Matching runs on UTF-16 code units, as the upstream `RegExp` without the `u` flag does: `*` matches any
    /// run (including newlines, the `s` flag), `?` one code unit, and a trailing ` *` also matches nothing.
    public enum Wildcard {
        private enum Token: Equatable {
            case literal(UInt16)
            case one
            case any
        }

        /// Whether `input` matches the permission `pattern`. Pass `ignoreCase` as true when the server runs on Windows.
        // parity: plugin-browser/src/wildcard.ts#match [status=implemented hash=5fc9c48050f3]
        public static func match(_ input: String, _ pattern: String, ignoreCase: Bool) -> Bool {
            let slash = UInt16(UInt8(ascii: "/"))
            let backslash = UInt16(UInt8(ascii: "\\"))
            let normalized = input.utf16.map { $0 == backslash ? slash : $0 }
            var tokens: [Token] = pattern.utf16.map { unit in
                switch unit {
                case UInt16(UInt8(ascii: "*")): return .any
                case UInt16(UInt8(ascii: "?")): return .one
                case backslash: return .literal(slash)
                default: return .literal(unit)
                }
            }
            // `escaped.endsWith(" .*")` → `( .*)?`: the trailing " *" is optional as a whole.
            let space = Token.literal(UInt16(UInt8(ascii: " ")))
            if tokens.count >= 2, tokens[tokens.count - 1] == .any, tokens[tokens.count - 2] == space {
                let full = tokens
                tokens.removeLast(2)
                return matches(normalized, tokens, ignoreCase) || matches(normalized, full, ignoreCase)
            }
            return matches(normalized, tokens, ignoreCase)
        }

        private static func matches(_ input: [UInt16], _ tokens: [Token], _ ignoreCase: Bool) -> Bool {
            var i = 0
            var t = 0
            var starToken = -1
            var starInput = 0
            while i < input.count {
                if t < tokens.count {
                    switch tokens[t] {
                    case .any:
                        starToken = t
                        starInput = i
                        t += 1
                        continue
                    case .one:
                        i += 1
                        t += 1
                        continue
                    case .literal(let unit):
                        if equal(unit, input[i], ignoreCase) {
                            i += 1
                            t += 1
                            continue
                        }
                    }
                }
                guard starToken >= 0 else { return false }
                t = starToken + 1
                starInput += 1
                i = starInput
            }
            while t < tokens.count, tokens[t] == .any { t += 1 }
            return t == tokens.count
        }

        private static func equal(_ a: UInt16, _ b: UInt16, _ ignoreCase: Bool) -> Bool {
            if a == b { return true }
            guard ignoreCase else { return false }
            return canonicalize(a) == canonicalize(b)
        }

        /// ECMAScript `Canonicalize` for a non-unicode, ignore-case `RegExp`: the code unit's simple upper case, unless
        /// that is several units or maps a non-ASCII unit into ASCII.
        private static func canonicalize(_ unit: UInt16) -> UInt16 {
            if unit < 0x80 {
                if unit >= 0x61 && unit <= 0x7A { return unit - 0x20 }
                return unit
            }
            if unit >= 0xD800 && unit <= 0xDFFF { return unit }
            guard let scalar = Unicode.Scalar(UInt32(unit)) else { return unit }
            let upper = Array(String(scalar).uppercased().utf16)
            guard upper.count == 1, upper[0] >= 0x80 else { return unit }
            return upper[0]
        }
    }

    // MARK: preview-path.ts

    /// Portable workspace-relative preview paths and `workspace://<session>/` display addresses.
    public enum PreviewPath {
        /// Remote preview requests use portable workspace-relative segments, never a server or OS address.
        // parity: plugin-browser/src/preview-path.ts#previewPath [status=implemented hash=7953e7124f23]
        public static func previewPath(_ path: String, windows: Bool = false) -> Bool {
            if hasDrivePrefix(path) { return false }
            return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
                !part.isEmpty && part != "." && part != ".."
                    && !part.unicodeScalars.contains(where: { $0 == "\\" || $0.value <= 0x1F })
                    && (!windows || windowsPreviewSegment(String(part)))
            }
        }

        /// Whether one segment is a name Windows can open: no `:` or `\`, no trailing dot or space, no device name.
        // parity: plugin-browser/src/preview-path.ts#windowsPreviewSegment [status=implemented hash=615d616f7ffd]
        public static func windowsPreviewSegment(_ part: String) -> Bool {
            if part.contains(":") || part.contains("\\") { return false }
            if part.hasSuffix(".") || part.hasSuffix(" ") { return false }
            let lower = part.lowercased()
            let stem = lower.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? lower
            if ["con", "conin$", "conout$", "nul", "prn", "aux"].contains(stem) { return false }
            if stem.count == 4, stem.hasPrefix("com") || stem.hasPrefix("lpt"),
               let digit = stem.last, ("1"..."9").contains(digit)
            {
                return false
            }
            return true
        }

        /// A stable, session-scoped display address with the file tree's relative path, never the API endpoint.
        // parity: plugin-browser/src/preview-path.ts#workspacePrefix [status=implemented hash=a841decc15b4]
        public static func workspacePrefix(_ session: String) -> String {
            "workspace://\(session.lowercased())/"
        }

        /// Parses a `workspace://<session>/<path>` address before URL normalization: rejects other sessions, alternate
        /// authorities, dot segments and encoded separators. Returns the decoded workspace-relative path.
        // parity: plugin-browser/src/preview-path.ts#remotePath [status=implemented hash=360482c1e565]
        public static func remotePath(_ address: String, prefix: String, windows: Bool = false) -> String? {
            let units = Array(address.utf16)
            let prefixUnits = Array(prefix.utf16)
            let head = String(decoding: units.prefix(prefixUnits.count), as: UTF16.self)
            // A scheme and a session ID read the same in any case, and `workspacePrefix` writes them in lower case.
            guard head.lowercased() == prefix else { return nil }
            let rest = String(decoding: units.dropFirst(prefixUnits.count), as: UTF16.self)
            let encoded = String(rest.prefix { $0 != "?" && $0 != "#" })
            if encoded.isEmpty { return nil }
            let lowered = encoded.lowercased()
            if lowered.contains("%2f") || lowered.contains("%5c") { return nil }
            guard let path = decodeURIComponent(encoded) else { return nil }
            return previewPath(path, windows: windows) ? path : nil
        }

        /// `^[a-z]:/` (case-insensitive).
        static func hasDrivePrefix(_ path: String) -> Bool {
            let units = Array(path.utf8.prefix(3))
            guard units.count == 3 else { return false }
            let letter = units[0] | 0x20
            return letter >= UInt8(ascii: "a") && letter <= UInt8(ascii: "z")
                && units[1] == UInt8(ascii: ":") && units[2] == UInt8(ascii: "/")
        }

        /// ECMAScript `decodeURIComponent`: every `%XX` escape decoded as UTF-8; `nil` where it would throw
        /// (a malformed escape or invalid UTF-8).
        static func decodeURIComponent(_ input: String) -> String? {
            let bytes = Array(input.utf8)
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count)
            var i = 0
            func hex(_ b: UInt8) -> UInt8? {
                switch b {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
                case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
                default: return nil
                }
            }
            while i < bytes.count {
                if bytes[i] == UInt8(ascii: "%") {
                    guard i + 2 < bytes.count, let hi = hex(bytes[i + 1]), let lo = hex(bytes[i + 2]) else { return nil }
                    out.append(hi << 4 | lo)
                    i += 3
                } else {
                    out.append(bytes[i])
                    i += 1
                }
            }
            return String(validating: out, as: UTF8.self)
        }
    }

    // MARK: workspace.ts

    /// Workspace containment checks on resolved (physical) paths.
    public enum Workspace {
        /// The physical target of `file` when both its name and its resolved target lie within the same one of
        /// `roots`; `nil` when the name is outside every root or its target escapes them. Physical names compare
        /// exactly, even on Windows: individual NTFS directories can be case sensitive. Errors from resolving the
        /// paths (for example `PlatformError.notFound`) propagate to the caller.
        // parity: plugin-browser/src/workspace.ts#workspaceTarget [status=implemented hash=13bb2fe8c3fb]
        public static func workspaceTarget(
            _ file: String,
            roots: [String],
            fileSystem: (any OpenCodeFileSystem)? = nil
        ) async throws -> String? {
            let candidates = roots.filter { root in
                let child = BrowserPOSIXPath.relative(root, file)
                return child != ".." && !child.hasPrefix("../") && !BrowserPOSIXPath.isAbsolute(child)
            }
            if candidates.isEmpty { return nil }
            let fs = fileSystem ?? CorePlugin.Host.currentFileSystem
            let target = try await fs.realPath(at: file)
            var directories: [String] = []
            for root in candidates {
                directories.append(try await fs.realPath(at: root))
            }
            let contained = directories.contains { root in
                let base = root.hasSuffix("/") ? String(root.dropLast()) : root
                return target == root || target.hasPrefix(base + "/")
            }
            return contained ? target : nil
        }
    }
}
