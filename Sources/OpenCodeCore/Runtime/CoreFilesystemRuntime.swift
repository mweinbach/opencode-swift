#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - CoreFilesystem Namespace (`mime`, `file-access`, `file-mutation`, `file-retention`, `file-write`, `filesystem/*`)

public enum CoreFilesystem {

    // MARK: - MIME Detection (`core/src/mime.ts`)

    public enum Mime {
        /// Detects the MIME type from magic bytes, falling back to `text/plain` vs `application/octet-stream`.
        // parity: core/src/mime.ts#detect [status=implemented hash=1cb2a0750a79]
        public static func detect(_ bytes: [UInt8]) -> String {
            detectMedia(bytes) ?? (isText(bytes) ? "text/plain" : "application/octet-stream")
        }

        /// Detects known image, PDF, audio, and video container MIME types from magic byte headers.
        // parity: core/src/mime.ts#detectMedia [status=implemented hash=3d1a95434e68]
        public static func detectMedia(_ bytes: [UInt8]) -> String? {
            if startsWith(bytes, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
            if startsWith(bytes, [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
            let sig6 = ascii(bytes, start: 0, end: 6)
            if sig6 == "GIF87a" || sig6 == "GIF89a" { return "image/gif" }
            if bytes.count >= 18 && startsWith(bytes, [0x42, 0x4D]) {
                let pixels = readUInt32LE(bytes, offset: 10)
                let dib = readUInt32LE(bytes, offset: 14)
                let validDib: Set<UInt32> = [12, 16, 40, 52, 56, 64, 108, 124]
                if validDib.contains(dib) && pixels >= 14 + dib {
                    return "image/bmp"
                }
            }
            if startsWith(bytes, [0x25, 0x50, 0x44, 0x46, 0x2D]) { return "application/pdf" }
            if bytes.count >= 12 &&
                startsWith(bytes, [0x52, 0x49, 0x46, 0x46]) &&
                startsWith(Array(bytes[8...]), [0x57, 0x45, 0x42, 0x50])
            {
                return "image/webp"
            }
            if bytes.count >= 12 && ascii(bytes, start: 4, end: 8) == "ftyp" {
                let brand = ascii(bytes, start: 8, end: 12)
                let boxSize = Int(readUInt32BE(bytes, offset: 0))
                let boxEnd = min(boxSize, bytes.count)
                var compatible: [String] = []
                if boxEnd >= 20 {
                    let count = (boxEnd - 16) / 4
                    for idx in 0..<count {
                        compatible.append(ascii(bytes, start: 16 + idx * 4, end: 20 + idx * 4))
                    }
                }
                let isGeneric = brand == "mif1" || brand == "msf1"
                if brand == "avif" || brand == "avis" ||
                    (isGeneric && (compatible.contains("avif") || compatible.contains("avis")))
                {
                    return "image/avif"
                }
                if isGeneric || ["heic", "heix", "hevc", "hevx"].contains(brand) {
                    return "image/heic"
                }
                if brand == "qt  " { return "video/quicktime" }
                if brand == "M4A " { return "audio/mp4" }
                return "video/mp4"
            }
            return nil
        }

        /// Returns whether a MIME type represents textual content safe to decode as UTF-8.
        // parity: core/src/mime.ts#isTextual [status=implemented hash=817951b9d03b]
        public static func isTextual(_ mime: String) -> Bool {
            mime.isEmpty ||
                mime.hasPrefix("text/") ||
                mime == "application/json" ||
                mime.hasSuffix("+json") ||
                mime == "application/xml" ||
                mime.hasSuffix("+xml") ||
                mime == "application/javascript" ||
                mime == "application/x-javascript"
        }

        private static func startsWith(_ bytes: [UInt8], _ prefix: [UInt8]) -> Bool {
            guard bytes.count >= prefix.count else { return false }
            for i in 0..<prefix.count where bytes[i] != prefix[i] { return false }
            return true
        }

        private static func ascii(_ bytes: [UInt8], start: Int, end: Int) -> String {
            guard start >= 0, end <= bytes.count, start <= end else { return "" }
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }

        private static func readUInt32LE(_ bytes: [UInt8], offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }

        private static func readUInt32BE(_ bytes: [UInt8], offset: Int) -> UInt32 {
            (UInt32(bytes[offset]) << 24)
                | (UInt32(bytes[offset + 1]) << 16)
                | (UInt32(bytes[offset + 2]) << 8)
                | UInt32(bytes[offset + 3])
        }

        private static func isText(_ bytes: [UInt8]) -> Bool {
            if bytes.isEmpty { return true }
            if bytes.contains(0) { return false }
            // Validate UTF-8 (allowing a trailing truncated multi-byte sequence like TextDecoder stream: true).
            var idx = 0
            while idx < bytes.count {
                let b = bytes[idx]
                if b < 0x80 {
                    idx += 1
                } else if b & 0xE0 == 0xC0 {
                    if idx + 1 >= bytes.count { break }
                    if b < 0xC2 || (bytes[idx + 1] & 0xC0) != 0x80 { return false }
                    idx += 2
                } else if b & 0xF0 == 0xE0 {
                    if idx + 2 >= bytes.count { break }
                    let b1 = bytes[idx + 1]
                    let b2 = bytes[idx + 2]
                    if (b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 { return false }
                    if (b == 0xE0 && b1 < 0xA0) || (b == 0xED && b1 >= 0xA0) { return false }
                    idx += 3
                } else if b & 0xF8 == 0xF0 {
                    if idx + 3 >= bytes.count { break }
                    let b1 = bytes[idx + 1]
                    let b2 = bytes[idx + 2]
                    let b3 = bytes[idx + 3]
                    if (b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 || (b3 & 0xC0) != 0x80 { return false }
                    if (b == 0xF0 && b1 < 0x90) || (b == 0xF4 && b1 >= 0x90) || b > 0xF4 { return false }
                    idx += 4
                } else {
                    return false
                }
            }
            var controls = 0
            for b in bytes where b < 9 || (b > 13 && b < 32) {
                controls += 1
            }
            return Double(controls) / Double(bytes.count) <= 0.3
        }
    }

    // MARK: - FileAccess (`core/src/file-access.ts`)

    public enum FileAccess {
        // parity: core/src/file-access.ts#Kind [status=implemented hash=4d172638824a]
        public enum Kind: String, Equatable, Hashable, Sendable, Codable {
            case file
            case directory
        }

        /// Where a typed path points.
        // parity: core/src/file-access.ts#Place [status=implemented hash=91c8666b31cc]
        public struct Place: Equatable, Hashable, Sendable, Codable {
            public struct EnvironmentRef: Equatable, Hashable, Sendable, Codable {
                public let id: CoreLocation.Environment.ID

                public init(id: CoreLocation.Environment.ID) {
                    self.id = id
                }
            }

            public let absolute: SchemaPrimitive.AbsolutePath
            public let environment: EnvironmentRef

            public init(absolute: SchemaPrimitive.AbsolutePath, environment: EnvironmentRef) {
                self.absolute = absolute
                self.environment = environment
            }

            public init(absolute: String, environment id: CoreLocation.Environment.ID) {
                self.absolute = SchemaPrimitive.AbsolutePath(rawValue: absolute)
                self.environment = EnvironmentRef(id: id)
            }
        }

        // parity: core/src/file-access.ts#ResolveInput [status=implemented hash=66b4d8c33498]
        public struct ResolveInput: Equatable, Hashable, Sendable, Codable {
            public let path: String
            /// Selects the external approval boundary; it does not validate the target type.
            public let kind: Kind?
            /// The directory and machine the text was written in, for a path derived from an existing target.
            public let base: Place?

            public init(path: String, kind: Kind? = nil, base: Place? = nil) {
                self.path = path
                self.kind = kind
                self.base = base
            }
        }

        // parity: core/src/file-access.ts#ExternalDirectoryAuthorization [status=implemented hash=bda1c1495f5a]
        public struct ExternalDirectoryAuthorization: Equatable, Hashable, Sendable, Codable {
            public let action: String
            public let directory: SchemaPrimitive.AbsolutePath
            public let resource: String
            public let save: String

            public init(
                action: String = "external_directory",
                directory: SchemaPrimitive.AbsolutePath,
                resource: String,
                save: String
            ) {
                self.action = action
                self.directory = directory
                self.resource = resource
                self.save = save
            }
        }

        /// A resolved target. `environment` is where the target lives: tools act on the target through it rather than
        /// through a captured Environment. Equality, hashing and coding identify the environment by its `id`; a decoded
        /// target binds the host environment when its id is `local` and an unavailable placeholder otherwise.
        // parity: core/src/file-access.ts#Target [status=implemented hash=4cb7d1ddd831]
        public struct Target: Equatable, Hashable, Sendable, Codable {
            public let absolute: SchemaPrimitive.AbsolutePath
            /// Location-relative for internal paths, absolute for external paths.
            public let resource: String
            public let externalDirectory: ExternalDirectoryAuthorization?
            /// Where the target lives.
            public let environment: any CoreLocation.Environment.Interface

            public init(
                absolute: SchemaPrimitive.AbsolutePath,
                resource: String,
                externalDirectory: ExternalDirectoryAuthorization? = nil,
                environment: any CoreLocation.Environment.Interface = CoreLocation.Environment.host
            ) {
                self.absolute = absolute
                self.resource = resource
                self.externalDirectory = externalDirectory
                self.environment = environment
            }

            /// The target's place: its absolute path and the id of its environment.
            public var place: Place {
                Place(absolute: absolute, environment: Place.EnvironmentRef(id: environment.id))
            }

            private enum CodingKeys: String, CodingKey {
                case absolute, resource, externalDirectory, environment
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.absolute = try container.decode(SchemaPrimitive.AbsolutePath.self, forKey: .absolute)
                self.resource = try container.decode(String.self, forKey: .resource)
                self.externalDirectory = try container.decodeIfPresent(ExternalDirectoryAuthorization.self, forKey: .externalDirectory)
                let ref = try container.decodeIfPresent(Place.EnvironmentRef.self, forKey: .environment)
                let id = ref?.id ?? CoreLocation.Environment.localID
                self.environment = id == CoreLocation.Environment.localID
                    ? CoreLocation.Environment.host
                    : CoreLocation.Environment.Service(
                        id: id,
                        driver: CoreLocation.Environment.Driver(spawner: CoreLocation.Environment.unavailableSpawner)
                    )
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(absolute, forKey: .absolute)
                try container.encode(resource, forKey: .resource)
                try container.encodeIfPresent(externalDirectory, forKey: .externalDirectory)
                try container.encode(Place.EnvironmentRef(id: environment.id), forKey: .environment)
            }

            public static func == (lhs: Target, rhs: Target) -> Bool {
                lhs.absolute == rhs.absolute
                    && lhs.resource == rhs.resource
                    && lhs.externalDirectory == rhs.externalDirectory
                    && lhs.environment.id == rhs.environment.id
            }

            public func hash(into hasher: inout Hasher) {
                hasher.combine(absolute)
                hasher.combine(resource)
                hasher.combine(externalDirectory)
                hasher.combine(environment.id)
            }
        }

        /// Identifies a target's file: the same path in two environments is two files. The id's length (UTF-16 code
        /// units, as upstream's `string.length`) comes first so no id and path can read as another pair's key, and the
        /// keys of one environment sort as its paths do.
        // parity: core/src/file-access.ts#key [status=implemented hash=ec27a3581df9]
        public static func key(absolute: String, environment id: CoreLocation.Environment.ID) -> String {
            "\(id.rawValue.utf16.count):\(id.rawValue):\(absolute)"
        }

        public static func key(_ target: Target) -> String {
            key(absolute: target.absolute.rawValue, environment: target.environment.id)
        }

        public static func key(_ place: Place) -> String {
            key(absolute: place.absolute.rawValue, environment: place.environment.id)
        }

        // parity: core/src/file-access.ts#Invocation [status=implemented hash=80b0595e56a1]
        public typealias Invocation = ToolSchema.Context

        // parity: core/src/file-access.ts#ReadOptions [status=implemented hash=b01959286103]
        public struct ReadOptions: Equatable, Hashable, Sendable, Codable {
            /// A target already authorized by this invocation, used for filename recovery.
            public let siblingOf: Target

            public init(siblingOf: Target) {
                self.siblingOf = siblingOf
            }
        }

        // parity: core/src/file-access.ts#Interface [status=adapted hash=453a2b1e5a4d]
        public protocol Interface: Sendable {
            /// Where a typed path points, from its text: no disk is touched and no machine is called. Only a path that
            /// starts at a machine's home consults anything: the home in that machine's live hello, held in memory. It
            /// fails when the machine is unknown or offline.
            func locate(_ path: String, base: Place?) async throws -> Place
            /// Resolve a lexical path and its permission resources, without requesting approval.
            func resolve(_ input: ResolveInput) async throws -> Target
            /// Approve external directories in one batch, preserving first-seen resource order.
            func authorizeExternal(
                _ targets: [Target],
                context: Invocation,
                metadata: [String: JSONValue]?
            ) async throws
            /// Resolve a read target and obtain external-directory approval before read approval.
            func authorizeRead(
                _ file: String,
                context: Invocation,
                options: ReadOptions?
            ) async throws -> Target
        }

        /// The machines registry FileAccess consults for a machine path (`Machines.Service` upstream): the machine's
        /// environment, and the home directory from its live hello. Looked up under `machinesServiceKey`; without one,
        /// every machine is unknown.
        public protocol Machines: Sendable {
            func get(_ id: CoreLocation.Environment.ID) async throws -> any CoreLocation.Environment.Interface
            func home(_ id: CoreLocation.Environment.ID) async throws -> String
        }

        public static let machinesServiceKey = "@opencode/Machines"

        /// No machine is known.
        public struct UnknownMachine: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public let machine: CoreLocation.Environment.ID

            public init(machine: CoreLocation.Environment.ID) {
                self.machine = machine
            }

            public var description: String { "No machine named \"\(machine.rawValue)\"." }
        }

        /// A machine path that is neither absolute nor rooted at the machine's home (`Machine.NotAbsolute` upstream).
        public struct MachinePathNotAbsolute: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public let machine: CoreLocation.Environment.ID

            public init(machine: CoreLocation.Environment.ID) {
                self.machine = machine
            }

            public var description: String {
                "A \(machine.rawValue) path must be absolute or start with ~/, as in \(machine.rawValue):/work/file."
            }
        }

        /// Splits `gpu:/work/a` or `gpu:~/a` into a machine and the rest. A Windows drive or any URL is not one.
        /// Mirrors `MachinePath.parse` with the `Machines.Name` rule: 2 to 63 of `[a-z0-9-]`, starting with a letter, and
        /// never `local`.
        public static func parseMachinePath(_ text: String) -> (machine: CoreLocation.Environment.ID, path: String)? {
            guard let colon = text.firstIndex(of: ":"), colon != text.startIndex else { return nil }
            let machine = String(text[..<colon])
            guard isMachineName(machine) else { return nil }
            let rest = String(text[text.index(after: colon)...])
            if !rest.hasPrefix("/") && !rest.hasPrefix("~") { return nil }
            if rest.hasPrefix("//") { return nil }
            return (CoreLocation.Environment.ID.make(machine), rest)
        }

        public static func isMachineName(_ name: String) -> Bool {
            let scalars = Array(name.unicodeScalars)
            guard scalars.count >= 2, scalars.count <= 63, name != CoreLocation.Environment.localID.rawValue else { return false }
            guard let first = scalars.first, first >= "a", first <= "z" else { return false }
            return scalars.dropFirst().allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" }
        }

        /// `path.posix.normalize` for an absolute path: collapses `.`, `..` and repeated slashes, keeping a trailing one.
        static func posixNormalize(_ path: String) -> String {
            let absolute = path.hasPrefix("/")
            var parts: [Substring] = []
            for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
                if segment == "." { continue }
                if segment == ".." {
                    if !parts.isEmpty, parts.last != ".." { parts.removeLast() } else if !absolute { parts.append(segment) }
                    continue
                }
                parts.append(segment)
            }
            var out = (absolute ? "/" : "") + parts.joined(separator: "/")
            if out.isEmpty { out = "." }
            if path.hasSuffix("/") && !out.hasSuffix("/") { out += "/" }
            return out
        }

        /// `path.posix.resolve(base, path)`: no trailing slash.
        static func posixResolve(_ base: String, _ path: String) -> String {
            let combined = path.hasPrefix("/") ? path : (base.hasSuffix("/") ? base + path : base + "/" + path)
            var out = posixNormalize(combined)
            while out.count > 1 && out.hasSuffix("/") { out.removeLast() }
            return out
        }

        static func posixDirname(_ path: String) -> String {
            var p = path
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            guard let slash = p.lastIndex(of: "/") else { return "." }
            if slash == p.startIndex { return "/" }
            return String(p[..<slash])
        }

        static func posixJoin(_ directory: String, _ name: String) -> String {
            posixNormalize(directory.hasSuffix("/") ? directory + name : directory + "/" + name)
        }

        /// Expands leading `~` and normalizes Windows shell paths before lexical resolution against `directory`.
        // parity: core/src/file-access.ts#resolvePath [status=implemented hash=900cf259c02b]
        public static func resolvePath(
            directory: String,
            input: String,
            home: String = Global.Path.home
        ) -> String {
            let normalized = FSPathUtil.windowsPath(input)
            let expanded: String
            if normalized == "~" {
                expanded = home
            } else if normalized.hasPrefix("~/") || (Platform.current == .windows && normalized.hasPrefix("~\\")) {
                expanded = CoreConfigDiscovery.joinPath(home, String(normalized.dropFirst(2)))
            } else {
                expanded = normalized
            }
            return CoreConfigDiscovery.resolvePath(base: directory, relative: expanded)
        }

        // parity: core/src/file-access.ts#Service [status=adapted hash=1e44626831b7]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/FileAccess"

            public let directory: String
            public let worktree: String
            /// The Location's own environment: local paths resolve here.
            public let environment: any CoreLocation.Environment.Interface
            private let fileSystem: any OpenCodeFileSystem
            private let permission: any CorePermission.Interface
            private let home: String
            private let flags: (any CoreFlag.Interface)?
            private let machines: (any Machines)?

            public init(
                directory: String,
                worktree: String? = nil,
                fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
                permission: any CorePermission.Interface = CorePermission.Service(),
                home: String = Global.Path.home,
                environment: (any CoreLocation.Environment.Interface)? = nil,
                flags: (any CoreFlag.Interface)? = nil,
                machines: (any Machines)? = nil
            ) {
                self.directory = CoreConfigDiscovery.resolvePath(base: "/", relative: directory)
                self.worktree = CoreConfigDiscovery.resolvePath(base: "/", relative: worktree ?? directory)
                self.fileSystem = fileSystem
                self.permission = permission
                self.home = home
                self.environment = environment ?? CoreLocation.Environment.local(fileSystem: fileSystem)
                self.flags = flags
                self.machines = machines
            }

            /// Whether the `machines` flag is on. Read once per operation by `locate` and `resolve`.
            private func machinesEnabled() async -> Bool {
                guard let flags, let key = ConfigFlagSchema.Key(rawValue: "machines") else { return false }
                return await flags.enabled(key)
            }

            private func machine(_ id: CoreLocation.Environment.ID) throws -> any Machines {
                guard let machines else { throw UnknownMachine(machine: id) }
                return machines
            }

            private func place(_ text: String, base: Place?, enabled: Bool) async throws -> Place {
                // Only text the model typed can name a machine: text derived from a target is a plain path on that
                // target's machine, and a shell there does not understand `gpu:`.
                let parsed = base == nil && enabled ? FileAccess.parseMachinePath(text) : nil
                let id = parsed?.machine ?? base?.environment.id ?? environment.id
                if parsed == nil && id == environment.id {
                    return Place(
                        absolute: FileAccess.resolvePath(directory: base?.absolute.rawValue ?? directory, input: text, home: home),
                        environment: id
                    )
                }
                // A machine's paths use POSIX rules rather than this server's, and `~` there is that machine's home,
                // never this server's. Only `~` and `~/` are read. With the flag off no home is asked for, so a base on
                // another machine refuses every `~`.
                let written = parsed?.path ?? text
                let rooted: String
                if enabled && (written == "~" || written.hasPrefix("~/")) {
                    let machineHome: String
                    do {
                        machineHome = try await machine(id).home(id)
                    } catch {
                        throw CoreLocation.Environment.Files.Failed(path: text, cause: error)
                    }
                    rooted = FileAccess.posixJoin(machineHome, String(written.dropFirst()))
                } else {
                    rooted = written
                }
                if rooted.hasPrefix("~") {
                    throw CoreLocation.Environment.Files.Failed(path: text, cause: MachinePathNotAbsolute(machine: id))
                }
                let absolute = base.map { FileAccess.posixResolve($0.absolute.rawValue, rooted) } ?? FileAccess.posixNormalize(rooted)
                return Place(absolute: absolute, environment: id)
            }

            public func locate(_ path: String, base: Place? = nil) async throws -> Place {
                let enabled = await machinesEnabled()
                return try await place(path, base: base, enabled: enabled)
            }

            public func resolve(_ input: ResolveInput) async throws -> Target {
                let enabled = await machinesEnabled()
                let located = try await place(input.path, base: input.base, enabled: enabled)
                // A machine path is another machine's absolute path: it is never internal to this Location and never
                // this server's.
                if located.environment.id != environment.id {
                    return try await machineTarget(located, kind: input.kind)
                }
                let abs = located.absolute.rawValue
                let absolute = located.absolute
                let isInternal = FSPathUtil.contains(parent: directory, child: abs)
                    || (worktree != "/" && FSPathUtil.contains(parent: worktree, child: abs))
                if isInternal {
                    let rel = FSPathUtil.posixRelative(from: directory, to: abs)
                    let relative = rel.isEmpty ? "." : rel
                    return Target(
                        absolute: absolute,
                        // With machines on, a local folder can be named like a machine path; `./` keeps its permission
                        // name its own.
                        resource: enabled && FileAccess.parseMachinePath(relative) != nil ? "./\(relative)" : relative,
                        externalDirectory: nil,
                        environment: environment
                    )
                }
                let kind: Kind?
                if let explicit = input.kind {
                    kind = explicit
                } else if let st = try? await fileSystem.stat(at: abs) {
                    kind = st.type == .directory ? .directory : .file
                } else {
                    kind = nil
                }
                let extDirStr = kind == .directory ? abs : CoreConfigDiscovery.dirname(abs)
                let extDir = SchemaPrimitive.AbsolutePath(rawValue: extDirStr)
                let resource = CoreConfigDiscovery.joinPath(extDirStr, "*")
                return Target(
                    absolute: absolute,
                    resource: abs,
                    externalDirectory: ExternalDirectoryAuthorization(
                        action: "external_directory",
                        directory: extDir,
                        resource: resource,
                        save: resource
                    ),
                    environment: environment
                )
            }

            /// A machine path is always external, and its resources carry the machine name so its rules never settle a
            /// local path's. Type detection runs over the machine's own files; a saved rule is the directory's own glob.
            private func machineTarget(_ place: Place, kind: Kind?) async throws -> Target {
                let id = place.environment.id
                let machineEnvironment: any CoreLocation.Environment.Interface
                do {
                    machineEnvironment = try await machine(id).get(id)
                } catch {
                    throw CoreLocation.Environment.Files.Failed(path: place.absolute.rawValue, cause: error)
                }
                let type: Kind?
                if let kind {
                    type = kind
                } else {
                    do {
                        type = try await CoreLocation.Environment.Files.typeFollowing(
                            machineEnvironment.files,
                            path: place.absolute.rawValue
                        ) == .directory ? .directory : .file
                    } catch is CoreLocation.Environment.Files.NotFound {
                        type = nil
                    }
                }
                let directory = type == .directory ? place.absolute.rawValue : FileAccess.posixDirname(place.absolute.rawValue)
                let prefix = "\(id.rawValue):"
                let glob = "\(prefix)\(FileAccess.posixJoin(directory, "*"))"
                return Target(
                    absolute: place.absolute,
                    resource: "\(prefix)\(place.absolute.rawValue)",
                    externalDirectory: ExternalDirectoryAuthorization(
                        action: "external_directory",
                        directory: SchemaPrimitive.AbsolutePath(rawValue: directory),
                        resource: glob,
                        save: glob
                    ),
                    environment: machineEnvironment
                )
            }

            public func authorizeExternal(
                _ targets: [Target],
                context: Invocation,
                metadata: [String: JSONValue]? = nil
            ) async throws {
                var seen: Set<String> = []
                var externals: [ExternalDirectoryAuthorization] = []
                for target in targets {
                    guard let ext = target.externalDirectory else { continue }
                    if seen.insert(ext.resource).inserted {
                        externals.append(ext)
                    }
                }
                if externals.isEmpty { return }
                let inv = CorePermission.invocation(context)
                try await permission.assert(CorePermission.AssertInput(
                    sessionID: inv.sessionID,
                    agent: inv.agent,
                    action: "external_directory",
                    resources: externals.map(\.resource),
                    save: externals.map(\.save),
                    metadata: metadata,
                    source: inv.source
                ))
            }

            public func authorizeRead(
                _ file: String,
                context: Invocation,
                options: ReadOptions? = nil
            ) async throws -> Target {
                // A local sibling keeps the Location's resolution exactly as without recovery; a machine's candidate has
                // no Location to resolve against, so it takes the machine and the sibling's directory.
                let base: Place? = options.flatMap { options in
                    options.siblingOf.environment.id == environment.id
                        ? nil
                        : Place(
                            absolute: CoreConfigDiscovery.dirname(options.siblingOf.absolute.rawValue),
                            environment: options.siblingOf.environment.id
                        )
                }
                let target = try await resolve(ResolveInput(path: file, kind: options != nil ? .file : nil, base: base))
                let isSibling = options.map {
                    target.environment.id == $0.siblingOf.environment.id
                        && CoreConfigDiscovery.dirname(target.absolute.rawValue) == CoreConfigDiscovery.dirname($0.siblingOf.absolute.rawValue)
                } ?? false
                // Filename recovery shares the directory approval, but checks the recovered file's own read rules.
                if !isSibling {
                    try await authorizeExternal([target], context: context, metadata: nil)
                }
                let inv = CorePermission.invocation(context)
                try await permission.assert(CorePermission.AssertInput(
                    sessionID: inv.sessionID,
                    agent: inv.agent,
                    action: "read",
                    resources: [target.resource],
                    save: ["*"],
                    source: inv.source
                ))
                return target
            }
        }

        // parity: core/src/file-access.ts#node [status=adapted hash=0dbddf29cd80]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer { deps, _ in
                let directory = deps.get("@opencode/Location.directory", as: String.self) ?? "/"
                let fsUtil = deps.get(FSUtil.Service.serviceKey, as: FSUtil.Service.self)
                let perm = deps.get(CorePermission.Service.serviceKey, as: (any CorePermission.Interface).self)
                    ?? CorePermission.Service()
                let fileSystem = fsUtil?.fileSystem ?? LocalFileSystem.shared
                let service = Service(
                    directory: directory,
                    fileSystem: fileSystem,
                    permission: perm,
                    environment: deps.get(CoreLocation.Environment.Service.serviceKey, as: (any CoreLocation.Environment.Interface).self),
                    flags: deps.get(CoreFlag.Service.serviceKey, as: (any CoreFlag.Interface).self),
                    machines: deps.get(machinesServiceKey, as: (any Machines).self)
                )
                return LayerNode.Output([Service.serviceKey: service as any Interface])
            },
            [FSUtil.node, CorePermission.node]
        )
    }

    // MARK: - FileMutation (`core/src/file-mutation.ts`)

    public enum FileMutation {
        /// A mutation target: the resolved path, its permission resource and the environment it lives in. Equality and
        /// hashing identify the environment by its `id`.
        // parity: core/src/file-mutation.ts#Target [status=implemented hash=0a9a4a0d0937]
        public struct Target: Equatable, Hashable, Sendable {
            public let absolute: SchemaPrimitive.AbsolutePath
            public let resource: String
            public let environment: any CoreLocation.Environment.Interface

            public init(
                absolute: SchemaPrimitive.AbsolutePath,
                resource: String,
                environment: any CoreLocation.Environment.Interface = CoreLocation.Environment.host
            ) {
                self.absolute = absolute
                self.resource = resource
                self.environment = environment
            }

            public init(_ target: FileAccess.Target) {
                self.absolute = target.absolute
                self.resource = target.resource
                self.environment = target.environment
            }

            public static func == (lhs: Target, rhs: Target) -> Bool {
                lhs.absolute == rhs.absolute && lhs.resource == rhs.resource && lhs.environment.id == rhs.environment.id
            }

            public func hash(into hasher: inout Hasher) {
                hasher.combine(absolute)
                hasher.combine(resource)
                hasher.combine(environment.id)
            }
        }

        // parity: core/src/file-mutation.ts#WriteInput [status=implemented hash=aaae6ea5738e]
        public struct WriteInput: Equatable, Sendable {
            public let target: Target
            public let content: [UInt8]

            public init(target: Target, content: [UInt8]) {
                self.target = target
                self.content = content
            }

            public init(target: Target, text: String) {
                self.target = target
                self.content = Array(text.utf8)
            }
        }

        // parity: core/src/file-mutation.ts#TextWriteInput [status=implemented hash=25f34df8a0a4]
        public struct TextWriteInput: Equatable, Hashable, Sendable {
            public let target: Target
            public let content: String

            public init(target: Target, content: String) {
                self.target = target
                self.content = content
            }
        }

        // parity: core/src/file-mutation.ts#WriteResult [status=implemented hash=8311bc10d4f1]
        public struct WriteResult: Equatable, Hashable, Sendable, Codable {
            public let operation: String
            public let target: String
            public let resource: String
            public let existed: Bool

            public init(operation: String = "write", target: String, resource: String, existed: Bool) {
                self.operation = operation
                self.target = target
                self.resource = resource
                self.existed = existed
            }
        }

        // parity: core/src/file-mutation.ts#TextWriteResult [status=implemented hash=7496e95de540]
        public struct TextWriteResult: Equatable, Hashable, Sendable, Codable {
            public let operation: String
            public let target: String
            public let resource: String
            public let existed: Bool
            public let bom: Bool

            public init(operation: String = "write", target: String, resource: String, existed: Bool, bom: Bool) {
                self.operation = operation
                self.target = target
                self.resource = resource
                self.existed = existed
                self.bom = bom
            }
        }

        /// A transaction lock target: a located place, or a typed path that is located first.
        public enum LockTarget: Equatable, Hashable, Sendable {
            case place(FileAccess.Place)
            case path(String)
        }

        // parity: core/src/file-mutation.ts#Interface [status=adapted hash=3176c93b10f0]
        public protocol Interface: Sendable {
            /// Serialize a complete read/prepare/write mutation transaction by file. A typed path is located first, so
            /// it names its machine when the text does.
            func withLock<T: Sendable>(_ targets: [LockTarget], body: @Sendable () async throws -> T) async throws -> T
            func write(_ input: WriteInput) async throws -> WriteResult
            /// Add bytes to the end of a file, creating it when missing.
            func append(_ input: WriteInput) async throws -> WriteResult
            func writeTextPreservingBom(_ input: TextWriteInput) async throws -> TextWriteResult
        }

        /// The file content was not valid UTF-8, so a text rewrite was refused.
        // parity: core/src/file-mutation.ts#InvalidUtf8Error [status=implemented hash=97101786cb8d]
        public struct InvalidUtf8Error: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
            public static let tag = "FileMutation.InvalidUtf8Error"
            public let path: String

            public init(path: String) {
                self.path = path
            }

            // parity: core/src/file-mutation.ts#InvalidUtf8Error.message [status=implemented hash=fc8468d09359]
            public var message: String {
                "file is not valid UTF-8. It was left unchanged because rewriting it as text would replace every byte that is not UTF-8 with U+FFFD; change it with a tool that preserves its bytes, or convert it to UTF-8 first"
            }

            public var description: String { message }
        }

        /// Strict UTF-8 validation, as Node's `buffer.isUtf8`: overlong forms, surrogates and truncated sequences fail.
        public static func isUtf8(_ bytes: [UInt8]) -> Bool {
            String(validating: bytes, as: UTF8.self) != nil
        }

        // parity: core/src/file-mutation.ts#readText [status=implemented hash=6c0c24320475]
        public static func readText(
            fileSystem: any OpenCodeFileSystem,
            target: String
        ) async throws -> BomSplitResult {
            let bytes = try await fileSystem.readFile(at: target)
            return Bom.decodeBytes(bytes)
        }

        /// Read text that will be rewritten. Decoding replaces invalid bytes with U+FFFD, so such files are refused.
        // parity: core/src/file-mutation.ts#readEditableText [status=implemented hash=8a694253bb2b]
        public static func readEditableText(
            fileSystem: any OpenCodeFileSystem,
            target: String
        ) async throws -> BomSplitResult {
            let bytes = try await fileSystem.readFile(at: target)
            guard isUtf8(bytes) else { throw InvalidUtf8Error(path: target) }
            return Bom.decodeBytes(bytes)
        }

        /// `readEditableText` over an environment's files, for a target that lives in another environment.
        public static func readEditableText(
            files: any CoreLocation.Environment.Files.Interface,
            target: String
        ) async throws -> BomSplitResult {
            let bytes = try await files.read(target, range: nil).bytes
            guard isUtf8(bytes) else { throw InvalidUtf8Error(path: target) }
            return Bom.decodeBytes(bytes)
        }

        // parity: core/src/file-mutation.ts#readOptionalText [status=implemented hash=6d79d58e9a8a]
        public static func readOptionalText(
            fileSystem: any OpenCodeFileSystem,
            target: String
        ) async throws -> BomSplitResult? {
            do {
                let bytes = try await fileSystem.readFile(at: target)
                return Bom.decodeBytes(bytes)
            } catch PlatformError.notFound {
                return nil
            }
        }

        // parity: core/src/file-mutation.ts#syncTextBom [status=implemented hash=f802955bd78b]
        public static func syncTextBom(
            fileSystem: any OpenCodeFileSystem,
            target: String,
            bom: Bool
        ) async throws -> String {
            let bytes = try await fileSystem.readFile(at: target)
            let synced = Bom.syncBytes(bytes, bom: bom)
            if let updatedBytes = synced.bytes {
                try await fileSystem.writeFile(updatedBytes, to: target, createDirectories: true)
            }
            return synced.text
        }

        /// The disk a target is read and written through: the service's own file system for this machine (`local`),
        /// the target environment's files anywhere else.
        static func fileSystem(
            for environment: any CoreLocation.Environment.Interface,
            local: any OpenCodeFileSystem
        ) -> any OpenCodeFileSystem {
            environment.id == CoreLocation.Environment.localID ? local : EnvironmentFileSystem(files: environment.files)
        }

        /// `OpenCodeFileSystem` view of an environment's `Files`, so text helpers act on another machine's disk.
        struct EnvironmentFileSystem: OpenCodeFileSystem {
            let files: any CoreLocation.Environment.Files.Interface

            private static func platformError(_ error: any Swift.Error, path: String) -> any Swift.Error {
                if error is CoreLocation.Environment.Files.NotFound { return PlatformError.notFound(path) }
                return error
            }

            func exists(at path: String) async -> Bool {
                (try? await CoreLocation.Environment.Files.exists(files, path: path)) ?? false
            }

            func readFile(at path: String) async throws -> [UInt8] {
                do { return try await files.read(path, range: nil).bytes } catch { throw Self.platformError(error, path: path) }
            }

            func writeFile(_ bytes: [UInt8], to path: String, createDirectories: Bool) async throws {
                try await files.write(path, bytes: bytes)
            }

            func readDirectory(at path: String) async throws -> [String] {
                do { return try await files.list(path).map(\.name) } catch { throw Self.platformError(error, path: path) }
            }

            func makeDirectory(at path: String, recursive: Bool) async throws {
                try await files.mkdir(path)
            }

            func remove(at path: String) async throws {
                try await files.remove(path)
            }

            func rename(from: String, to: String) async throws {
                try await files.move(from: from, to: to)
            }

            func stat(at path: String) async throws -> FileStat {
                do {
                    let info = try await files.stat(path)
                    let type: FileEntryType
                    switch info.type {
                    case .file: type = .file
                    case .directory: type = .directory
                    case .symlink: type = .symlink
                    case .other: type = .other
                    }
                    return FileStat(type: type, size: info.size, modifiedAtMs: info.mtimeMs)
                } catch {
                    throw Self.platformError(error, path: path)
                }
            }
        }

        private actor PathLockManager {
            private var locked: Set<String> = []
            private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

            func acquire(_ key: String) async {
                while locked.contains(key) {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        waiters[key, default: []].append(cont)
                    }
                }
                locked.insert(key)
            }

            func release(_ key: String) {
                locked.remove(key)
                if var list = waiters[key], !list.isEmpty {
                    let next = list.removeFirst()
                    if list.isEmpty {
                        waiters.removeValue(forKey: key)
                    } else {
                        waiters[key] = list
                    }
                    next.resume()
                }
            }
        }

        // parity: core/src/file-mutation.ts#Service [status=adapted hash=898beb9cb78c]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/FileMutation"

            private static let transactionLocks = PathLockManager()
            private let targetLocks = PathLockManager()
            private let fileSystem: any OpenCodeFileSystem
            private let access: (any FileAccess.Interface)?

            public init(
                fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
                access: (any FileAccess.Interface)? = nil
            ) {
                self.fileSystem = fileSystem
                self.access = access
            }

            private func locate(_ target: LockTarget) async throws -> FileAccess.Place {
                switch target {
                case .place(let place):
                    return place
                case .path(let path):
                    if let access { return try await access.locate(path, base: nil) }
                    return FileAccess.Place(absolute: path, environment: CoreLocation.Environment.localID)
                }
            }

            public func withLock<T: Sendable>(
                _ targets: [LockTarget],
                body: @Sendable () async throws -> T
            ) async throws -> T {
                var keys: Set<String> = []
                for target in targets {
                    let place = try await locate(target)
                    keys.insert(FileAccess.key(
                        absolute: CoreConfigDiscovery.resolvePath(base: "/", relative: place.absolute.rawValue),
                        environment: place.environment.id
                    ))
                }
                let ordered = keys.sorted()
                for key in ordered {
                    await Self.transactionLocks.acquire(key)
                }
                defer {
                    Task {
                        for key in ordered.reversed() {
                            await Self.transactionLocks.release(key)
                        }
                    }
                }
                return try await body()
            }

            private func disk(_ target: Target) -> any OpenCodeFileSystem {
                FileMutation.fileSystem(for: target.environment, local: fileSystem)
            }

            public func write(_ input: WriteInput) async throws -> WriteResult {
                let path = input.target.absolute.rawValue
                let key = FileAccess.key(absolute: path, environment: input.target.environment.id)
                let disk = self.disk(input.target)
                await targetLocks.acquire(key)
                defer { Task { await targetLocks.release(key) } }
                let existed = await disk.exists(at: path)
                try await disk.writeFile(input.content, to: path, createDirectories: true)
                return WriteResult(target: path, resource: input.target.resource, existed: existed)
            }

            public func append(_ input: WriteInput) async throws -> WriteResult {
                let path = input.target.absolute.rawValue
                let key = FileAccess.key(absolute: path, environment: input.target.environment.id)
                await targetLocks.acquire(key)
                defer { Task { await targetLocks.release(key) } }
                if input.target.environment.id != CoreLocation.Environment.localID {
                    let files = input.target.environment.files
                    let existed = (try? await CoreLocation.Environment.Files.exists(files, path: path)) ?? false
                    try await files.append(path, bytes: input.content)
                    return WriteResult(target: path, resource: input.target.resource, existed: existed)
                }
                let existing: [UInt8]?
                do {
                    existing = try await fileSystem.readFile(at: path)
                } catch PlatformError.notFound {
                    existing = nil
                }
                var combined = existing ?? []
                combined.append(contentsOf: input.content)
                try await fileSystem.writeFile(combined, to: path, createDirectories: true)
                return WriteResult(target: path, resource: input.target.resource, existed: existing != nil)
            }

            public func writeTextPreservingBom(_ input: TextWriteInput) async throws -> TextWriteResult {
                let path = input.target.absolute.rawValue
                let key = FileAccess.key(absolute: path, environment: input.target.environment.id)
                let disk = self.disk(input.target)
                await targetLocks.acquire(key)
                defer { Task { await targetLocks.release(key) } }
                let next = Bom.split(input.content)
                let currentBytes: [UInt8]?
                do {
                    currentBytes = try await disk.readFile(at: path)
                } catch PlatformError.notFound {
                    currentBytes = nil
                }
                let bom = (currentBytes.map(Bom.has) ?? false) || next.bom
                let joined = Bom.join(next.text, bom: bom)
                try await disk.writeFile(Array(joined.utf8), to: path, createDirectories: true)
                return TextWriteResult(
                    target: path,
                    resource: input.target.resource,
                    existed: currentBytes != nil,
                    bom: bom
                )
            }
        }

        // parity: core/src/file-mutation.ts#node [status=adapted hash=8885d308dbd5]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer { deps, _ in
                let fsUtil = deps.get(FSUtil.Service.serviceKey, as: FSUtil.Service.self)
                let access = deps.get(FileAccess.Service.serviceKey, as: (any FileAccess.Interface).self)
                let service = Service(fileSystem: fsUtil?.fileSystem ?? LocalFileSystem.shared, access: access)
                return LayerNode.Output([Service.serviceKey: service as any Interface])
            },
            [FSUtil.node, FileAccess.node]
        )
    }


    // MARK: - FileRetention (`core/src/file-retention.ts`)

    public enum FileRetention {
        /// Deletes files whose modification timestamp is strictly older than `nowMs - retentionMs`.
        // parity: core/src/file-retention.ts#cleanup [status=implemented hash=a757962b1dbf]
        public static func cleanup(
            fileSystem: any OpenCodeFileSystem,
            files: [String],
            retentionMs: Int64,
            nowMs: Int64 = Flock.currentEpochMs()
        ) async {
            let cutoff = nowMs - retentionMs
            for file in files {
                guard let info = try? await fileSystem.stat(at: file) else { continue }
                if info.modifiedAtMs >= cutoff { continue }
                try? await fileSystem.remove(at: file)
            }
        }
    }

    // MARK: - FileWrite (`core/src/file-write.ts`)

    public enum FileWrite {
        // parity: core/src/file-write.ts#WriteInput [status=implemented hash=4581f57f2d12]
        public struct WriteInput: Equatable, Hashable, Sendable, Codable {
            public let path: String
            public let content: String

            public init(path: String, content: String) {
                self.path = path
                self.content = content
            }
        }

        // parity: core/src/file-write.ts#Written [status=implemented hash=c07427b2e8dd]
        public struct Written: Equatable, Hashable, Sendable, Codable {
            public let operation: String
            public let target: String
            public let resource: String
            public let existed: Bool
            public let bom: Bool
            public let formatted: String?

            public init(
                operation: String = "write",
                target: String,
                resource: String,
                existed: Bool,
                bom: Bool,
                formatted: String? = nil
            ) {
                self.operation = operation
                self.target = target
                self.resource = resource
                self.existed = existed
                self.bom = bom
                self.formatted = formatted
            }
        }

        // parity: core/src/file-write.ts#Interface [status=adapted hash=317892b48519]
        public protocol Interface: Sendable {
            func target(_ file: String, context: FileAccess.Invocation) async throws -> FileAccess.Target
            func authorize(_ target: FileAccess.Target, context: FileAccess.Invocation, preview: FileDiffSchema.Info?) async throws
            func commit(_ target: FileAccess.Target, content: String) async throws -> Written
            func write(_ input: WriteInput, context: FileAccess.Invocation) async throws -> Written
        }

        // parity: core/src/file-write.ts#Service [status=adapted hash=b298c1345f59]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/FileWrite"

            private let fileSystem: any OpenCodeFileSystem
            private let access: any FileAccess.Interface
            private let mutation: any FileMutation.Interface
            private let permission: any CorePermission.Interface
            private let formatFile: (@Sendable (FileAccess.Target) async -> Bool)?

            public init(
                fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
                access: any FileAccess.Interface,
                mutation: any FileMutation.Interface,
                permission: any CorePermission.Interface,
                formatFile: (@Sendable (FileAccess.Target) async -> Bool)? = nil
            ) {
                self.fileSystem = fileSystem
                self.access = access
                self.mutation = mutation
                self.permission = permission
                self.formatFile = formatFile
            }

            public func target(_ file: String, context: FileAccess.Invocation) async throws -> FileAccess.Target {
                let resolved = try await access.resolve(FileAccess.ResolveInput(path: file, kind: .file))
                try await access.authorizeExternal([resolved], context: context, metadata: nil)
                return resolved
            }

            public func authorize(
                _ target: FileAccess.Target,
                context: FileAccess.Invocation,
                preview: FileDiffSchema.Info? = nil
            ) async throws {
                let inv = CorePermission.invocation(context)
                var meta: [String: JSONValue]? = nil
                if let preview,
                   let encoded = try? JSONEncoder().encode([preview]),
                   let jsonVal = try? JSONDecoder().decode(JSONValue.self, from: encoded)
                {
                    meta = ["files": jsonVal]
                }
                try await permission.assert(CorePermission.AssertInput(
                    sessionID: inv.sessionID,
                    agent: inv.agent,
                    action: "edit",
                    resources: [target.resource],
                    save: ["*"],
                    metadata: meta,
                    source: inv.source
                ))
            }

            public func commit(_ target: FileAccess.Target, content: String) async throws -> Written {
                let written = try await mutation.writeTextPreservingBom(
                    FileMutation.TextWriteInput(target: FileMutation.Target(target), content: content)
                )
                if let formatFile, await formatFile(target) {
                    let formatted = try await FileMutation.syncTextBom(
                        fileSystem: FileMutation.fileSystem(for: target.environment, local: fileSystem),
                        target: target.absolute.rawValue,
                        bom: written.bom
                    )
                    return Written(
                        operation: written.operation,
                        target: written.target,
                        resource: written.resource,
                        existed: written.existed,
                        bom: written.bom,
                        formatted: formatted
                    )
                }
                return Written(
                    operation: written.operation,
                    target: written.target,
                    resource: written.resource,
                    existed: written.existed,
                    bom: written.bom,
                    formatted: nil
                )
            }

            public func write(_ input: WriteInput, context: FileAccess.Invocation) async throws -> Written {
                let resolved = try await target(input.path, context: context)
                let current = try await FileMutation.readOptionalText(
                    fileSystem: FileMutation.fileSystem(for: resolved.environment, local: fileSystem),
                    target: resolved.absolute.rawValue
                )
                let nextText = Bom.split(input.content).text
                let preview = CoreFilesystemDiff.compute(
                    file: resolved.resource,
                    before: current?.text ?? "",
                    after: nextText,
                    status: current != nil ? .modified : .added
                )
                try await authorize(resolved, context: context, preview: preview)
                return try await commit(resolved, content: input.content)
            }
        }

        // parity: core/src/file-write.ts#node [status=adapted hash=0ecfc8c52b06]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer { deps, _ in
                let fsUtil = deps.get(FSUtil.Service.serviceKey, as: FSUtil.Service.self)
                let fs = fsUtil?.fileSystem ?? LocalFileSystem.shared
                let access = deps.get(FileAccess.Service.serviceKey, as: (any FileAccess.Interface).self)
                    ?? FileAccess.Service(directory: "/", fileSystem: fs)
                let mutation = deps.get(FileMutation.Service.serviceKey, as: (any FileMutation.Interface).self)
                    ?? FileMutation.Service(fileSystem: fs)
                let perm = deps.get(CorePermission.Service.serviceKey, as: (any CorePermission.Interface).self)
                    ?? CorePermission.Service()
                let formatter = deps.get(CoreFormatter.Service.serviceKey, as: (any CoreFormatter.Interface).self)
                var formatFile: (@Sendable (FileAccess.Target) async -> Bool)? = nil
                if let formatter {
                    formatFile = { @Sendable (target: FileAccess.Target) async -> Bool in
                        await formatter.file(target)
                    }
                }
                let service = Service(
                    fileSystem: fs,
                    access: access,
                    mutation: mutation,
                    permission: perm,
                    formatFile: formatFile
                )
                return LayerNode.Output([Service.serviceKey: service as any Interface])
            },
            [FSUtil.node, FileAccess.node, FileMutation.node, CoreFormatter.node, CorePermission.node]
        )
    }

    // MARK: - Protected Home Directories (`core/src/filesystem/protected.ts`)

    public enum Protected {
        private static let darwinHome: Set<String> = [
            "Music", "Pictures", "Movies", "Downloads", "Desktop",
            "Documents", "Public", "Applications", "Library",
        ]
        private static let win32Home: Set<String> = [
            "AppData", "Downloads", "Desktop", "Documents", "Pictures", "Music", "Videos", "OneDrive",
        ]

        // parity: core/src/filesystem/protected.ts#isHome [status=implemented hash=d0d143352725]
        public static func isHome(
            _ directory: String,
            home: String = Global.Path.home
        ) -> Bool {
            CoreConfigDiscovery.resolvePath(base: "/", relative: directory) ==
                CoreConfigDiscovery.resolvePath(base: "/", relative: home)
        }

        // parity: core/src/filesystem/protected.ts#names [status=implemented hash=0549e63b7fe1]
        public static func names(platform: PlatformOS = Platform.current) -> Set<String> {
            switch platform {
            case .macOS: return darwinHome
            case .windows: return win32Home
            default: return []
            }
        }
    }

    // MARK: - FFF Fuzzy File Finder Adapter (`core/src/filesystem/fff*.ts`)

    public enum Fff {
        // parity: core/src/filesystem/fff.ts#Result [status=implemented hash=b590ffbff4ae]
        public enum Result<T: Sendable>: Sendable {
            case ok(T)
            case error(String)
        }

        // parity: core/src/filesystem/fff.ts#Init [status=implemented hash=f29188cd5c63]
        public struct Init: Equatable, Hashable, Sendable, Codable {
            public let basePath: String
            public let aiMode: Bool?
            public let disableMmapCache: Bool?
            public let disableContentIndexing: Bool?

            public init(
                basePath: String,
                aiMode: Bool? = nil,
                disableMmapCache: Bool? = nil,
                disableContentIndexing: Bool? = nil
            ) {
                self.basePath = basePath
                self.aiMode = aiMode
                self.disableMmapCache = disableMmapCache
                self.disableContentIndexing = disableContentIndexing
            }
        }

        // parity: core/src/filesystem/fff.ts#SearchOptions [status=implemented hash=92a10bf585df]
        public struct SearchOptions: Equatable, Hashable, Sendable, Codable {
            public let currentFile: String?
            public let pageIndex: Int?
            public let pageSize: Int?

            public init(currentFile: String? = nil, pageIndex: Int? = nil, pageSize: Int? = nil) {
                self.currentFile = currentFile
                self.pageIndex = pageIndex
                self.pageSize = pageSize
            }
        }

        // parity: core/src/filesystem/fff.ts#File [status=implemented hash=274566a603d0]
        public struct File: Equatable, Hashable, Sendable, Codable {
            public let relativePath: String

            public init(relativePath: String) {
                self.relativePath = relativePath
            }
        }

        // parity: core/src/filesystem/fff.ts#Directory [status=implemented hash=5a9ede5f29f6]
        public struct Directory: Equatable, Hashable, Sendable, Codable {
            public let relativePath: String

            public init(relativePath: String) {
                self.relativePath = relativePath
            }
        }

        // parity: core/src/filesystem/fff.ts#Mixed [status=implemented hash=58694202330d]
        public enum Mixed: Equatable, Hashable, Sendable, Codable {
            case file(File)
            case directory(Directory)
        }

        // parity: core/src/filesystem/fff.ts#Score [status=implemented hash=ed887d1924fe]
        public struct Score: Equatable, Hashable, Sendable, Codable {
            public let total: Double

            public init(total: Double) {
                self.total = total
            }
        }

        // parity: core/src/filesystem/fff.ts#Search [status=implemented hash=49c8564c9351]
        public struct Search: Equatable, Hashable, Sendable, Codable {
            public let items: [File]
            public let scores: [Score]

            public init(items: [File], scores: [Score]) {
                self.items = items
                self.scores = scores
            }
        }

        // parity: core/src/filesystem/fff.ts#DirSearch [status=implemented hash=473a79a45008]
        public struct DirSearch: Equatable, Hashable, Sendable, Codable {
            public let items: [Directory]
            public let scores: [Score]

            public init(items: [Directory], scores: [Score]) {
                self.items = items
                self.scores = scores
            }
        }

        // parity: core/src/filesystem/fff.ts#MixedSearch [status=implemented hash=b18339957538]
        public struct MixedSearch: Equatable, Hashable, Sendable, Codable {
            public let items: [Mixed]
            public let scores: [Score]

            public init(items: [Mixed], scores: [Score]) {
                self.items = items
                self.scores = scores
            }
        }

        // parity: core/src/filesystem/fff.ts#Picker [status=implemented hash=5bfc7f31ebc7]
        public protocol Picker: Sendable {
            func destroy()
            func isScanning() -> Bool
            func fileSearch(_ query: String, options: SearchOptions?) -> Result<Search>
            func directorySearch(_ query: String, options: SearchOptions?) -> Result<DirSearch>
            func mixedSearch(_ query: String, options: SearchOptions?) -> Result<MixedSearch>
        }

        // parity: core/src/filesystem/fff.ts#Backend [status=implemented hash=23b7edc09840]
        public protocol Backend: Sendable {
            func isAvailable() -> Bool
            func create(_ options: Init) -> Result<any Picker>
        }

        public struct BoundAdapter: Sendable {
            public let available: @Sendable () -> Bool
            public let create: @Sendable (Init) -> Result<any Picker>

            public init(
                available: @escaping @Sendable () -> Bool,
                create: @escaping @Sendable (Init) -> Result<any Picker>
            ) {
                self.available = available
                self.create = create
            }
        }

        // parity: core/src/filesystem/fff.ts#bind [status=implemented hash=5155f719d14c]
        public static func bind(
            _ backend: (any Backend)?,
            unavailable: String = "fff unavailable"
        ) -> BoundAdapter {
            BoundAdapter(
                available: { backend?.isAvailable() ?? false },
                create: { options in backend?.create(options) ?? .error(unavailable) }
            )
        }
    }

    public enum FffBun {
        private static let adapter = Fff.nativeAdapter()

        // parity: core/src/filesystem/fff.bun.ts#available [status=adapted hash=0280b1b290a7]
        public static func available() -> Bool { adapter.available() }

        // parity: core/src/filesystem/fff.bun.ts#create [status=adapted hash=58947e26c00d]
        public static func create(_ options: Fff.Init) -> Fff.Result<any Fff.Picker> { adapter.create(options) }
    }

    public enum FffNode {
        private static let adapter = Fff.nativeAdapter()

        // parity: core/src/filesystem/fff.node.ts#available [status=adapted hash=0280b1b290a7]
        public static func available() -> Bool { adapter.available() }

        // parity: core/src/filesystem/fff.node.ts#create [status=adapted hash=58947e26c00d]
        public static func create(_ options: Fff.Init) -> Fff.Result<any Fff.Picker> { adapter.create(options) }
    }

    public enum FffWorkerd {
        private static let adapter = Fff.bind(nil, unavailable: "fff unavailable on workerd runtime")

        // parity: core/src/filesystem/fff.workerd.ts#available [status=adapted hash=0280b1b290a7]
        public static func available() -> Bool { adapter.available() }

        // parity: core/src/filesystem/fff.workerd.ts#create [status=adapted hash=58947e26c00d]
        public static func create(_ options: Fff.Init) -> Fff.Result<any Fff.Picker> { adapter.create(options) }
    }

    // MARK: - Watcher (`core/src/filesystem/watcher.ts`)

    public enum Watcher {
        // parity: core/src/filesystem/watcher.ts#hasNativeBinding [status=adapted hash=d01c2b419c2f]
        public static func hasNativeBinding() -> Bool {
            NativeFileWatcher.isNativelySupported
        }

        // parity: core/src/filesystem/watcher.ts#Update [status=implemented hash=7227f75ead81]
        public typealias Update = CoreConfig.WatchUpdate

        // parity: core/src/filesystem/watcher.ts#WatchInput [status=implemented hash=4d5d05330035]
        public enum WatchInput: Equatable, Hashable, Sendable {
            case file(path: String)
            case entries(path: String, names: [String])
            case directory(path: String, ignore: [String] = [])

            public var path: String {
                switch self {
                case .file(let p): return p
                case .entries(let p, _): return p
                case .directory(let p, _): return p
                }
            }
        }

        public struct NativeSubscription: Sendable {
            public let backend: String?
            private let unsubscribeImpl: @Sendable () async -> Void

            public init(backend: String? = nil, unsubscribe: @escaping @Sendable () async -> Void) {
                self.backend = backend
                self.unsubscribeImpl = unsubscribe
            }

            public func unsubscribe() async {
                await unsubscribeImpl()
            }
        }

        // parity: core/src/filesystem/watcher.ts#NativeInterface [status=adapted hash=545191a915fa]
        public protocol NativeInterface: Sendable {
            func subscribe(
                _ input: WatchInput,
                publish: @escaping @Sendable (Update) -> Void
            ) async -> NativeSubscription?
        }

        // parity: core/src/filesystem/watcher.ts#Native [status=adapted hash=94da95dc6bce]
        public final class Native: NativeInterface, Sendable {
            public static let serviceKey = "@opencode/Watcher/Native"
            private let subscribeImpl: @Sendable (WatchInput, @escaping @Sendable (Update) -> Void) async -> NativeSubscription?

            public init(
                subscribe: @escaping @Sendable (WatchInput, @escaping @Sendable (Update) -> Void) async -> NativeSubscription?
            ) {
                self.subscribeImpl = subscribe
            }

            public func subscribe(
                _ input: WatchInput,
                publish: @escaping @Sendable (Update) -> Void
            ) async -> NativeSubscription? {
                await subscribeImpl(input, publish)
            }
        }

        // parity: core/src/filesystem/watcher.ts#Interface [status=adapted hash=009448542dd2]
        public protocol Interface: Sendable {
            func subscribe(_ input: WatchInput, onReady: (@Sendable () async -> Void)?) async -> AsyncStream<Update>
        }

        // parity: core/src/filesystem/watcher.ts#Options [status=implemented hash=a1975e855722]
        public struct Options: Equatable, Hashable, Sendable, Codable {
            public let enabled: Bool?

            public init(enabled: Bool? = nil) {
                self.enabled = enabled
            }
        }

        // parity: core/src/filesystem/watcher.ts#Service [status=adapted hash=7a2055dddbaf]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/Watcher"

            private struct SubscriptionSlot: Sendable {
                var subscription: NativeSubscription?
                var terminated: Bool = false
            }

            private let enabled: Bool
            private let native: any NativeInterface

            public init(enabled: Bool = true, native: any NativeInterface = Watcher.defaultNative()) {
                self.enabled = enabled
                self.native = native
            }

            public func subscribe(
                _ input: WatchInput,
                onReady: (@Sendable () async -> Void)? = nil
            ) async -> AsyncStream<Update> {
                guard enabled else {
                    return AsyncStream { $0.finish() }
                }
                let native = self.native
                return AsyncStream { continuation in
                    let slot = Mutex(SubscriptionSlot())
                    let task = Task {
                        let sub = await native.subscribe(input) { update in
                            continuation.yield(update)
                        }
                        guard let sub else {
                            continuation.finish()
                            return
                        }
                        let alreadyTerminated = slot.withLock { s -> Bool in
                            if s.terminated {
                                return true
                            }
                            s.subscription = sub
                            return false
                        }
                        if alreadyTerminated {
                            await sub.unsubscribe()
                            return
                        }
                        await onReady?()
                    }
                    continuation.onTermination = { _ in
                        task.cancel()
                        let activeSub = slot.withLock { s -> NativeSubscription? in
                            s.terminated = true
                            let current = s.subscription
                            s.subscription = nil
                            return current
                        }
                        if let activeSub {
                            Task {
                                await activeSub.unsubscribe()
                            }
                        }
                    }
                }
            }
        }

        // parity: core/src/filesystem/watcher.ts#Test [status=adapted hash=a3d6be52a901]
        public final class Test: Interface, Sendable {
            public static let serviceKey = "@opencode/Watcher/Test"

            private struct SubEntry: Sendable {
                let id: UInt64
                let matcher: @Sendable (String) -> Bool
                let continuation: AsyncStream<Update>.Continuation
            }

            private struct State: Sendable {
                var recorded: [WatchInput] = []
                var active: [UInt64: SubEntry] = [:]
                var nextID: UInt64 = 1
            }

            private let state = Mutex(State())

            public init() {}

            public func subscribe(
                _ input: WatchInput,
                onReady: (@Sendable () async -> Void)? = nil
            ) async -> AsyncStream<Update> {
                let resolvedTarget = CoreConfigDiscovery.resolvePath(base: "/", relative: input.path)
                let matcher: @Sendable (String) -> Bool
                switch input {
                case .file:
                    matcher = { target in target == resolvedTarget }
                case .entries(_, let names):
                    let allowed = Set(names)
                    matcher = { target in
                        CoreConfigDiscovery.dirname(target) == resolvedTarget &&
                            allowed.contains(CoreConfigDiscovery.basename(target))
                    }
                case .directory(_, let ignore):
                    let ignoredRoots = ignore.map { CoreConfigDiscovery.resolvePath(base: resolvedTarget, relative: $0) }
                    matcher = { target in
                        FSPathUtil.contains(parent: resolvedTarget, child: target) &&
                            !ignoredRoots.contains(where: { FSPathUtil.contains(parent: $0, child: target) })
                    }
                }

                let stream = AsyncStream<Update> { continuation in
                    let id = state.withLock { s -> UInt64 in
                        s.recorded.append(input)
                        let id = s.nextID
                        s.nextID &+= 1
                        s.active[id] = SubEntry(id: id, matcher: matcher, continuation: continuation)
                        return id
                    }
                    continuation.onTermination = { [weak self] _ in
                        self?.state.withLock { s in
                            _ = s.active.removeValue(forKey: id)
                        }
                    }
                }
                await onReady?()
                return stream
            }

            public func emit(_ update: Update) async {
                let resolved = CoreConfigDiscovery.resolvePath(base: "/", relative: update.path)
                let entries = state.withLock { Array($0.active.values) }
                for entry in entries where entry.matcher(resolved) {
                    entry.continuation.yield(update)
                }
            }

            public func subscriptions() async -> [WatchInput] {
                state.withLock { $0.recorded }
            }
        }

        /// Creates the default live native watcher backend powered by ``NativeFileWatcher``.
        public static func defaultNative() -> Native {
            Native { input, publish in
                guard NativeFileWatcher.isNativelySupported else {
                    return nil
                }

                let backendName = NativeFileWatcher.backend.rawValue
                let watcher: NativeFileWatcher
                let handler: @Sendable (NativeFileEvent) -> Void

                switch input {
                case .file(let rawFilePath):
                    let directory = CoreConfigDiscovery.dirname(rawFilePath)
                    let targetName = CoreConfigDiscovery.basename(rawFilePath)
                    watcher = NativeFileWatcher(
                        path: directory,
                        recursive: false,
                        ignore: [],
                        includeDefaultIgnores: false
                    )
                    handler = { event in
                        guard CoreConfigDiscovery.basename(event.path) == targetName else { return }
                        publish(Update(path: event.path, type: mapNativeEventKind(event.kind, renamedAsUpdate: true)))
                    }

                case .entries(let rawDirPath, let names):
                    let allowed = Set(names)
                    watcher = NativeFileWatcher(
                        path: rawDirPath,
                        recursive: false,
                        ignore: [],
                        includeDefaultIgnores: false
                    )
                    handler = { event in
                        guard allowed.contains(CoreConfigDiscovery.basename(event.path)) else { return }
                        publish(Update(path: event.path, type: mapNativeEventKind(event.kind, renamedAsUpdate: true)))
                    }

                case .directory(let rawDirPath, let ignore):
                    watcher = NativeFileWatcher(
                        path: rawDirPath,
                        recursive: true,
                        ignore: ignore,
                        includeDefaultIgnores: true
                    )
                    handler = { event in
                        publish(Update(path: event.path, type: mapNativeEventKind(event.kind, renamedAsUpdate: false)))
                    }
                }

                do {
                    try watcher.start(onEvent: handler)
                } catch {
                    return nil
                }

                return NativeSubscription(backend: backendName) {
                    watcher.stop()
                }
            }
        }

        private static func mapNativeEventKind(
            _ kind: NativeFileEventKind,
            renamedAsUpdate: Bool
        ) -> Update.Kind {
            switch kind {
            case .created: return .create
            case .modified: return .update
            case .deleted: return .delete
            case .renamed: return renamedAsUpdate ? .update : .create
            }
        }

        // parity: core/src/filesystem/watcher.ts#nativeLayer [status=adapted hash=a45fa1add560]
        public static let nativeLayer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { _, _ in
            let native = defaultNative()
            return LayerNode.Output([Native.serviceKey: native as any NativeInterface])
        }

        // parity: core/src/filesystem/watcher.ts#layer [status=adapted hash=4fa5f06d5d85]
        public static func layer(_ options: Options? = nil) -> LayerNode.ExecutableLayer {
            LayerNode.ExecutableLayer { deps, _ in
                let native = deps.get(Native.serviceKey, as: (any NativeInterface).self)
                    ?? defaultNative()
                let svc = Service(enabled: options?.enabled ?? true, native: native)
                return LayerNode.Output([Service.serviceKey: svc as any Interface])
            }
        }

        /// Resolves the platform-specific watcher binding package/path (`core/src/filesystem/watcher-binding.ts#default`).
        // parity: core/src/filesystem/watcher-binding.ts#default [status=adapted hash=4dbf51bfe931]
        public static func loadWatcherBinding(
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) -> String {
            if let override = environment.variable("OPENCODE_PARCEL_WATCHER_PATH"), !override.isEmpty {
                return override
            }
            let platformName: String
            switch Platform.current {
            case .macOS: platformName = "darwin"
            case .linux: platformName = "linux"
            case .windows: platformName = "win32"
            default: platformName = Platform.current.rawValue
            }
            #if arch(arm64)
            let archName = "arm64"
            #elseif arch(x86_64)
            let archName = "x64"
            #else
            let archName = "unknown"
            #endif
            let linuxSuffix = platformName == "linux" ? "-glibc" : ""
            return "@parcel/watcher-\(platformName)-\(archName)\(linuxSuffix)"
        }

        // parity: core/src/filesystem/watcher.ts#testLayer [status=adapted hash=01abf8ee854b]
        public static let testLayer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { _, _ in
            let test = Test()
            return LayerNode.Output([
                Service.serviceKey: test as any Interface,
                Test.serviceKey: test,
            ])
        }

        // parity: core/src/filesystem/watcher.ts#configured [status=adapted hash=e1f0e2fca6c5]
        public static func configured(_ options: Options? = nil) -> LayerNode.Provider {
            let nativeNode = AppNode.makeGlobalNode(Native.serviceKey, nativeLayer, [])
            return AppNode.makeGlobalNode(Service.serviceKey, layer(options), [nativeNode])
        }

        // parity: core/src/filesystem/watcher.ts#node [status=adapted hash=aea3814ebc3b]
        public static let node: LayerNode.Provider = configured()
    }

    // MARK: - LocationWatcherPolicy (`core/src/filesystem/location-watcher-policy.ts`)

    public enum LocationWatcherPolicy {
        // parity: core/src/filesystem/location-watcher-policy.ts#Editor [status=adapted hash=8b790fc6c137]
        public final class Editor: @unchecked Sendable {
            public private(set) var ignored: [String] = []

            public init(initial: [String] = []) {
                self.ignored = initial
            }

            public func add(_ patterns: [String]) {
                ignored.append(contentsOf: patterns)
            }

            public func list() -> [String] {
                ignored
            }
        }

        public struct Registration: Sendable {
            private let disposeImpl: @Sendable () -> Void

            public init(dispose: @escaping @Sendable () -> Void) {
                self.disposeImpl = dispose
            }

            public func dispose() {
                disposeImpl()
            }
        }

        // parity: core/src/filesystem/location-watcher-policy.ts#Interface [status=adapted hash=d7045de03d55]
        public protocol Interface: Sendable {
            func current() -> [String]
            func transform(_ fn: @escaping @Sendable (Editor) -> Void) async -> Registration
            func reload() async
            func observe(_ listener: @escaping @Sendable ([String]) async -> Void) -> Registration
        }

        // parity: core/src/filesystem/location-watcher-policy.ts#Service [status=adapted hash=7722c0ae5a01]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/LocationWatcherPolicy"

            private struct State: Sendable {
                var transforms: [UInt64: @Sendable (Editor) -> Void] = [:]
                var transformOrder: [UInt64] = []
                var listeners: [UInt64: @Sendable ([String]) async -> Void] = [:]
                var cachedIgnore: [String] = []
                var nextID: UInt64 = 1
            }

            private let state = Mutex(State())

            public init() {}

            public func current() -> [String] {
                state.withLock { $0.cachedIgnore }
            }

            public func transform(_ fn: @escaping @Sendable (Editor) -> Void) async -> Registration {
                let id = state.withLock { s -> UInt64 in
                    let id = s.nextID
                    s.nextID &+= 1
                    s.transforms[id] = fn
                    s.transformOrder.append(id)
                    return id
                }
                await reload()
                return Registration { [weak self] in
                    self?.state.withLock { s in
                        _ = s.transforms.removeValue(forKey: id)
                        s.transformOrder.removeAll { $0 == id }
                    }
                }
            }

            public func reload() async {
                let (ignoreList, listeners): ([String], [@Sendable ([String]) async -> Void]) = state.withLock { s in
                    let editor = Editor()
                    for id in s.transformOrder {
                        s.transforms[id]?(editor)
                    }
                    s.cachedIgnore = editor.list()
                    return (s.cachedIgnore, Array(s.listeners.values))
                }
                for listener in listeners {
                    await listener(ignoreList)
                }
            }

            public func observe(_ listener: @escaping @Sendable ([String]) async -> Void) -> Registration {
                let id = state.withLock { s -> UInt64 in
                    let id = s.nextID
                    s.nextID &+= 1
                    s.listeners[id] = listener
                    return id
                }
                return Registration { [weak self] in
                    self?.state.withLock { s in
                        _ = s.listeners.removeValue(forKey: id)
                    }
                }
            }
        }

        // parity: core/src/filesystem/location-watcher-policy.ts#node [status=adapted hash=0c79ea0a2c77]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer.succeed(key: Service.serviceKey, value: Service() as any Interface),
            []
        )
    }

    // MARK: - LocationWatcher (`core/src/filesystem/location-watcher.ts`)

    public enum LocationWatcher {
        // parity: core/src/filesystem/location-watcher.ts#Interface [status=adapted hash=9f70dc435258]
        public protocol Interface: Sendable {}

        // parity: core/src/filesystem/location-watcher.ts#Service [status=adapted hash=c475860cfeda]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/LocationWatcher"

            private let policy: any LocationWatcherPolicy.Interface
            private let watcher: any Watcher.Interface

            public init(
                policy: any LocationWatcherPolicy.Interface = LocationWatcherPolicy.Service(),
                watcher: any Watcher.Interface = Watcher.Test()
            ) {
                self.policy = policy
                self.watcher = watcher
            }

            public func isIgnored(_ path: String) -> Bool {
                policy.current().contains(path)
            }
        }

        // parity: core/src/filesystem/location-watcher.ts#node [status=adapted hash=af216e7260b3]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer { deps, _ in
                let policy = deps.get(LocationWatcherPolicy.Service.serviceKey, as: (any LocationWatcherPolicy.Interface).self)
                    ?? LocationWatcherPolicy.Service()
                let watcher = deps.get(Watcher.Service.serviceKey, as: (any Watcher.Interface).self)
                    ?? Watcher.Test()
                return LayerNode.Output([Service.serviceKey: Service(policy: policy, watcher: watcher) as any Interface])
            },
            [Watcher.node, LocationWatcherPolicy.node]
        )
    }

    // MARK: - FileWatch (`core/src/filesystem/file-watch.ts`)

    public enum FileWatch {
        /// 24 hours in milliseconds.
        // parity: core/src/filesystem/file-watch.ts#TTL [status=implemented hash=3c44faf7c64c]
        public static let TTL: Int64 = 24 * 60 * 60 * 1_000

        /// 5 minutes in milliseconds.
        // parity: core/src/filesystem/file-watch.ts#SWEEP_INTERVAL [status=implemented hash=606f7ed8c838]
        public static let SWEEP_INTERVAL: Int64 = 5 * 60 * 1_000

        // parity: core/src/filesystem/file-watch.ts#MAX_PER_LOCATION [status=implemented hash=d0c39ff43968]
        public static let MAX_PER_LOCATION: Int = 256

        // parity: core/src/filesystem/file-watch.ts#DisabledError [status=implemented hash=237cf17835f5]
        public struct DisabledError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
            public static let tag = "FileWatch.DisabledError"

            public init() {}

            // parity: core/src/filesystem/file-watch.ts#DisabledError.message [status=implemented hash=c2a9bbd80cef]
            public var message: String { "File watching is disabled" }
            public var description: String { message }
        }

        // parity: core/src/filesystem/file-watch.ts#Input [status=implemented hash=0c65b14de885]
        public struct Input: Equatable, Hashable, Sendable, Codable {
            public let location: LocationSchema.Ref
            public let file: String

            public init(location: LocationSchema.Ref, file: String) {
                self.location = location
                self.file = file
            }
        }

        // parity: core/src/filesystem/file-watch.ts#Interface [status=adapted hash=db6c1a5b5083]
        public protocol Interface: Sendable {
            func watch(_ input: Input) async throws
            func unwatch(_ input: Input) async
        }

        // parity: core/src/filesystem/file-watch.ts#Options [status=implemented hash=a1d7a62d1948]
        public struct Options: Equatable, Hashable, Sendable, Codable {
            public let enabled: Bool?

            public init(enabled: Bool? = nil) {
                self.enabled = enabled
            }
        }

        // parity: core/src/filesystem/file-watch.ts#Service [status=adapted hash=bf4b57f65474]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/FileWatch"

            private struct Entry: Sendable {
                var expiresAtMs: Int64
            }

            private let enabled: Bool
            private let nowMs: @Sendable () -> Int64
            private let locations = Mutex<[String: [String: Entry]]>([:])

            public init(
                enabled: Bool = true,
                nowMs: @escaping @Sendable () -> Int64 = { Flock.currentEpochMs() }
            ) {
                self.enabled = enabled
                self.nowMs = nowMs
            }

            public func watch(_ input: Input) async throws {
                guard enabled else { throw DisabledError() }
                let key = "\(input.location.directory.rawValue)|\(input.location.workspaceID?.rawValue ?? "")"
                let expires = nowMs() + TTL
                locations.withLock { map in
                    var files = map[key] ?? [:]
                    if files[input.file] != nil {
                        files[input.file] = Entry(expiresAtMs: expires)
                        map[key] = files
                        return
                    }
                    if files.count >= MAX_PER_LOCATION,
                       let soonest = files.min(by: { $0.value.expiresAtMs < $1.value.expiresAtMs })
                    {
                        files.removeValue(forKey: soonest.key)
                    }
                    files[input.file] = Entry(expiresAtMs: expires)
                    map[key] = files
                }
            }

            public func unwatch(_ input: Input) async {
                let key = "\(input.location.directory.rawValue)|\(input.location.workspaceID?.rawValue ?? "")"
                locations.withLock { map in
                    var files = map[key] ?? [:]
                    files.removeValue(forKey: input.file)
                    if files.isEmpty {
                        map.removeValue(forKey: key)
                    } else {
                        map[key] = files
                    }
                }
            }

            public func sweepExpired() -> Int {
                let now = nowMs()
                return locations.withLock { map in
                    var removed = 0
                    for (locKey, files) in map {
                        let remaining = files.filter { $0.value.expiresAtMs > now }
                        removed += files.count - remaining.count
                        if remaining.isEmpty {
                            map.removeValue(forKey: locKey)
                        } else {
                            map[locKey] = remaining
                        }
                    }
                    return removed
                }
            }
        }

        // parity: core/src/filesystem/file-watch.ts#layer [status=adapted hash=83179527e28f]
        public static func layer(_ options: Options? = nil) -> LayerNode.ExecutableLayer {
            LayerNode.ExecutableLayer { _, _ in
                LayerNode.Output([Service.serviceKey: Service(enabled: options?.enabled ?? true) as any Interface])
            }
        }

        // parity: core/src/filesystem/file-watch.ts#configured [status=adapted hash=f7c41fdfc4ff]
        public static func configured(_ options: Options? = nil) -> LayerNode.Provider {
            AppNode.makeGlobalNode(Service.serviceKey, layer(options), [Watcher.node, FSUtil.node])
        }

        // parity: core/src/filesystem/file-watch.ts#node [status=adapted hash=aea3814ebc3b]
        public static let node: LayerNode.Provider = configured()
    }

    // MARK: - FileSystemSearch (`core/src/filesystem/search.ts`)

    public enum Search {
        // parity: core/src/filesystem/search.ts#Interface [status=adapted hash=50f1f96bef88]
        public protocol Interface: Sendable {
            func find(_ input: FileSystemSchema.FindInput) async -> [FileSystemSchema.Entry]
        }

        // parity: core/src/filesystem/search.ts#Options [status=implemented hash=890bd6f8dcd0]
        public struct Options: Equatable, Hashable, Sendable, Codable {
            public let fff: Bool?

            public init(fff: Bool? = nil) {
                self.fff = fff
            }
        }

        // parity: core/src/filesystem/search.ts#Service [status=adapted hash=83a663c1d6c0]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/FileSystem/Search"

            private let directory: String
            private let fileSystem: any OpenCodeFileSystem

            public init(directory: String, fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared) {
                self.directory = directory
                self.fileSystem = fileSystem
            }

            public func find(_ input: FileSystemSchema.FindInput) async -> [FileSystemSchema.Entry] {
                let fsUtil = FSUtil.Service(fileSystem: fileSystem)
                let allFiles = (try? await fsUtil.scan(
                    pattern: "**/*",
                    options: Glob.Options(cwd: directory, absolute: false, include: .all, dot: true, ignore: FSPathUtil.ignoreGlobs)
                )) ?? []

                let queryLower = input.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let limit = input.limit?.rawValue ?? 50

                var scored: [(entry: FileSystemSchema.Entry, score: Int)] = []
                for rel in allFiles {
                    let abs = CoreConfigDiscovery.joinPath(directory, rel)
                    let isDir = await fsUtil.isDir(abs)
                    let entryType: FileSystemSchema.EntryType = isDir ? .directory : .file
                    if let requestedType = input.type, requestedType != entryType {
                        continue
                    }
                    let display = isDir ? (rel.hasSuffix("/") ? rel : rel + "/") : rel
                    if let score = fuzzyScore(query: queryLower, candidate: display.lowercased()) {
                        scored.append((
                            FileSystemSchema.Entry(
                                path: SchemaPrimitive.RelativePath(rawValue: display),
                                type: entryType
                            ),
                            score
                        ))
                    }
                }
                scored.sort { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    return lhs.entry.path.rawValue.count < rhs.entry.path.rawValue.count
                }
                return Array(scored.prefix(limit).map(\.entry))
            }

            private func fuzzyScore(query: String, candidate: String) -> Int? {
                if query.isEmpty { return 0 }
                if candidate == query { return 10_000 }
                if candidate.contains(query) { return 5_000 - candidate.count }
                var score = 0
                var qIdx = query.startIndex
                var consecutive = 0
                for c in candidate {
                    if qIdx < query.endIndex && c == query[qIdx] {
                        consecutive += 1
                        score += 10 * consecutive
                        qIdx = query.index(after: qIdx)
                    } else {
                        consecutive = 0
                    }
                }
                return qIdx == query.endIndex ? score : nil
            }
        }

        // parity: core/src/filesystem/search.ts#makeFffLayer [status=adapted hash=6cdbca187d27]
        public static func makeFffLayer(
            _ create: @escaping @Sendable (Fff.Init) -> Fff.Result<any Fff.Picker>
        ) -> LayerNode.ExecutableLayer {
            LayerNode.ExecutableLayer { deps, _ in
                let directory = deps.get("@opencode/Location.directory", as: String.self) ?? "/"
                let fsUtil = deps.get(FSUtil.Service.serviceKey, as: FSUtil.Service.self)
                let pickerRes = create(Fff.Init(basePath: directory, aiMode: true, disableMmapCache: true, disableContentIndexing: true))
                if case .ok(let picker) = pickerRes {
                    let adapter = FffBackedSearchService(picker: picker)
                    return LayerNode.Output([Service.serviceKey: adapter as any Interface])
                }
                let fallback = Service(directory: directory, fileSystem: fsUtil?.fileSystem ?? LocalFileSystem.shared)
                return LayerNode.Output([Service.serviceKey: fallback as any Interface])
            }
        }

        private final class FffBackedSearchService: Interface, Sendable {
            private let picker: any Fff.Picker

            init(picker: any Fff.Picker) {
                self.picker = picker
            }

            deinit {
                picker.destroy()
            }

            func find(_ input: FileSystemSchema.FindInput) async -> [FileSystemSchema.Entry] {
                let opts = Fff.SearchOptions(pageIndex: 0, pageSize: input.limit?.rawValue ?? 50)
                let q = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
                switch input.type {
                case .file:
                    guard case .ok(let res) = picker.fileSearch(q, options: opts) else { return [] }
                    return res.items.map {
                        FileSystemSchema.Entry(path: SchemaPrimitive.RelativePath(rawValue: $0.relativePath), type: .file)
                    }
                case .directory:
                    guard case .ok(let res) = picker.directorySearch(q, options: opts) else { return [] }
                    return res.items.map {
                        let p = $0.relativePath.hasSuffix("/") ? $0.relativePath : $0.relativePath + "/"
                        return FileSystemSchema.Entry(path: SchemaPrimitive.RelativePath(rawValue: p), type: .directory)
                    }
                case nil:
                    guard case .ok(let res) = picker.mixedSearch(q, options: opts) else { return [] }
                    return res.items.map { item in
                        switch item {
                        case .file(let f):
                            return FileSystemSchema.Entry(path: SchemaPrimitive.RelativePath(rawValue: f.relativePath), type: .file)
                        case .directory(let d):
                            let p = d.relativePath.hasSuffix("/") ? d.relativePath : d.relativePath + "/"
                            return FileSystemSchema.Entry(path: SchemaPrimitive.RelativePath(rawValue: p), type: .directory)
                        }
                    }
                }
            }
        }

        // parity: core/src/filesystem/search.ts#fffLayer [status=adapted hash=5f571c65b8ef]
        public static let fffLayer: LayerNode.ExecutableLayer = makeFffLayer(FffBun.create)

        // parity: core/src/filesystem/search.ts#configured [status=adapted hash=a8a273a62cbb]
        public static func configured(_ options: Options? = nil) -> LayerNode.Provider {
            let layer: LayerNode.ExecutableLayer = options?.fff == true && FffBun.available()
                ? fffLayer
                : LayerNode.ExecutableLayer { deps, _ in
                    let directory = deps.get("@opencode/Location.directory", as: String.self) ?? "/"
                    let fsUtil = deps.get(FSUtil.Service.serviceKey, as: FSUtil.Service.self)
                    let fileSystem = fsUtil?.fileSystem ?? LocalFileSystem.shared
                    // The index walks the Location's environment: this machine's disk, or a workspace's own files.
                    let environment = deps.get(
                        CoreLocation.Environment.Service.serviceKey,
                        as: (any CoreLocation.Environment.Interface).self
                    )
                    if let environment, environment.id != CoreLocation.Environment.localID {
                        let service = Service(
                            directory: directory,
                            fileSystem: FileMutation.fileSystem(for: environment, local: fileSystem)
                        )
                        return LayerNode.Output([Service.serviceKey: service as any Interface])
                    }
                    let service = FuzzyIndexedService(directory: directory, fileSystem: fileSystem)
                    return LayerNode.Output([Service.serviceKey: service as any Interface])
                }
            return AppNode.makeLocationNode(Service.serviceKey, layer, [FSUtil.node])
        }

        // parity: core/src/filesystem/search.ts#node [status=adapted hash=aea3814ebc3b]
        public static let node: LayerNode.Provider = configured()
    }

    // MARK: - Core Location FileSystem (`core/src/filesystem.ts`)

    // parity: core/src/filesystem.ts#FindInput [status=implemented hash=a9fab1734951]
    public typealias FindInput = FileSystemSchema.FindInput

    // parity: core/src/filesystem.ts#Write [status=implemented hash=a9fab1734951]
    public typealias Write = FileSystemSchema.Write

    // parity: core/src/filesystem.ts#ReadInput [status=implemented hash=bc8bdeb1983d]
    public struct ReadInput: Equatable, Hashable, Sendable, Codable {
        public let path: SchemaPrimitive.RelativePath

        public init(path: SchemaPrimitive.RelativePath) {
            self.path = path
        }
    }

    // parity: core/src/filesystem.ts#WriteInput [status=implemented hash=252b56e427d4]
    public struct WriteInput: Equatable, Sendable {
        public let path: String
        public let data: [UInt8]

        public init(path: String, data: [UInt8]) {
            self.path = path
            self.data = data
        }
    }

    // parity: core/src/filesystem.ts#NotFoundError [status=implemented hash=0053a747464a]
    public struct NotFoundError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "FileSystem.NotFoundError"
        public let path: SchemaPrimitive.RelativePath

        public init(path: SchemaPrimitive.RelativePath) {
            self.path = path
        }

        public var description: String { "File not found: \(path.rawValue)" }
    }

    // parity: core/src/filesystem.ts#DirectoryNotFoundError [status=implemented hash=ba8e6efb3af5]
    public struct DirectoryNotFoundError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "FileSystem.DirectoryNotFoundError"
        public let directory: SchemaPrimitive.AbsolutePath
        public let detail: String?

        public init(directory: SchemaPrimitive.AbsolutePath, detail: String? = nil) {
            self.directory = directory
            self.detail = detail
        }

        // parity: core/src/filesystem.ts#DirectoryNotFoundError.message [status=implemented hash=49c31c1ea453]
        public var message: String { "Directory not found: \(directory.rawValue)" }
        public var description: String { message }
    }

    // parity: core/src/filesystem.ts#DirectoryAccessDeniedError [status=implemented hash=7ef8417b2076]
    public struct DirectoryAccessDeniedError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "FileSystem.DirectoryAccessDeniedError"
        public let directory: SchemaPrimitive.AbsolutePath
        public let detail: String?

        public init(directory: SchemaPrimitive.AbsolutePath, detail: String? = nil) {
            self.directory = directory
            self.detail = detail
        }

        // parity: core/src/filesystem.ts#DirectoryAccessDeniedError.message [status=implemented hash=4c76341acd0c]
        public var message: String { "Access denied to directory: \(directory.rawValue)" }
        public var description: String { message }
    }

    // parity: core/src/filesystem.ts#Content [status=implemented hash=a7d7427f368a]
    public struct Content: Equatable, Hashable, Sendable, Codable {
        public enum Encoding: String, Equatable, Hashable, Sendable, Codable {
            case utf8
            case base64
        }

        public let uri: String
        public let name: String?
        public let content: String
        public let encoding: Encoding
        public let mime: String

        public init(uri: String, name: String? = nil, content: String, encoding: Encoding, mime: String) {
            self.uri = uri
            self.name = name
            self.content = content
            self.encoding = encoding
            self.mime = mime
        }
    }

    // parity: core/src/filesystem.ts#ListInput [status=implemented hash=3f6435018a1c]
    public struct ListInput: Equatable, Hashable, Sendable, Codable {
        public let path: String?

        public init(path: String? = nil) {
            self.path = path
        }
    }

    // parity: core/src/filesystem.ts#DEFAULT_SEARCH_LIMIT [status=implemented hash=a431515d6830]
    public static let DEFAULT_SEARCH_LIMIT: Int = 100

    // parity: core/src/filesystem.ts#DEFAULT_SEARCH_TIMEOUT_MS [status=implemented hash=aa6d20d788b9]
    public static let DEFAULT_SEARCH_TIMEOUT_MS: Int = 30_000

    // parity: core/src/filesystem.ts#GlobInput [status=implemented hash=80f69c14bc0e]
    public struct GlobInput: Equatable, Hashable, Sendable, Codable {
        public let pattern: String
        public let path: SchemaPrimitive.RelativePath?
        public let hidden: Bool?
        public let limit: SchemaPrimitive.PositiveInt?

        public init(
            pattern: String,
            path: SchemaPrimitive.RelativePath? = nil,
            hidden: Bool? = nil,
            limit: SchemaPrimitive.PositiveInt? = nil
        ) {
            self.pattern = pattern
            self.path = path
            self.hidden = hidden
            self.limit = limit
        }
    }

    // parity: core/src/filesystem.ts#GrepInput [status=implemented hash=5f4099a0e40c]
    public struct GrepInput: Equatable, Hashable, Sendable, Codable {
        public let pattern: String
        public let path: SchemaPrimitive.RelativePath?
        public let include: String?
        public let literal: Bool?
        public let caseSensitive: Bool?
        public let limit: SchemaPrimitive.PositiveInt?

        public init(
            pattern: String,
            path: SchemaPrimitive.RelativePath? = nil,
            include: String? = nil,
            literal: Bool? = nil,
            caseSensitive: Bool? = nil,
            limit: SchemaPrimitive.PositiveInt? = nil
        ) {
            self.pattern = pattern
            self.path = path
            self.include = include
            self.literal = literal
            self.caseSensitive = caseSensitive
            self.limit = limit
        }
    }

    // parity: core/src/filesystem.ts#Event [status=implemented hash=102fbf305a39]
    public typealias Event = FileSystemSchema.Event

    // parity: core/src/filesystem.ts#File [status=adapted hash=b082c781921d]
    public struct File: Sendable {
        public let mime: String
        public let size: Int64
        public let modifiedAtMs: Int64?
        public let readRange: @Sendable (_ offset: Int?, _ bytesToRead: Int?) async throws -> [UInt8]

        public init(
            mime: String,
            size: Int64,
            modifiedAtMs: Int64? = nil,
            readRange: @escaping @Sendable (_ offset: Int?, _ bytesToRead: Int?) async throws -> [UInt8]
        ) {
            self.mime = mime
            self.size = size
            self.modifiedAtMs = modifiedAtMs
            self.readRange = readRange
        }
    }

    // parity: core/src/filesystem.ts#Interface [status=adapted hash=c3974f38fcbd]
    public protocol Interface: Sendable {
        func read(_ input: ReadInput) async throws -> File
        func list(_ input: ListInput?) async throws -> [FileSystemSchema.Entry]
        func find(_ input: FileSystemSchema.FindInput) async -> [FileSystemSchema.Entry]
        func write(_ input: WriteInput) async throws -> FileSystemSchema.Write
    }

    // parity: core/src/filesystem.ts#Service [status=adapted hash=a38c5dc467d4]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/FileSystem"

        public let directory: String
        private let fileSystem: any OpenCodeFileSystem
        private let search: any Search.Interface

        public init(
            directory: String,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            search: (any Search.Interface)? = nil
        ) {
            self.directory = CoreConfigDiscovery.resolvePath(base: "/", relative: directory)
            self.fileSystem = fileSystem
            self.search = search ?? Search.Service(directory: self.directory, fileSystem: fileSystem)
        }

        public func read(_ input: ReadInput) async throws -> File {
            if input.path.rawValue.contains("\u{0}") {
                throw NotFoundError(path: input.path)
            }
            let abs = CoreConfigDiscovery.resolvePath(base: directory, relative: input.path.rawValue)
            guard FSPathUtil.contains(parent: directory, child: abs) else {
                throw NotFoundError(path: input.path)
            }
            let real: String
            do {
                real = try await fileSystem.realPath(at: abs)
            } catch {
                throw NotFoundError(path: input.path)
            }
            let rootReal = (try? await fileSystem.realPath(at: directory)) ?? directory
            guard FSPathUtil.contains(parent: rootReal, child: real) else {
                throw NotFoundError(path: input.path)
            }
            let info: FileStat
            do {
                info = try await fileSystem.stat(at: real)
            } catch {
                throw NotFoundError(path: input.path)
            }
            guard info.type == .file else {
                throw NotFoundError(path: input.path)
            }
            let fs = self.fileSystem
            return File(
                mime: FSPathUtil.mimeType(real),
                size: info.size,
                modifiedAtMs: info.modifiedAtMs,
                readRange: { offset, bytesToRead in
                    let all = try await fs.readFile(at: real)
                    let start = max(0, min(offset ?? 0, all.count))
                    let end = bytesToRead.map { min(all.count, start + max(0, $0)) } ?? all.count
                    return Array(all[start..<end])
                }
            )
        }

        public func list(_ input: ListInput? = nil) async throws -> [FileSystemSchema.Entry] {
            let relPath = input?.path ?? "."
            let targetDir = CoreConfigDiscovery.resolvePath(base: directory, relative: relPath)
            let missing = NotFoundError(path: SchemaPrimitive.RelativePath(rawValue: relPath))
            guard let info = try? await fileSystem.stat(at: targetDir), info.type == .directory else {
                throw missing
            }
            let names = try await fileSystem.readDirectory(at: targetDir)
            var entries: [FileSystemSchema.Entry] = []
            for name in names {
                let abs = CoreConfigDiscovery.joinPath(targetDir, name)
                guard let st = try? await fileSystem.stat(at: abs) else { continue }
                guard st.type == .file || st.type == .directory else { continue }
                let type: FileSystemSchema.EntryType = st.type == .directory ? .directory : .file
                let rel = FSPathUtil.posixRelative(from: directory, to: abs)
                let display = (rel.isEmpty ? "." : rel) + (type == .directory ? "/" : "")
                entries.append(FileSystemSchema.Entry(
                    path: SchemaPrimitive.RelativePath(rawValue: display),
                    type: type
                ))
            }
            entries.sort { lhs, rhs in
                if lhs.type != rhs.type { return lhs.type == .directory }
                return lhs.path.rawValue.localizedStandardCompare(rhs.path.rawValue) == .orderedAscending
            }
            return entries
        }

        public func find(_ input: FileSystemSchema.FindInput) async -> [FileSystemSchema.Entry] {
            await search.find(input)
        }

        public func write(_ input: WriteInput) async throws -> FileSystemSchema.Write {
            let target = CoreConfigDiscovery.resolvePath(base: directory, relative: input.path)
            try await fileSystem.writeFile(input.data, to: target, createDirectories: true)
            return FileSystemSchema.Write(path: SchemaPrimitive.AbsolutePath(rawValue: target))
        }
    }

    // parity: core/src/filesystem.ts#node [status=adapted hash=b6a3bdfea8a2]
    public static let node: LayerNode.Provider = AppNode.makeLocationNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            let directory = deps.get("@opencode/Location.directory", as: String.self) ?? "/"
            let fsUtil = deps.get(FSUtil.Service.serviceKey, as: FSUtil.Service.self)
            let search = deps.get(Search.Service.serviceKey, as: (any Search.Interface).self)
            let service = Service(
                directory: directory,
                fileSystem: fsUtil?.fileSystem ?? LocalFileSystem.shared,
                search: search
            )
            return LayerNode.Output([Service.serviceKey: service as any Interface])
        },
        [FSUtil.node, Search.node]
    )
}

