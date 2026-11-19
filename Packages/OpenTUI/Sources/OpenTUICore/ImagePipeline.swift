/// Pure-Swift image decoding, manipulation, pixel pooling, Kitty Graphics Protocol APC encoding,
/// Sixel palette quantization & RLE encoding, and Unicode half-block/quadrant/braille rasterization
/// directly into `OptimizedBuffer`, matching `packages/core/src/image.ts`.

// MARK: - Core Image Types & Error Codes

/// Encoded or raw image container format.
// parity: core/src/image.ts#ImageFormat [status=implemented hash=26e14d8851e6]
public enum ImageFormat: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case png
    case rawRgba = "raw-rgba"
    case jpeg
    case webp
    case gif
    case bmp
    case ppm
}

/// Color profile provenance reported in `ImageInfo`.
// parity: core/src/image.ts#ImageColorStatus [status=implemented hash=7487e251d33b]
public enum ImageColorStatus: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case assumedSrgb = "assumed-srgb"
    case explicitSrgb = "explicit-srgb"
}

/// Resampling filter kernel used by `NativeImage.resize(_:)`.
// parity: core/src/image.ts#ResizeKernel [status=implemented hash=a6d34ae16242]
public enum ResizeKernel: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case `default`
    case area
    case triangle
    case cubicBspline = "cubic-bspline"
    case catmullRom = "catmull-rom"
    case mitchell
    case nearest
}

/// Porter-Duff compositing modes supported by `NativeImage.composite(_:options:)`.
// parity: core/src/image.ts#BlendMode [status=implemented hash=68223d9005aa]
public enum BlendMode: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case sourceOver = "source-over"
    case source
    case destinationOver = "destination-over"
}

/// Interleaved 8-bit pixel channel layout.
// parity: core/src/image.ts#PixelFormat [status=implemented hash=4b5ed2728cff]
public enum PixelFormat: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case rgba8
    case bgra8
}

/// Alpha interpretation when importing raw pixels.
public enum PixelAlphaMode: String, Equatable, Hashable, Sendable, Codable {
    case straight
    case opaque
}

/// Input sources accepted by `NativeImage.load(_:options:)`.
// parity: core/src/image.ts#ImageSource [status=implemented hash=513e856ef37a]
public enum ImageSource: Equatable, Sendable {
    case bytes([UInt8])
    case rawRgba(pixels: [UInt8], width: Int, height: Int, stride: Int? = nil)
    case filePath(String)
    case url(String)
}

/// Classification of image I/O loading failures.
// parity: core/src/image.ts#ImageLoadErrorCode [status=implemented hash=ee2dde19ab15]
public enum ImageLoadErrorCode: String, Equatable, Hashable, Sendable, Codable {
    case fileRead = "file-read"
    case network
    case httpStatus = "http-status"
    case unsupportedUrlScheme = "unsupported-url-scheme"
}

/// Error raised while fetching or reading image data from a URL or file source.
// parity: core/src/image.ts#ImageLoadError [status=implemented hash=fb6b26bbc0d8]
public final class ImageLoadError: Error, Sendable, CustomStringConvertible {
    public let code: ImageLoadErrorCode
    public let source: String
    public let message: String
    public let status: Int?

    public init(code: ImageLoadErrorCode, source: String, message: String, status: Int? = nil) {
        self.code = code
        self.source = source
        self.message = message
        self.status = status
    }

    public var description: String { message }
}

/// Status error codes returned by native image operations.
// parity: core/src/image.ts#ImageErrorCode [status=implemented hash=dc0a7a2be47f]
public enum ImageErrorCode: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case invalidHandle = "invalid-handle"
    case unsupportedFormat = "unsupported-format"
    case unsupportedColorSpace = "unsupported-color-space"
    case malformedData = "malformed-data"
    case dimensionLimit = "dimension-limit"
    case memoryLimit = "memory-limit"
    case invalidArgument = "invalid-argument"
    case outOfMemory = "out-of-memory"
    case outputTooSmall = "output-too-small"
    case internalError = "internal-error"
    case unsupportedFeature = "unsupported-feature"
    case busy
}

private let imageStatusMessages: [String] = [
    "ok",
    "invalid image handle",
    "unsupported image format",
    "unsupported image color space",
    "malformed image data",
    "image dimensions exceed limits",
    "image memory limit exceeded",
    "invalid image argument",
    "out of memory",
    "image output buffer is too small",
    "internal image error",
    "unsupported image feature",
    "image is retained",
]

private let imageStatusCodes: [ImageErrorCode] = [
    .internalError,
    .invalidHandle,
    .unsupportedFormat,
    .unsupportedColorSpace,
    .malformedData,
    .dimensionLimit,
    .memoryLimit,
    .invalidArgument,
    .outOfMemory,
    .outputTooSmall,
    .internalError,
    .unsupportedFeature,
    .busy,
]

/// Error raised by decoding, validation, transform, or buffer export operations.
// parity: core/src/image.ts#ImageError [status=implemented hash=8e90521536a6]
public final class ImageError: Error, Sendable, CustomStringConvertible {
    public let code: ImageErrorCode
    public let status: Int
    public let message: String

    public init(status: Int, message: String? = nil) {
        self.status = status
        self.code = (status >= 0 && status < imageStatusCodes.count) ? imageStatusCodes[status] : .internalError
        if let message {
            self.message = message
        } else {
            let reason = (status >= 0 && status < imageStatusMessages.count)
                ? imageStatusMessages[status]
                : "unknown status \(status)"
            self.message = "Native image operation failed: \(reason)"
        }
    }

    public init(code: ImageErrorCode, message: String) {
        self.code = code
        self.status = imageStatusCodes.firstIndex(of: code) ?? 10
        self.message = message
    }

    public var description: String { message }
}

// MARK: - Option & Metadata Structs

/// Optional lifetime owner token for image creation.
// parity: core/src/image.ts#ImageCreateOptions [status=implemented hash=8797b76da37f]
public struct ImageCreateOptions: Equatable, Hashable, Sendable {
    public var ownerId: String?

    public init(ownerId: String? = nil) {
        self.ownerId = ownerId
    }
}

/// Response returned by an injectable pure-Swift image fetcher.
public struct ImageFetchResponse: Sendable {
    public let status: Int
    public let bytes: [UInt8]

    public init(status: Int = 200, bytes: [UInt8]) {
        self.status = status
        self.bytes = bytes
    }
}

/// Options for loading images from raw bytes, paths, or URLs via injectable callbacks.
// parity: core/src/image.ts#ImageLoadOptions [status=implemented hash=ba18f35c2bd3]
public struct ImageLoadOptions: Sendable {
    public var ownerId: String?
    public var readFile: (@Sendable (String) async throws -> [UInt8])?
    public var fetch: (@Sendable (String) async throws -> ImageFetchResponse)?

    public init(
        ownerId: String? = nil,
        readFile: (@Sendable (String) async throws -> [UInt8])? = nil,
        fetch: (@Sendable (String) async throws -> ImageFetchResponse)? = nil
    ) {
        self.ownerId = ownerId
        self.readFile = readFile
        self.fetch = fetch
    }
}

/// Decoded or probed image metadata.
// parity: core/src/image.ts#ImageInfo [status=implemented hash=35efe5108f29]
public struct ImageInfo: Equatable, Hashable, Sendable, Codable {
    public var width: Int
    public var height: Int
    public var sourceWidth: Int
    public var sourceHeight: Int
    public var format: ImageFormat
    public var colorStatus: ImageColorStatus
    public var orientation: Int
    public var hasAlpha: Bool

    public var channels: Int { hasAlpha ? 4 : 3 }

    public init(
        width: Int,
        height: Int,
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil,
        format: ImageFormat,
        colorStatus: ImageColorStatus = .assumedSrgb,
        orientation: Int = 1,
        hasAlpha: Bool = true
    ) {
        self.width = width
        self.height = height
        self.sourceWidth = sourceWidth ?? width
        self.sourceHeight = sourceHeight ?? height
        self.format = format
        self.colorStatus = colorStatus
        self.orientation = orientation
        self.hasAlpha = hasAlpha
    }
}

/// Resize dimensions and resampling kernel configuration.
// parity: core/src/image.ts#ResizeOptions [status=implemented hash=63a858546167]
public struct ResizeOptions: Equatable, Hashable, Sendable, Codable {
    public var width: Int?
    public var height: Int?
    public var kernel: ResizeKernel?

    public init(width: Int? = nil, height: Int? = nil, kernel: ResizeKernel? = nil) {
        self.width = width
        self.height = height
        self.kernel = kernel
    }
}

/// Rectangular crop region in source pixel coordinates.
// parity: core/src/image.ts#ExtractOptions [status=implemented hash=009c0789e0a2]
public struct ExtractOptions: Equatable, Hashable, Sendable, Codable {
    public var left: Int
    public var top: Int
    public var width: Int
    public var height: Int

    public init(left: Int, top: Int, width: Int, height: Int) {
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }
}

/// Edge padding options for `NativeImage.extend(_:)`.
// parity: core/src/image.ts#ExtendOptions [status=implemented hash=265625fffc9e]
public struct ExtendOptions: Equatable, Hashable, Sendable {
    public var top: Int
    public var right: Int
    public var bottom: Int
    public var left: Int
    public var background: (UInt8, UInt8, UInt8, UInt8)

    public init(
        top: Int = 0,
        right: Int = 0,
        bottom: Int = 0,
        left: Int = 0,
        background: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    ) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
        self.background = background
    }

    public static func == (lhs: ExtendOptions, rhs: ExtendOptions) -> Bool {
        lhs.top == rhs.top
            && lhs.right == rhs.right
            && lhs.bottom == rhs.bottom
            && lhs.left == rhs.left
            && lhs.background.0 == rhs.background.0
            && lhs.background.1 == rhs.background.1
            && lhs.background.2 == rhs.background.2
            && lhs.background.3 == rhs.background.3
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(top)
        hasher.combine(right)
        hasher.combine(bottom)
        hasher.combine(left)
        hasher.combine(background.0)
        hasher.combine(background.1)
        hasher.combine(background.2)
        hasher.combine(background.3)
    }
}

/// Layer placement and blending options for `NativeImage.composite(_:options:)`.
// parity: core/src/image.ts#CompositeOptions [status=implemented hash=29bb1f8c4b5f]
public struct CompositeOptions: Equatable, Hashable, Sendable, Codable {
    public var left: Int
    public var top: Int
    public var blend: BlendMode
    public var opacity: Double

    public init(left: Int = 0, top: Int = 0, blend: BlendMode = .sourceOver, opacity: Double = 1.0) {
        self.left = left
        self.top = top
        self.blend = blend
        self.opacity = opacity
    }
}

/// Exported raw pixel buffer with row stride and channel format metadata.
// parity: core/src/image.ts#RawImage [status=implemented hash=7ecbcc8ec593]
public struct RawImage: Equatable, Hashable, Sendable {
    public var data: [UInt8]
    public var width: Int
    public var height: Int
    public var stride: Int
    public var format: PixelFormat
    public var colorSpace: String
    public var alpha: PixelAlphaMode

    public init(
        data: [UInt8],
        width: Int,
        height: Int,
        stride: Int,
        format: PixelFormat = .rgba8,
        colorSpace: String = "srgb",
        alpha: PixelAlphaMode = .straight
    ) {
        self.data = data
        self.width = width
        self.height = height
        self.stride = stride
        self.format = format
        self.colorSpace = colorSpace
        self.alpha = alpha
    }
}

/// Raw pixel import configuration for `NativeImage.fromPixels(_:width:height:options:)`.
// parity: core/src/image.ts#PixelImportOptions [status=implemented hash=9ad5c84784d9]
public struct PixelImportOptions: Equatable, Hashable, Sendable {
    public var ownerId: String?
    public var stride: Int?
    public var format: PixelFormat
    public var alpha: PixelAlphaMode
    public var colorSpace: String

    public init(
        ownerId: String? = nil,
        stride: Int? = nil,
        format: PixelFormat = .rgba8,
        alpha: PixelAlphaMode = .straight,
        colorSpace: String = "srgb"
    ) {
        self.ownerId = ownerId
        self.stride = stride
        self.format = format
        self.alpha = alpha
        self.colorSpace = colorSpace
    }
}

/// Owned raw pixel buffer returned by `NativeImage.takeRaw()` with explicit disposal.
// parity: core/src/image.ts#OwnedRawImage [status=implemented hash=2bc505836b94]
public final class OwnedRawImage: @unchecked Sendable {
    public private(set) var data: [UInt8]
    public let width: Int
    public let height: Int
    public let stride: Int
    public let format: PixelFormat = .rgba8
    public let colorSpace: String = "srgb"
    public let alpha: PixelAlphaMode = .straight
    public private(set) var isDisposed: Bool = false

    public init(data: [UInt8], width: Int, height: Int, stride: Int) {
        self.data = data
        self.width = width
        self.height = height
        self.stride = stride
    }

    public func asRawImage() -> RawImage {
        RawImage(data: data, width: width, height: height, stride: stride, format: format, colorSpace: colorSpace, alpha: alpha)
    }

    public func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        data.removeAll()
    }
}

// MARK: - Aspect-Ratio Layout Math (Non-Colliding Core API)

/// Scaling strategy for fitting a source image into a target box or cell grid.
public enum ImageScaleMode: String, Equatable, Hashable, Sendable, CaseIterable {
    case fit
    case contain
    case cover
    case fill
    case scaleDown
}

/// Computed image placement size and source crop rectangle.
public struct ImageAspectLayout: Equatable, Hashable, Sendable {
    public let destWidth: Int
    public let destHeight: Int
    public let offsetX: Int
    public let offsetY: Int
    public let sourceCrop: ExtractOptions

