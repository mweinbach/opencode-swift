/// Pure-Swift color matrices, framebuffer color-matrix transforms, post-processing filters,
/// and animated visual effects matching `packages/core/src/post/{matrices,filters,effects}.ts`
/// and `packages/native/src/buffer-methods.zig`.

// MARK: - Pure-Swift Math & Deterministic PRNG Helpers

private let twoPi: Double = 2.0 * Double.pi
private let halfPi: Double = Double.pi / 2.0
private let ln2Const: Double = 0.693147180559945309417232121458176568

/// Pure-Swift sine accurate to double precision without OS math imports.
private func postSin(_ x: Double) -> Double {
    if !x.isFinite { return .nan }
    var reduced = x.truncatingRemainder(dividingBy: twoPi)
    if reduced > Double.pi { reduced -= twoPi }
    if reduced < -Double.pi { reduced += twoPi }

    if reduced > halfPi {
        reduced = Double.pi - reduced
    } else if reduced < -halfPi {
        reduced = -Double.pi - reduced
    }

    let x2 = reduced * reduced
    var term = reduced
    var sum = reduced
    for k in 1...9 {
        let denom = Double((2 * k) * (2 * k + 1))
        term = -term * x2 / denom
        sum += term
    }
    return sum
}

/// Pure-Swift cosine accurate to double precision without OS math imports.
private func postCos(_ x: Double) -> Double {
    postSin(x + halfPi)
}

/// Pure-Swift exponential function accurate to double precision without OS math imports.
private func postExp(_ x: Double) -> Double {
    if x.isNaN { return .nan }
    if x > 709.782712893384 { return .infinity }
    if x < -745.1332191019412 { return 0.0 }

    let k = Int((x / ln2Const).rounded())
    let r = x - Double(k) * ln2Const

    var term = 1.0
    var sum = 1.0
    for n in 1...18 {
        term *= r / Double(n)
        sum += term
    }
    return sum * Double(sign: .plus, exponent: k, significand: 1.0)
}

@inline(__always)
private func jsRound(_ value: Double) -> Int {
    Int((value + 0.5).rounded(.down))
}

@inline(__always)
private func clampChannelToU8(_ value: Double) -> UInt8 {
    let clamped = value.isFinite ? max(0.0, min(1.0, value)) : 0.0
    return UInt8(jsRound(clamped * 255.0))
}

@inline(__always)
private func clampChannelFloatToU8(_ value: Float) -> UInt8 {
    clampChannelToU8(Double(value))
}

@inline(__always)
private func rgbaWithRGB(_ original: RGBA, r: Double, g: Double, b: Double) -> RGBA {
    let (_, _, _, a) = original.toInts()
    return RGBA.fromInts(Int(clampChannelToU8(r)), Int(clampChannelToU8(g)), Int(clampChannelToU8(b)), Int(a))
}

@inline(__always)
private func normalizedRGB(_ color: RGBA) -> (r: Double, g: Double, b: Double, a: Double) {
    let (r, g, b, a) = color.toInts()
    return (Double(r) / 255.0, Double(g) / 255.0, Double(b) / 255.0, Double(a) / 255.0)
}

@inline(__always)
private func luminance(_ color: RGBA) -> Double {
    let (r, g, b, _) = normalizedRGB(color)
    return 0.299 * r + 0.587 * g + 0.114 * b
}

/// Fast pure-Swift SplitMix64 PRNG for deterministic or default pseudo-random post effects.
private struct PurePRNG: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Returns a uniform Double in `[0, 1)`.
    mutating func nextUnitDouble() -> Double {
        Double(nextUInt64() >> 11) * (1.0 / Double(UInt64(1) << 53))
    }
}

// MARK: - Color Matrices

/// Alias for `TargetChannel` matching `ColorTarget` in `native/src/buffer-methods.zig`.
// parity: native/src/buffer-methods.zig#ColorTarget [status=implemented hash=7eee05e5ab40]
public typealias ColorTarget = TargetChannel

/// Standard 4x4 row-major RGBA color transformation matrices matching `packages/core/src/post/matrices.ts`,
/// plus parameterized factory helpers (brightness, gain, contrast, saturation, hue rotation, 3x3 lifting).
public enum ColorMatrices {
    /// 4x4 identity matrix.
    public static let identity: [Float] = [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    ]

    /// Standard sepia transformation matrix (4x4 RGBA with alpha identity).
    // parity: core/src/post/matrices.ts#SEPIA_MATRIX [status=implemented hash=13da8c2f29f8]
    public static let sepia: [Float] = [
        0.393, 0.769, 0.189, 0,
        0.349, 0.686, 0.168, 0,
        0.272, 0.534, 0.131, 0,
        0, 0, 0, 1,
    ]

    /// Protanopia (red-blind) simulation matrix.
    // parity: core/src/post/matrices.ts#PROTANOPIA_SIM_MATRIX [status=implemented hash=0a760bb4833e]
    public static let protanopiaSim: [Float] = [
        0.567, 0.433, 0.0, 0,
        0.558, 0.442, 0.0, 0,
        0.0, 0.242, 0.758, 0,
        0, 0, 0, 1,
    ]

    /// Deuteranopia (green-blind) simulation matrix.
    // parity: core/src/post/matrices.ts#DEUTERANOPIA_SIM_MATRIX [status=implemented hash=f498a71c350d]
    public static let deuteranopiaSim: [Float] = [
        0.625, 0.375, 0.0, 0,
        0.7, 0.3, 0.0, 0,
        0.0, 0.3, 0.7, 0,
        0, 0, 0, 1,
    ]

    /// Tritanopia (blue-blind) simulation matrix.
    // parity: core/src/post/matrices.ts#TRITANOPIA_SIM_MATRIX [status=implemented hash=9b2200fed817]
    public static let tritanopiaSim: [Float] = [
        0.95, 0.05, 0.0, 0,
        0.0, 0.433, 0.567, 0,
        0.0, 0.475, 0.525, 0,
        0, 0, 0, 1,
    ]

    /// Achromatopsia (complete color blindness / luminance grayscale) matrix.
    // parity: core/src/post/matrices.ts#ACHROMATOPSIA_MATRIX [status=implemented hash=0d75619f6689]
    public static let achromatopsia: [Float] = [
        0.299, 0.587, 0.114, 0,
        0.299, 0.587, 0.114, 0,
        0.299, 0.587, 0.114, 0,
        0, 0, 0, 1,
    ]

    /// Protanopia compensation matrix.
    // parity: core/src/post/matrices.ts#PROTANOPIA_COMP_MATRIX [status=implemented hash=51e5acd7a1f3]
    public static let protanopiaComp: [Float] = [
        1.0, 0.2, 0.0, 0,
        0.0, 0.9, 0.1, 0,
        0.0, 0.1, 0.9, 0,
        0, 0, 0, 1,
    ]

    /// Deuteranopia compensation matrix.
    // parity: core/src/post/matrices.ts#DEUTERANOPIA_COMP_MATRIX [status=implemented hash=2eb356961ca1]
    public static let deuteranopiaComp: [Float] = [
        0.9, 0.1, 0.0, 0,
        0.2, 0.8, 0.0, 0,
        0.0, 0.0, 1.0, 0,
        0, 0, 0, 1,
    ]

    /// Tritanopia compensation matrix.
    // parity: core/src/post/matrices.ts#TRITANOPIA_COMP_MATRIX [status=implemented hash=3a380961f2d5]
    public static let tritanopiaComp: [Float] = [
        1.0, 0.0, 0.0, 0,
        0.0, 0.9, 0.1, 0,
        0.1, 0.0, 0.9, 0,
        0, 0, 0, 1,
    ]

    /// Technicolor creative effect matrix.
    // parity: core/src/post/matrices.ts#TECHNICOLOR_MATRIX [status=implemented hash=1793a0dc109b]
    public static let technicolor: [Float] = [
        1.5, -0.2, -0.3, 0,
        -0.3, 1.4, -0.1, 0,
        -0.2, -0.2, 1.4, 0,
        0, 0, 0, 1,
    ]

