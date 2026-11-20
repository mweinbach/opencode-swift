#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeSchema

/// Port of `core/src/machine/join.ts`: the `ocjoin_` string a home prints for one machine to join.
public enum MachineJoin {
    static let prefix = "ocjoin_"
    /// Longer than any join string this home prints, so a hostile one is refused before it is decoded.
    static let maxLength = 4_096
    static let keyBytes = 32
    static let maxSafeInteger: Int64 = 9_007_199_254_740_991

    /// A way to reach the home, as the worker's transport understands it.
    // parity: core/src/machine/join.ts#Reach [status=implemented hash=b553c0804a0e]
    public enum Reach: Equatable, Hashable, Sendable {
        case url(String)

        static func decode(_ value: JSONValue) -> Reach? {
            guard case .object(let fields) = value,
                  fields["type"] == .string("url"),
                  case .string(let url)? = fields["url"]
            else {
                return nil
            }
            return .url(url)
        }

        func json() -> String {
            switch self {
            case .url(let url): return "{\"type\":\"url\",\"url\":\(MachineJoin.jsonString(url))}"
            }
        }
    }

    // parity: core/src/machine/join.ts#Value [status=implemented hash=8593c1189975]
    public struct Value: Equatable, Hashable, Sendable {
        public let v: Int
        public let home: [UInt8]
        public let secret: [UInt8]
        public let expires: Int64
        public let reach: [Reach]

        public init(home: [UInt8], secret: [UInt8], expires: Int64, reach: [Reach]) {
            self.v = 1
            self.home = home
            self.secret = secret
            self.expires = expires
            self.reach = reach
        }
    }

    /// The join string of `value`. The Rust worker parses this too: plain JSON with these names, in this order, with
    /// keys as unpadded base64url.
    // parity: core/src/machine/join.ts#encode [status=implemented hash=6896eb04ef33]
    public static func encode(_ value: Value) -> String {
        let reach = value.reach.map { $0.json() }.joined(separator: ",")
        let json = "{\"v\":\(value.v),\"home\":\"\(MachineCrypto.base64URLEncode(value.home))\","
            + "\"secret\":\"\(MachineCrypto.base64URLEncode(value.secret))\",\"expires\":\(value.expires),"
            + "\"reach\":[\(reach)]}"
        return prefix + MachineCrypto.base64URLEncode(Array(json.utf8))
    }

    /// The value of a join string, or `nil` for anything this home did not print: `reach` entries this worker cannot
    /// use are dropped.
    // parity: core/src/machine/join.ts#decode [status=implemented hash=5463d2866e45]
    public static func decode(_ text: String) -> Value? {
        if text.utf16.count > maxLength || !text.hasPrefix(prefix) { return nil }
        let encoded = String(text.dropFirst(prefix.count))
        // Only canonical text passes, as the strict decoder the Rust worker uses requires.
        guard let bytes = MachineCrypto.base64URLDecode(encoded), MachineCrypto.base64URLEncode(bytes) == encoded else {
            return nil
        }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(String(decoding: bytes, as: UTF8.self).utf8)),
              case .object(let fields) = json,
              let v = integer(fields["v"]), v == 1,
              let home = key(fields["home"]),
              let secret = key(fields["secret"]),
              let expires = integer(fields["expires"]), expires >= 0, expires <= maxSafeInteger,
              case .array(let entries)? = fields["reach"],
              entries.allSatisfy({ if case .object = $0 { return true } else { return false } })
        else {
            return nil
        }
        return Value(home: home, secret: secret, expires: expires, reach: entries.compactMap(Reach.decode))
    }

    private static func integer(_ value: JSONValue?) -> Int64? {
        switch value {
        case .int(let n)?: return n
        case .double(let d)? where d.rounded() == d && abs(d) <= Double(maxSafeInteger): return Int64(d)
        default: return nil
        }
    }

    private static func key(_ value: JSONValue?) -> [UInt8]? {
        guard case .string(let text)? = value, let bytes = MachineCrypto.base64URLDecode(text), bytes.count == keyBytes else {
            return nil
        }
        return bytes
    }

    /// `JSON.stringify` of a string.
    static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// Port of `core/src/machine/path.ts`: a path that names a machine, as in `gpu:/work/a` or `gpu:~/a`.
public enum MachinePath {
    // parity: core/src/machine/path.ts#Parsed [status=implemented hash=85e2d3e93135]
    public struct Parsed: Equatable, Hashable, Sendable {
        public let machine: String
        /// The rest as written, `/...` or `~...`: locating a path owner normalizes it.
        public let path: String

        public init(machine: String, path: String) {
            self.machine = machine
            self.path = path
        }
    }

    // parity: core/src/machine/path.ts#NotAbsolute [status=implemented hash=75d3204117ca]
    public struct NotAbsolute: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Machine.NotAbsolute"
        public let machine: String

        public init(machine: String) {
            self.machine = machine
        }

        // parity: core/src/machine/path.ts#NotAbsolute.message [status=implemented hash=f629307ff2b5]
        public var message: String {
            "A \(machine) path must be absolute or start with ~/, as in \(machine):/work/file."
        }

        public var description: String { message }
    }

    /// Splits `gpu:/work/a` or `gpu:~/a` into a machine and the rest. A Windows drive or any URL is not one.
    // parity: core/src/machine/path.ts#parse [status=implemented hash=2c0e8f965fb7]
    public static func parse(_ text: String) -> Parsed? {
        // Scalar-wise, as `indexOf` and `startsWith` compare code units, never grapheme clusters.
        let scalars = text.unicodeScalars
        guard let colon = scalars.firstIndex(of: ":"), colon > scalars.startIndex else { return nil }
        let machine = String(Substring(scalars[..<colon]))
        guard Machines.Name.isValid(machine) else { return nil }
        let rest = scalars[scalars.index(after: colon)...]
        guard let first = rest.first, first == "/" || first == "~" else { return nil }
        if first == "/", rest.dropFirst().first == "/" { return nil }
        return Parsed(machine: machine, path: String(Substring(rest)))
    }
}

/// Port of `core/src/machine/sql.ts`.
public enum MachineSQL {
    /// The `machine` table: one row per known machine, with its public key (base64url) once it has joined.
    // parity: core/src/machine/sql.ts#MachineTable [status=adapted hash=5ed8011a0a2d]
    public enum MachineTable {
        public static let tableName = "machine"
        public static let id = "id"
        /// The machine's public key, base64url, once it has joined. Null until then.
        public static let key = "key"
        public static let timeCreated = "time_created"
        public static let keyIndex = "machine_key_idx"
        public static let createTableSQL = """
            CREATE TABLE `machine` (
              `id` text PRIMARY KEY,
              `key` text,
              `time_created` integer NOT NULL
            );
            """
        public static let createKeyIndexSQL = "CREATE UNIQUE INDEX `machine_key_idx` ON `machine` (`key`);"
    }
}