    public init(destWidth: Int, destHeight: Int, offsetX: Int, offsetY: Int, sourceCrop: ExtractOptions) {
        self.destWidth = destWidth
        self.destHeight = destHeight
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.sourceCrop = sourceCrop
    }
}

/// Computes target dimensions, centering offsets, and source crop for aspect-ratio scaling.
/// Pass `cellAspectRatio = 1.0` for square pixel targets or `cellAspectRatio = 2.0` for terminal cells.
public func computeImageAspectLayout(
    sourceWidth: Int,
    sourceHeight: Int,
    targetWidth: Int,
    targetHeight: Int,
    mode: ImageScaleMode,
    cellAspectRatio: Double = 1.0
) -> ImageAspectLayout {
    guard sourceWidth > 0 && sourceHeight > 0 && targetWidth > 0 && targetHeight > 0 else {
        return ImageAspectLayout(
            destWidth: 0,
            destHeight: 0,
            offsetX: 0,
            offsetY: 0,
            sourceCrop: ExtractOptions(left: 0, top: 0, width: max(0, sourceWidth), height: max(0, sourceHeight))
        )
    }

    let safeCellAspect = (cellAspectRatio.isFinite && cellAspectRatio > 0) ? cellAspectRatio : 1.0
    let fullCrop = ExtractOptions(left: 0, top: 0, width: sourceWidth, height: sourceHeight)

    switch mode {
    case .fill:
        return ImageAspectLayout(
            destWidth: targetWidth,
            destHeight: targetHeight,
            offsetX: 0,
            offsetY: 0,
            sourceCrop: fullCrop
        )

    case .fit, .contain:
        let displayAspect = (Double(sourceWidth) / Double(sourceHeight)) * safeCellAspect
        let scale = min(Double(targetWidth) / displayAspect, Double(targetHeight))
        let w = max(1, min(targetWidth, Int((displayAspect * scale).rounded(.toNearestOrAwayFromZero))))
        let h = max(1, min(targetHeight, Int(scale.rounded(.toNearestOrAwayFromZero))))
        return ImageAspectLayout(
            destWidth: w,
            destHeight: h,
            offsetX: (targetWidth - w) / 2,
            offsetY: (targetHeight - h) / 2,
            sourceCrop: fullCrop
        )

    case .scaleDown:
        let naturalHeight = max(1, Int((Double(sourceHeight) / safeCellAspect).rounded(.toNearestOrAwayFromZero)))
        if sourceWidth <= targetWidth && naturalHeight <= targetHeight {
            return ImageAspectLayout(
                destWidth: sourceWidth,
                destHeight: naturalHeight,
                offsetX: (targetWidth - sourceWidth) / 2,
                offsetY: (targetHeight - naturalHeight) / 2,
                sourceCrop: fullCrop
            )
        }
        return computeImageAspectLayout(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            mode: .contain,
            cellAspectRatio: safeCellAspect
        )

    case .cover:
        let targetAspect = Double(targetWidth) / (Double(targetHeight) * safeCellAspect)
        let sourceAspect = Double(sourceWidth) / Double(sourceHeight)
        var cropX = 0
        var cropY = 0
        var cropW = sourceWidth
        var cropH = sourceHeight
        if sourceAspect > targetAspect {
            cropW = max(1, min(sourceWidth, Int((Double(sourceHeight) * targetAspect).rounded(.toNearestOrAwayFromZero))))
            cropX = (sourceWidth - cropW) / 2
        } else {
            cropH = max(1, min(sourceHeight, Int((Double(sourceWidth) / targetAspect).rounded(.toNearestOrAwayFromZero))))
            cropY = (sourceHeight - cropH) / 2
        }
        return ImageAspectLayout(
            destWidth: targetWidth,
            destHeight: targetHeight,
            offsetX: 0,
            offsetY: 0,
            sourceCrop: ExtractOptions(left: cropX, top: cropY, width: cropW, height: cropH)
        )
    }
}

// MARK: - Pure-Swift Checksums (CRC-32 & Adler-32) and Base64

private let pngCRC32Table: [UInt32] = {
    var table = Array<UInt32>(repeating: 0, count: 256)
    for n in 0..<256 {
        var c = UInt32(n)
        for _ in 0..<8 {
            if (c & 1) != 0 {
                c = 0xEDB8_8320 ^ (c >> 1)
            } else {
                c >>= 1
            }
        }
        table[n] = c
    }
    return table
}()

private func computeCRC32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
        let idx = Int((crc ^ UInt32(byte)) & 0xFF)
        crc = pngCRC32Table[idx] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
}

private func computeAdler32(_ bytes: [UInt8]) -> UInt32 {
    var s1: UInt32 = 1
    var s2: UInt32 = 0
    for byte in bytes {
        s1 = (s1 + UInt32(byte)) % 65521
        s2 = (s2 + s1) % 65521
    }
    return (s2 << 16) | s1
}

private let imageBase64Alphabet: [UInt8] = Array(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8
)

/// Pure-Swift RFC 4648 Base64 encoder for Kitty Graphics Protocol transmission.
public func encodeImageBase64(_ bytes: [UInt8]) -> String {
    guard !bytes.isEmpty else { return "" }
    var out: [UInt8] = []
    out.reserveCapacity(((bytes.count + 2) / 3) * 4)

    var i = 0
    while i < bytes.count {
        let b0 = UInt32(bytes[i])
        let hasB1 = i + 1 < bytes.count
        let hasB2 = i + 2 < bytes.count
        let b1 = hasB1 ? UInt32(bytes[i + 1]) : 0
        let b2 = hasB2 ? UInt32(bytes[i + 2]) : 0

        let triple = (b0 << 16) | (b1 << 8) | b2
        out.append(imageBase64Alphabet[Int((triple >> 18) & 0x3F)])
        out.append(imageBase64Alphabet[Int((triple >> 12) & 0x3F)])
        out.append(hasB1 ? imageBase64Alphabet[Int((triple >> 6) & 0x3F)] : 0x3D)
        out.append(hasB2 ? imageBase64Alphabet[Int(triple & 0x3F)] : 0x3D)
        i += 3
    }
    return String(decoding: out, as: UTF8.self)
}

// MARK: - Pure-Swift Format Probing & Codecs (PNG / BMP / PPM / PGM / JPEG / GIF / WebP headers)

private let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
private let imageMaxDimension = 32_768
private let imageMaxEncodedBytes = 64 * 1024 * 1024

@inline(__always)
private func readU16BE(_ data: [UInt8], at i: Int) -> UInt16 {
    (UInt16(data[i]) << 8) | UInt16(data[i + 1])
}

@inline(__always)
private func readU32BE(_ data: [UInt8], at i: Int) -> UInt32 {
    (UInt32(data[i]) << 24)
        | (UInt32(data[i + 1]) << 16)
        | (UInt32(data[i + 2]) << 8)
        | UInt32(data[i + 3])
}

@inline(__always)
private func readU16LE(_ data: [UInt8], at i: Int) -> UInt16 {
    UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
}

@inline(__always)
private func readU32LE(_ data: [UInt8], at i: Int) -> UInt32 {
    UInt32(data[i])
        | (UInt32(data[i + 1]) << 8)
        | (UInt32(data[i + 2]) << 16)
        | (UInt32(data[i + 3]) << 24)
}

@inline(__always)
private func appendU32BE(_ value: UInt32, to out: inout [UInt8]) {
    out.append(UInt8((value >> 24) & 0xFF))
    out.append(UInt8((value >> 16) & 0xFF))
    out.append(UInt8((value >> 8) & 0xFF))
    out.append(UInt8(value & 0xFF))
}

@inline(__always)
private func appendU16LE(_ value: UInt16, to out: inout [UInt8]) {
    out.append(UInt8(value & 0xFF))
    out.append(UInt8((value >> 8) & 0xFF))
}

@inline(__always)
private func appendU32LE(_ value: UInt32, to out: inout [UInt8]) {
    out.append(UInt8(value & 0xFF))
    out.append(UInt8((value >> 8) & 0xFF))
    out.append(UInt8((value >> 16) & 0xFF))
    out.append(UInt8((value >> 24) & 0xFF))
}

private func paethPredictor(_ a: Int, _ b: Int, _ c: Int) -> UInt8 {
    let p = a + b - c
    let pa = abs(p - a)
    let pb = abs(p - b)
    let pc = abs(p - c)
    if pa <= pb && pa <= pc { return UInt8(a) }
    if pb <= pc { return UInt8(b) }
    return UInt8(c)
}

private func isWhitespaceASCII(_ b: UInt8) -> Bool {
    b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
}

private func nextPNMToken(_ bytes: [UInt8], cursor: inout Int) -> String? {
    let count = bytes.count
    while cursor < count {
        let b = bytes[cursor]
        if isWhitespaceASCII(b) {
            cursor += 1
        } else if b == 0x23 { // '#' comment
            while cursor < count && bytes[cursor] != 0x0A {
                cursor += 1
            }
        } else {
            break
        }
    }
    guard cursor < count else { return nil }
    let start = cursor
    while cursor < count && !isWhitespaceASCII(bytes[cursor]) && bytes[cursor] != 0x23 {
        cursor += 1
    }
    return String(decoding: bytes[start..<cursor], as: UTF8.self)
}

/// Probes encoded image bytes (`PNG`, `BMP`, `PPM`/`PGM`, `JPEG`, `GIF`, `WebP`) without full decoding.
// parity: core/src/image.ts#imageInfo [status=implemented hash=8d2ba1808192]
public func imageInfo(_ data: [UInt8], options: ImageCreateOptions = ImageCreateOptions()) throws(ImageError) -> ImageInfo {
    guard !data.isEmpty else {
        throw ImageError(code: .invalidArgument, message: "image data must not be empty")
    }
    guard data.count <= imageMaxEncodedBytes else {
        throw ImageError(status: 6)
    }

    // PNG
    if data.count >= 29 && Array(data[0..<8]) == pngSignature {
        guard data[12] == 0x49 && data[13] == 0x48 && data[14] == 0x44 && data[15] == 0x52 else {
            throw ImageError(code: .malformedData, message: "PNG missing IHDR header")
        }
        let width = Int(readU32BE(data, at: 16))
        let height = Int(readU32BE(data, at: 20))
        let colorType = data[25]
        let hasAlpha = colorType == 4 || colorType == 6
        guard width > 0 && height > 0 else {
            throw ImageError(code: .malformedData, message: "PNG has invalid dimensions")
        }
        return ImageInfo(width: width, height: height, format: .png, colorStatus: .assumedSrgb, orientation: 1, hasAlpha: hasAlpha)
    }

    // BMP
    if data.count >= 26 && data[0] == 0x42 && data[1] == 0x4D {
        let width = Int(Int32(bitPattern: readU32LE(data, at: 18)))
        let rawHeight = Int(Int32(bitPattern: readU32LE(data, at: 22)))
        let height = abs(rawHeight)
        let bpp = data.count >= 30 ? Int(readU16LE(data, at: 28)) : 24
        guard width > 0 && height > 0 else {
            throw ImageError(code: .malformedData, message: "BMP has invalid dimensions")
        }
        return ImageInfo(width: width, height: height, format: .bmp, colorStatus: .assumedSrgb, orientation: 1, hasAlpha: bpp == 32)
    }

    // PPM / PGM (P2, P3, P5, P6)
    if data.count >= 7 && data[0] == 0x50 && (data[1] == 0x32 || data[1] == 0x33 || data[1] == 0x35 || data[1] == 0x36) {
        var cursor = 2
        if let wStr = nextPNMToken(data, cursor: &cursor),
           let hStr = nextPNMToken(data, cursor: &cursor),
           let width = Int(wStr),
           let height = Int(hStr),
           width > 0 && height > 0
        {
            return ImageInfo(width: width, height: height, format: .ppm, colorStatus: .assumedSrgb, orientation: 1, hasAlpha: false)
        }
        throw ImageError(code: .malformedData, message: "Malformed PNM/PPM header")
    }

    // GIF87a / GIF89a
    if data.count >= 10 && data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46 {
        let width = Int(readU16LE(data, at: 6))
        let height = Int(readU16LE(data, at: 8))
        guard width > 0 && height > 0 else {
            throw ImageError(code: .malformedData, message: "GIF has invalid dimensions")
        }
        return ImageInfo(width: width, height: height, format: .gif, colorStatus: .assumedSrgb, orientation: 1, hasAlpha: true)
    }

    // WebP (RIFF....WEBP)
    if data.count >= 30 && data[0] == 0x52 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x46
        && data[8] == 0x57 && data[9] == 0x45 && data[10] == 0x42 && data[11] == 0x50
    {
        if data[12] == 0x56 && data[13] == 0x50 && data[14] == 0x38 && data[15] == 0x58 { // VP8X
            let w = Int(data[24]) | (Int(data[25]) << 8) | (Int(data[26]) << 16)
            let h = Int(data[27]) | (Int(data[28]) << 8) | (Int(data[29]) << 16)
            let hasAlpha = (data[20] & 0x10) != 0
            return ImageInfo(width: w + 1, height: h + 1, format: .webp, colorStatus: .assumedSrgb, orientation: 1, hasAlpha: hasAlpha)
        }
        if data[12] == 0x56 && data[13] == 0x50 && data[14] == 0x38 && data[15] == 0x20 && data.count >= 30 { // VP8
            let w = Int(readU16LE(data, at: 26) & 0x3FFF)
            let h = Int(readU16LE(data, at: 28) & 0x3FFF)
            if w > 0 && h > 0 {
                return ImageInfo(width: w, height: h, format: .webp, colorStatus: .assumedSrgb, orientation: 1, hasAlpha: false)
            }
        }
        if data[12] == 0x56 && data[13] == 0x50 && data[14] == 0x38 && data[15] == 0x4C && data.count >= 25 { // VP8L
            let bits = readU32LE(data, at: 21)
            let w = Int(bits & 0x3FFF) + 1
            let h = Int((bits >> 14) & 0x3FFF) + 1
            let hasAlpha = ((bits >> 28) & 1) != 0
            return ImageInfo(width: w, height: h, format: .webp, colorStatus: .assumedSrgb, orientation: 1, hasAlpha: hasAlpha)
        }
    }

    // JPEG (SOI FF D8, scan for SOF0/SOF2)
    if data.count >= 4 && data[0] == 0xFF && data[1] == 0xD8 {
        var offset = 2
        while offset + 4 < data.count {
            if data[offset] != 0xFF { break }
            while offset < data.count && data[offset] == 0xFF { offset += 1 }
            guard offset < data.count else { break }
            let marker = data[offset]
            offset += 1
            if marker == 0xD9 || marker == 0xDA { break }
            guard offset + 2 <= data.count else { break }
            let segLen = Int(readU16BE(data, at: offset))
            guard segLen >= 2 && offset + segLen <= data.count else { break }
            if (marker == 0xC0 || marker == 0xC1 || marker == 0xC2) && segLen >= 7 {
                let height = Int(readU16BE(data, at: offset + 3))
                let width = Int(readU16BE(data, at: offset + 5))
                if width > 0 && height > 0 {
                    return ImageInfo(width: width, height: height, format: .jpeg, colorStatus: .assumedSrgb, orientation: 1, hasAlpha: false)
                }
            }
            offset += segLen
        }
        throw ImageError(code: .malformedData, message: "JPEG missing SOF frame dimensions")
    }

    throw ImageError(code: .unsupportedFormat, message: "Unsupported or unrecognized image format")
}