    /// Solarization partial-negative effect matrix.
    // parity: core/src/post/matrices.ts#SOLARIZATION_MATRIX [status=implemented hash=6be6bc284ba6]
    public static let solarization: [Float] = [
        -0.5, 0.5, 0.5, 0,
        0.5, -0.5, 0.5, 0,
        0.5, 0.5, -0.5, 0,
        0, 0, 0, 1,
    ]

    /// Synthwave retro neon magenta/cyan effect matrix.
    // parity: core/src/post/matrices.ts#SYNTHWAVE_MATRIX [status=implemented hash=4a9df48264ba]
    public static let synthwave: [Float] = [
        1.0, 0.0, 0.25, 0,
        0.1, 0.1, 0.1, 0,
        0.25, 0.0, 1.0, 0,
        0, 0, 0, 1,
    ]

    /// Monochrome phosphor green luminance matrix.
    // parity: core/src/post/matrices.ts#GREENSCALE_MATRIX [status=implemented hash=4e0479176ed2]
    public static let greenscale: [Float] = [
        0, 0, 0, 0,
        0.299, 0.587, 0.114, 0,
        0, 0, 0, 0,
        0, 0, 0, 1,
    ]

    /// Grayscale luminance matrix.
    // parity: core/src/post/matrices.ts#GRAYSCALE_MATRIX [status=implemented hash=2a5d38957e6a]
    public static let grayscale: [Float] = [
        0.299, 0.587, 0.114, 0,
        0.299, 0.587, 0.114, 0,
        0.299, 0.587, 0.114, 0,
        0, 0, 0, 1,
    ]

    /// Photographic negative matrix (`1 - R`, `1 - G`, `1 - B`).
    // parity: core/src/post/matrices.ts#INVERT_MATRIX [status=implemented hash=57d2169ed7de]
    public static let invert: [Float] = [
        -1, 0, 0, 1,
        0, -1, 0, 1,
        0, 0, -1, 1,
        0, 0, 0, 1,
    ]

    /// Lifts a 3x3 row-major RGB matrix into a 4x4 RGBA matrix with identity alpha.
    public static func from3x3(_ m: [Float]) -> [Float] {
        guard m.count >= 9 else { return identity }
        return [
            m[0], m[1], m[2], 0,
            m[3], m[4], m[5], 0,
            m[6], m[7], m[8], 0,
            0, 0, 0, 1,
        ]
    }

    /// Additive brightness matrix (`channel + delta * alpha`).
    public static func brightness(_ delta: Float) -> [Float] {
        [
            1, 0, 0, delta,
            0, 1, 0, delta,
            0, 0, 1, delta,
            0, 0, 0, 1,
        ]
    }

    /// Multiplicative gain matrix (`channel * max(0, factor)`).
    public static func gain(_ factor: Float) -> [Float] {
        let g = max(0, factor)
        return [
            g, 0, 0, 0,
            0, g, 0, 0,
            0, 0, g, 0,
            0, 0, 0, 1,
        ]
    }

    /// Contrast adjustment matrix around mid-gray (`factor * channel + 0.5 * (1 - factor) * alpha`).
    public static func contrast(_ factor: Float) -> [Float] {
        let offset = 0.5 * (1.0 - factor)
        return [
            factor, 0, 0, offset,
            0, factor, 0, offset,
            0, 0, factor, offset,
            0, 0, 0, 1,
        ]
    }

    /// Luminance-preserving saturation adjustment matrix (`0` = grayscale, `1` = identity, `>1` = vivid).
    public static func saturation(_ saturation: Float) -> [Float] {
        let s = max(0, saturation)
        let sr = 0.299 * (1 - s)
        let sg = 0.587 * (1 - s)
        let sb = 0.114 * (1 - s)
        return [
            sr + s, sg, sb, 0,
            sr, sg + s, sb, 0,
            sr, sg, sb + s, 0,
            0, 0, 0, 1,
        ]
    }

    /// Luminance-preserving RGB hue rotation matrix for `degrees`.
    public static func hueRotation(degrees: Double) -> [Float] {
        let rad = degrees * Double.pi / 180.0
        let c = postCos(rad)
        let s = postSin(rad)

        let lumR = 0.213
        let lumG = 0.715
        let lumB = 0.072

        return [
            Float(lumR + c * (1 - lumR) + s * (-lumR)),
            Float(lumG + c * (-lumG) + s * (-lumG)),
            Float(lumB + c * (-lumB) + s * (1 - lumB)),
            0,
            Float(lumR + c * (-lumR) + s * 0.143),
            Float(lumG + c * (1 - lumG) + s * 0.140),
            Float(lumB + c * (-lumB) + s * (-0.283)),
            0,
            Float(lumR + c * (-lumR) + s * (-(1 - lumR))),
            Float(lumG + c * (-lumG) + s * lumG),
            Float(lumB + c * (1 - lumB) + s * lumB),
            0,
            0, 0, 0, 1,
        ]
    }
}

// MARK: - Core 4x4 Matrix Application

@inline(__always)
private func normalizeMatrix4x4(_ matrix: [Float]) -> [Float]? {
    if matrix.count >= 16 {
        return matrix
    }
    if matrix.count == 9 {
        return ColorMatrices.from3x3(matrix)
    }
    return nil
}

@inline(__always)
private func applyMatrix4x4(to color: RGBA, matrix m: [Float], strength: Float) -> RGBA {
    let (r8, g8, b8, a8) = color.toInts()
    let r = Float(r8) / 255.0
    let g = Float(g8) / 255.0
    let b = Float(b8) / 255.0
    let a = Float(a8) / 255.0

    let newR = m[0] * r + m[1] * g + m[2] * b + m[3] * a
    let newG = m[4] * r + m[5] * g + m[6] * b + m[7] * a
    let newB = m[8] * r + m[9] * g + m[10] * b + m[11] * a
    let newA = m[12] * r + m[13] * g + m[14] * b + m[15] * a

    let outR = r + (newR - r) * strength
    let outG = g + (newG - g) * strength
    let outB = b + (newB - b) * strength
    let outA = a + (newA - a) * strength

    return RGBA.fromInts(
        Int(clampChannelFloatToU8(outR)),
        Int(clampChannelFloatToU8(outG)),
        Int(clampChannelFloatToU8(outB)),
        Int(clampChannelFloatToU8(outA))
    )
}

extension OptimizedBuffer {
    /// Applies a 4x4 (or 3x3) color matrix to specific `(x, y, cellStrength)` mask triplets.
    // parity: core/src/buffer.ts#OptimizedBuffer.colorMatrix [status=implemented hash=78edfc60b82d]
    // parity: native/src/buffer-methods.zig#colorMatrix [status=implemented hash=3fd03709c748]
    public func colorMatrix(
        _ matrix: [Float],
        cellMask: [Float],
        strength: Float = 1.0,
        target: TargetChannel = .both
    ) {
        guard let mat4 = normalizeMatrix4x4(matrix), cellMask.count >= 3, strength.isFinite else {
            return
        }

        let processFG = (target.rawValue & TargetChannel.fg.rawValue) != 0
        let processBG = (target.rawValue & TargetChannel.bg.rawValue) != 0
        guard processFG || processBG else { return }

        let usableLen = cellMask.count - (cellMask.count % 3)
        var i = 0
        while i < usableLen {
            let xf = cellMask[i]
            let yf = cellMask[i + 1]
            let localStrength = cellMask[i + 2] * strength
            i += 3

            if !xf.isFinite || !yf.isFinite || xf < 0 || yf < 0 { continue }
            if !localStrength.isFinite || localStrength == 0 { continue }

            let x = Int(xf)
            let y = Int(yf)
            guard x >= 0 && x < width && y >= 0 && y < height else { continue }
            guard var current = cell(atX: x, y: y) else { continue }

            if processFG {
                current.foreground = applyMatrix4x4(to: current.foreground, matrix: mat4, strength: localStrength)
            }
            if processBG {
                current.background = applyMatrix4x4(to: current.background, matrix: mat4, strength: localStrength)
            }
            setCellRaw(x: x, y: y, cell: current)
        }
    }

