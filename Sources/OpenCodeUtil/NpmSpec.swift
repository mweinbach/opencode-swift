/// Pure-Swift npm package specification helpers matching `packages/util/src/npm.ts`.
public enum NpmSpec {
    // parity: util/src/npm.ts#InstallFailedError [status=implemented hash=3f7b6785d4b4]
    public struct InstallFailedError: Error, Equatable, Sendable, CustomStringConvertible {
        public let add: [String]?
        public let dir: String
        public let causeMessage: String?
        public let causeStderr: String?

        public init(
            add: [String]? = nil,
            dir: String,
            causeMessage: String? = nil,
            causeStderr: String? = nil
        ) {
            self.add = add
            self.dir = dir
            self.causeMessage = causeMessage
            self.causeStderr = causeStderr
        }

        public var message: String {
            let target = (add?.isEmpty == false) ? add!.joined(separator: ", ") : dir
            let summary = "Failed to install \(target)"
            guard let causeMessage else { return summary }
            let trimmedStderr = causeStderr?.trimmingASCIIWhitespace() ?? ""
            if trimmedStderr.isEmpty {
                return "\(summary): \(causeMessage)"
            }
            return "\(summary): \(causeMessage)\n\(trimmedStderr)"
        }

        public var description: String { message }
    }

    // parity: util/src/npm.ts#Package [status=implemented hash=b6a2a8c6f446]
    public struct Package: Equatable, Hashable, Sendable, Codable {
        public let directory: String
        public let name: String
        public let version: String?
        public let revision: String?

        public init(directory: String, name: String, version: String? = nil, revision: String? = nil) {
            self.directory = directory
            self.name = name
            self.version = version
            self.revision = revision
        }
    }

    public enum ParsedTarget: Equatable, Hashable, Sendable {
        case registry(name: String, spec: String, mutable: Bool)
        case git(name: String?, slug: String, mutable: Bool)
    }

    private static let windowsIllegalChars: Set<UInt16> = [
        0x3C, // '<'
        0x3E, // '>'
        0x3A, // ':'
        0x22, // '"'
        0x7C, // '|'
        0x3F, // '?'
        0x2A, // '*'
    ]

    /// Replaces Windows-illegal filename characters (`< > : " | ? *` and control chars < 32) with `_`.
    // parity: util/src/npm.ts#sanitize [status=implemented hash=1abc6f1eb40e]
    public static func sanitize(_ pkg: String, isWindows: Bool? = nil) -> String {
        guard isWindows ?? defaultIsWindows else { return pkg }
        var out = ""
        out.reserveCapacity(pkg.count)
        for ch in pkg {
            if let firstU16 = ch.utf16.first, (windowsIllegalChars.contains(firstU16) || firstU16 < 32) {
                out.append("_")
            } else {
                out.append(ch)
            }
        }
        return out
    }

    // parity: util/src/npm.ts#isRegistryPackage [status=implemented hash=f1e0ecdd30cb]
    public static func isRegistryPackage(_ pkg: String) -> Bool {
        if case .registry = parse(pkg) { return true }
        return false
    }

    // parity: util/src/npm.ts#isInstallablePackage [status=implemented hash=e947d1f4e16d]
    public static func isInstallablePackage(_ pkg: String) -> Bool {
        parse(pkg) != nil
    }

    // parity: util/src/npm.ts#cacheKey [status=implemented hash=bffe9eca4a08]
    public static func cacheKey(_ pkg: String, isWindows: Bool? = nil) -> String {
        switch parse(pkg) {
        case .git(_, let slug, _):
            let digest = String(Hash.sha256(pkg).prefix(12))
            return "git-\(slug)-\(digest)"
        case .registry(let name, let spec, _):
            return sanitize("\(name)@\(spec)", isWindows: isWindows)
        case nil:
            return sanitize(pkg, isWindows: isWindows)
        }
    }