private enum PureImageCodec {
    static func decode(_ data: [UInt8]) throws(ImageError) -> (pixels: [UInt8], info: ImageInfo) {
        guard !data.isEmpty else {
            throw ImageError(code: .invalidArgument, message: "image data must not be empty")
        }
        if data.count >= 8 && Array(data[0..<8]) == pngSignature {
            return try decodeUncompressedPNG(data)
        }
        if data.count >= 26 && data[0] == 0x42 && data[1] == 0x4D {
            return try decodeBMP(data)
        }
        if data.count >= 7 && data[0] == 0x50 && (data[1] == 0x32 || data[1] == 0x33 || data[1] == 0x35 || data[1] == 0x36) {
            return try decodePNM(data)
        }
        throw ImageError(code: .unsupportedFormat, message: "Unsupported image format for pure-Swift decoding")
    }

    static func decodePNM(_ data: [UInt8]) throws(ImageError) -> (pixels: [UInt8], info: ImageInfo) {
        let magic = data[1] // '2', '3', '5', '6'
        var cursor = 2
        guard let wStr = nextPNMToken(data, cursor: &cursor),
              let hStr = nextPNMToken(data, cursor: &cursor),
              let maxStr = nextPNMToken(data, cursor: &cursor),
              let width = Int(wStr),
              let height = Int(hStr),
              let maxVal = Int(maxStr),
              width > 0 && height > 0 && maxVal > 0 && maxVal <= 65535
        else {
            throw ImageError(code: .malformedData, message: "Malformed PPM/PGM header")
        }
        guard width <= imageMaxDimension && height <= imageMaxDimension else {
            throw ImageError(code: .dimensionLimit, message: "Image dimensions exceed limit")
        }

        let pixelCount = width * height
        var rgba = Array<UInt8>(repeating: 255, count: pixelCount * 4)
        let scale = 255.0 / Double(maxVal)

        if magic == 0x36 || magic == 0x35 { // Binary P6 (RGB) or P5 (Gray)
            // Single whitespace byte separates header from binary payload
            guard cursor < data.count && isWhitespaceASCII(data[cursor]) else {
                throw ImageError(code: .malformedData, message: "Missing whitespace before PNM binary payload")
            }
            cursor += 1
            let channels = (magic == 0x36) ? 3 : 1
            let bytesPerSample = maxVal > 255 ? 2 : 1
            let required = pixelCount * channels * bytesPerSample
            guard cursor + required <= data.count else {
                throw ImageError(code: .malformedData, message: "Truncated PNM binary payload")
            }

            for i in 0..<pixelCount {
                if channels == 3 {
                    for c in 0..<3 {
                        let raw: Int
                        if bytesPerSample == 1 {
                            raw = Int(data[cursor])
                            cursor += 1
                        } else {
                            raw = Int(readU16BE(data, at: cursor))
                            cursor += 2
                        }
                        rgba[i * 4 + c] = maxVal == 255 ? UInt8(raw) : UInt8(min(255, Int((Double(raw) * scale).rounded())))
                    }
                } else {
                    let raw: Int
                    if bytesPerSample == 1 {
                        raw = Int(data[cursor])
                        cursor += 1
                    } else {
                        raw = Int(readU16BE(data, at: cursor))
                        cursor += 2
                    }
                    let gray = maxVal == 255 ? UInt8(raw) : UInt8(min(255, Int((Double(raw) * scale).rounded())))
                    rgba[i * 4] = gray
                    rgba[i * 4 + 1] = gray
                    rgba[i * 4 + 2] = gray
                }
                rgba[i * 4 + 3] = 255
            }
        } else { // ASCII P3 (RGB) or P2 (Gray)
            let isColor = (magic == 0x33)
            for i in 0..<pixelCount {
                if isColor {
                    guard let rs = nextPNMToken(data, cursor: &cursor), let r = Int(rs),
                          let gs = nextPNMToken(data, cursor: &cursor), let g = Int(gs),
                          let bs = nextPNMToken(data, cursor: &cursor), let b = Int(bs)
                    else {
                        throw ImageError(code: .malformedData, message: "Truncated ASCII PPM payload")
                    }
                    rgba[i * 4] = UInt8(max(0, min(255, Int((Double(r) * scale).rounded()))))
                    rgba[i * 4 + 1] = UInt8(max(0, min(255, Int((Double(g) * scale).rounded()))))
                    rgba[i * 4 + 2] = UInt8(max(0, min(255, Int((Double(b) * scale).rounded()))))
                } else {
                    guard let gs = nextPNMToken(data, cursor: &cursor), let g = Int(gs) else {
                        throw ImageError(code: .malformedData, message: "Truncated ASCII PGM payload")
                    }
                    let gray = UInt8(max(0, min(255, Int((Double(g) * scale).rounded()))))
                    rgba[i * 4] = gray
                    rgba[i * 4 + 1] = gray
                    rgba[i * 4 + 2] = gray
                }
                rgba[i * 4 + 3] = 255
            }
        }

        let info = ImageInfo(width: width, height: height, format: .ppm, colorStatus: .assumedSrgb, orientation: 1, hasAlpha: false)
        return (rgba, info)
    }

    static func encodePPM(width: Int, height: Int, rgba: [UInt8]) -> [UInt8] {
        var out = Array("P6\n\(width) \(height)\n255\n".utf8)
        out.reserveCapacity(out.count + width * height * 3)
        for i in 0..<(width * height) {
            out.append(rgba[i * 4])
            out.append(rgba[i * 4 + 1])
            out.append(rgba[i * 4 + 2])
        }
        return out
    }

    static func decodeBMP(_ data: [UInt8]) throws(ImageError) -> (pixels: [UInt8], info: ImageInfo) {
        guard data.count >= 54 else {
            throw ImageError(code: .malformedData, message: "BMP header is truncated")
        }
        let pixelOffset = Int(readU32LE(data, at: 10))
        let dibHeaderSize = Int(readU32LE(data, at: 14))
        guard dibHeaderSize >= 40 else {
            throw ImageError(code: .unsupportedFeature, message: "Unsupported BMP DIB header size \(dibHeaderSize)")
        }
        let width = Int(Int32(bitPattern: readU32LE(data, at: 18)))
        let signedHeight = Int(Int32(bitPattern: readU32LE(data, at: 22)))
        let topDown = signedHeight < 0
        let height = abs(signedHeight)
        let bpp = Int(readU16LE(data, at: 28))
        let compression = readU32LE(data, at: 30)

        guard width > 0 && height > 0 && width <= imageMaxDimension && height <= imageMaxDimension else {
            throw ImageError(code: .dimensionLimit, message: "Invalid BMP dimensions \(width)x\(height)")
        }
        guard compression == 0 else {
            throw ImageError(code: .unsupportedFeature, message: "Only uncompressed BI_RGB BMP is supported")
        }
        guard bpp == 24 || bpp == 32 else {
            throw ImageError(code: .unsupportedFeature, message: "Only 24-bit and 32-bit BMP are supported")
        }

        let bytesPerPixel = bpp / 8
        let rowStride = ((width * bytesPerPixel + 3) / 4) * 4
        guard pixelOffset >= 0 && pixelOffset + rowStride * height <= data.count else {
            throw ImageError(code: .malformedData, message: "BMP pixel data is truncated")
        }

        var rgba = Array<UInt8>(repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let srcRow = topDown ? y : (height - 1 - y)
            let rowBase = pixelOffset + srcRow * rowStride
            for x in 0..<width {
                let s = rowBase + x * bytesPerPixel
                let d = (y * width + x) * 4
                rgba[d] = data[s + 2]     // R
                rgba[d + 1] = data[s + 1] // G
                rgba[d + 2] = data[s]     // B
                rgba[d + 3] = (bpp == 32) ? data[s + 3] : 255
            }
        }

        let info = ImageInfo(width: width, height: height, format: .bmp, colorStatus: .assumedSrgb, orientation: 1, hasAlpha: bpp == 32)
        return (rgba, info)
    }

    static func encodeBMP(width: Int, height: Int, rgba: [UInt8], includeAlpha: Bool = true) -> [UInt8] {
        let bpp = includeAlpha ? 32 : 24
        let bytesPerPixel = bpp / 8
        let rowStride = ((width * bytesPerPixel + 3) / 4) * 4
        let pixelBytes = rowStride * height
        let fileSize = 54 + pixelBytes

        var out: [UInt8] = []
        out.reserveCapacity(fileSize)
        // BITMAPFILEHEADER (14 bytes)
        out.append(0x42); out.append(0x4D) // "BM"
        appendU32LE(UInt32(clamping: fileSize), to: &out)
        appendU16LE(0, to: &out)
        appendU16LE(0, to: &out)
        appendU32LE(54, to: &out)
        // BITMAPINFOHEADER (40 bytes)
        appendU32LE(40, to: &out)
        appendU32LE(UInt32(bitPattern: Int32(clamping: width)), to: &out)
        appendU32LE(UInt32(bitPattern: Int32(clamping: height)), to: &out) // positive = bottom-up
        appendU16LE(1, to: &out)
        appendU16LE(UInt16(bpp), to: &out)
        appendU32LE(0, to: &out) // BI_RGB
        appendU32LE(UInt32(clamping: pixelBytes), to: &out)
        appendU32LE(2835, to: &out)
        appendU32LE(2835, to: &out)
        appendU32LE(0, to: &out)
        appendU32LE(0, to: &out)

        let padBytes = rowStride - width * bytesPerPixel
        for row in stride(from: height - 1, through: 0, by: -1) {
            for x in 0..<width {
                let s = (row * width + x) * 4
                out.append(rgba[s + 2]) // B
                out.append(rgba[s + 1]) // G
                out.append(rgba[s])     // R
                if includeAlpha {
                    out.append(rgba[s + 3]) // A
                }
            }
            for _ in 0..<padBytes {
                out.append(0)
            }
        }
        return out
    }

    /// Encodes RGBA8888 pixels into a spec-compliant uncompressed (stored DEFLATE) PNG byte stream.
    static func encodeUncompressedPNG(width: Int, height: Int, rgba: [UInt8]) -> [UInt8] {
        // Build filtered scanlines (filter byte 0 = None per row)
        let rowBytes = width * 4
        var rawScanlines: [UInt8] = []
        rawScanlines.reserveCapacity(height * (1 + rowBytes))
        for y in 0..<height {
            rawScanlines.append(0) // filter type 0 (None)
            let start = y * rowBytes
            rawScanlines.append(contentsOf: rgba[start..<(start + rowBytes)])
        }

        // Wrap raw scanlines in valid zlib stored-block stream
        var zlibData: [UInt8] = [0x78, 0x01] // CMF=0x78 (deflate, 32K), FLG=0x01 (check valid, no dict)
        var offset = 0
        let maxStoredBlock = 65535
        while offset < rawScanlines.count || rawScanlines.isEmpty {
            let chunkLen = min(maxStoredBlock, rawScanlines.count - offset)
            let isFinal = (offset + chunkLen) >= rawScanlines.count
            zlibData.append(isFinal ? 0x01 : 0x00) // BFINAL + BTYPE=00 (stored)
            let len16 = UInt16(chunkLen)
            let nlen16 = ~len16
            appendU16LE(len16, to: &zlibData)
            appendU16LE(nlen16, to: &zlibData)
            if chunkLen > 0 {
                zlibData.append(contentsOf: rawScanlines[offset..<(offset + chunkLen)])
            }
            offset += chunkLen
            if isFinal { break }
        }
        appendU32BE(computeAdler32(rawScanlines), to: &zlibData)

        var out = pngSignature

        func appendChunk(_ type: [UInt8], _ payload: [UInt8]) {
            appendU32BE(UInt32(clamping: payload.count), to: &out)
            var typeAndPayload = type
            typeAndPayload.append(contentsOf: payload)
            out.append(contentsOf: typeAndPayload)
            appendU32BE(computeCRC32(typeAndPayload), to: &out)
        }

        // IHDR
        var ihdr: [UInt8] = []
        appendU32BE(UInt32(clamping: width), to: &ihdr)
        appendU32BE(UInt32(clamping: height), to: &ihdr)
        ihdr.append(8) // bit depth 8
        ihdr.append(6) // color type 6 = RGBA
        ihdr.append(0) // compression 0
        ihdr.append(0) // filter 0
        ihdr.append(0) // interlace 0
        appendChunk([0x49, 0x48, 0x44, 0x52], ihdr)

        // IDAT
        appendChunk([0x49, 0x44, 0x41, 0x54], zlibData)

        // IEND
        appendChunk([0x49, 0x45, 0x4E, 0x44], [])

        return out
    }