    /// Applies a 4x4 (or 3x3) color matrix uniformly across every cell of the buffer.
    // parity: core/src/buffer.ts#OptimizedBuffer.colorMatrixUniform [status=implemented hash=e559f64db97a]
    // parity: native/src/buffer-methods.zig#colorMatrixUniform [status=implemented hash=9e07722010e6]
    public func colorMatrixUniform(
        _ matrix: [Float],
        strength: Float = 1.0,
        target: TargetChannel = .both
    ) {
        guard let mat4 = normalizeMatrix4x4(matrix), strength.isFinite, strength != 0 else {
            return
        }

        let processFG = (target.rawValue & TargetChannel.fg.rawValue) != 0
        let processBG = (target.rawValue & TargetChannel.bg.rawValue) != 0
        guard processFG || processBG else { return }

        for y in 0..<height {
            for x in 0..<width {
                guard var current = cell(atX: x, y: y) else { continue }
                if processFG {
                    current.foreground = applyMatrix4x4(to: current.foreground, matrix: mat4, strength: strength)
                }
                if processBG {
                    current.background = applyMatrix4x4(to: current.background, matrix: mat4, strength: strength)
                }
                setCellRaw(x: x, y: y, cell: current)
            }
        }
    }
}

/// Applies a 3x3 or 4x4 color matrix uniformly (or via `cellMask`) to `buffer`.
public func applyColorMatrix(
    buffer: OptimizedBuffer,
    matrix: [Float],
    strength: Float = 1.0,
    target: TargetChannel = .both,
    cellMask: [Float]? = nil
) {
    if let cellMask, !cellMask.isEmpty {
        buffer.colorMatrix(matrix, cellMask: cellMask, strength: strength, target: target)
    } else {
        buffer.colorMatrixUniform(matrix, strength: strength, target: target)
    }
}

// MARK: - Post-Processing Filters (`post/filters.ts`)

/// Applies a CRT scanline effect by scaling background colors on every `step`-th row.
// parity: core/src/post/filters.ts#applyScanlines [status=implemented hash=0dc605583d4a]
public func applyScanlines(buffer: OptimizedBuffer, strength: Float = 0.8, step: Int = 2) {
    guard strength != 1.0, step >= 1, buffer.width > 0, buffer.height > 0 else { return }

    let affectedRows = (buffer.height + step - 1) / step
    var cellMask: [Float] = []
    cellMask.reserveCapacity(buffer.width * affectedRows * 3)

    var y = 0
    while y < buffer.height {
        for x in 0..<buffer.width {
            cellMask.append(Float(x))
            cellMask.append(Float(y))
            cellMask.append(1.0)
        }
        y += step
    }

    let matrix: [Float] = [
        strength, 0, 0, 0,
        0, strength, 0, 0,
        0, 0, strength, 0,
        0, 0, 0, 1,
    ]
    buffer.colorMatrix(matrix, cellMask: cellMask, strength: 1.0, target: .bg)
}

/// Inverts foreground and background colors in `buffer`.
// parity: core/src/post/filters.ts#applyInvert [status=implemented hash=95d47db8f368]
public func applyInvert(buffer: OptimizedBuffer, strength: Float = 1.0) {
    guard strength != 0.0 else { return }
    buffer.colorMatrixUniform(ColorMatrices.invert, strength: strength, target: .both)
}

/// Adds per-cell random luminance noise to `buffer`. Pass `seed` for deterministic output.
// parity: core/src/post/filters.ts#applyNoise [status=implemented hash=1ba5638b4227]
public func applyNoise(buffer: OptimizedBuffer, strength: Float = 0.1, seed: UInt64 = 0x517C_C1B7_2722_0A95) {
    guard strength != 0.0, buffer.width > 0, buffer.height > 0 else { return }

    var rng = PurePRNG(seed: seed)
    var cellMask: [Float] = []
    cellMask.reserveCapacity(buffer.width * buffer.height * 3)

    for y in 0..<buffer.height {
        for x in 0..<buffer.width {
            cellMask.append(Float(x))
            cellMask.append(Float(y))
            cellMask.append(Float((rng.nextUnitDouble() - 0.5) * 2.0))
        }
    }

    let b = 1.0 + strength
    let matrix: [Float] = [
        b, 0, 0, 0,
        0, b, 0, 0,
        0, 0, b, 0,
        0, 0, 0, 1,
    ]
    buffer.colorMatrix(matrix, cellMask: cellMask, strength: 1.0, target: .both)
}

/// Applies radial RGB channel separation to the foreground plane of `buffer`.
// parity: core/src/post/filters.ts#applyChromaticAberration [status=implemented hash=249adf72b9eb]
public func applyChromaticAberration(buffer: OptimizedBuffer, strength: Double = 1.0) {
    let width = buffer.width
    let height = buffer.height
    guard width > 0, height > 0 else { return }

    let srcFg = buffer.fg
    let centerX = Double(width) / 2.0
    let centerY = Double(height) / 2.0
    let maxCenter = max(centerX, centerY)
    guard maxCenter > 0 else { return }

    for y in 0..<height {
        for x in 0..<width {
            let dx = Double(x) - centerX
            let dy = Double(y) - centerY
            let offset = jsRound(((dx * dx + dy * dy).squareRoot() / maxCenter) * strength)

            let rX = max(0, min(width - 1, x - offset))
            let bX = max(0, min(width - 1, x + offset))

            let rColor = normalizedRGB(srcFg[y * width + rX])
            let gColor = normalizedRGB(srcFg[y * width + x])
            let bColor = normalizedRGB(srcFg[y * width + bX])

            if var current = buffer.cell(atX: x, y: y) {
                current.foreground = rgbaWithRGB(current.foreground, r: rColor.r, g: gColor.g, b: bColor.b)
                buffer.setCellRaw(x: x, y: y, cell: current)
            }
        }
    }
}

/// Default ASCII luminance ramp matching `applyAsciiArt` in `post/filters.ts`.
public let defaultAsciiArtRamp: String = #" .'`^"",:;Il!i><~+_-?][}{1)(|\/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$"#

/// Converts `buffer` cells into ASCII art characters driven by background luminance.
// parity: core/src/post/filters.ts#applyAsciiArt [status=implemented hash=653a5b0b3fe3]
public func applyAsciiArt(
    buffer: OptimizedBuffer,
    ramp: String = defaultAsciiArtRamp,
    fgColor: (r: Float, g: Float, b: Float) = (1.0, 1.0, 1.0),
    bgColor: (r: Float, g: Float, b: Float) = (0.0, 0.0, 0.0)
) {
    let rampScalars = Array(ramp.unicodeScalars)
    guard !rampScalars.isEmpty, buffer.width > 0, buffer.height > 0 else { return }
    let rampLength = rampScalars.count

    for y in 0..<buffer.height {
        for x in 0..<buffer.width {
            guard var current = buffer.cell(atX: x, y: y) else { continue }
            let lum = luminance(current.background)
            let rampIndex = min(rampLength - 1, max(0, Int((lum * Double(rampLength)).rounded(.down))))
            current.scalar = rampScalars[rampIndex].value
            buffer.setCellRaw(x: x, y: y, cell: current)
        }
    }

    let fgMatrix: [Float] = [
        0, 0, 0, fgColor.r,
        0, 0, 0, fgColor.g,
        0, 0, 0, fgColor.b,
        0, 0, 0, 1,
    ]
    let bgMatrix: [Float] = [
        0, 0, 0, bgColor.r,
        0, 0, 0, bgColor.g,
        0, 0, 0, bgColor.b,
        0, 0, 0, 1,
    ]
    buffer.colorMatrixUniform(fgMatrix, strength: 1.0, target: .fg)
    buffer.colorMatrixUniform(bgMatrix, strength: 1.0, target: .bg)
}

/// Applies additive brightness adjustment to `buffer`.
// parity: core/src/post/filters.ts#applyBrightness [status=implemented hash=4f6800114b28]
public func applyBrightness(buffer: OptimizedBuffer, brightness: Float = 0.0, cellMask: [Float]? = nil) {
    guard brightness != 0.0 else { return }
    applyColorMatrix(
        buffer: buffer,
        matrix: ColorMatrices.brightness(brightness),
        strength: 1.0,
        target: .both,
        cellMask: cellMask
    )
}