    public static func parse(_ pkg: String) -> ParsedTarget? {
        let trimmed = pkg.trimmingASCIIWhitespace()
        guard !trimmed.isEmpty, trimmed == pkg else {
            // npm-package-arg rejects leading/trailing whitespace in names, though handles raw cleanly.
            if trimmed.isEmpty { return nil }
            return nil
        }

        // Reject explicit file/directory/tarball paths early.
        if pkg.hasPrefix("file:") || pkg.hasPrefix("./") || pkg.hasPrefix("../") || pkg.hasPrefix("/") || pkg.hasPrefix("~/") {
            return nil
        }

        // Split optional `name@spec` (accounting for `@scope/name@spec`).
        let (optName, rawSpec) = splitNameAndSpec(pkg)

        if let name = optName, let spec = rawSpec {
            if spec.hasPrefix("file:") || spec.hasPrefix("npm:") || isTarballSpec(spec) {
                return nil
            }
            if isGitSpec(spec) {
                return .git(
                    name: name,
                    slug: gitSlug(pkg),
                    mutable: !isCommitHash(extractGitCommittish(spec))
                )
            }
            guard isValidPackageName(name) else { return nil }
            if spec.isEmpty {
                return .registry(name: name, spec: "latest", mutable: true)
            }
            if isValidRegistrySpec(spec) {
                let exact = isExactSemver(spec)
                return .registry(name: name, spec: spec, mutable: !exact)
            }
            return nil
        }

        // No `@spec` split (or bare package name / bare git URL / bare GitHub shorthand)
        if isGitSpec(pkg) {
            return .git(
                name: nil,
                slug: gitSlug(pkg),
                mutable: !isCommitHash(extractGitCommittish(pkg))
            )
        }
        if isTarballSpec(pkg) {
            return nil
        }
        if isValidPackageName(pkg) {
            return .registry(name: pkg, spec: "latest", mutable: true)
        }
        return nil
    }

    public static func gitSlug(_ pkg: String) -> String {
        let beforeHash: String
        if let hashIdx = pkg.firstIndex(of: "#") {
            beforeHash = String(pkg[..<hashIdx])
        } else {
            beforeHash = pkg
        }
        let decoded = percentDecode(beforeHash) ?? beforeHash
        var stripped = decoded
        if stripped.lowercased().hasSuffix(".git") {
            stripped = String(stripped.dropLast(4))
        }
        let segments = stripped.split(omittingEmptySubsequences: false) { ch in
            ch == "/" || ch == ":" || ch == "\\"
        }
        let last = segments.last.map(String.init) ?? ""
        var slug = ""
        var prevDash = false
        for ch in last {
            let ok = ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-")
            if ok {
                slug.append(ch)
                prevDash = false
            } else if !prevDash {
                slug.append("-")
                prevDash = true
            }
        }
        while slug.hasPrefix("-") { slug.removeFirst() }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "repository" : slug
    }

    // MARK: - Helpers

    private static var defaultIsWindows: Bool {
        #if os(Windows)
        return true
        #else
        return false
        #endif
    }

    private static func splitNameAndSpec(_ pkg: String) -> (String?, String?) {
        // Don't split bare git URLs like git@github.com:org/repo.git
        if pkg.hasPrefix("git@") || pkg.hasPrefix("git+") || pkg.hasPrefix("git://")
            || pkg.hasPrefix("http://") || pkg.hasPrefix("https://") || pkg.hasPrefix("ssh://")
            || pkg.hasPrefix("github:") || pkg.hasPrefix("gitlab:") || pkg.hasPrefix("bitbucket:")
            || pkg.hasPrefix("gist:") {
            return (nil, nil)
        }
        if pkg.hasPrefix("@") {
            // Scoped: `@scope/name` or `@scope/name@spec`
            guard let slash = pkg.firstIndex(of: "/") else { return (nil, nil) }
            let afterSlash = pkg.index(after: slash)
            if let at = pkg[afterSlash...].firstIndex(of: "@") {
                return (String(pkg[..<at]), String(pkg[pkg.index(after: at)...]))
            }
            return (nil, nil)
        }
        if let at = pkg.firstIndex(of: "@") {
            let name = String(pkg[..<at])
            let spec = String(pkg[pkg.index(after: at)...])
            if isValidPackageName(name) {
                return (name, spec)
            }
        }
        return (nil, nil)
    }

    private static func isTarballSpec(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.hasSuffix(".tgz") || lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tar")
    }