    /// Decodes an uncompressed (stored-block DEFLATE) 8-bit PNG (Gray, RGB, Gray+Alpha, RGBA).
    static func decodeUncompressedPNG(_ data: [UInt8]) throws(ImageError) -> (pixels: [UInt8], info: ImageInfo) {
        guard data.count >= 33 && Array(data[0..<8]) == pngSignature else {
            throw ImageError(code: .malformedData, message: "Invalid PNG signature")
        }

        var width = 0
        var height = 0
        var bitDepth: UInt8 = 0
        var colorType: UInt8 = 0
        var hasIHDR = false
        var hasSRGB = false
        var idat: [UInt8] = []

        var offset = 8
        while offset + 12 <= data.count {
            let length = Int(readU32BE(data, at: offset))
            let typeStart = offset + 4
            let dataStart = offset + 8
            let dataEnd = dataStart + length
            let crcEnd = dataEnd + 4
            guard length >= 0 && crcEnd <= data.count else {
                throw ImageError(code: .malformedData, message: "Truncated PNG chunk")
            }

            let t0 = data[typeStart]
            let t1 = data[typeStart + 1]
            let t2 = data[typeStart + 2]
            let t3 = data[typeStart + 3]

            if t0 == 0x49 && t1 == 0x48 && t2 == 0x44 && t3 == 0x52 { // IHDR
                guard length == 13 else {
                    throw ImageError(code: .malformedData, message: "Invalid PNG IHDR length")
                }
                width = Int(readU32BE(data, at: dataStart))
                height = Int(readU32BE(data, at: dataStart + 4))
                bitDepth = data[dataStart + 8]
                colorType = data[dataStart + 9]
                let compression = data[dataStart + 10]
                let filter = data[dataStart + 11]
                let interlace = data[dataStart + 12]
                guard width > 0 && height > 0 && width <= imageMaxDimension && height <= imageMaxDimension else {
                    throw ImageError(code: .dimensionLimit, message: "PNG dimensions out of bounds")
                }
                guard bitDepth == 8 && compression == 0 && filter == 0 && interlace == 0 else {
                    throw ImageError(code: .unsupportedFeature, message: "Unsupported PNG bit depth or interlace mode")
                }
                hasIHDR = true
            } else if t0 == 0x73 && t1 == 0x52 && t2 == 0x47 && t3 == 0x42 { // sRGB
                hasSRGB = true
            } else if t0 == 0x49 && t1 == 0x44 && t2 == 0x41 && t3 == 0x54 { // IDAT
                idat.append(contentsOf: data[dataStart..<dataEnd])
            } else if t0 == 0x49 && t1 == 0x45 && t2 == 0x4E && t3 == 0x44 { // IEND
                break
            }

            offset = crcEnd
        }

        guard hasIHDR, idat.count >= 6 else {
            throw ImageError(code: .malformedData, message: "PNG missing IHDR or IDAT payload")
        }

        let bpp: Int
        switch colorType {
        case 0: bpp = 1
        case 2: bpp = 3
        case 4: bpp = 2
        case 6: bpp = 4
        default:
            throw ImageError(code: .unsupportedFeature, message: "Unsupported PNG color type \(colorType)")
        }

        // Parse zlib header + uncompressed DEFLATE stored blocks
        let cmf = idat[0]
        let flg = idat[1]
        guard (cmf & 0x0F) == 8 && ((UInt16(cmf) * 256 + UInt16(flg)) % 31 == 0) && (flg & 0x20) == 0 else {
            throw ImageError(code: .malformedData, message: "Invalid zlib header in PNG IDAT")
        }

        var zpos = 2
        var scanlines: [UInt8] = []
        let expectedScanlineBytes = height * (1 + width * bpp)
        scanlines.reserveCapacity(expectedScanlineBytes)

        while zpos < idat.count - 4 {
            let blockHeader = idat[zpos]
            zpos += 1
            let isFinal = (blockHeader & 0x01) != 0
            let btype = (blockHeader >> 1) & 0x03
            guard btype == 0 else {
                throw ImageError(code: .unsupportedFeature, message: "Compressed DEFLATE PNG streams require an external decoder; uncompressed stored PNG is supported in pure OpenTUICore")
            }
            guard zpos + 4 <= idat.count - 4 else {
                throw ImageError(code: .malformedData, message: "Truncated DEFLATE stored block header")
            }
            let len = Int(readU16LE(idat, at: zpos))
            let nlen = readU16LE(idat, at: zpos + 2)
            zpos += 4
            guard UInt16(len) == ~nlen else {
                throw ImageError(code: .malformedData, message: "Corrupted DEFLATE stored block length check")
            }
            guard zpos + len <= idat.count - 4 else {
                throw ImageError(code: .malformedData, message: "Truncated DEFLATE stored block payload")
            }
            scanlines.append(contentsOf: idat[zpos..<(zpos + len)])
            zpos += len
            if isFinal { break }
        }

        guard scanlines.count >= expectedScanlineBytes else {
            throw ImageError(code: .malformedData, message: "PNG decoded scanline length mismatch")
        }

        // Reconstruct PNG scanlines across all 5 standard filter modes
        let rowStride = width * bpp
        var reconstructed = Array<UInt8>(repeating: 0, count: height * rowStride)
        for y in 0..<height {
            let filterType = scanlines[y * (rowStride + 1)]
            let srcRowBase = y * (rowStride + 1) + 1
            let dstRowBase = y * rowStride

            for x in 0..<rowStride {
                let raw = Int(scanlines[srcRowBase + x])
                let left = (x >= bpp) ? Int(reconstructed[dstRowBase + x - bpp]) : 0
                let up = (y > 0) ? Int(reconstructed[(y - 1) * rowStride + x]) : 0
                let upLeft = (y > 0 && x >= bpp) ? Int(reconstructed[(y - 1) * rowStride + x - bpp]) : 0

                let val: Int
                switch filterType {
                case 0: val = raw
                case 1: val = (raw + left) & 0xFF
                case 2: val = (raw + up) & 0xFF
                case 3: val = (raw + ((left + up) >> 1)) & 0xFF
                case 4: val = (raw + Int(paethPredictor(left, up, upLeft))) & 0xFF
                default:
                    throw ImageError(code: .malformedData, message: "Invalid PNG filter type \(filterType)")
                }
                reconstructed[dstRowBase + x] = UInt8(val)
            }
        }

        // Convert to RGBA8888
        var rgba = Array<UInt8>(repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            switch colorType {
            case 0:
                let g = reconstructed[i]
                rgba[i * 4] = g; rgba[i * 4 + 1] = g; rgba[i * 4 + 2] = g; rgba[i * 4 + 3] = 255
            case 2:
                rgba[i * 4] = reconstructed[i * 3]
                rgba[i * 4 + 1] = reconstructed[i * 3 + 1]
                rgba[i * 4 + 2] = reconstructed[i * 3 + 2]
                rgba[i * 4 + 3] = 255
            case 4:
                let g = reconstructed[i * 2]
                rgba[i * 4] = g; rgba[i * 4 + 1] = g; rgba[i * 4 + 2] = g
                rgba[i * 4 + 3] = reconstructed[i * 2 + 1]
            case 6:
                rgba[i * 4] = reconstructed[i * 4]
                rgba[i * 4 + 1] = reconstructed[i * 4 + 1]
                rgba[i * 4 + 2] = reconstructed[i * 4 + 2]
                rgba[i * 4 + 3] = reconstructed[i * 4 + 3]
            default:
                break
            }
        }

        let info = ImageInfo(
            width: width,
            height: height,
            format: .png,
            colorStatus: hasSRGB ? .explicitSrgb : .assumedSrgb,
            orientation: 1,
            hasAlpha: colorType == 4 || colorType == 6
        )
        return (rgba, info)
    }
}

// MARK: - NativeImage (OpenTUIImage)

/// Convenience non-colliding alias for `NativeImage`.
public typealias OpenTUIImage = NativeImage

/// Opaque handle identifier for an active `NativeImage` instance.
public struct NativeImageHandle: Equatable, Hashable, Sendable {
    public let id: UInt64
    public init(id: UInt64) { self.id = id }
}

private func cubicWeight(_ t: Double, b: Double, c: Double) -> Double {
    let x = abs(t)
    if x < 1.0 {
        return ((12.0 - 9.0 * b - 6.0 * c) * x * x * x
            + (-18.0 + 12.0 * b + 6.0 * c) * x * x
            + (6.0 - 2.0 * b)) / 6.0
    } else if x < 2.0 {
        return ((-b - 6.0 * c) * x * x * x
            + (6.0 * b + 30.0 * c) * x * x
            + (-12.0 * b - 48.0 * c) * x
            + (8.0 * b + 24.0 * c)) / 6.0
    }
    return 0.0
}

/// Pure-Swift RGBA8888 image handle supporting decoding, pixel import/export, resizing, cropping,
/// padding, rotation, flipping, Porter-Duff compositing, PNG/BMP/PPM encoding, and explicit disposal.
// parity: core/src/image.ts#NativeImage [status=implemented hash=35855d569bed]
public final class NativeImage: @unchecked Sendable {
    private static let handleCounterLock = HandleCounter()

    private final class HandleCounter: @unchecked Sendable {
        private var current: UInt64 = 1
        func next() -> UInt64 {
            let value = current
            current &+= 1
            return value
        }
    }

    private var handle: NativeImageHandle?
    private var pixels: [UInt8]
    private var imageInfo: ImageInfo
    private var cachedPng: [UInt8]? = nil
    internal var retainCount: Int = 1

    internal init(pixels: [UInt8], info: ImageInfo) {
        self.handle = NativeImageHandle(id: Self.handleCounterLock.next())
        self.pixels = pixels
        self.imageInfo = info
    }

    // MARK: - Constructors & Loaders

    // parity: core/src/image.ts#NativeImage.decode [status=implemented hash=a5e0e0391aad]
    public static func decode(_ data: [UInt8], options: ImageCreateOptions = ImageCreateOptions()) throws(ImageError) -> NativeImage {
        let decoded = try PureImageCodec.decode(data)
        return NativeImage(pixels: decoded.pixels, info: decoded.info)
    }

    // parity: core/src/image.ts#NativeImage.load [status=implemented hash=27355192921a]
    public static func load(_ source: ImageSource, options: ImageLoadOptions = ImageLoadOptions()) async throws -> NativeImage {
        switch source {
        case .bytes(let data):
            return try NativeImage.decode(data, options: ImageCreateOptions(ownerId: options.ownerId))
        case .rawRgba(let pixels, let width, let height, let stride):
            return try NativeImage.fromRgba(
                pixels,
                width: width,
                height: height,
                stride: stride ?? width * 4,
                options: ImageCreateOptions(ownerId: options.ownerId)
            )
        case .filePath(let path):
            guard let reader = options.readFile else {
                throw ImageLoadError(code: .fileRead, source: path, message: "No file reader provided for '\(path)'")
            }
            let bytes: [UInt8]
            do {
                bytes = try await reader(path)
            } catch {
                throw ImageLoadError(code: .fileRead, source: path, message: "Failed to read image: \(path)")
            }
            return try NativeImage.decode(bytes, options: ImageCreateOptions(ownerId: options.ownerId))
        case .url(let urlString):
            let lower = urlString.lowercased()
            let supported = lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("data:") || lower.hasPrefix("blob:")
            guard supported else {
                throw ImageLoadError(code: .unsupportedUrlScheme, source: urlString, message: "Unsupported image URL scheme: \(urlString)")
            }
            guard let fetcher = options.fetch else {
                throw ImageLoadError(code: .network, source: urlString, message: "No fetcher provided for '\(urlString)'")
            }
            let response: ImageFetchResponse
            do {
                response = try await fetcher(urlString)
            } catch {
                throw ImageLoadError(code: .network, source: urlString, message: "Failed to fetch image: \(urlString)")
            }
            guard (200...299).contains(response.status) else {
                throw ImageLoadError(
                    code: .httpStatus,
                    source: urlString,
                    message: "Failed to fetch image: HTTP \(response.status)",
                    status: response.status
                )
            }
            return try NativeImage.decode(response.bytes, options: ImageCreateOptions(ownerId: options.ownerId))
        }
    }

    // parity: core/src/image.ts#NativeImage.fromRgba [status=implemented hash=2d515fc6db1f]
    public static func fromRgba(
        _ pixels: [UInt8],
        width: Int,
        height: Int,
        stride: Int? = nil,
        options: ImageCreateOptions = ImageCreateOptions()
    ) throws(ImageError) -> NativeImage {
        try fromPixels(
            pixels,
            width: width,
            height: height,
            options: PixelImportOptions(ownerId: options.ownerId, stride: stride ?? width * 4, format: .rgba8, alpha: .straight)
        )
    }