/// Applies multiplicative gain adjustment to `buffer`.
// parity: core/src/post/filters.ts#applyGain [status=implemented hash=d71a66bd1be0]
public func applyGain(buffer: OptimizedBuffer, gain: Float = 1.0, cellMask: [Float]? = nil) {
    guard gain != 1.0 else { return }
    applyColorMatrix(
        buffer: buffer,
        matrix: ColorMatrices.gain(gain),
        strength: 1.0,
        target: .both,
        cellMask: cellMask
    )
}

/// Applies saturation adjustment to `buffer`.
// parity: core/src/post/filters.ts#applySaturation [status=implemented hash=e05d0d78988d]
public func applySaturation(buffer: OptimizedBuffer, cellMask: [Float]? = nil, strength: Float = 1.0) {
    guard strength != 1.0 && strength != 0.0 else { return }
    applyColorMatrix(
        buffer: buffer,
        matrix: ColorMatrices.saturation(strength),
        strength: 1.0,
        target: .both,
        cellMask: cellMask
    )
}

/// Applies a Gaussian-weighted spatial blur across neighboring cell colors.
public func applyBlur(buffer: OptimizedBuffer, radius: Int = 1, target: TargetChannel = .both) {
    let width = buffer.width
    let height = buffer.height
    guard radius > 0, width > 0, height > 0 else { return }

    let processFG = (target.rawValue & TargetChannel.fg.rawValue) != 0
    let processBG = (target.rawValue & TargetChannel.bg.rawValue) != 0
    guard processFG || processBG else { return }

    let srcFg = buffer.fg
    let srcBg = buffer.bg

    // Precompute 1D Gaussian weights using postExp
    let sigma = max(0.5, Double(radius) / 2.0)
    let twoSigmaSq = 2.0 * sigma * sigma
    var weights: [Double] = []
    weights.reserveCapacity(radius * 2 + 1)
    for k in -radius...radius {
        weights.append(postExp(-Double(k * k) / twoSigmaSq))
    }

    for y in 0..<height {
        for x in 0..<width {
            guard var current = buffer.cell(atX: x, y: y) else { continue }
            var fgR = 0.0, fgG = 0.0, fgB = 0.0
            var bgR = 0.0, bgG = 0.0, bgB = 0.0
            var totalWeight = 0.0

            for ky in -radius...radius {
                let sy = max(0, min(height - 1, y + ky))
                let wy = weights[ky + radius]
                let rowBase = sy * width
                for kx in -radius...radius {
                    let sx = max(0, min(width - 1, x + kx))
                    let w = wy * weights[kx + radius]
                    totalWeight += w
                    let idx = rowBase + sx
                    if processFG {
                        let c = normalizedRGB(srcFg[idx])
                        fgR += c.r * w
                        fgG += c.g * w
                        fgB += c.b * w
                    }
                    if processBG {
                        let c = normalizedRGB(srcBg[idx])
                        bgR += c.r * w
                        bgG += c.g * w
                        bgB += c.b * w
                    }
                }
            }

            if totalWeight > 0 {
                if processFG {
                    current.foreground = rgbaWithRGB(
                        current.foreground,
                        r: fgR / totalWeight,
                        g: fgG / totalWeight,
                        b: fgB / totalWeight
                    )
                }
                if processBG {
                    current.background = rgbaWithRGB(
                        current.background,
                        r: bgR / totalWeight,
                        g: bgG / totalWeight,
                        b: bgB / totalWeight
                    )
                }
                buffer.setCellRaw(x: x, y: y, cell: current)
            }
        }
    }
}

/// Functional convenience applying a radial vignette darkening toward the buffer corners.
public func applyVignette(buffer: OptimizedBuffer, strength: Float = 0.5) {
    let effect = VignetteEffect(strength: strength)
    effect.apply(buffer)
}

/// Functional convenience applying a luminance-threshold bloom halo around bright cells.
public func applyBloom(buffer: OptimizedBuffer, threshold: Double = 0.8, strength: Double = 0.2, radius: Int = 2) {
    let effect = BloomEffect(threshold: threshold, strength: strength, radius: radius)
    effect.apply(buffer)
}

/// Functional convenience applying one step of the animated glitch distortion effect.
public func applyDistortion(
    buffer: OptimizedBuffer,
    deltaTime: Double = 0.1,
    glitchChancePerSecond: Double = 10.0,
    seed: UInt64 = 0xD157_0A71_0000_0001
) {
    let effect = DistortionEffect(glitchChancePerSecond: glitchChancePerSecond, seed: seed)
    effect.apply(buffer, deltaTime: deltaTime)
}

// MARK: - PostProcessEffect Protocol & Built-in Effect Structs

/// Common protocol for stateful or stateless framebuffer post-processing effects.
public protocol PostProcessEffect {
    mutating func apply(to buffer: OptimizedBuffer, deltaTime: Double)
}

extension PostProcessEffect {
    public mutating func apply(to buffer: OptimizedBuffer) {
        apply(to: buffer, deltaTime: 0)
    }
}

/// Applies an arbitrary 3x3 or 4x4 color matrix as a `PostProcessEffect`.
public struct ColorMatrixEffect: PostProcessEffect, Equatable, Sendable {
    public var matrix: [Float]
    public var strength: Float
    public var target: TargetChannel
    public var cellMask: [Float]?

    public init(
        matrix: [Float],
        strength: Float = 1.0,
        target: TargetChannel = .both,
        cellMask: [Float]? = nil
    ) {
        self.matrix = matrix
        self.strength = strength
        self.target = target
        self.cellMask = cellMask
    }

    public mutating func apply(to buffer: OptimizedBuffer, deltaTime: Double) {
        _ = deltaTime
        applyColorMatrix(buffer: buffer, matrix: matrix, strength: strength, target: target, cellMask: cellMask)
    }
}

/// Scanlines post-processing effect struct.
public struct ScanlinesEffect: PostProcessEffect, Equatable, Sendable {
    public var strength: Float
    public var step: Int

    public init(strength: Float = 0.8, step: Int = 2) {
        self.strength = strength
        self.step = step
    }

    public mutating func apply(to buffer: OptimizedBuffer, deltaTime: Double) {
        _ = deltaTime
        applyScanlines(buffer: buffer, strength: strength, step: step)
    }
}

/// Noise post-processing effect struct.
public struct NoiseEffect: PostProcessEffect, Equatable, Sendable {
    public var strength: Float
    public var seed: UInt64

    public init(strength: Float = 0.1, seed: UInt64 = 0x517C_C1B7_2722_0A95) {
        self.strength = strength
        self.seed = seed
    }

    public mutating func apply(to buffer: OptimizedBuffer, deltaTime: Double) {
        _ = deltaTime
        applyNoise(buffer: buffer, strength: strength, seed: seed)
        seed &+= 0x9E37_79B9_7F4A_7C15
    }
}

/// Gaussian blur post-processing effect struct.
public struct BlurEffect: PostProcessEffect, Equatable, Sendable {
    public var radius: Int
    public var target: TargetChannel

    public init(radius: Int = 1, target: TargetChannel = .both) {
        self.radius = radius
        self.target = target
    }

    public mutating func apply(to buffer: OptimizedBuffer, deltaTime: Double) {
        _ = deltaTime
        applyBlur(buffer: buffer, radius: radius, target: target)
    }
}

/// Chromatic aberration post-processing effect struct.
public struct ChromaticAberrationEffect: PostProcessEffect, Equatable, Sendable {
    public var strength: Double

    public init(strength: Double = 1.0) {
        self.strength = strength
    }

    public mutating func apply(to buffer: OptimizedBuffer, deltaTime: Double) {
        _ = deltaTime
        applyChromaticAberration(buffer: buffer, strength: strength)
    }
}

/// ASCII art luminance-mapping post-processing effect struct.
public struct AsciiArtEffect: PostProcessEffect, Equatable, Sendable {
    public var ramp: String
    public var fgR: Float
    public var fgG: Float
    public var fgB: Float
    public var bgR: Float
    public var bgG: Float
    public var bgB: Float

