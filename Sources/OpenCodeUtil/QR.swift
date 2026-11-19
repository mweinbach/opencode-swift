/// Pure-Swift ISO/IEC 18004 byte-mode QR Code encoder (error correction level L)
/// matching `packages/util/src/qr.ts` bit-for-bit.
public enum QR {
    public struct Error: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }

        public var description: String { message }
    }

    private static let eccPerBlock: [Int] = [
        7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28,
        28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
    ]

    private static let blocks: [Int] = [
        1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8,
        8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25,
    ]

    private static let masks: [@Sendable (Int, Int) -> Bool] = [
        { x, y in (x + y) % 2 == 0 },
        { _, y in y % 2 == 0 },
        { x, _ in x % 3 == 0 },
        { x, y in (x + y) % 3 == 0 },
        { x, y in ((x / 3) + (y / 2)) % 2 == 0 },
        { x, y in ((x * y) % 2) + ((x * y) % 3) == 0 },
        { x, y in (((x * y) % 2) + ((x * y) % 3)) % 2 == 0 },
        { x, y in (((x + y) % 2) + ((x * y) % 3)) % 2 == 0 },
    ]

    /// Encodes `text` as UTF-8 into the smallest level-L QR Code that fits (`true` = dark module).
    // parity: util/src/qr.ts#encode [status=implemented hash=4515d23eb39c]
    public static func encode(_ text: String) throws -> [[Bool]] {
        let bytes = Array(text.utf8)
        var version: Int? = nil
        for v in 1...40 {
            if 4 + (v < 10 ? 8 : 16) + bytes.count * 8 <= dataCapacity(v) * 8 {
                version = v
                break
            }
        }
        guard let version else {
            throw Error("Text is too long for a QR Code: \(bytes.count) bytes")
        }

        let size = version * 4 + 17
        var modules = Array(repeating: Array(repeating: false, count: size), count: size)
        var reserved = Array(repeating: Array(repeating: false, count: size), count: size)
        drawFunctionPatterns(version: version, size: size) { x, y, dark in
            modules[y][x] = dark
            reserved[y][x] = true
        }
        let codewords = addErrorCorrection(data: dataCodewords(bytes: bytes, version: version), version: version)
        drawCodewords(modules: &modules, reserved: reserved, codewords: codewords)

        var bestCandidate: [[Bool]] = []
        var bestPenalty = Int.max
        for (index, mask) in masks.enumerated() {
            var masked = modules
            for y in 0..<size {
                for x in 0..<size {
                    if !reserved[y][x] && mask(x, y) {
                        masked[y][x] = !masked[y][x]
                    }
                }
            }
            drawFormat(mask: index, size: size) { x, y, dark in
                masked[y][x] = dark
            }
            let score = penalty(masked)
            if score < bestPenalty {
                bestPenalty = score
                bestCandidate = masked
            }
        }
        return bestCandidate
    }

    /// Renders `text` as an SVG QR Code with 10-unit modules and a quiet zone of `border` modules.
    // parity: util/src/qr.ts#renderSVG [status=implemented hash=3b2029585703]
    public static func renderSVG(
        _ text: String,
        border: Int = 1,
        blackColor: String = "black",
        whiteColor: String = "white"
    ) throws -> String {
        let modules = addBorder(try encode(text), border: border)
        let width = modules.count * 10
        var path = ""
        for (y, row) in modules.enumerated() {
            for (x, dark) in row.enumerated() where dark {
                path.append("M\(x * 10),\(y * 10)h10v10h-10z")
            }
        }
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(width) \(width)\">"
            + "<rect fill=\"\(escapeAttribute(whiteColor))\" width=\"\(width)\" height=\"\(width)\"/>"
            + "<path fill=\"\(escapeAttribute(blackColor))\" d=\"\(path)\"/></svg>"
    }

    /// Renders `text` as a terminal QR Code using Unicode half-block characters (two rows per line).
    // parity: util/src/qr.ts#renderUnicodeCompact [status=implemented hash=b4d21a2e4691]
    public static func renderUnicodeCompact(_ text: String, border: Int = 1) throws -> String {
        let modules = addBorder(try encode(text), border: border)
        let lineCount = (modules.count + 1) / 2
        var lines: [String] = []
        lines.reserveCapacity(lineCount)
        for line in 0..<lineCount {
            let topRow = modules[line * 2]
            let bottomRow: [Bool]? = (line * 2 + 1 < modules.count) ? modules[line * 2 + 1] : nil
            var rowStr = ""
            rowStr.reserveCapacity(topRow.count * 3)
            for x in 0..<topRow.count {
                let top = topRow[x]
                let bottom = bottomRow?[x] ?? true
                if top {
                    rowStr.append(bottom ? " " : "\u{2584}")
                } else {
                    rowStr.append(bottom ? "\u{2580}" : "\u{2588}")
                }
            }
            lines.append(rowStr)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Private QR Encoder Internals

    private static func drawFunctionPatterns(version: Int, size: Int, set: (Int, Int, Bool) -> Void) {
        for i in 0..<size {
            set(6, i, i % 2 == 0)
            set(i, 6, i % 2 == 0)
        }
        for (cx, cy) in [(3, 3), (size - 4, 3), (3, size - 4)] {
            for dy in -4...4 {
                for dx in -4...4 {
                    let x = cx + dx
                    let y = cy + dy
                    let distance = max(abs(dx), abs(dy))
                    if x >= 0 && x < size && y >= 0 && y < size {
                        set(x, y, distance != 2 && distance != 4)
                    }
                }
            }
        }

        let positions = alignmentPositions(version: version, size: size)
        let last = positions.count - 1
        for (i, cx) in positions.enumerated() {
            for (j, cy) in positions.enumerated() {
                if (i == 0 && j == 0) || (i == 0 && j == last) || (i == last && j == 0) { continue }
                for dy in -2...2 {
                    for dx in -2...2 {
                        set(cx + dx, cy + dy, max(abs(dx), abs(dy)) != 1)
                    }
                }
            }
        }

        drawFormat(mask: 0, size: size, set: set)
        if version < 7 { return }
        let bits = bch(data: version, degree: 12, generator: 0x1F25)
        for i in 0..<18 {
            let a = size - 11 + (i % 3)
            let b = i / 3
            let dark = ((bits >> i) & 1) == 1
            set(a, b, dark)
            set(b, a, dark)
        }
    }

    private static func alignmentPositions(version: Int, size: Int) -> [Int] {
        if version == 1 { return [] }
        let count = version / 7 + 2
        let step: Int
        if version == 32 {
            step = 26
        } else {
            let num = version * 4 + 4
            let den = count * 2 - 2
            step = ((num + den - 1) / den) * 2
        }
        var result = [6]
        for i in 0..<(count - 1) {
            result.append(size - 7 - (count - 2 - i) * step)
        }
        return result
    }

    private static func drawFormat(mask: Int, size: Int, set: (Int, Int, Bool) -> Void) {
        let bits = bch(data: (1 << 3) | mask, degree: 10, generator: 0x537) ^ 0x5412
        func bit(_ i: Int) -> Bool { ((bits >> i) & 1) == 1 }
        for i in 0...5 { set(8, i, bit(i)) }
        set(8, 7, bit(6))
        set(8, 8, bit(7))
        set(7, 8, bit(8))
        for i in 9..<15 { set(14 - i, 8, bit(i)) }
        for i in 0..<8 { set(size - 1 - i, 8, bit(i)) }
        for i in 8..<15 { set(8, size - 15 + i, bit(i)) }
        set(8, size - 8, true)
    }

    private static func bch(data: Int, degree: Int, generator: Int) -> Int {
        var remainder = data
        for _ in 0..<degree {
            remainder = (remainder << 1) ^ ((remainder >> (degree - 1)) * generator)
        }
        return (data << degree) | remainder
    }

    private static func dataCodewords(bytes: [UInt8], version: Int) -> [Int] {
        let capacity = dataCapacity(version)
        var bits: [Int] = []
        bits.reserveCapacity(capacity * 8)
        func append(_ value: Int, _ length: Int) {
            if length <= 0 { return }
            for i in stride(from: length - 1, through: 0, by: -1) {
                bits.append((value >> i) & 1)
            }
        }
        append(0b0100, 4)
        append(bytes.count, version < 10 ? 8 : 16)
        for byte in bytes { append(Int(byte), 8) }
        append(0, min(4, capacity * 8 - bits.count))
        append(0, (8 - (bits.count % 8)) % 8)

        var data: [Int] = []
        data.reserveCapacity(capacity)
        let byteCount = bits.count / 8
        for i in 0..<byteCount {
            var byte = 0
            for j in 0..<8 {
                byte = (byte << 1) | bits[i * 8 + j]
            }
            data.append(byte)
        }
        var padIdx = 0
        while data.count < capacity {
            data.append(padIdx % 2 == 0 ? 0xEC : 0x11)
            padIdx += 1
        }
        return data
    }

    private static func addErrorCorrection(data: [Int], version: Int) -> [Int] {
        let blockCount = blocks[version - 1]
        let ecc = eccPerBlock[version - 1]
        let raw = rawModules(version) / 8
        let shortCount = blockCount - (raw % blockCount)
        let shortLength = raw / blockCount - ecc
        let divisor = reedSolomonDivisor(ecc)

        var split: [[Int]] = []
        split.reserveCapacity(blockCount)
        for i in 0..<blockCount {
            let start = i * shortLength + max(0, i - shortCount)
            let len = shortLength + (i < shortCount ? 0 : 1)
            split.append(Array(data[start..<(start + len)]))
        }

        var result: [Int] = []
        result.reserveCapacity(raw)
        for i in 0..<(shortLength + 1) {
            for block in split where i < block.count {
                result.append(block[i])
            }
        }
        let eccBlocks = split.map { reedSolomonRemainder(data: $0, divisor: divisor) }
        for i in 0..<ecc {
            for block in eccBlocks where i < block.count {
                result.append(block[i])
            }
        }
        return result
    }

    private static func drawCodewords(modules: inout [[Bool]], reserved: [[Bool]], codewords: [Int]) {
        let size = modules.count
        var i = 0
        var right = size - 1
        while right >= 1 {
            if right == 6 { right = 5 }
            for vertical in 0..<size {
                for j in 0..<2 {
                    let x = right - j
                    let y = ((right + 1) & 2) == 0 ? size - 1 - vertical : vertical
                    if reserved[y][x] || i >= codewords.count * 8 { continue }
                    modules[y][x] = ((codewords[i >> 3] >> (7 - (i & 7))) & 1) == 1
                    i += 1
                }
            }
            right -= 2
        }
    }

    private static func penalty(_ modules: [[Bool]]) -> Int {
        let size = modules.count
        var lines = 0
        for row in modules {
            lines += linePenalty(row)
        }
        var col = Array(repeating: false, count: size)
        for x in 0..<size {
            for y in 0..<size { col[y] = modules[y][x] }
            lines += linePenalty(col)
        }

        var boxes = 0
        for y in 0..<(size - 1) {
            for x in 0..<(size - 1) {
                let c = modules[y][x]
                if c == modules[y][x + 1] && c == modules[y + 1][x] && c == modules[y + 1][x + 1] {
                    boxes += 1
                }
            }
        }

        var dark = 0
        for row in modules {
            for cell in row where cell { dark += 1 }
        }
        let total = size * size
        let ratio = (Double(abs(dark * 20 - total * 10)) / Double(total)).rounded(.up)
        let balancePenalty = (Int(ratio) - 1) * 10
        return lines + boxes * 3 + balancePenalty
    }

    private static func linePenalty(_ line: [Bool]) -> Int {
        let size = line.count
        var history = [0, 0, 0, 0, 0, 0, 0]
        func push(_ length: Int) {
            let head = history[0]
            history.removeLast()
            history.insert(head == 0 ? length + size : length, at: 0)
        }
        func finders() -> Int {
            let n = history[1]
            let core = n > 0 && history[2] == n && history[3] == n * 3 && history[4] == n && history[5] == n
            return ((core && history[0] >= n * 4 && history[6] >= n) ? 1 : 0)
                + ((core && history[6] >= n * 4 && history[0] >= n) ? 1 : 0)
        }
        var result = 0
        var color = false
        var run = 0
        for dark in line {
            if dark == color {
                run += 1
                if run == 5 { result += 3 }
                if run > 5 { result += 1 }
                continue
            }
            push(run)
            if !color { result += finders() * 40 }
            color = dark
            run = 1
        }
        if color {
            push(run)
            run = 0
        }
        push(run + size)
        return result + finders() * 40
    }

    private static func reedSolomonDivisor(_ degree: Int) -> [Int] {
        var result = Array(repeating: 0, count: degree)
        result[degree - 1] = 1
        var root = 1
        for _ in 0..<degree {
            for j in 0..<degree {
                result[j] = multiplyGF(result[j], root)
                if j + 1 < degree { result[j] ^= result[j + 1] }
            }
            root = multiplyGF(root, 2)
        }
        return result
    }

    private static func reedSolomonRemainder(data: [Int], divisor: [Int]) -> [Int] {
        var remainder = Array(repeating: 0, count: divisor.count)
        for byte in data {
            let factor = byte ^ remainder[0]
            for i in 0..<(divisor.count - 1) {
                remainder[i] = remainder[i + 1] ^ multiplyGF(divisor[i], factor)
            }
            remainder[divisor.count - 1] = multiplyGF(divisor[divisor.count - 1], factor)
        }
        return remainder
    }

    private static func multiplyGF(_ x: Int, _ y: Int) -> Int {
        var z = 0
        for i in stride(from: 7, through: 0, by: -1) {
            z = (z << 1) ^ ((z >> 7) * 0x11D)
            z ^= ((y >> i) & 1) * x
        }
        return z
    }

    private static func rawModules(_ version: Int) -> Int {
        let base = (16 * version + 128) * version + 64
        if version < 2 { return base }
        let count = version / 7 + 2
        return base - ((25 * count - 10) * count - 55) - (version >= 7 ? 36 : 0)
    }

    private static func dataCapacity(_ version: Int) -> Int {
        rawModules(version) / 8 - eccPerBlock[version - 1] * blocks[version - 1]
    }

    private static func addBorder(_ modules: [[Bool]], border: Int) -> [[Bool]] {
        let b = max(0, border)
        let width = modules.count + b * 2
        let blank = Array(repeating: false, count: width)
        let pad = Array(repeating: false, count: b)
        var result: [[Bool]] = []
        result.reserveCapacity(width)
        for _ in 0..<b { result.append(blank) }
        for row in modules {
            result.append(pad + row + pad)
        }
        for _ in 0..<b { result.append(blank) }
        return result
    }

    private static func escapeAttribute(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": out.append("&amp;")
            case "\"": out.append("&quot;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