    // parity: core/src/image.ts#NativeImage.fromPixels [status=implemented hash=79c3fb96e0f2]
    public static func fromPixels(
        _ pixels: [UInt8],
        width: Int,
        height: Int,
        options: PixelImportOptions = PixelImportOptions()
    ) throws(ImageError) -> NativeImage {
        guard width > 0 && height > 0 else {
            throw ImageError(code: .invalidArgument, message: "width and height must be positive integers")
        }
        guard width <= imageMaxDimension && height <= imageMaxDimension else {
            throw ImageError(code: .dimensionLimit, message: "Image dimensions exceed limit")
        }
        guard options.colorSpace == "srgb" else {
            throw ImageError(code: .unsupportedColorSpace, message: "Unsupported pixel color space: \(options.colorSpace)")
        }
        let stride = options.stride ?? (width * 4)
        guard stride >= width * 4 else {
            throw ImageError(code: .invalidArgument, message: "stride must be at least width * 4")
        }
        let minRequired = (height - 1) * stride + width * 4
        guard pixels.count >= minRequired else {
            throw ImageError(code: .malformedData, message: "Pixel buffer too small: need \(minRequired) bytes, got \(pixels.count)")
        }

        var normalized = Array<UInt8>(repeating: 255, count: width * height * 4)
        let isBGRA = (options.format == .bgra8)
        let forceOpaque = (options.alpha == .opaque)

        for y in 0..<height {
            let srcRow = y * stride
            let dstRow = y * width * 4
            for x in 0..<width {
                let s = srcRow + x * 4
                let d = dstRow + x * 4
                if isBGRA {
                    normalized[d] = pixels[s + 2]
                    normalized[d + 1] = pixels[s + 1]
                    normalized[d + 2] = pixels[s]
                } else {
                    normalized[d] = pixels[s]
                    normalized[d + 1] = pixels[s + 1]
                    normalized[d + 2] = pixels[s + 2]
                }
                normalized[d + 3] = forceOpaque ? 255 : pixels[s + 3]
            }
        }

        let info = ImageInfo(
            width: width,
            height: height,
            format: .rawRgba,
            colorStatus: .explicitSrgb,
            orientation: 1,
            hasAlpha: !forceOpaque
        )
        return NativeImage(pixels: normalized, info: info)
    }

    /// Creates a `NativeImage` from packed 24-bit RGB bytes (`3 * width * height`).
    public static func fromRGB(_ rgb: [UInt8], width: Int, height: Int) throws(ImageError) -> NativeImage {
        guard width > 0 && height > 0, rgb.count >= width * height * 3 else {
            throw ImageError(code: .invalidArgument, message: "Invalid RGB buffer dimensions")
        }
        var rgba = Array<UInt8>(repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[i * 4] = rgb[i * 3]
            rgba[i * 4 + 1] = rgb[i * 3 + 1]
            rgba[i * 4 + 2] = rgb[i * 3 + 2]
            rgba[i * 4 + 3] = 255
        }
        return NativeImage(
            pixels: rgba,
            info: ImageInfo(width: width, height: height, format: .rawRgba, colorStatus: .explicitSrgb, orientation: 1, hasAlpha: false)
        )
    }

    /// Creates a `NativeImage` from 8-bit grayscale bytes (`width * height`).
    public static func fromGrayscale(_ gray: [UInt8], width: Int, height: Int) throws(ImageError) -> NativeImage {
        guard width > 0 && height > 0, gray.count >= width * height else {
            throw ImageError(code: .invalidArgument, message: "Invalid grayscale buffer dimensions")
        }
        var rgba = Array<UInt8>(repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let v = gray[i]
            rgba[i * 4] = v; rgba[i * 4 + 1] = v; rgba[i * 4 + 2] = v; rgba[i * 4 + 3] = 255
        }
        return NativeImage(
            pixels: rgba,
            info: ImageInfo(width: width, height: height, format: .rawRgba, colorStatus: .explicitSrgb, orientation: 1, hasAlpha: false)
        )
    }