    public init(
        ramp: String = defaultAsciiArtRamp,
        fgColor: (r: Float, g: Float, b: Float) = (1.0, 1.0, 1.0),
        bgColor: (r: Float, g: Float, b: Float) = (0.0, 0.0, 0.0)
    ) {
        self.ramp = ramp
        self.fgR = fgColor.r
        self.fgG = fgColor.g
        self.fgB = fgColor.b
        self.bgR = bgColor.r
        self.bgG = bgColor.g
        self.bgB = bgColor.b
    }

    public mutating func apply(to buffer: OptimizedBuffer, deltaTime: Double) {
        _ = deltaTime
        applyAsciiArt(buffer: buffer, ramp: ramp, fgColor: (fgR, fgG, fgB), bgColor: (bgR, bgG, bgB))
    }
}

// MARK: - BloomEffect (`post/filters.ts`)

/// Spreads luminance from bright pixels onto neighboring cells within `radius`.
// parity: core/src/post/filters.ts#BloomEffect [status=implemented hash=3f8451e373f5]
public final class BloomEffect: PostProcessEffect {
    private var _threshold: Double
    private var _strength: Double
    private var _radius: Int

    public init(threshold: Double = 0.8, strength: Double = 0.2, radius: Int = 2) {
        self._threshold = max(0, min(1, threshold))
        self._strength = max(0, strength)
        self._radius = max(0, radius)
    }

    // parity: core/src/post/filters.ts#BloomEffect.threshold [status=implemented hash=e326fb37d07b]
    public var threshold: Double {
        get { _threshold }
        set { _threshold = max(0, min(1, newValue)) }
    }

    // parity: core/src/post/filters.ts#BloomEffect.strength [status=implemented hash=d2758220d02f]
    public var strength: Double {
        get { _strength }
        set { _strength = max(0, newValue) }
    }

    // parity: core/src/post/filters.ts#BloomEffect.radius [status=implemented hash=1d06770d5af9]
    public var radius: Int {
        get { _radius }
        set { _radius = max(0, newValue) }
    }

    public func apply(to buffer: OptimizedBuffer, deltaTime: Double) {
        _ = deltaTime
        apply(buffer)
    }

