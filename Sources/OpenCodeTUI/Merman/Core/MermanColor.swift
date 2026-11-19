import OpenTUICore

extension Merman {
    // parity: merman/src/core/color/style.ts#DiagramRgb [status=implemented hash=6ec8ee90be8d]
    public typealias DiagramRgb = (Int, Int, Int)

    // parity: merman/src/core/color/style.ts#DiagramFadeStep [status=implemented hash=3644e2022ca0]
    public enum DiagramFadeStep: Int, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case s1 = 1
        case s2 = 2
        case s3 = 3
        case s4 = 4
        case s5 = 5
    }

    // parity: merman/src/core/color/style.ts#DIAGRAM_FADE_STEPS [status=implemented hash=3aeb8d4d63d8]
    public static let DIAGRAM_FADE_STEPS: [Int] = [1, 2, 3, 4, 5]

    // parity: merman/src/core/color/style.ts#numberedStyleKeys [status=implemented hash=6a559a73f8d3]
    public static func numberedStyleKeys(_ prefix: String, _ steps: [Int]) -> [String] {
        steps.map { "\(prefix)\($0)" }
    }

    // parity: merman/src/core/color/style.ts#rgba [status=implemented hash=f8f5b93a4de2]
    public static func rgba(_ rgb: DiagramRgb) -> RGBA {
        RGBA.fromInts(rgb.0, rgb.1, rgb.2, 255)
    }

    // parity: merman/src/core/color/style.ts#blendColor [status=implemented hash=4f9f2ee844c2]
    public static func blendColor(_ from: RGBA, _ to: RGBA, _ amount: Double) -> RGBA {
        let (fromR, fromG, fromB, fromA) = from.toInts()
        let (toR, toG, toB, toA) = to.toInts()
        func mix(_ left: UInt8, _ right: UInt8) -> Double {
            Double(left) + (Double(right) - Double(left)) * amount
        }
        return RGBA.fromInts(
            mix(fromR, toR),
            mix(fromG, toG),
            mix(fromB, toB),
            mix(fromA, toA)
        )
    }

    public static func blendColor(_ from: RGBA?, _ to: RGBA?, _ amount: Double) -> RGBA? {
        guard let from else { return to }
        guard let to else { return from }
        return blendColor(from, to, amount)
    }

    // parity: merman/src/core/color/style.ts#colorsEqual [status=implemented hash=560a3a5f0a67]
    public static func colorsEqual(_ left: RGBA?, _ right: RGBA?) -> Bool {
        switch (left, right) {
        case (nil, nil): return true
        case (let l?, let r?): return l.equals(r)
        default: return false
        }
    }

    // parity: merman/src/core/color/style.ts#createColorRampTheme [status=implemented hash=89fcc80f73e9]
    public static func createColorRampTheme<Style: Hashable>(
        _ styles: [Style],
        from: RGBA,
        to: RGBA
    ) -> [Style: RGBA] {
        var result: [Style: RGBA] = [:]
        result.reserveCapacity(styles.count)
        let denom = Double(styles.count + 1)
        for (index, style) in styles.enumerated() {
            result[style] = blendColor(from, to, Double(index + 1) / denom)
        }
        return result
    }

    public static func createColorRampTheme<Style: Hashable>(
        _ styles: [Style],
        from: RGBA?,
        to: RGBA?
    ) -> [Style: RGBA?] {
        var result: [Style: RGBA?] = [:]
        result.reserveCapacity(styles.count)
        let denom = Double(styles.count + 1)
        for (index, style) in styles.enumerated() {
            result[style] = blendColor(from, to, Double(index + 1) / denom)
        }
        return result
    }
}