    /// Creates a solid-color RGBA image.
    public static func solid(width: Int, height: Int, color: RGBA) throws(ImageError) -> NativeImage {
        guard width > 0 && height > 0 else {
            throw ImageError(code: .invalidArgument, message: "Dimensions must be positive")
        }
        let (r, g, b, a) = color.toInts()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) {
            bytes.append(r); bytes.append(g); bytes.append(b); bytes.append(a)
        }
        return NativeImage(
            pixels: bytes,
            info: ImageInfo(width: width, height: height, format: .rawRgba, colorStatus: .explicitSrgb, orientation: 1, hasAlpha: a < 255)
        )
    }

    // MARK: - Guarded Inspection & Accessors

    private func guardHandle() throws(ImageError) -> NativeImageHandle {
        guard let handle else {
            throw ImageError(code: .invalidHandle, message: "NativeImage is disposed")
        }
        return handle
    }

    public var isDisposed: Bool {
        handle == nil
    }

    // parity: core/src/image.ts#NativeImage.ptr [status=implemented hash=0f5e3d9003d7]
    public func ptr() throws(ImageError) -> NativeImageHandle {
        try guardHandle()
    }

    // parity: core/src/image.ts#NativeImage.info [status=implemented hash=910b9d914d05]
    public func info() throws(ImageError) -> ImageInfo {
        _ = try guardHandle()
        return imageInfo
    }

    // parity: core/src/image.ts#NativeImage.width [status=implemented hash=ac2a5d3d5297]
    public var width: Int {
        handle == nil ? 0 : imageInfo.width
    }

    // parity: core/src/image.ts#NativeImage.height [status=implemented hash=d1c8720704db]
    public var height: Int {
        handle == nil ? 0 : imageInfo.height
    }

    /// Reads an RGBA pixel clamped to valid bounds (returns transparent black if disposed).
    public func pixel(x: Int, y: Int) -> RGBA {
        guard handle != nil, imageInfo.width > 0, imageInfo.height > 0 else {
            return RGBA.fromInts(0, 0, 0, 0)
        }
        let cx = max(0, min(imageInfo.width - 1, x))
        let cy = max(0, min(imageInfo.height - 1, y))
        let idx = (cy * imageInfo.width + cx) * 4
        return RGBA.fromInts(Int(pixels[idx]), Int(pixels[idx + 1]), Int(pixels[idx + 2]), Int(pixels[idx + 3]))
    }

    /// Direct read-only view of internal RGBA8888 bytes.
    public var rgbaBytes: [UInt8] {
        pixels
    }

    internal func updateInPlace(pixels newPixels: [UInt8]) {
        self.pixels = newPixels
        self.cachedPng = nil
    }

    // MARK: - Cloning, Retention & Disposal

    // parity: core/src/image.ts#NativeImage.clone [status=implemented hash=c8c1c69169f7]
    public func clone() throws(ImageError) -> NativeImage {
        _ = try guardHandle()
        return NativeImage(pixels: pixels, info: imageInfo)
    }

    // parity: core/src/image.ts#NativeImage.retain [status=implemented hash=14d501012b85]
    public func retain() throws(ImageError) -> NativeImage {
        _ = try guardHandle()
        retainCount += 1
        return NativeImage(pixels: pixels, info: imageInfo)
    }

    // parity: core/src/image.ts#NativeImage.dispose [status=implemented hash=191c9859f814]
    public func dispose() {
        guard handle != nil else { return }
        handle = nil
        pixels.removeAll()
        cachedPng = nil
        retainCount = 0
    }

    // MARK: - Image Processing Operations

    // parity: core/src/image.ts#NativeImage.resize [status=implemented hash=6e6ee8469baa]
    public func resize(_ options: ResizeOptions) throws(ImageError) -> NativeImage {
        _ = try guardHandle()
        guard options.width != nil || options.height != nil else {
            throw ImageError(code: .invalidArgument, message: "resize requires width, height, or both")
        }
        let srcW = imageInfo.width
        let srcH = imageInfo.height
        var dstW = options.width
        var dstH = options.height
        if let w = dstW, w <= 0 { throw ImageError(code: .invalidArgument, message: "width must be positive") }
        if let h = dstH, h <= 0 { throw ImageError(code: .invalidArgument, message: "height must be positive") }

        if dstW == nil, let h = dstH {
            dstW = max(1, Int((Double(srcW * h) / Double(srcH)).rounded(.toNearestOrAwayFromZero)))
        }
        if dstH == nil, let w = dstW {
            dstH = max(1, Int((Double(srcH * w) / Double(srcW)).rounded(.toNearestOrAwayFromZero)))
        }
        let targetW = dstW!
        let targetH = dstH!
        guard targetW <= imageMaxDimension && targetH <= imageMaxDimension else {
            throw ImageError(code: .dimensionLimit, message: "Target resize dimensions exceed limit")
        }

        let kernel = options.kernel ?? .area
        var out = Array<UInt8>(repeating: 0, count: targetW * targetH * 4)

        switch kernel {
        case .nearest:
            for dy in 0..<targetH {
                let sy = min(srcH - 1, (dy * srcH) / targetH)
                for dx in 0..<targetW {
                    let sx = min(srcW - 1, (dx * srcW) / targetW)
                    let sIdx = (sy * srcW + sx) * 4
                    let dIdx = (dy * targetW + dx) * 4
                    out[dIdx] = pixels[sIdx]
                    out[dIdx + 1] = pixels[sIdx + 1]
                    out[dIdx + 2] = pixels[sIdx + 2]
                    out[dIdx + 3] = pixels[sIdx + 3]
                }
            }

        case .triangle:
            // Bilinear interpolation
            let scaleX = Double(srcW) / Double(targetW)
            let scaleY = Double(srcH) / Double(targetH)
            for dy in 0..<targetH {
                let fy = max(0.0, min(Double(srcH - 1), (Double(dy) + 0.5) * scaleY - 0.5))
                let y0 = Int(fy)
                let y1 = min(srcH - 1, y0 + 1)
                let wy = fy - Double(y0)
                for dx in 0..<targetW {
                    let fx = max(0.0, min(Double(srcW - 1), (Double(dx) + 0.5) * scaleX - 0.5))
                    let x0 = Int(fx)
                    let x1 = min(srcW - 1, x0 + 1)
                    let wx = fx - Double(x0)

                    let i00 = (y0 * srcW + x0) * 4
                    let i10 = (y0 * srcW + x1) * 4
                    let i01 = (y1 * srcW + x0) * 4
                    let i11 = (y1 * srcW + x1) * 4
                    let dIdx = (dy * targetW + dx) * 4

                    for c in 0..<4 {
                        let top = Double(pixels[i00 + c]) * (1.0 - wx) + Double(pixels[i10 + c]) * wx
                        let bot = Double(pixels[i01 + c]) * (1.0 - wx) + Double(pixels[i11 + c]) * wx
                        let val = top * (1.0 - wy) + bot * wy
                        out[dIdx + c] = UInt8(max(0, min(255, Int(val.rounded()))))
                    }
                }
            }

        case .area, .default:
            // Area averaging when downscaling, bilinear when upscaling
            if targetW < srcW || targetH < srcH {
                let scaleX = Double(srcW) / Double(targetW)
                let scaleY = Double(srcH) / Double(targetH)
                for dy in 0..<targetH {
                    let yStart = Double(dy) * scaleY
                    let yEnd = Double(dy + 1) * scaleY
                    let iyStart = max(0, Int(yStart.rounded(.down)))
                    let iyEnd = min(srcH - 1, Int((yEnd - 1e-9).rounded(.down)))
                    for dx in 0..<targetW {
                        let xStart = Double(dx) * scaleX
                        let xEnd = Double(dx + 1) * scaleX
                        let ixStart = max(0, Int(xStart.rounded(.down)))
                        let ixEnd = min(srcW - 1, Int((xEnd - 1e-9).rounded(.down)))

                        var accR = 0.0, accG = 0.0, accB = 0.0, accA = 0.0, wSum = 0.0
                        for sy in iyStart...iyEnd {
                            let wy = min(Double(sy + 1), yEnd) - max(Double(sy), yStart)
                            for sx in ixStart...ixEnd {
                                let wx = min(Double(sx + 1), xEnd) - max(Double(sx), xStart)
                                let w = max(0.0, wx * wy)
                                let sIdx = (sy * srcW + sx) * 4
                                accR += Double(pixels[sIdx]) * w
                                accG += Double(pixels[sIdx + 1]) * w
                                accB += Double(pixels[sIdx + 2]) * w
                                accA += Double(pixels[sIdx + 3]) * w
                                wSum += w
                            }
                        }
                        let dIdx = (dy * targetW + dx) * 4
                        if wSum > 0 {
                            out[dIdx] = UInt8(max(0, min(255, Int((accR / wSum).rounded()))))
                            out[dIdx + 1] = UInt8(max(0, min(255, Int((accG / wSum).rounded()))))
                            out[dIdx + 2] = UInt8(max(0, min(255, Int((accB / wSum).rounded()))))
                            out[dIdx + 3] = UInt8(max(0, min(255, Int((accA / wSum).rounded()))))
                        }
                    }
                }
            } else {
                return try resize(ResizeOptions(width: targetW, height: targetH, kernel: .triangle))
            }

        case .catmullRom, .mitchell, .cubicBspline:
            let (b, c): (Double, Double)
            switch kernel {
            case .catmullRom: (b, c) = (0.0, 0.5)
            case .mitchell: (b, c) = (1.0 / 3.0, 1.0 / 3.0)
            default: (b, c) = (1.0, 0.0)
            }
            let scaleX = Double(srcW) / Double(targetW)
            let scaleY = Double(srcH) / Double(targetH)
            for dy in 0..<targetH {
                let fy = (Double(dy) + 0.5) * scaleY - 0.5
                let iy = Int(fy.rounded(.down))
                for dx in 0..<targetW {
                    let fx = (Double(dx) + 0.5) * scaleX - 0.5
                    let ix = Int(fx.rounded(.down))

                    var acc0 = 0.0, acc1 = 0.0, acc2 = 0.0, acc3 = 0.0, wSum = 0.0
                    for ky in -1...2 {
                        let sy = max(0, min(srcH - 1, iy + ky))
                        let wy = cubicWeight(fy - Double(iy + ky), b: b, c: c)
                        for kx in -1...2 {
                            let sx = max(0, min(srcW - 1, ix + kx))
                            let w = wy * cubicWeight(fx - Double(ix + kx), b: b, c: c)
                            let sIdx = (sy * srcW + sx) * 4
                            acc0 += Double(pixels[sIdx]) * w
                            acc1 += Double(pixels[sIdx + 1]) * w
                            acc2 += Double(pixels[sIdx + 2]) * w
                            acc3 += Double(pixels[sIdx + 3]) * w
                            wSum += w
                        }
                    }
                    let dIdx = (dy * targetW + dx) * 4
                    let inv = wSum != 0 ? (1.0 / wSum) : 1.0
                    out[dIdx] = UInt8(max(0, min(255, Int((acc0 * inv).rounded()))))
                    out[dIdx + 1] = UInt8(max(0, min(255, Int((acc1 * inv).rounded()))))
                    out[dIdx + 2] = UInt8(max(0, min(255, Int((acc2 * inv).rounded()))))
                    out[dIdx + 3] = UInt8(max(0, min(255, Int((acc3 * inv).rounded()))))
                }
            }
        }

        let newInfo = ImageInfo(
            width: targetW,
            height: targetH,
            sourceWidth: imageInfo.sourceWidth,
            sourceHeight: imageInfo.sourceHeight,
            format: imageInfo.format,
            colorStatus: imageInfo.colorStatus,
            orientation: 1,
            hasAlpha: imageInfo.hasAlpha
        )
        return NativeImage(pixels: out, info: newInfo)
    }

    // parity: core/src/image.ts#NativeImage.extract [status=implemented hash=a9d558f2fcd9]
    public func extract(_ options: ExtractOptions) throws(ImageError) -> NativeImage {
        _ = try guardHandle()
        guard options.left >= 0 && options.top >= 0 && options.width > 0 && options.height > 0 else {
            throw ImageError(code: .invalidArgument, message: "extract region requires non-negative origin and positive size")
        }
        guard options.left + options.width <= imageInfo.width && options.top + options.height <= imageInfo.height else {
            throw ImageError(code: .invalidArgument, message: "extract region lies outside source image bounds")
        }

        var out = Array<UInt8>(repeating: 0, count: options.width * options.height * 4)
        let srcW = imageInfo.width
        for y in 0..<options.height {
            let srcStart = ((options.top + y) * srcW + options.left) * 4
            let dstStart = (y * options.width) * 4
            let rowLen = options.width * 4
            for i in 0..<rowLen {
                out[dstStart + i] = pixels[srcStart + i]
            }
        }

        let newInfo = ImageInfo(
            width: options.width,
            height: options.height,
            sourceWidth: imageInfo.sourceWidth,
            sourceHeight: imageInfo.sourceHeight,
            format: imageInfo.format,
            colorStatus: imageInfo.colorStatus,
            orientation: 1,
            hasAlpha: imageInfo.hasAlpha
        )
        return NativeImage(pixels: out, info: newInfo)
    }

    // parity: core/src/image.ts#NativeImage.extend [status=implemented hash=94fa86956353]
    public func extend(_ options: ExtendOptions = ExtendOptions()) throws(ImageError) -> NativeImage {
        _ = try guardHandle()
        guard options.top >= 0 && options.right >= 0 && options.bottom >= 0 && options.left >= 0 else {
            throw ImageError(code: .invalidArgument, message: "extend margins must be non-negative")
        }
        let newW = imageInfo.width + options.left + options.right
        let newH = imageInfo.height + options.top + options.bottom
        guard newW <= imageMaxDimension && newH <= imageMaxDimension else {
            throw ImageError(code: .dimensionLimit, message: "Extended image dimensions exceed limit")
        }

        var out = Array<UInt8>(repeating: 0, count: newW * newH * 4)
        let (br, bg, bb, ba) = options.background
        for i in 0..<(newW * newH) {
            out[i * 4] = br
            out[i * 4 + 1] = bg
            out[i * 4 + 2] = bb
            out[i * 4 + 3] = ba
        }

        for y in 0..<imageInfo.height {
            let srcRow = y * imageInfo.width * 4
            let dstRow = ((y + options.top) * newW + options.left) * 4
            let len = imageInfo.width * 4
            for i in 0..<len {
                out[dstRow + i] = pixels[srcRow + i]
            }
        }

        let newInfo = ImageInfo(
            width: newW,
            height: newH,
            sourceWidth: imageInfo.sourceWidth,
            sourceHeight: imageInfo.sourceHeight,
            format: imageInfo.format,
            colorStatus: imageInfo.colorStatus,
            orientation: 1,
            hasAlpha: imageInfo.hasAlpha || ba < 255
        )
        return NativeImage(pixels: out, info: newInfo)
    }

    // parity: core/src/image.ts#NativeImage.rotate [status=implemented hash=e8bfda76d796]
    public func rotate(_ angle: Int) throws(ImageError) -> NativeImage {
        _ = try guardHandle()
        guard angle == 90 || angle == 180 || angle == 270 else {
            throw ImageError(code: .invalidArgument, message: "angle must be 90, 180, or 270")
        }
        let srcW = imageInfo.width
        let srcH = imageInfo.height
        let dstW = (angle == 180) ? srcW : srcH
        let dstH = (angle == 180) ? srcH : srcW
        var out = Array<UInt8>(repeating: 0, count: dstW * dstH * 4)

        for sy in 0..<srcH {
            for sx in 0..<srcW {
                let dx: Int
                let dy: Int
                switch angle {
                case 90:
                    dx = srcH - 1 - sy
                    dy = sx
                case 180:
                    dx = srcW - 1 - sx
                    dy = srcH - 1 - sy
                default: // 270
                    dx = sy
                    dy = srcW - 1 - sx
                }
                let s = (sy * srcW + sx) * 4
                let d = (dy * dstW + dx) * 4
                out[d] = pixels[s]
                out[d + 1] = pixels[s + 1]
                out[d + 2] = pixels[s + 2]
                out[d + 3] = pixels[s + 3]
            }
        }

        let newInfo = ImageInfo(
            width: dstW,
            height: dstH,
            sourceWidth: imageInfo.sourceWidth,
            sourceHeight: imageInfo.sourceHeight,
            format: imageInfo.format,
            colorStatus: imageInfo.colorStatus,
            orientation: 1,
            hasAlpha: imageInfo.hasAlpha
        )
        return NativeImage(pixels: out, info: newInfo)
    }

    /// Vertical flip (top-to-bottom), matching upstream `NativeImage.flip()`.
    // parity: core/src/image.ts#NativeImage.flip [status=implemented hash=0b03cf1318ee]
    public func flip() throws(ImageError) -> NativeImage {
        _ = try guardHandle()
        let w = imageInfo.width
        let h = imageInfo.height
        let rowLen = w * 4
        var out = Array<UInt8>(repeating: 0, count: pixels.count)
        for y in 0..<h {
            let srcStart = (h - 1 - y) * rowLen
            let dstStart = y * rowLen
            for i in 0..<rowLen {
                out[dstStart + i] = pixels[srcStart + i]
            }
        }
        return NativeImage(pixels: out, info: imageInfo)
    }

    /// Horizontal mirror (left-to-right), matching upstream `NativeImage.flop()`.
    // parity: core/src/image.ts#NativeImage.flop [status=implemented hash=9930c2263605]
    public func flop() throws(ImageError) -> NativeImage {
        _ = try guardHandle()
        let w = imageInfo.width
        let h = imageInfo.height
        var out = Array<UInt8>(repeating: 0, count: pixels.count)
        for y in 0..<h {
            for x in 0..<w {
                let s = (y * w + (w - 1 - x)) * 4
                let d = (y * w + x) * 4
                out[d] = pixels[s]
                out[d + 1] = pixels[s + 1]
                out[d + 2] = pixels[s + 2]
                out[d + 3] = pixels[s + 3]
            }
        }
        return NativeImage(pixels: out, info: imageInfo)
    }

    // parity: core/src/image.ts#NativeImage.composite [status=implemented hash=c4ea3ccb0650]
    public func composite(_ overlay: NativeImage, options: CompositeOptions = CompositeOptions()) throws(ImageError) -> NativeImage {
        _ = try guardHandle()
        _ = try overlay.guardHandle()
        guard options.opacity.isFinite && options.opacity >= 0.0 && options.opacity <= 1.0 else {
            throw ImageError(code: .invalidArgument, message: "opacity must be between 0 and 1")
        }

        let dstW = imageInfo.width
        let dstH = imageInfo.height
        let srcW = overlay.imageInfo.width
        let srcH = overlay.imageInfo.height
        var out = pixels

        let opacityScale = options.opacity

        for sy in 0..<srcH {
            let dy = sy + options.top
            guard dy >= 0 && dy < dstH else { continue }
            for sx in 0..<srcW {
                let dx = sx + options.left
                guard dx >= 0 && dx < dstW else { continue }

                let sIdx = (sy * srcW + sx) * 4
                let dIdx = (dy * dstW + dx) * 4

                let sr = Double(overlay.pixels[sIdx])
                let sg = Double(overlay.pixels[sIdx + 1])
                let sb = Double(overlay.pixels[sIdx + 2])
                let sa = (Double(overlay.pixels[sIdx + 3]) / 255.0) * opacityScale

                let dr = Double(out[dIdx])
                let dg = Double(out[dIdx + 1])
                let db = Double(out[dIdx + 2])
                let da = Double(out[dIdx + 3]) / 255.0

                let rr: Double
                let rg: Double
                let rb: Double
                let ra: Double

                switch options.blend {
                case .source:
                    rr = sr; rg = sg; rb = sb; ra = sa
                case .sourceOver:
                    ra = sa + da * (1.0 - sa)
                    if ra > 0 {
                        rr = (sr * sa + dr * da * (1.0 - sa)) / ra
                        rg = (sg * sa + dg * da * (1.0 - sa)) / ra
                        rb = (sb * sa + db * da * (1.0 - sa)) / ra
                    } else {
                        rr = 0; rg = 0; rb = 0
                    }
                case .destinationOver:
                    ra = da + sa * (1.0 - da)
                    if ra > 0 {
                        rr = (dr * da + sr * sa * (1.0 - da)) / ra
                        rg = (dg * da + sg * sa * (1.0 - da)) / ra
                        rb = (db * da + sb * sa * (1.0 - da)) / ra
                    } else {
                        rr = 0; rg = 0; rb = 0
                    }
                }

                out[dIdx] = UInt8(max(0, min(255, Int(rr.rounded()))))
                out[dIdx + 1] = UInt8(max(0, min(255, Int(rg.rounded()))))
                out[dIdx + 2] = UInt8(max(0, min(255, Int(rb.rounded()))))
                out[dIdx + 3] = UInt8(max(0, min(255, Int((ra * 255.0).rounded()))))
            }
        }

        let newInfo = ImageInfo(
            width: dstW,
            height: dstH,
            sourceWidth: imageInfo.sourceWidth,
            sourceHeight: imageInfo.sourceHeight,
            format: imageInfo.format,
            colorStatus: imageInfo.colorStatus,
            orientation: 1,
            hasAlpha: imageInfo.hasAlpha || overlay.imageInfo.hasAlpha
        )
        return NativeImage(pixels: out, info: newInfo)
    }

    // MARK: - Encoding & Raw Pixel Export

    // parity: core/src/image.ts#NativeImage.ensureEncodedPng [status=implemented hash=d2a2e317543b]
    public func ensureEncodedPng() throws(ImageError) {
        _ = try guardHandle()
        if cachedPng == nil {
            cachedPng = PureImageCodec.encodeUncompressedPNG(width: imageInfo.width, height: imageInfo.height, rgba: pixels)
        }
    }

    /// Returns cached or freshly encoded uncompressed PNG bytes.
    public func encodePNG() throws(ImageError) -> [UInt8] {
        try ensureEncodedPng()
        return cachedPng ?? []
    }

    /// Encodes the image as a binary P6 PPM byte buffer.
    public func encodePPM() throws(ImageError) -> [UInt8] {
        _ = try guardHandle()
        return PureImageCodec.encodePPM(width: imageInfo.width, height: imageInfo.height, rgba: pixels)
    }

    /// Encodes the image as an uncompressed 24-bit or 32-bit BMP byte buffer.
    public func encodeBMP(includeAlpha: Bool = true) throws(ImageError) -> [UInt8] {
        _ = try guardHandle()
        return PureImageCodec.encodeBMP(width: imageInfo.width, height: imageInfo.height, rgba: pixels, includeAlpha: includeAlpha)
    }

    // parity: core/src/image.ts#NativeImage.raw [status=implemented hash=8b44870ab5eb]
    public func raw(format: PixelFormat = .rgba8) throws(ImageError) -> RawImage {
        _ = try guardHandle()
        let stride = imageInfo.width * 4
        var out = Array<UInt8>(repeating: 0, count: stride * imageInfo.height)
        try copyTo(&out, stride: stride, format: format)
        return RawImage(
            data: out,
            width: imageInfo.width,
            height: imageInfo.height,
            stride: stride,
            format: format,
            colorSpace: "srgb",
            alpha: .straight
        )
    }

    // parity: core/src/image.ts#NativeImage.takeRaw [status=implemented hash=1e96a120f86b]
    public func takeRaw() throws(ImageError) -> OwnedRawImage {
        _ = try guardHandle()
        guard retainCount <= 1 else {
            throw ImageError(code: .busy, message: "Cannot transfer image pixels while native buffers retain the image")
        }
        let owned = OwnedRawImage(
            data: pixels,
            width: imageInfo.width,
            height: imageInfo.height,
            stride: imageInfo.width * 4
        )
        dispose()
        return owned
    }

    // parity: core/src/image.ts#NativeImage.copyTo [status=implemented hash=002f17814763]
    public func copyTo(_ destination: inout [UInt8], stride: Int? = nil, format: PixelFormat = .rgba8) throws(ImageError) {
        _ = try guardHandle()
        let targetStride = stride ?? (imageInfo.width * 4)
        guard targetStride >= imageInfo.width * 4 else {
            throw ImageError(code: .invalidArgument, message: "stride must be at least width * 4")
        }
        let required = (imageInfo.height - 1) * targetStride + imageInfo.width * 4
        guard destination.count >= required else {
            throw ImageError(code: .outputTooSmall, message: "Destination buffer too small: need \(required), got \(destination.count)")
        }

        let isBGRA = (format == .bgra8)
        for y in 0..<imageInfo.height {
            let srcRow = y * imageInfo.width * 4
            let dstRow = y * targetStride
            for x in 0..<imageInfo.width {
                let s = srcRow + x * 4
                let d = dstRow + x * 4
                if isBGRA {
                    destination[d] = pixels[s + 2]
                    destination[d + 1] = pixels[s + 1]
                    destination[d + 2] = pixels[s]
                    destination[d + 3] = pixels[s + 3]
                } else {
                    destination[d] = pixels[s]
                    destination[d + 1] = pixels[s + 1]
                    destination[d + 2] = pixels[s + 2]
                    destination[d + 3] = pixels[s + 3]
                }
            }
        }
    }
}