    // parity: core/src/post/filters.ts#BloomEffect.apply [status=implemented hash=d3af3692e1a4]
    public func apply(_ buffer: OptimizedBuffer) {
        guard _strength > 0, _radius > 0, buffer.width > 0, buffer.height > 0 else { return }

        let width = buffer.width
        let height = buffer.height
        var brightPixels: [(x: Int, y: Int, intensity: Double)] = []

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                let lum = max(luminance(buffer.fg[idx]), luminance(buffer.bg[idx]))
                if lum > _threshold {
                    let intensity = max(0.0, (lum - _threshold) / (1.0 - _threshold + 1e-6))
                    brightPixels.append((x, y, intensity))
                }
            }
        }

        guard !brightPixels.isEmpty else { return }
        let radiusSq = Double(_radius * _radius)

        for bright in brightPixels {
            for ky in -_radius..._radius {
                for kx in -_radius..._radius {
                    if kx == 0 && ky == 0 { continue }
                    let sampleX = bright.x + kx
                    let sampleY = bright.y + ky
                    guard sampleX >= 0 && sampleX < width && sampleY >= 0 && sampleY < height else { continue }

                    let distSq = Double(kx * kx + ky * ky)
                    if distSq <= radiusSq {
                        let falloff = 1.0 - distSq / radiusSq
                        let bloomAmount = bright.intensity * _strength * falloff
                        if var current = buffer.cell(atX: sampleX, y: sampleY) {
                            let fgC = normalizedRGB(current.foreground)
                            let bgC = normalizedRGB(current.background)
                            current.foreground = rgbaWithRGB(
                                current.foreground,
                                r: min(1.0, fgC.r + bloomAmount),
                                g: min(1.0, fgC.g + bloomAmount),
                                b: min(1.0, fgC.b + bloomAmount)
                            )
                            current.background = rgbaWithRGB(
                                current.background,
                                r: min(1.0, bgC.r + bloomAmount),
                                g: min(1.0, bgC.g + bloomAmount),
                                b: min(1.0, bgC.b + bloomAmount)
                            )
                            buffer.setCellRaw(x: sampleX, y: sampleY, cell: current)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Animated Effects (`post/effects.ts`)

/// Animated horizontal shift, row flip, and color-burst glitch effect.
// parity: core/src/post/effects.ts#DistortionEffect [status=implemented hash=7796956b688e]
public final class DistortionEffect: PostProcessEffect {
    private enum GlitchType {
        case shift
        case flip
        case color
    }

    private struct ActiveGlitch {
        let y: Int
        let type: GlitchType
        let amount: Int
    }

    public var glitchChancePerSecond: Double
    public var maxGlitchLines: Int
    public var minGlitchDuration: Double
    public var maxGlitchDuration: Double
    public var maxShiftAmount: Int
    public var shiftFlipRatio: Double
    public var colorGlitchChance: Double

    private var lastGlitchTime: Double = 0
    private var glitchDuration: Double = 0
    private var activeGlitches: [ActiveGlitch] = []
    private var rng: PurePRNG

    public init(
        glitchChancePerSecond: Double = 0.5,
        maxGlitchLines: Int = 3,
        minGlitchDuration: Double = 0.05,
        maxGlitchDuration: Double = 0.2,
        maxShiftAmount: Int = 10,
        shiftFlipRatio: Double = 0.6,
        colorGlitchChance: Double = 0.2,
        seed: UInt64 = 0xD157_0A71_CAFE_BABE
    ) {
        self.glitchChancePerSecond = glitchChancePerSecond
        self.maxGlitchLines = max(1, maxGlitchLines)
        self.minGlitchDuration = minGlitchDuration
        self.maxGlitchDuration = maxGlitchDuration
        self.maxShiftAmount = maxShiftAmount
        self.shiftFlipRatio = shiftFlipRatio
        self.colorGlitchChance = colorGlitchChance
        self.rng = PurePRNG(seed: seed)
    }

    public func apply(to buffer: OptimizedBuffer, deltaTime: Double) {
        apply(buffer, deltaTime: deltaTime)
    }

    // parity: core/src/post/effects.ts#DistortionEffect.apply [status=implemented hash=8e096e65683b]
    public func apply(_ buffer: OptimizedBuffer, deltaTime: Double) {
        let width = buffer.width
        let height = buffer.height
        guard width > 0, height > 0 else { return }

        lastGlitchTime += deltaTime

        if !activeGlitches.isEmpty && lastGlitchTime >= glitchDuration {
            activeGlitches.removeAll()
            glitchDuration = 0
        }

        if activeGlitches.isEmpty && rng.nextUnitDouble() < glitchChancePerSecond * deltaTime {
            lastGlitchTime = 0
            glitchDuration = minGlitchDuration + rng.nextUnitDouble() * (maxGlitchDuration - minGlitchDuration)
            let numGlitches = 1 + Int((rng.nextUnitDouble() * Double(maxGlitchLines)).rounded(.down))

            for _ in 0..<numGlitches {
                let y = Int((rng.nextUnitDouble() * Double(height)).rounded(.down))
                let typeRoll = rng.nextUnitDouble()
                let type: GlitchType
                var amount = 0

                if typeRoll < colorGlitchChance {
                    type = .color
                } else {
                    let denom = max(1e-9, 1.0 - colorGlitchChance)
                    let shiftRoll = (typeRoll - colorGlitchChance) / denom
                    if shiftRoll < shiftFlipRatio {
                        type = .shift
                        amount = Int(((rng.nextUnitDouble() - 0.5) * 2.0 * Double(maxShiftAmount)).rounded(.down))
                    } else {
                        type = .flip
                    }
                }

                if !activeGlitches.contains(where: { $0.y == y }) {
                    activeGlitches.append(ActiveGlitch(y: y, type: type, amount: amount))
                }
            }
        }

        guard !activeGlitches.isEmpty else { return }

        for glitch in activeGlitches {
            let y = glitch.y
            guard y >= 0 && y < height else { continue }

            switch glitch.type {
            case .shift, .flip:
                var rowSnapshot: [TerminalCell] = []
                rowSnapshot.reserveCapacity(width)
                for x in 0..<width {
                    rowSnapshot.append(buffer.cell(atX: x, y: y) ?? TerminalCell())
                }

                if glitch.type == .shift {
                    let shift = glitch.amount
                    for x in 0..<width {
                        let srcX = (((x - shift) % width) + width) % width
                        buffer.setCellRaw(x: x, y: y, cell: rowSnapshot[srcX])
                    }
                } else {
                    for x in 0..<width {
                        let srcX = width - 1 - x
                        buffer.setCellRaw(x: x, y: y, cell: rowSnapshot[srcX])
                    }
                }

            case .color:
                let glitchStart = Int((rng.nextUnitDouble() * Double(width)).rounded(.down))
                let maxPossibleLength = max(1, width - glitchStart)
                var glitchLength = Int((rng.nextUnitDouble() * Double(maxPossibleLength)).rounded(.down)) + 1
                if rng.nextUnitDouble() < 0.2 {
                    glitchLength = Int((rng.nextUnitDouble() * (Double(width) / 4.0)).rounded(.down)) + 1
                }
                glitchLength = min(glitchLength, maxPossibleLength)

                for x in glitchStart..<min(width, glitchStart + glitchLength) {
                    guard var current = buffer.cell(atX: x, y: y) else { continue }
                    let rFg: Double
                    let gFg: Double
                    let bFg: Double
                    let rBg: Double
                    let gBg: Double
                    let bBg: Double

                    let colorMode = rng.nextUnitDouble()
                    if colorMode < 0.33 {
                        rFg = rng.nextUnitDouble()
                        gFg = rng.nextUnitDouble()
                        bFg = rng.nextUnitDouble()
                        rBg = rng.nextUnitDouble()
                        gBg = rng.nextUnitDouble()
                        bBg = rng.nextUnitDouble()
                    } else if colorMode < 0.66 {
                        let emphasis = rng.nextUnitDouble()
                        if emphasis < 0.25 {
                            rFg = rng.nextUnitDouble(); gFg = 0; bFg = 0
                        } else if emphasis < 0.5 {
                            rFg = 0; gFg = rng.nextUnitDouble(); bFg = 0
                        } else if emphasis < 0.75 {
                            rFg = 0; gFg = 0; bFg = rng.nextUnitDouble()
                        } else {
                            let roll = rng.nextUnitDouble()
                            if roll < 0.33 {
                                rFg = 1; gFg = 0; bFg = 1
                            } else if roll < 0.66 {
                                rFg = 0; gFg = 1; bFg = 1
                            } else {
                                rFg = 1; gFg = 1; bFg = 0
                            }
                        }

                        if rng.nextUnitDouble() < 0.5 {
                            rBg = 1 - rFg; gBg = 1 - gFg; bBg = 1 - bFg
                        } else {
                            let scaleR = rng.nextUnitDouble() * 0.5 + 0.2
                            let scaleG = rng.nextUnitDouble() * 0.5 + 0.2
                            let scaleB = rng.nextUnitDouble() * 0.5 + 0.2
                            rBg = rFg * scaleR; gBg = gFg * scaleG; bBg = bFg * scaleB
                        }
                    } else {
                        rFg = rng.nextUnitDouble() > 0.5 ? 1 : 0
                        gFg = rng.nextUnitDouble() > 0.5 ? 1 : 0
                        bFg = rng.nextUnitDouble() > 0.5 ? 1 : 0
                        rBg = 1 - rFg; gBg = 1 - gFg; bBg = 1 - bFg
                    }

                    current.foreground = rgbaWithRGB(current.foreground, r: rFg, g: gFg, b: bFg)
                    current.background = rgbaWithRGB(current.background, r: rBg, g: gBg, b: bBg)
                    buffer.setCellRaw(x: x, y: y, cell: current)
                }
            }
        }
    }
}

/// Corner-darkening radial vignette effect with cached attenuation masks and grapheme-run preservation.
// parity: core/src/post/effects.ts#VignetteEffect [status=implemented hash=a4481c016ce3]
public final class VignetteEffect: PostProcessEffect {
    private static let zeroMatrix: [Float] = Array(repeating: 0, count: 16)

    private var _strength: Float
    private var precomputedCellMask: [Float] = []
    private var precomputedAttenuation: [Float] = []
    private var cachedWidth: Int = -1
    private var cachedHeight: Int = -1

    public init(strength: Float = 0.5) {
        self._strength = strength
    }

    // parity: core/src/post/effects.ts#VignetteEffect.strength [status=implemented hash=a801a5095aac]
    public var strength: Float {
        get { _strength }
        set {
            _strength = max(0, newValue)
            cachedWidth = -1
            cachedHeight = -1
            precomputedCellMask.removeAll()
            precomputedAttenuation.removeAll()
        }
    }

    private func computeFactors(width: Int, height: Int) {
        let count = width * height
        precomputedCellMask = Array(repeating: 0, count: count * 3)
        precomputedAttenuation = Array(repeating: 0, count: count)

        let centerX = Double(width) / 2.0
        let centerY = Double(height) / 2.0
        let maxDistSq = centerX * centerX + centerY * centerY
        let safeMaxDistSq = maxDistSq == 0 ? 1.0 : maxDistSq

        var i = 0
        for y in 0..<height {
            let dy = Double(y) - centerY
            let dySq = dy * dy
            for x in 0..<width {
                let dx = Double(x) - centerX
                let distSq = dx * dx + dySq
                let baseAttenuation = min(1.0, distSq / safeMaxDistSq)
                let attenuation = Float(baseAttenuation) * _strength
                precomputedCellMask[i] = Float(x)
                precomputedCellMask[i + 1] = Float(y)
                precomputedCellMask[i + 2] = attenuation
                i += 3
                precomputedAttenuation[y * width + x] = attenuation
            }
        }
        cachedWidth = width
        cachedHeight = height
    }

    private func preserveGraphemeRuns(chars: [UInt32], width: Int, height: Int) {
        for y in 0..<height {
            var x = 0
            while x < width {
                let cell = y * width + x
                if !isClusterChar(chars[cell]) {
                    precomputedCellMask[cell * 3 + 2] = precomputedAttenuation[cell]
                    x += 1
                    continue
                }
                let start = x
                while x < width && isClusterChar(chars[y * width + x]) {
                    x += 1
                }
                let mid = y * width + start + ((x - start) / 2)
                let attenuation = precomputedAttenuation[mid]
                for runX in start..<x {
                    precomputedCellMask[(y * width + runX) * 3 + 2] = attenuation
                }
            }
        }
    }

    public func apply(to buffer: OptimizedBuffer, deltaTime: Double) {
        _ = deltaTime
        apply(buffer)
    }

    // parity: core/src/post/effects.ts#VignetteEffect.apply [status=implemented hash=ef0b08537fcd]
    public func apply(_ buffer: OptimizedBuffer) {
        let width = buffer.width
        let height = buffer.height
        guard width > 0, height > 0 else { return }

        if width != cachedWidth || height != cachedHeight || precomputedCellMask.isEmpty {
            computeFactors(width: width, height: height)
        }
        preserveGraphemeRuns(chars: buffer.chars, width: width, height: height)
        buffer.colorMatrix(Self.zeroMatrix, cellMask: precomputedCellMask, strength: 1.0, target: .both)
    }
}

/// 3D Perlin noise generator shared by `CloudsEffect` and `FlamesEffect`.
private struct PerlinNoise3D {
    private static let grad3: [(Double, Double, Double)] = [
        (1, 1, 0), (-1, 1, 0), (1, -1, 0), (-1, -1, 0),
        (1, 0, 1), (-1, 0, 1), (1, 0, -1), (-1, 0, -1),
        (0, 1, 1), (0, -1, 1), (0, 1, -1), (0, -1, -1),
    ]

    private var perm: [UInt8]

    init(seed: UInt64) {
        var rng = PurePRNG(seed: seed)
        var p = Array<UInt8>(0...255)
        for i in stride(from: 255, through: 1, by: -1) {
            let r = Int((rng.nextUnitDouble() * Double(i + 1)).rounded(.down))
            p.swapAt(i, r)
        }
        var duplicated = [UInt8](repeating: 0, count: 512)
        for i in 0..<512 {
            duplicated[i] = p[i & 255]
        }
        self.perm = duplicated
    }

    @inline(__always)
    private func dot(_ g: (Double, Double, Double), _ x: Double, _ y: Double, _ z: Double) -> Double {
        g.0 * x + g.1 * y + g.2 * z
    }

    @inline(__always)
    private func mix(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    @inline(__always)
    private func fade(_ t: Double) -> Double {
        t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
    }

    func noise3d(_ x: Double, _ y: Double, _ z: Double) -> Double {
        let fx = x.rounded(.down)
        let fy = y.rounded(.down)
        let fz = z.rounded(.down)

        let X = Int(fx) & 255
        let Y = Int(fy) & 255
        let Z = Int(fz) & 255

        let xf = x - fx
        let yf = y - fy
        let zf = z - fz

        let u = fade(xf)
        let v = fade(yf)
        let w = fade(zf)

        let A = Int(perm[X]) + Y
        let AA = Int(perm[A]) + Z
        let AB = Int(perm[A + 1]) + Z
        let B = Int(perm[X + 1]) + Y
        let BA = Int(perm[B]) + Z
        let BB = Int(perm[B + 1]) + Z

        let g = Self.grad3
        return mix(
            mix(
                mix(
                    dot(g[Int(perm[AA]) % 12], xf, yf, zf),
                    dot(g[Int(perm[BA]) % 12], xf - 1, yf, zf),
                    u
                ),
                mix(
                    dot(g[Int(perm[AB]) % 12], xf, yf - 1, zf),
                    dot(g[Int(perm[BB]) % 12], xf - 1, yf - 1, zf),
                    u
                ),
                v
            ),
            mix(
                mix(
                    dot(g[Int(perm[AA + 1]) % 12], xf, yf, zf - 1),
                    dot(g[Int(perm[BA + 1]) % 12], xf - 1, yf, zf - 1),
                    u
                ),
                mix(
                    dot(g[Int(perm[AB + 1]) % 12], xf, yf - 1, zf - 1),
                    dot(g[Int(perm[BB + 1]) % 12], xf - 1, yf - 1, zf - 1),
                    u
                ),
                v
            ),
            w
        )
    }
}

/// Animated procedural cloud shadow effect using 4-octave 3D Perlin FBM.
// parity: core/src/post/effects.ts#CloudsEffect [status=implemented hash=7413f71610bf]
public final class CloudsEffect: PostProcessEffect {
    private static let zeroMatrix: [Float] = Array(repeating: 0, count: 16)

    private let noise: PerlinNoise3D
    private var _scale: Double
    private var _speed: Double
    private var _density: Double
    private var _darkness: Double
    private var time: Double = 0

    public init(
        scale: Double = 0.02,
        speed: Double = 0.5,
        density: Double = 0.6,
        darkness: Double = 0.7,
        seed: UInt64 = 0xC100_D500_0000_0001
    ) {
        self.noise = PerlinNoise3D(seed: seed)
        self._scale = scale
        self._speed = speed
        self._density = density
        self._darkness = darkness
    }

    // parity: core/src/post/effects.ts#CloudsEffect.scale [status=implemented hash=09da546d4910]
    public var scale: Double {
        get { _scale }
        set { _scale = max(0.001, newValue) }
    }

    // parity: core/src/post/effects.ts#CloudsEffect.speed [status=implemented hash=95310572639e]
    public var speed: Double {
        get { _speed }
        set { _speed = max(0, newValue) }
    }

    // parity: core/src/post/effects.ts#CloudsEffect.density [status=implemented hash=a0fa274c40f7]
    public var density: Double {
        get { _density }
        set { _density = max(0, min(1, newValue)) }
    }

    // parity: core/src/post/effects.ts#CloudsEffect.darkness [status=implemented hash=e74242ef86e4]
    public var darkness: Double {
        get { _darkness }
        set { _darkness = max(0, min(1, newValue)) }
    }

    public func apply(to buffer: OptimizedBuffer, deltaTime: Double) {
        apply(buffer, deltaTime: deltaTime)
    }

    // parity: core/src/post/effects.ts#CloudsEffect.apply [status=implemented hash=1f52f284d083]
    public func apply(_ buffer: OptimizedBuffer, deltaTime: Double) {
        let width = buffer.width
        let height = buffer.height
        guard width > 0, height > 0 else { return }

        time += deltaTime * _speed
        var cellMask: [Float] = []
        cellMask.reserveCapacity(width * height * 3)

        for y in 0..<height {
            for x in 0..<width {
                var noiseValue = 0.0
                var amplitude = 1.0
                var frequency = 1.0
                var maxValue = 0.0

                for _ in 0..<4 {
                    let nx = (Double(x) * _scale * frequency + time) * 0.5
                    let ny = Double(y) * _scale * frequency * 0.5
                    let nz = time * 0.3
                    noiseValue += noise.noise3d(nx, ny, nz) * amplitude
                    maxValue += amplitude
                    amplitude *= 0.5
                    frequency *= 2.0
                }

                noiseValue = (noiseValue / maxValue + 1.0) * 0.5
                let cloudDensity = max(0.0, noiseValue - (1.0 - _density))
                let attenuation = Float(cloudDensity * _darkness)

                cellMask.append(Float(x))
                cellMask.append(Float(y))
                cellMask.append(attenuation)
            }
        }

        buffer.colorMatrix(Self.zeroMatrix, cellMask: cellMask, strength: 1.0, target: .bg)
    }
}

/// Animated procedural flames rising from the bottom edge using 3-octave 3D Perlin FBM.
// parity: core/src/post/effects.ts#FlamesEffect [status=implemented hash=a7e200a59953]
public final class FlamesEffect: PostProcessEffect {
    private let noise: PerlinNoise3D
    private var _scale: Double
    private var _speed: Double
    private var _intensity: Double
    private var time: Double = 0

    public init(
        scale: Double = 0.03,
        speed: Double = 0.02,
        intensity: Double = 0.8,
        seed: UInt64 = 0xF1A3_E500_0000_0001
    ) {
        self.noise = PerlinNoise3D(seed: seed)
        self._scale = scale
        self._speed = speed
        self._intensity = intensity
    }

    // parity: core/src/post/effects.ts#FlamesEffect.scale [status=implemented hash=09da546d4910]
    public var scale: Double {
        get { _scale }
        set { _scale = max(0.001, newValue) }
    }

    // parity: core/src/post/effects.ts#FlamesEffect.speed [status=implemented hash=95310572639e]
    public var speed: Double {
        get { _speed }
        set { _speed = max(0, newValue) }
    }

    // parity: core/src/post/effects.ts#FlamesEffect.intensity [status=implemented hash=38a40a80e3a0]
    public var intensity: Double {
        get { _intensity }
        set { _intensity = max(0, min(1, newValue)) }
    }

    public func apply(to buffer: OptimizedBuffer, deltaTime: Double) {
        apply(buffer, deltaTime: deltaTime)
    }

    // parity: core/src/post/effects.ts#FlamesEffect.apply [status=implemented hash=4978da206a24]
    public func apply(_ buffer: OptimizedBuffer, deltaTime: Double) {
        let width = buffer.width
        let height = buffer.height
        guard width > 0, height > 0 else { return }

        time += deltaTime * _speed

        for y in 0..<height {
            let heightFactor = 1.0 - Double(y) / Double(height)
            for x in 0..<width {
                var noiseValue = 0.0
                var amplitude = 1.0
                var frequency = 1.0
                var maxValue = 0.0

                for _ in 0..<3 {
                    let nx = (Double(x) * _scale * frequency + time) * 0.5
                    let ny = Double(height - y) * _scale * frequency * 2.0 * 0.5
                    let nz = time * 2.0
                    noiseValue += noise.noise3d(nx, ny, nz) * amplitude
                    maxValue += amplitude
                    amplitude *= 0.5
                    frequency *= 2.0
                }

                noiseValue = (noiseValue / maxValue + 1.0) * 0.5
                let flameIntensity = noiseValue * heightFactor * _intensity
                guard flameIntensity > 0 else { continue }

                let r: Double
                let g: Double
                let b: Double
                if flameIntensity > 0.7 {
                    r = 1.0
                    g = 1.0
                    b = 0.3 + (flameIntensity - 0.7) * 2.3
                } else if flameIntensity > 0.4 {
                    r = 1.0
                    g = 0.5 + (flameIntensity - 0.4) * 1.67
                    b = 0.0
                } else {
                    r = 0.3 + flameIntensity * 1.75
                    g = flameIntensity * 0.5
                    b = 0.0
                }

                if var current = buffer.cell(atX: x, y: y) {
                    let existing = normalizedRGB(current.background)
                    current.background = rgbaWithRGB(
                        current.background,
                        r: max(existing.r, r * flameIntensity),
                        g: max(existing.g, g * flameIntensity),
                        b: max(existing.b, b * flameIntensity)
                    )
                    buffer.setCellRaw(x: x, y: y, cell: current)
                }
            }
        }
    }
}

/// CRT rolling scan-bar highlight effect with cosine bell-curve falloff.
// parity: core/src/post/effects.ts#CRTRollingBarEffect [status=implemented hash=54f492993bb8]
public final class CRTRollingBarEffect: PostProcessEffect {
    private var _speed: Double
    private var _height: Double
    private var _intensity: Double
    private var _fadeDistance: Double
    private var position: Double = 0

    public init(
        speed: Double = 0.5,
        height: Double = 0.15,
        intensity: Double = 0.3,
        fadeDistance: Double = 0.3
    ) {
        self._speed = speed
        self._height = max(0.01, min(0.5, height))
        self._intensity = max(0, min(1, intensity))
        self._fadeDistance = max(0, min(1, fadeDistance))
    }

    // parity: core/src/post/effects.ts#CRTRollingBarEffect.speed [status=implemented hash=4cf6f87a73ab]
    public var speed: Double {
        get { _speed }
        set { _speed = newValue }
    }

    // parity: core/src/post/effects.ts#CRTRollingBarEffect.height [status=implemented hash=ddaf5916958d]
    public var height: Double {
        get { _height }
        set { _height = max(0.01, min(0.5, newValue)) }
    }

    // parity: core/src/post/effects.ts#CRTRollingBarEffect.intensity [status=implemented hash=38a40a80e3a0]
    public var intensity: Double {
        get { _intensity }
        set { _intensity = max(0, min(1, newValue)) }
    }

    // parity: core/src/post/effects.ts#CRTRollingBarEffect.fadeDistance [status=implemented hash=c77bf4dfb73e]
    public var fadeDistance: Double {
        get { _fadeDistance }
        set { _fadeDistance = max(0, min(1, newValue)) }
    }

    public func apply(to buffer: OptimizedBuffer, deltaTime: Double) {
        apply(buffer, deltaTime: deltaTime)
    }

    // parity: core/src/post/effects.ts#CRTRollingBarEffect.apply [status=implemented hash=e11b8bfb464f]
    public func apply(_ buffer: OptimizedBuffer, deltaTime: Double) {
        let width = buffer.width
        let height = buffer.height
        guard width > 0, height > 0 else { return }

        let hDouble = Double(height)
        position += (deltaTime / 1000.0) * _speed
        let cycleHeight = hDouble + _height * hDouble * 2.0
        if cycleHeight > 0 {
            position = position.truncatingRemainder(dividingBy: cycleHeight)
            if position < 0 { position += cycleHeight }
        }

        let barPixelHeight = _height * hDouble
        let fadePixelDistance = _fadeDistance * barPixelHeight
        let totalEffectHeight = barPixelHeight + fadePixelDistance * 2.0
        let halfEffectHeight = totalEffectHeight / 2.0
        guard halfEffectHeight > 0 else { return }
        let effectCenter = position - halfEffectHeight + barPixelHeight / 2.0

        for y in 0..<height {
            let distFromCenter = abs(Double(y) - effectCenter)
            var barFactor = 0.0
            if distFromCenter <= halfEffectHeight {
                let normalizedDist = distFromCenter / halfEffectHeight
                barFactor = postCos(normalizedDist * halfPi)
            }

            if barFactor > 0.001 {
                let rowMultiplier = 1.0 + _intensity * barFactor
                for x in 0..<width {
                    guard var current = buffer.cell(atX: x, y: y) else { continue }
                    let fgC = normalizedRGB(current.foreground)
                    let bgC = normalizedRGB(current.background)
                    current.foreground = rgbaWithRGB(
                        current.foreground,
                        r: min(1.0, fgC.r * rowMultiplier),
                        g: min(1.0, fgC.g * rowMultiplier),
                        b: min(1.0, fgC.b * rowMultiplier)
                    )
                    current.background = rgbaWithRGB(
                        current.background,
                        r: min(1.0, bgC.r * rowMultiplier),
                        g: min(1.0, bgC.g * rowMultiplier),
                        b: min(1.0, bgC.b * rowMultiplier)
                    )
                    buffer.setCellRaw(x: x, y: y, cell: current)
                }
            }
        }
    }
}

/// Animated diagonal HSV rainbow shader applied to cells with white foreground (`r, g, b >= 0.9`).
// parity: core/src/post/effects.ts#RainbowTextEffect [status=implemented hash=597d42df613b]
public final class RainbowTextEffect: PostProcessEffect {
    private var _speed: Double
    private var _saturation: Double
    private var _value: Double
    private var _repeats: Double
    private var time: Double = 0

    public init(
        speed: Double = 0.01,
        saturation: Double = 1.0,
        value: Double = 1.0,
        repeats: Double = 3.0
    ) {
        self._speed = speed
        self._saturation = saturation
        self._value = value
        self._repeats = repeats
    }

    // parity: core/src/post/effects.ts#RainbowTextEffect.speed [status=implemented hash=95310572639e]
    public var speed: Double {
        get { _speed }
        set { _speed = max(0, newValue) }
    }

    // parity: core/src/post/effects.ts#RainbowTextEffect.saturation [status=implemented hash=d7f9aea93e48]
    public var saturation: Double {
        get { _saturation }
        set { _saturation = max(0, min(1, newValue)) }
    }

    // parity: core/src/post/effects.ts#RainbowTextEffect.value [status=implemented hash=35f708afa686]
    public var value: Double {
        get { _value }
        set { _value = max(0, min(1, newValue)) }
    }

    // parity: core/src/post/effects.ts#RainbowTextEffect.repeats [status=implemented hash=137ab8efed6f]
    public var repeats: Double {
        get { _repeats }
        set { _repeats = max(0.1, newValue) }
    }

    private func unitHsvToRgb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let sector = Int((h * 6.0).rounded(.down))
        let f = h * 6.0 - Double(sector)
        let p = v * (1.0 - s)
        let q = v * (1.0 - f * s)
        let t = v * (1.0 - (1.0 - f) * s)

        switch ((sector % 6) + 6) % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    public func apply(to buffer: OptimizedBuffer, deltaTime: Double) {
        apply(buffer, deltaTime: deltaTime)
    }

    // parity: core/src/post/effects.ts#RainbowTextEffect.apply [status=implemented hash=46e1807ed577]
    public func apply(_ buffer: OptimizedBuffer, deltaTime: Double) {
        let width = buffer.width
        let height = buffer.height
        guard width > 0, height > 0 else { return }

        time += deltaTime * _speed

        let angleRad = 25.0 * Double.pi / 180.0
        let cosAngle = postCos(angleRad)
        let sinAngle = postSin(angleRad)
        let maxProjection = Double(width) * cosAngle + Double(height) * sinAngle
        guard maxProjection > 0 else { return }

        let whiteThreshold = 0.9

        for y in 0..<height {
            for x in 0..<width {
                guard var current = buffer.cell(atX: x, y: y) else { continue }
                let fgC = normalizedRGB(current.foreground)
                if fgC.r >= whiteThreshold && fgC.g >= whiteThreshold && fgC.b >= whiteThreshold {
                    let projection = Double(x) * cosAngle + Double(y) * sinAngle
                    let rawHue = (projection / maxProjection) * _repeats + time * 0.1
                    let hue = rawHue - rawHue.rounded(.down)
                    let (newR, newG, newB) = unitHsvToRgb(hue, _saturation, _value)
                    current.foreground = rgbaWithRGB(current.foreground, r: newR, g: newG, b: newB)
                    buffer.setCellRaw(x: x, y: y, cell: current)
                }
            }
        }
    }
}