    private static func isGitSpec(_ s: String) -> Bool {
        if s.hasPrefix("git+") || s.hasPrefix("git://") || s.hasPrefix("git@")
            || s.hasPrefix("github:") || s.hasPrefix("gitlab:") || s.hasPrefix("bitbucket:")
            || s.hasPrefix("gist:") || s.hasPrefix("ssh://") {
            return true
        }
        if s.hasPrefix("https://") || s.hasPrefix("http://") {
            let base = s.split(separator: "#", maxSplits: 1).first.map(String.init) ?? s
            if base.lowercased().hasSuffix(".git") { return true }
            if base.hasPrefix("https://github.com/") || base.hasPrefix("https://gitlab.com/")
                || base.hasPrefix("https://bitbucket.org/") {
                let parts = base.dropFirst("https://".count).split(separator: "/")
                return parts.count == 3 // host / owner / repo
            }
            return false
        }
        // GitHub shorthand: `owner/repo` or `owner/repo#ref`
        if !s.hasPrefix("@") && !s.hasPrefix(".") && !s.hasPrefix("/") {
            let base = s.split(separator: "#", maxSplits: 1).first.map(String.init) ?? s
            let parts = base.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty {
                let validPart: (Substring) -> Bool = { part in
                    part.allSatisfy { ch in
                        ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-")
                    }
                }
                return validPart(parts[0]) && validPart(parts[1])
            }
        }
        return false
    }

    private static func extractGitCommittish(_ s: String) -> String? {
        guard let idx = s.firstIndex(of: "#") else { return nil }
        let ref = String(s[s.index(after: idx)...])
        return ref.isEmpty ? nil : ref
    }

    private static func isCommitHash(_ committish: String?) -> Bool {
        guard let committish, committish.count >= 7 && committish.count <= 40 else { return false }
        return committish.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
        }
    }

    private static func isValidPackageName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 214 else { return false }
        guard !name.hasPrefix("."), !name.hasPrefix("_") else { return false }
        if name.hasPrefix("@") {
            let parts = name.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
            return isValidPackageSegment(parts[0]) && isValidPackageSegment(parts[1])
        }
        guard !name.contains("/") else { return false }
        return isValidPackageSegment(name[...])
    }

    private static func isValidPackageSegment(_ seg: Substring) -> Bool {
        guard !seg.isEmpty, !seg.hasPrefix("."), !seg.hasPrefix("_") else { return false }
        for b in seg.utf8 {
            let lowerAlpha = (b >= 0x61 && b <= 0x7A)
            let digit = (b >= 0x30 && b <= 0x39)
            let punct = (b == 0x2D || b == 0x5F || b == 0x2E || b == 0x7E) // - _ . ~
            if !(lowerAlpha || digit || punct) {
                return false
            }
        }
        return true
    }

    private static func isValidRegistrySpec(_ spec: String) -> Bool {
        guard !spec.isEmpty else { return false }
        // Reject raw URLs / paths inside version specs
        if spec.contains("://") || spec.hasPrefix("/") || spec.hasPrefix("./") || spec.hasPrefix("../") {
            return false
        }
        return true
    }

    private static func isExactSemver(_ spec: String) -> Bool {
        var s = spec
        if s.hasPrefix("v") || s.hasPrefix("=") { s.removeFirst() }
        let main = s.split(separator: "-", maxSplits: 1).first?.split(separator: "+", maxSplits: 1).first ?? Substring()
        let nums = main.split(separator: ".", omittingEmptySubsequences: false)
        guard nums.count == 3 else { return false }
        return nums.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
        }
    }

    private static func percentDecode(_ s: String) -> String? {
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25 { // '%'
                guard i + 2 < bytes.count,
                      let hi = hexVal(bytes[i + 1]),
                      let lo = hexVal(bytes[i + 2]) else {
                    return nil
                }
                out.append((hi << 4) | lo)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexVal(_ b: UInt8) -> UInt8? {
        if b >= 0x30 && b <= 0x39 { return b - 0x30 }
        if b >= 0x41 && b <= 0x46 { return b - 0x41 + 10 }
        if b >= 0x61 && b <= 0x66 { return b - 0x61 + 10 }
        return nil
    }
}

private extension String {
    func trimmingASCIIWhitespace() -> String {
        let bytes = Array(utf8)
        var start = 0
        var end = bytes.count
        while start < end && (bytes[start] == 0x20 || bytes[start] == 0x09 || bytes[start] == 0x0A || bytes[start] == 0x0D) {
            start += 1
        }
        while end > start && (bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09 || bytes[end - 1] == 0x0A || bytes[end - 1] == 0x0D) {
            end -= 1
        }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }
}