// MARK: - NativeImagePool

/// Configuration options for `NativeImagePool`.
// parity: core/src/image.ts#NativeImagePoolOptions [status=implemented hash=83f86361118a]
public struct NativeImagePoolOptions: Equatable, Hashable, Sendable {
    public var ownerId: String?
    public var width: Int
    public var height: Int
    public var capacity: Int

    public init(ownerId: String? = nil, width: Int, height: Int, capacity: Int = 3) {
        self.ownerId = ownerId
        self.width = width
        self.height = height
        self.capacity = capacity
    }
}

/// Bounded pool of reusable fixed-size `NativeImage` buffers for streaming/video frame publishing.
// parity: core/src/image.ts#NativeImagePool [status=implemented hash=f65f9964cd38]
public final class NativeImagePool: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let capacity: Int

    private let ownerId: String?
    private var slots: [NativeImage] = []
    private var nextSlotIndex: Int = 0
    private var disposed: Bool = false

    public init(options: NativeImagePoolOptions) throws(ImageError) {
        guard options.width > 0 && options.height > 0 else {
            throw ImageError(code: .invalidArgument, message: "Pool width and height must be positive")
        }
        guard options.capacity >= 1 && options.capacity <= 8 else {
            throw ImageError(code: .invalidArgument, message: "capacity must be between 1 and 8")
        }
        self.ownerId = options.ownerId
        self.width = options.width
        self.height = options.height
        self.capacity = options.capacity
    }

    // parity: core/src/image.ts#NativeImagePool.publishRgba [status=implemented hash=7aba2ac485bb]
    public func publishRgba(_ pixels: [UInt8], stride: Int? = nil) throws(ImageError) -> NativeImage? {
        try publishPixels(pixels, options: PixelImportOptions(ownerId: ownerId, stride: stride ?? width * 4))
    }

    // parity: core/src/image.ts#NativeImagePool.publishPixels [status=implemented hash=70eda410250c]
    public func publishPixels(_ pixels: [UInt8], options: PixelImportOptions = PixelImportOptions()) throws(ImageError) -> NativeImage? {
        guard !disposed else {
            throw ImageError(code: .invalidHandle, message: "NativeImagePool is disposed")
        }

        let imported = try NativeImage.fromPixels(pixels, width: width, height: height, options: options)
        if slots.count < capacity {
            slots.append(imported)
            return try imported.clone()
        }

        // Reuse the next non-busy slot in round-robin order
        for step in 0..<slots.count {
            let idx = (nextSlotIndex + step) % slots.count
            let slot = slots[idx]
            if slot.retainCount <= 1 {
                slot.updateInPlace(pixels: imported.rgbaBytes)
                nextSlotIndex = (idx + 1) % slots.count
                return try slot.clone()
            }
        }

        return nil
    }

    // parity: core/src/image.ts#NativeImagePool.dispose [status=implemented hash=1c10b195c185]
    public func dispose() {
        guard !disposed else { return }
        for image in slots {
            image.dispose()
        }
        slots.removeAll()
        disposed = true
    }
}

// MARK: - Kitty Graphics Protocol Chunked APC Encoder

/// Transmission payload format for `KittyImageEncoder`.
public enum KittyPayloadFormat: Int, Equatable, Hashable, Sendable {
    case rgba32 = 32
    case png = 100
}

/// Pure-Swift Kitty Graphics Protocol APC encoder (`\u{1B}_G...;\u{1B}\\`).
public enum KittyImageEncoder {
    /// Encodes a `NativeImage` into one or more Kitty Graphics Protocol APC chunks.
    public static func encode(
        _ image: NativeImage,
        format: KittyPayloadFormat = .rgba32,
        cols: Int? = nil,
        rows: Int? = nil,
        imageId: UInt32? = nil,
        placementId: UInt32? = nil,
        quiet: Int = 2,
        chunkSize: Int = 4096
    ) throws(ImageError) -> String {
        let info = try image.info()
        let rawBytes: [UInt8]
        switch format {
        case .rgba32:
            rawBytes = image.rgbaBytes
        case .png:
            rawBytes = try image.encodePNG()
        }

        let payload = encodeImageBase64(rawBytes)
        let payloadBytes = Array(payload.utf8)
        let safeChunkSize = max(4, chunkSize)

        var params: [String] = ["a=T", "f=\(format.rawValue)"]
        if format == .rgba32 {
            params.append("s=\(info.width)")
            params.append("v=\(info.height)")
        }
        if let cols, cols > 0 { params.append("c=\(cols)") }
        if let rows, rows > 0 { params.append("r=\(rows)") }
        if let imageId, imageId > 0 { params.append("i=\(imageId)") }
        if let placementId, placementId > 0 { params.append("p=\(placementId)") }
        if quiet > 0 { params.append("q=\(quiet)") }

        if payloadBytes.count <= safeChunkSize {
            params.append("m=0")
            return "\u{1B}_G\(params.joined(separator: ","));\(payload)\u{1B}\\"
        }

        var output = ""
        var offset = 0
        var isFirst = true
        while offset < payloadBytes.count {
            let end = min(offset + safeChunkSize, payloadBytes.count)
            let hasMore = end < payloadBytes.count
            let chunkStr = String(decoding: payloadBytes[offset..<end], as: UTF8.self)
            if isFirst {
                var firstParams = params
                firstParams.append("m=\(hasMore ? 1 : 0)")
                output.append("\u{1B}_G\(firstParams.joined(separator: ","));\(chunkStr)\u{1B}\\")
                isFirst = false
            } else {
                output.append("\u{1B}_Gm=\(hasMore ? 1 : 0);\(chunkStr)\u{1B}\\")
            }
            offset = end
        }
        return output
    }

    /// Encodes a Kitty Graphics Protocol delete command (`a=d`).
    public static func delete(imageId: UInt32? = nil, quiet: Int = 2) -> String {
        var params = ["a=d"]
        if let imageId, imageId > 0 {
            params.append("d=I")
            params.append("i=\(imageId)")
        } else {
            params.append("d=a")
        }
        if quiet > 0 { params.append("q=\(quiet)") }
        return "\u{1B}_G\(params.joined(separator: ","))\u{1B}\\"
    }
}

// MARK: - Sixel Palette Quantization & RLE Encoder

/// Pure-Swift Sixel DCS image encoder with palette quantization (up to 256 colors)
/// and `!count<char>` run-length encoding.
public enum SixelEncoder {
    private struct PaletteColor: Hashable {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    /// Encodes a `NativeImage` into a Sixel DCS escape sequence (`\u{1B}Pq...\u{1B}\\`).
    public static func encode(
        _ image: NativeImage,
        maxColors: Int = 256,
        alphaThreshold: UInt8 = 128
    ) throws(ImageError) -> String {
        let info = try image.info()
        let w = info.width
        let h = info.height
        let rgba = image.rgbaBytes
        let colorLimit = max(2, min(256, maxColors))

        // Step 1: Collect unique visible colors; quantize to 6x6x6 + grayscale or median-cut if exceeding limit
        var uniqueMap: [PaletteColor: Int] = [:]
        var palette: [PaletteColor] = []
        var exceededExact = false

        for i in 0..<(w * h) {
            let a = rgba[i * 4 + 3]
            if a < alphaThreshold { continue }
            let color = PaletteColor(r: rgba[i * 4], g: rgba[i * 4 + 1], b: rgba[i * 4 + 2])
            if uniqueMap[color] == nil {
                if palette.count >= colorLimit {
                    exceededExact = true
                    break
                }
                uniqueMap[color] = palette.count
                palette.append(color)
            }
        }

        var pixelIndices = Array<Int>(repeating: -1, count: w * h)

        if !exceededExact {
            for i in 0..<(w * h) {
                guard rgba[i * 4 + 3] >= alphaThreshold else { continue }
                let color = PaletteColor(r: rgba[i * 4], g: rgba[i * 4 + 1], b: rgba[i * 4 + 2])
                pixelIndices[i] = uniqueMap[color] ?? -1
            }
        } else {
            // Quantize via uniform RGB levels fitting within colorLimit
            let levels: Int
            if colorLimit >= 216 {
                levels = 6 // 6x6x6 = 216 colors
            } else if colorLimit >= 64 {
                levels = 4 // 4x4x4 = 64 colors
            } else if colorLimit >= 27 {
                levels = 3 // 3x3x3 = 27 colors
            } else {
                levels = 2 // 2x2x2 = 8 colors
            }

            palette.removeAll()
            var usedSlot = Array<Int>(repeating: -1, count: levels * levels * levels)
            let denom = max(1, levels - 1)

            for i in 0..<(w * h) {
                guard rgba[i * 4 + 3] >= alphaThreshold else { continue }
                let qr = (Int(rgba[i * 4]) * denom + 127) / 255
                let qg = (Int(rgba[i * 4 + 1]) * denom + 127) / 255
                let qb = (Int(rgba[i * 4 + 2]) * denom + 127) / 255
                let bucket = (qr * levels + qg) * levels + qb
                if usedSlot[bucket] == -1 {
                    let idx = palette.count
                    usedSlot[bucket] = idx
                    palette.append(
                        PaletteColor(
                            r: UInt8((qr * 255) / denom),
                            g: UInt8((qg * 255) / denom),
                            b: UInt8((qb * 255) / denom)
                        )
                    )
                }
                pixelIndices[i] = usedSlot[bucket]
            }
        }

        // Step 2: Emit DCS header, raster attributes, and palette registers
        var out = "\u{1B}P0;1;0q\"1;1;\(w);\(h)"
        for (index, c) in palette.enumerated() {
            let rPct = (Int(c.r) * 100 + 127) / 255
            let gPct = (Int(c.g) * 100 + 127) / 255
            let bPct = (Int(c.b) * 100 + 127) / 255
            out.append("#\(index);2;\(rPct);\(gPct);\(bPct)")
        }

        // Step 3: Emit 6-pixel-tall bands with RLE compression
        let bandCount = (h + 5) / 6
        var colorMasks = Array<UInt8>(repeating: 0, count: w)

        for band in 0..<bandCount {
            let yBase = band * 6
            let bandRows = min(6, h - yBase)

            // Collect which palette indices appear in this band
            var presentColors: [Int] = []
            var seen = Array<Bool>(repeating: false, count: palette.count)
            for row in 0..<bandRows {
                let rowOffset = (yBase + row) * w
                for x in 0..<w {
                    let cIdx = pixelIndices[rowOffset + x]
                    if cIdx >= 0 && !seen[cIdx] {
                        seen[cIdx] = true
                        presentColors.append(cIdx)
                    }
                }
            }

            for (pos, colorIdx) in presentColors.enumerated() {
                var lastNonZeroX = -1
                for x in 0..<w {
                    var mask: UInt8 = 0
                    for row in 0..<bandRows {
                        if pixelIndices[(yBase + row) * w + x] == colorIdx {
                            mask |= (1 << UInt8(row))
                        }
                    }
                    colorMasks[x] = mask
                    if mask != 0 {
                        lastNonZeroX = x
                    }
                }
                guard lastNonZeroX >= 0 else { continue }

                out.append("#\(colorIdx)")
                var x = 0
                while x <= lastNonZeroX {
                    let mask = colorMasks[x]
                    var runLen = 1
                    while x + runLen <= lastNonZeroX && colorMasks[x + runLen] == mask {
                        runLen += 1
                    }
                    let sixelChar = Character(UnicodeScalar(63 + Int(mask))!)
                    if runLen >= 4 {
                        out.append("!\(runLen)\(sixelChar)")
                    } else {
                        for _ in 0..<runLen {
                            out.append(sixelChar)
                        }
                    }
                    x += runLen
                }

                if pos + 1 < presentColors.count {
                    out.append("$") // graphics carriage return for next color in same band
                }
            }

            if band + 1 < bandCount {
                out.append("-") // graphics newline for next 6-row band
            }
        }

        out.append("\u{1B}\\")
        return out
    }
}

// MARK: - Terminal Cell Rasterizers (Half-Block, Quadrant-Block, Braille -> OptimizedBuffer)

/// Unicode cell rasterizer modes for drawing `NativeImage` directly into an `OptimizedBuffer`.
public enum ImageRasterMode: String, Equatable, Hashable, Sendable, CaseIterable {
    case halfBlock
    case quadrant
    case braille
}

private let halfBlockUpper: UInt32 = 0x2580 // '▀'
private let halfBlockLower: UInt32 = 0x2584 // '▄'
private let halfBlockFull: UInt32 = 0x2588  // '█'

/// 16 Unicode quadrant block scalars indexed by 4-bit mask:
/// bit 0 = top-left, bit 1 = top-right, bit 2 = bottom-left, bit 3 = bottom-right.
private let quadrantBlockChars: [UInt32] = [
    0x0020, // 0000 ' '
    0x2598, // 0001 '▘'
    0x259D, // 0010 '▝'
    0x2580, // 0011 '▀'
    0x2596, // 0100 '▖'
    0x258C, // 0101 '▌'
    0x259E, // 0110 '▞'
    0x259B, // 0111 '▛'
    0x2597, // 1000 '▗'
    0x259A, // 1001 '▚'
    0x2590, // 1010 '▐'
    0x259C, // 1011 '▜'
    0x2584, // 1100 '▄'
    0x2599, // 1101 '▙'
    0x259F, // 1110 '▟'
    0x2588, // 1111 '█'
]

/// Braille dot bit positions for a 2x4 subpixel cell `(col in 0..<2, row in 0..<4)`.
private let brailleDotBits: [[UInt32]] = [
    [0x01, 0x08], // row 0: dot 1, dot 4
    [0x02, 0x10], // row 1: dot 2, dot 5
    [0x04, 0x20], // row 2: dot 3, dot 6
    [0x40, 0x80], // row 3: dot 7, dot 8
]

/// Pure-Swift rasterizer drawing `NativeImage` directly into an `OptimizedBuffer` using
/// Unicode half-blocks (1×2), quadrant blocks (2×2), or Braille patterns (2×4).
public enum ImageBufferRasterizer {
    /// Draws `image` into `buffer` using the specified Unicode raster mode.
    public static func render(
        _ image: NativeImage,
        into buffer: OptimizedBuffer,
        x: Int = 0,
        y: Int = 0,
        width: Int? = nil,
        height: Int? = nil,
        mode: ImageScaleMode = .fit,
        rasterMode: ImageRasterMode = .halfBlock,
        cellAspectRatio: Double = 2.0,
        brailleThreshold: UInt8 = 128
    ) {
        let boxW = width ?? max(0, buffer.width - x)
        let boxH = height ?? max(0, buffer.height - y)
        switch rasterMode {
        case .halfBlock:
            renderHalfBlocks(image, into: buffer, x: x, y: y, width: boxW, height: boxH, mode: mode, cellAspectRatio: cellAspectRatio)
        case .quadrant:
            renderQuadrants(image, into: buffer, x: x, y: y, width: boxW, height: boxH, mode: mode, cellAspectRatio: cellAspectRatio)
        case .braille:
            renderBraille(image, into: buffer, x: x, y: y, width: boxW, height: boxH, mode: mode, threshold: brailleThreshold, cellAspectRatio: cellAspectRatio)
        }
    }