// MARK: - Pure-Swift Unified File Diff Generator (Shared by FileWrite, EditTool, PatchTool)

public enum CoreFilesystemDiff {
    public static func compute(
        file: String,
        before: String,
        after: String,
        status: FileDiffSchema.Status = .modified,
        contextLines: Int = 3
    ) -> FileDiffSchema.Info {
        let oldLines = splitLines(before)
        let newLines = splitLines(after)
        let edits = diffSequence(oldLines, newLines)

        var additions = 0
        var deletions = 0
        for edit in edits {
            switch edit {
            case .insert: additions += 1
            case .delete: deletions += 1
            case .equal: break
            }
        }

        let patch = formatUnifiedPatch(file: file, edits: edits, contextLines: contextLines)
        return FileDiffSchema.Info(
            file: file,
            patch: patch,
            additions: SchemaPrimitive.NonNegativeInt(rawValue: additions) ?? .zero,
            deletions: SchemaPrimitive.NonNegativeInt(rawValue: deletions) ?? .zero,
            status: status
        )
    }

    private enum EditOp {
        case equal(String)
        case delete(String)
        case insert(String)
    }

    private static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = text.replacing("\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func diffSequence(_ a: [String], _ b: [String]) -> [EditOp] {
        let m = a.count
        let n = b.count
        // Trim common prefix and suffix for speed on large files.
        var prefix = 0
        while prefix < m && prefix < n && a[prefix] == b[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < (m - prefix) && suffix < (n - prefix) && a[m - 1 - suffix] == b[n - 1 - suffix] {
            suffix += 1
        }

        let midA = Array(a[prefix..<(m - suffix)])
        let midB = Array(b[prefix..<(n - suffix)])
        var ops: [EditOp] = []
        for idx in 0..<prefix { ops.append(.equal(a[idx])) }

        if midA.count * midB.count <= 400_000 {
            let ma = midA.count
            let mb = midB.count
            var dp = Array(repeating: Array(repeating: 0, count: mb + 1), count: ma + 1)
            if ma > 0 && mb > 0 {
                for i in stride(from: ma - 1, through: 0, by: -1) {
                    for j in stride(from: mb - 1, through: 0, by: -1) {
                        if midA[i] == midB[j] {
                            dp[i][j] = dp[i + 1][j + 1] + 1
                        } else {
                            dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                        }
                    }
                }
            }
            var i = 0
            var j = 0
            while i < ma && j < mb {
                if midA[i] == midB[j] {
                    ops.append(.equal(midA[i]))
                    i += 1
                    j += 1
                } else if dp[i + 1][j] >= dp[i][j + 1] {
                    ops.append(.delete(midA[i]))
                    i += 1
                } else {
                    ops.append(.insert(midB[j]))
                    j += 1
                }
            }
            while i < ma { ops.append(.delete(midA[i])); i += 1 }
            while j < mb { ops.append(.insert(midB[j])); j += 1 }
        } else {
            for line in midA { ops.append(.delete(line)) }
            for line in midB { ops.append(.insert(line)) }
        }

        for idx in (m - suffix)..<m { ops.append(.equal(a[idx])) }
        return ops
    }

    private static func formatUnifiedPatch(file: String, edits: [EditOp], contextLines: Int) -> String {
        var header = "===================================================================\n--- \(file)\n+++ \(file)\n"
        var hasChanges = false
        for op in edits {
            if case .equal = op { continue }
            hasChanges = true
            break
        }
        guard hasChanges else { return header }

        // Compute ranges of changed ops expanded by contextLines.
        var changeIndices: [Int] = []
        for (idx, op) in edits.enumerated() {
            if case .equal = op { continue }
            changeIndices.append(idx)
        }
        var ranges: [(Int, Int)] = []
        for idx in changeIndices {
            let start = max(0, idx - contextLines)
            let end = min(edits.count - 1, idx + contextLines)
            if let last = ranges.last, start <= last.1 + 1 {
                ranges[ranges.count - 1] = (last.0, max(last.1, end))
            } else {
                ranges.append((start, end))
            }
        }

        for (start, end) in ranges {
            var oldStart = 1
            var newStart = 1
            for i in 0..<start {
                switch edits[i] {
                case .equal: oldStart += 1; newStart += 1
                case .delete: oldStart += 1
                case .insert: newStart += 1
                }
            }
            var oldCount = 0
            var newCount = 0
            var body = ""
            for i in start...end {
                switch edits[i] {
                case .equal(let line):
                    oldCount += 1; newCount += 1; body += " \(line)\n"
                case .delete(let line):
                    oldCount += 1; body += "-\(line)\n"
                case .insert(let line):
                    newCount += 1; body += "+\(line)\n"
                }
            }
            header += "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n"
            header += body
        }
        return header
    }
}

extension CoreFilesystem.FileMutation.Interface {
    /// Locks typed paths, each located first (`withLock(_:)` with string targets).
    public func withLock<T: Sendable>(_ targets: [String], body: @Sendable () async throws -> T) async throws -> T {
        try await withLock(targets.map { CoreFilesystem.FileMutation.LockTarget.path($0) }, body: body)
    }

    /// Locks located places.
    public func withLock<T: Sendable>(places: [CoreFilesystem.FileAccess.Place], body: @Sendable () async throws -> T) async throws -> T {
        try await withLock(places.map { CoreFilesystem.FileMutation.LockTarget.place($0) }, body: body)
    }
}