    /// Renders `image` using true-color Unicode half-blocks (`▀`, `▄`, `█`) at 1×2 subpixel resolution per cell.
    public static func renderHalfBlocks(
        _ image: NativeImage,
        into buffer: OptimizedBuffer,
        x originX: Int = 0,
        y originY: Int = 0,
        width boxWidth: Int,
        height boxHeight: Int,
        mode: ImageScaleMode = .fit,
        cellAspectRatio: Double = 2.0
    ) {
        guard !image.isDisposed, image.width > 0, image.height > 0, boxWidth > 0, boxHeight > 0 else { return }

        let layout = computeImageAspectLayout(
            sourceWidth: image.width,
            sourceHeight: image.height,
            targetWidth: boxWidth,
            targetHeight: boxHeight,
            mode: mode,
            cellAspectRatio: cellAspectRatio
        )
        guard layout.destWidth > 0 && layout.destHeight > 0 else { return }

        let destX = originX + layout.offsetX
        let destY = originY + layout.offsetY
        let crop = layout.sourceCrop
        let totalVirtualRows = layout.destHeight * 2
        let transparent = RGBA.fromInts(0, 0, 0, 0)

        for cellRow in 0..<layout.destHeight {
            let by = destY + cellRow
            guard by >= 0 && by < buffer.height else { continue }
            let pyTop = crop.top + min(crop.height - 1, (cellRow * 2 * crop.height) / totalVirtualRows)
            let pyBot = crop.top + min(crop.height - 1, ((cellRow * 2 + 1) * crop.height) / totalVirtualRows)

            for cellCol in 0..<layout.destWidth {
                let bx = destX + cellCol
                guard bx >= 0 && bx < buffer.width else { continue }
                let px = crop.left + min(crop.width - 1, (cellCol * crop.width) / layout.destWidth)

                let topColor = image.pixel(x: px, y: pyTop)
                let botColor = image.pixel(x: px, y: pyBot)
                let topA = topColor.toInts().3
                let botA = botColor.toInts().3

                if topA == 0 && botA == 0 {
                    continue
                } else if topA > 0 && botA == 0 {
                    buffer.drawChar(halfBlockUpper, x: bx, y: by, fg: topColor, bg: transparent)
                } else if topA == 0 && botA > 0 {
                    buffer.drawChar(halfBlockLower, x: bx, y: by, fg: botColor, bg: transparent)
                } else if topColor == botColor {
                    buffer.drawChar(halfBlockFull, x: bx, y: by, fg: topColor, bg: botColor)
                } else {
                    buffer.drawChar(halfBlockUpper, x: bx, y: by, fg: topColor, bg: botColor)
                }
            }
        }
    }

    /// Renders `image` using Unicode 2×2 quadrant block characters (`▘`, `▝`, `▖`, `▗`, `▌`, `▐`, `▀`, `▄`, `▛`, `▜`, `▙`, `▟`, `▞`, `▚`, `█`)
    /// choosing the minimum-error 2-color partition for every 2×2 subpixel cell.
    public static func renderQuadrants(
        _ image: NativeImage,
        into buffer: OptimizedBuffer,
        x originX: Int = 0,
        y originY: Int = 0,
        width boxWidth: Int,
        height boxHeight: Int,
        mode: ImageScaleMode = .fit,
        cellAspectRatio: Double = 2.0
    ) {
        guard !image.isDisposed, image.width > 0, image.height > 0, boxWidth > 0, boxHeight > 0 else { return }

        let layout = computeImageAspectLayout(
            sourceWidth: image.width,
            sourceHeight: image.height,
            targetWidth: boxWidth,
            targetHeight: boxHeight,
            mode: mode,
            cellAspectRatio: cellAspectRatio
        )
        guard layout.destWidth > 0 && layout.destHeight > 0 else { return }

        let destX = originX + layout.offsetX
        let destY = originY + layout.offsetY
        let crop = layout.sourceCrop
        let virtualW = layout.destWidth * 2
        let virtualH = layout.destHeight * 2

        for cellRow in 0..<layout.destHeight {
            let by = destY + cellRow
            guard by >= 0 && by < buffer.height else { continue }
            let py0 = crop.top + min(crop.height - 1, (cellRow * 2 * crop.height) / virtualH)
            let py1 = crop.top + min(crop.height - 1, ((cellRow * 2 + 1) * crop.height) / virtualH)

            for cellCol in 0..<layout.destWidth {
                let bx = destX + cellCol
                guard bx >= 0 && bx < buffer.width else { continue }
                let px0 = crop.left + min(crop.width - 1, (cellCol * 2 * crop.width) / virtualW)
                let px1 = crop.left + min(crop.width - 1, ((cellCol * 2 + 1) * crop.width) / virtualW)

                let samples = [
                    image.pixel(x: px0, y: py0).toInts(),
                    image.pixel(x: px1, y: py0).toInts(),
                    image.pixel(x: px0, y: py1).toInts(),
                    image.pixel(x: px1, y: py1).toInts(),
                ]

                if samples.allSatisfy({ $0.3 == 0 }) { continue }

                var bestMask = 15
                var bestError = Int.max
                var bestFg = RGBA.fromInts(Int(samples[0].0), Int(samples[0].1), Int(samples[0].2), 255)
                var bestBg = bestFg

                for mask in 1...15 {
                    var fgR = 0, fgG = 0, fgB = 0, fgN = 0
                    var bgR = 0, bgG = 0, bgB = 0, bgN = 0
                    for bit in 0..<4 {
                        let s = samples[bit]
                        if (mask & (1 << bit)) != 0 {
                            fgR += Int(s.0); fgG += Int(s.1); fgB += Int(s.2); fgN += 1
                        } else {
                            bgR += Int(s.0); bgG += Int(s.1); bgB += Int(s.2); bgN += 1
                        }
                    }
                    let fR = fgN > 0 ? fgR / fgN : 0
                    let fG = fgN > 0 ? fgG / fgN : 0
                    let fB = fgN > 0 ? fgB / fgN : 0
                    let bR = bgN > 0 ? bgR / bgN : fR
                    let bG = bgN > 0 ? bgG / bgN : fG
                    let bB = bgN > 0 ? bgB / bgN : fB

                    var err = 0
                    for bit in 0..<4 {
                        let s = samples[bit]
                        let isFg = (mask & (1 << bit)) != 0
                        let dr = Int(s.0) - (isFg ? fR : bR)
                        let dg = Int(s.1) - (isFg ? fG : bG)
                        let db = Int(s.2) - (isFg ? fB : bB)
                        err += dr * dr + dg * dg + db * db
                    }
                    if err < bestError {
                        bestError = err
                        bestMask = mask
                        bestFg = RGBA.fromInts(fR, fG, fB, 255)
                        bestBg = RGBA.fromInts(bR, bG, bB, 255)
                    }
                }

                buffer.drawChar(quadrantBlockChars[bestMask], x: bx, y: by, fg: bestFg, bg: bestBg)
            }
        }
    }

    /// Renders `image` using 2×4 Unicode Braille patterns (`U+2800..U+28FF`), thresholding
    /// per-subpixel luminance and coloring each cell with average lit/unlit colors.
    public static func renderBraille(
        _ image: NativeImage,
        into buffer: OptimizedBuffer,
        x originX: Int = 0,
        y originY: Int = 0,
        width boxWidth: Int,
        height boxHeight: Int,
        mode: ImageScaleMode = .fit,
        threshold: UInt8 = 128,
        cellAspectRatio: Double = 2.0
    ) {
        guard !image.isDisposed, image.width > 0, image.height > 0, boxWidth > 0, boxHeight > 0 else { return }

        let layout = computeImageAspectLayout(
            sourceWidth: image.width,
            sourceHeight: image.height,
            targetWidth: boxWidth,
            targetHeight: boxHeight,
            mode: mode,
            cellAspectRatio: cellAspectRatio
        )
        guard layout.destWidth > 0 && layout.destHeight > 0 else { return }

        let destX = originX + layout.offsetX
        let destY = originY + layout.offsetY
        let crop = layout.sourceCrop
        let virtualW = layout.destWidth * 2
        let virtualH = layout.destHeight * 4
        let thresholdInt = Int(threshold)

        for cellRow in 0..<layout.destHeight {
            let by = destY + cellRow
            guard by >= 0 && by < buffer.height else { continue }

            for cellCol in 0..<layout.destWidth {
                let bx = destX + cellCol
                guard bx >= 0 && bx < buffer.width else { continue }

                var pattern: UInt32 = 0
                var onR = 0, onG = 0, onB = 0, onCount = 0
                var offR = 0, offG = 0, offB = 0, offCount = 0

                for subY in 0..<4 {
                    let py = crop.top + min(crop.height - 1, ((cellRow * 4 + subY) * crop.height) / virtualH)
                    for subX in 0..<2 {
                        let px = crop.left + min(crop.width - 1, ((cellCol * 2 + subX) * crop.width) / virtualW)
                        let (r, g, b, a) = image.pixel(x: px, y: py).toInts()
                        let luma = (Int(r) * 299 + Int(g) * 587 + Int(b) * 114) / 1000
                        if a >= 128 && luma >= thresholdInt {
                            pattern |= brailleDotBits[subY][subX]
                            onR += Int(r); onG += Int(g); onB += Int(b); onCount += 1
                        } else {
                            offR += Int(r); offG += Int(g); offB += Int(b); offCount += 1
                        }
                    }
                }

                let fg = onCount > 0
                    ? RGBA.fromInts(onR / onCount, onG / onCount, onB / onCount, 255)
                    : RGBA.fromInts(0, 0, 0, 255)
                let bg = offCount > 0
                    ? RGBA.fromInts(offR / offCount, offG / offCount, offB / offCount, 255)
                    : RGBA.fromInts(0, 0, 0, 0)

                buffer.drawChar(0x2800 + pattern, x: bx, y: by, fg: fg, bg: bg)
            }
        }
    }
}
