import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout

// MARK: - Image & Pixel Buffer Primitives

/// How an image or video frame scales into its renderable box.
// parity: core/src/renderables/Image.ts#ImageFit [status=implemented hash=9a41f1926992]
public enum ImageFit: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case fit
    case cover
    case fill
}

/// Pixel crop rectangle in source image coordinates.
public struct ImageExtractOptions: Equatable, Hashable, Sendable, Codable {
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

/// Validation errors thrown by `checkCrop` and `VideoRenderable` option setters.
public enum MediaRenderableError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case invalidCrop(String)
    case invalidPixelBuffer(String)
    case invalidVolume(Double)
    case invalidAvSyncOffset(Double)
    case invalidMaxFps(Int)
    case invalidTime(String)

    public var description: String {
        switch self {
        case .invalidCrop(let msg): return msg
        case .invalidPixelBuffer(let msg): return msg
        case .invalidVolume(let v): return "volume must be finite and non-negative: \(v)"
        case .invalidAvSyncOffset(let v): return "avSyncOffsetMs must be between -60000 and 60000: \(v)"
        case .invalidMaxFps(let v): return "maxFps must be an integer from 1 to 120: \(v)"
        case .invalidTime(let msg): return msg
        }
    }
}

/// Pure-Swift RGBA8888 pixel buffer (`4 * width * height` bytes in row-major `[R, G, B, A]` order).
public struct PixelImage: Equatable, Hashable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) throws(MediaRenderableError) {
        guard width > 0 && height > 0 else {
            throw .invalidPixelBuffer("Image dimensions must be positive (\(width)x\(height))")
        }
        let expected = width * height * 4
        guard pixels.count == expected else {
            throw .invalidPixelBuffer("Expected \(expected) RGBA bytes for \(width)x\(height), got \(pixels.count)")
        }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Creates a solid-colored `width x height` RGBA pixel image.
    public static func solid(width: Int, height: Int, color: RGBA) -> PixelImage {
        let w = max(1, width)
        let h = max(1, height)
        let (r, g, b, a) = color.toInts()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(w * h * 4)
        for _ in 0..<(w * h) {
            bytes.append(r)
            bytes.append(g)
            bytes.append(b)
            bytes.append(a)
        }
        return try! PixelImage(width: w, height: h, pixels: bytes)
    }

    /// Returns the `RGBA` pixel at `(x, y)` clamped to valid bounds.
    public func pixel(x: Int, y: Int) -> RGBA {
        let cx = max(0, min(width - 1, x))
        let cy = max(0, min(height - 1, y))
        let idx = (cy * width + cx) * 4
        return RGBA.fromInts(Int(pixels[idx]), Int(pixels[idx + 1]), Int(pixels[idx + 2]), Int(pixels[idx + 3]))
    }

    /// Updates the pixel at `(x, y)` if inside bounds.
    public mutating func setPixel(x: Int, y: Int, color: RGBA) {
        guard x >= 0 && x < width && y >= 0 && y < height else { return }
        let idx = (y * width + x) * 4
        let (r, g, b, a) = color.toInts()
        pixels[idx] = r
        pixels[idx + 1] = g
        pixels[idx + 2] = b
        pixels[idx + 3] = a
    }
}

/// Source accepted by `ImageRenderable`.
// parity: core/src/renderables/Image.ts#ImageRenderableSource [status=implemented hash=aca9213628b5]
public enum ImageRenderableSource: Equatable, Hashable, Sendable {
    case pixelImage(PixelImage)
    case rgba(width: Int, height: Int, pixels: [UInt8])
}

/// Resolves the active image rendering protocol given user preference, terminal capabilities,
/// and whether cell pixel resolution is known.
// parity: core/src/renderables/Image.ts#resolveImageRenderProtocol [status=implemented hash=2c8db1f6a883]
public func resolveImageRenderProtocol(
    requested: ImageRenderProtocol,
    capabilities: TerminalCapabilities?,
    hasResolution: Bool
) -> ImageRenderProtocol {
    if requested != .auto {
        return (requested == .sixel && !hasResolution) ? .blocks : requested
    }
    let configured = capabilities?.imageProtocol ?? .auto
    if configured != .auto {
        return (configured == .sixel && !hasResolution) ? .blocks : configured
    }
    guard let capabilities, capabilities.multiplexer != .tmux else {
        return .blocks
    }
    if capabilities.kittyGraphics {
        return .kitty
    }
    if capabilities.sixel && hasResolution {
        return .sixel
    }
    return .blocks
}

/// Validates a pixel crop rectangle against optional source dimensions.
// parity: core/src/renderables/Image.ts#checkCrop [status=implemented hash=e3cb6ac41646]
public func checkCrop(
    _ crop: ImageExtractOptions,
    width: Int? = nil,
    height: Int? = nil
) throws(MediaRenderableError) -> ImageExtractOptions {
    guard crop.left >= 0 && crop.top >= 0 && crop.width >= 1 && crop.height >= 1 else {
        throw .invalidCrop("crop needs non-negative left/top and positive width/height")
    }
    if let width, crop.left + crop.width > width {
        throw .invalidCrop("crop \(crop.width)x\(crop.height) at \(crop.left),\(crop.top) lies outside width \(width)")
    }
    if let height, crop.top + crop.height > height {
        throw .invalidCrop("crop \(crop.width)x\(crop.height) at \(crop.left),\(crop.top) lies outside height \(height)")
    }
    return crop
}

/// Compares two optional crop rectangles for exact equality.
// parity: core/src/renderables/Image.ts#sameCrop [status=implemented hash=a89fbe190013]
public func sameCrop(_ a: ImageExtractOptions?, _ b: ImageExtractOptions?) -> Bool {
    a == b
}

// MARK: - Pure-Swift Base64 & Kitty Graphics Protocol Encoder

private let base64Alphabet: [UInt8] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

private func encodeBase64PureSwift(_ bytes: [UInt8]) -> String {
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
        out.append(base64Alphabet[Int((triple >> 18) & 0x3F)])
        out.append(base64Alphabet[Int((triple >> 12) & 0x3F)])
        out.append(hasB1 ? base64Alphabet[Int((triple >> 6) & 0x3F)] : 0x3D) // '='
        out.append(hasB2 ? base64Alphabet[Int(triple & 0x3F)] : 0x3D) // '='
        i += 3
    }
    return String(decoding: out, as: UTF8.self)
}

/// Encodes an RGBA8888 `PixelImage` as a chunked Kitty Graphics Protocol APC escape sequence
/// (`\x1b_G...;\x1b\\`) with `f=32`, `a=T`, and optional image ID & cell dimensions.
public func encodeKittyGraphics(
    image: PixelImage,
    cols: Int? = nil,
    rows: Int? = nil,
    imageId: UInt32? = nil,
    chunkSize: Int = 4096
) -> String {
    let payload = encodeBase64PureSwift(image.pixels)
    let safeChunkSize = max(4, chunkSize)
    let payloadBytes = Array(payload.utf8)

    var headerParts: [String] = [
        "a=T",
        "f=32",
        "s=\(image.width)",
        "v=\(image.height)",
        "q=2",
    ]
    if let cols, cols > 0 { headerParts.append("c=\(cols)") }
    if let rows, rows > 0 { headerParts.append("r=\(rows)") }
    if let imageId, imageId > 0 { headerParts.append("i=\(imageId)") }

    if payloadBytes.count <= safeChunkSize {
        headerParts.append("m=0")
        return "\u{1B}_G\(headerParts.joined(separator: ","));\(payload)\u{1B}\\"
    }

    var result = ""
    var offset = 0
    var isFirst = true
    while offset < payloadBytes.count {
        let end = min(offset + safeChunkSize, payloadBytes.count)
        let hasMore = end < payloadBytes.count
        let slice = String(decoding: payloadBytes[offset..<end], as: UTF8.self)
        if isFirst {
            var firstHeader = headerParts
            firstHeader.append("m=\(hasMore ? 1 : 0)")
            result.append("\u{1B}_G\(firstHeader.joined(separator: ","));\(slice)\u{1B}\\")
            isFirst = false
        } else {
            result.append("\u{1B}_Gm=\(hasMore ? 1 : 0);\(slice)\u{1B}\\")
        }
        offset = end
    }
    return result
}

/// Encodes a Kitty Graphics Protocol delete escape sequence (`a=d`).
public func encodeKittyGraphicsDelete(imageId: UInt32? = nil) -> String {
    if let imageId, imageId > 0 {
        return "\u{1B}_Ga=d,d=I,i=\(imageId),q=2\u{1B}\\"
    }
    return "\u{1B}_Ga=d,d=a,q=2\u{1B}\\"
}

// MARK: - Shared Half-Block Pixel Renderer

private let upperHalfBlockChar: UInt32 = 0x2580 // '▀'
private let lowerHalfBlockChar: UInt32 = 0x2584 // '▄'
private let fullBlockChar: UInt32 = 0x2588 // '█'

private func computeFittedCellSize(
    fit: ImageFit,
    targetWidth: Int,
    targetHeight: Int,
    cellAspectRatio: Double,
    sourceWidth: Int,
    sourceHeight: Int
) -> (width: Int, height: Int) {
    guard sourceWidth > 0 && sourceHeight > 0 && targetWidth > 0 && targetHeight > 0 else {
        return (0, 0)
    }
    if fit == .fill {
        return (targetWidth, targetHeight)
    }
    let displayAspect = (Double(sourceWidth) / Double(sourceHeight)) * cellAspectRatio
    let scale: Double
    switch fit {
    case .fit:
        scale = min(Double(targetWidth) / displayAspect, Double(targetHeight))
    case .cover:
        scale = max(Double(targetWidth) / displayAspect, Double(targetHeight))
    case .fill:
        return (targetWidth, targetHeight)
    }
    let fittedW = max(1, Int((displayAspect * scale).rounded(.toNearestOrAwayFromZero)))
    let fittedH = max(1, Int(scale.rounded(.toNearestOrAwayFromZero)))
    return (fittedW, fittedH)
}

private func renderPixelImageHalfBlocks(
    image: PixelImage,
    into buffer: OptimizedBuffer,
    originX: Int,
    originY: Int,
    boxWidth: Int,
    boxHeight: Int,
    fit: ImageFit,
    crop: ImageExtractOptions?,
    cellAspectRatio: Double
) {
    guard boxWidth > 0 && boxHeight > 0 else { return }

    let region: ImageExtractOptions
    if let crop, crop.left + crop.width <= image.width, crop.top + crop.height <= image.height {
        region = crop
    } else {
        region = ImageExtractOptions(left: 0, top: 0, width: image.width, height: image.height)
    }

    let fitted: (width: Int, height: Int)
    if fit == .cover {
        fitted = (boxWidth, boxHeight)
    } else {
        fitted = computeFittedCellSize(
            fit: fit,
            targetWidth: boxWidth,
            targetHeight: boxHeight,
            cellAspectRatio: cellAspectRatio,
            sourceWidth: region.width,
            sourceHeight: region.height
        )
    }
    guard fitted.width > 0 && fitted.height > 0 else { return }

    let destX = originX + (boxWidth - fitted.width) / 2
    let destY = originY + (boxHeight - fitted.height) / 2

    var srcX = region.left
    var srcY = region.top
    var srcW = region.width
    var srcH = region.height

    if fit == .cover {
        let targetAspect = Double(boxWidth) / (Double(boxHeight) * cellAspectRatio)
        let sourceAspect = Double(srcW) / Double(srcH)
        if sourceAspect > targetAspect {
            srcW = max(1, Int((Double(srcH) * targetAspect).rounded(.toNearestOrAwayFromZero)))
            srcX += (region.width - srcW) / 2
        } else {
            srcH = max(1, Int((Double(srcW) / targetAspect).rounded(.toNearestOrAwayFromZero)))
            srcY += (region.height - srcH) / 2
        }
    }

    let totalVirtualRows = fitted.height * 2
    let transparent = RGBA.fromInts(0, 0, 0, 0)

    for cellRow in 0..<fitted.height {
        let y = destY + cellRow
        guard y >= 0 && y < buffer.height else { continue }

        let topSubRow = cellRow * 2
        let botSubRow = topSubRow + 1
        let pyTop = srcY + min(srcH - 1, (topSubRow * srcH) / totalVirtualRows)
        let pyBot = srcY + min(srcH - 1, (botSubRow * srcH) / totalVirtualRows)

        for cellCol in 0..<fitted.width {
            let x = destX + cellCol
            guard x >= 0 && x < buffer.width else { continue }

            let px = srcX + min(srcW - 1, (cellCol * srcW) / fitted.width)
            let topColor = image.pixel(x: px, y: pyTop)
            let botColor = image.pixel(x: px, y: pyBot)

            let topA = topColor.toInts().3
            let botA = botColor.toInts().3

            if topA == 0 && botA == 0 {
                continue
            } else if topA > 0 && botA == 0 {
                buffer.drawChar(upperHalfBlockChar, x: x, y: y, fg: topColor, bg: transparent)
            } else if topA == 0 && botA > 0 {
                buffer.drawChar(lowerHalfBlockChar, x: x, y: y, fg: botColor, bg: transparent)
            } else if topColor == botColor {
                buffer.drawChar(fullBlockChar, x: x, y: y, fg: topColor, bg: botColor)
            } else {
                buffer.drawChar(upperHalfBlockChar, x: x, y: y, fg: topColor, bg: botColor)
            }
        }
    }
}

private func ctxPixelResolution(_ ctx: any RenderContext) -> PixelResolution? {
    guard ctx.terminalWidth > 0 && ctx.terminalHeight > 0, let res = ctx.resolution else {
        return nil
    }
    return (res.width > 0 && res.height > 0) ? res : nil
}

// MARK: - ImageOptions & ImageRenderable

/// Alias matching requested Swift option name.
public typealias ImageOptions = ImageRenderableOptions

/// Configuration options for `ImageRenderable`.
// parity: core/src/renderables/Image.ts#ImageRenderableOptions [status=implemented hash=99d550c87351]
public struct ImageRenderableOptions {
    public var base: RenderableOptions
    public var source: ImageRenderableSource?
    public var fit: ImageFit?
    public var crop: ImageExtractOptions?
    public var `protocol`: ImageRenderProtocol?
    public var onLoad: ((PixelImage) -> Void)?
    public var onError: ((any Error) -> Void)?

    public init(
        id: String? = nil,
        width: FlexValue? = nil,
        height: FlexValue? = nil,
        minWidth: FlexValue? = nil,
        maxWidth: FlexValue? = nil,
        minHeight: FlexValue? = nil,
        maxHeight: FlexValue? = nil,
        flexGrow: Float? = nil,
        flexShrink: Float? = nil,
        position: PositionType? = nil,
        top: FlexValue? = nil,
        right: FlexValue? = nil,
        bottom: FlexValue? = nil,
        left: FlexValue? = nil,
        margin: FlexValue? = nil,
        padding: FlexValue? = nil,
        zIndex: Int? = nil,
        visible: Bool? = nil,
        buffered: Bool? = nil,
        source: ImageRenderableSource? = nil,
        fit: ImageFit? = nil,
        crop: ImageExtractOptions? = nil,
        protocol imageProtocol: ImageRenderProtocol? = nil,
        onLoad: ((PixelImage) -> Void)? = nil,
        onError: ((any Error) -> Void)? = nil
    ) {
        self.base = RenderableOptions(
            id: id,
            width: width,
            height: height,
            minWidth: minWidth,
            maxWidth: maxWidth,
            minHeight: minHeight,
            maxHeight: maxHeight,
            flexGrow: flexGrow,
            flexShrink: flexShrink,
            position: position,
            top: top,
            right: right,
            bottom: bottom,
            left: left,
            margin: margin,
            padding: padding,
            zIndex: zIndex,
            visible: visible,
            buffered: buffered
        )
        self.source = source
        self.fit = fit
        self.crop = crop
        self.`protocol` = imageProtocol
        self.onLoad = onLoad
        self.onError = onError
    }
}

/// Terminal image renderable backed by an RGBA `PixelImage` with half-block (`▀`/`▄`/`█`)
/// true-color fallback rendering and Kitty Graphics Protocol encoding.
// parity: core/src/renderables/Image.ts#ImageRenderable [status=implemented hash=799459b68d0b]
open class ImageRenderable: Renderable, @unchecked Sendable {
    private var _source: ImageRenderableSource? = nil
    private var _image: PixelImage? = nil
    private var _loadError: (any Error)? = nil
    private var _loading: Bool = false
    private var _fit: ImageFit
    private var _crop: ImageExtractOptions? = nil
    private var _protocol: ImageRenderProtocol

    public var onLoad: ((PixelImage) -> Void)?
    public var onError: ((any Error) -> Void)?

    public init(ctx: any RenderContext, options: ImageRenderableOptions = ImageRenderableOptions()) {
        self._fit = options.fit ?? .fit
        self._protocol = options.`protocol` ?? .auto
        self.onLoad = options.onLoad
        self.onError = options.onError

        super.init(ctx: ctx, options: options.base)

        if let source = options.source {
            self.source = source
        }
        if let crop = options.crop {
            self.crop = crop
        }
    }

    // parity: core/src/renderables/Image.ts#ImageRenderable.source [status=implemented hash=6786e2d3684b]
    public var source: ImageRenderableSource? {
        get { _source }
        set {
            guard _source != newValue else { return }
            _source = newValue
            _loadError = nil

            guard let newValue else {
                _image = nil
                _loading = false
                requestRender()
                return
            }

            switch newValue {
            case .pixelImage(let img):
                _image = img
                _loading = false
                if let crop = _crop {
                    do {
                        _ = try checkCrop(crop, width: img.width, height: img.height)
                    } catch {
                        _loadError = error
                        onError?(error)
                    }
                }
                requestRender()
                onLoad?(img)

            case .rgba(let w, let h, let pixels):
                do {
                    let img = try PixelImage(width: w, height: h, pixels: pixels)
                    _image = img
                    _loading = false
                    if let crop = _crop {
                        do {
                            _ = try checkCrop(crop, width: img.width, height: img.height)
                        } catch {
                            _loadError = error
                            onError?(error)
                        }
                    }
                    requestRender()
                    onLoad?(img)
                } catch {
                    _image = nil
                    _loading = false
                    _loadError = error
                    onError?(error)
                }
            }
        }
    }

    // parity: core/src/renderables/Image.ts#ImageRenderable.image [status=implemented hash=8a3e7187f445]
    public var image: PixelImage? { _image }

    // parity: core/src/renderables/Image.ts#ImageRenderable.fit [status=implemented hash=4addcb51cfe1]
    public var fit: ImageFit {
        get { _fit }
        set {
            guard _fit != newValue else { return }
            _fit = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/Image.ts#ImageRenderable.crop [status=implemented hash=794a8407c7a9]
    public var crop: ImageExtractOptions? {
        get { _crop }
        set {
            guard !sameCrop(_crop, newValue), !isDestroyed else { return }
            guard let newValue else {
                _crop = nil
                requestRender()
                return
            }
            do {
                let checked = try checkCrop(newValue, width: _image?.width, height: _image?.height)
                _crop = checked
                requestRender()
            } catch {
                _loadError = error
                onError?(error)
            }
        }
    }

    // parity: core/src/renderables/Image.ts#ImageRenderable.protocol [status=implemented hash=06af13668bc3]
    public var `protocol`: ImageRenderProtocol {
        get { _protocol }
        set {
            guard _protocol != newValue else { return }
            _protocol = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/Image.ts#ImageRenderable.effectiveProtocol [status=implemented hash=881d689ca906]
    public var effectiveProtocol: ImageRenderProtocol {
        resolveImageRenderProtocol(
            requested: _protocol,
            capabilities: ctx.capabilities,
            hasResolution: ctxPixelResolution(ctx) != nil
        )
    }

    // parity: core/src/renderables/Image.ts#ImageRenderable.cellAspectRatio [status=implemented hash=e1dc7442bf7e]
    public var cellAspectRatio: Double {
        guard let res = ctxPixelResolution(ctx) else { return 2.0 }
        let cellWidth = Double(res.width) / Double(ctx.terminalWidth)
        let cellHeight = Double(res.height) / Double(ctx.terminalHeight)
        return (cellWidth > 0 && cellHeight > 0) ? (cellHeight / cellWidth) : 2.0
    }

    private func activeRegion() -> ImageExtractOptions? {
        guard let img = _image else { return nil }
        if let crop = _crop, crop.left + crop.width <= img.width, crop.top + crop.height <= img.height {
            return crop
        }
        return ImageExtractOptions(left: 0, top: 0, width: img.width, height: img.height)
    }

    // parity: core/src/renderables/Image.ts#ImageRenderable.getFittedSize [status=implemented hash=b8c314fb5435]
    public func getFittedSize(
        targetWidth: Int,
        targetHeight: Int,
        cellAspectRatio: Double? = nil,
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil
    ) -> (width: Int, height: Int) {
        let region = activeRegion()
        return computeFittedCellSize(
            fit: _fit,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            cellAspectRatio: cellAspectRatio ?? self.cellAspectRatio,
            sourceWidth: sourceWidth ?? region?.width ?? 0,
            sourceHeight: sourceHeight ?? region?.height ?? 0
        )
    }

    // parity: core/src/renderables/Image.ts#ImageRenderable.loading [status=implemented hash=b4ecf3735119]
    public var loading: Bool { _loading }

    // parity: core/src/renderables/Image.ts#ImageRenderable.loadError [status=implemented hash=a5a4cd7fe897]
    public var loadError: (any Error)? { _loadError }

    /// Encodes the current image using the Kitty Graphics Protocol when available.
    public func encodeKittySequence(cols: Int? = nil, rows: Int? = nil, imageId: UInt32? = nil) -> String? {
        guard let img = _image else { return nil }
        let fitted = getFittedSize(targetWidth: cols ?? width, targetHeight: rows ?? height)
        return encodeKittyGraphics(
            image: img,
            cols: fitted.width > 0 ? fitted.width : cols,
            rows: fitted.height > 0 ? fitted.height : rows,
            imageId: imageId
        )
    }

    open override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        guard let img = _image, width > 0 && height > 0 else { return }
        let origin = paintOrigin(for: buffer)
        renderPixelImageHalfBlocks(
            image: img,
            into: buffer,
            originX: origin.x,
            originY: origin.y,
            boxWidth: width,
            boxHeight: height,
            fit: _fit,
            crop: _crop,
            cellAspectRatio: cellAspectRatio
        )
    }

    open override func destroySelf() {
        _image = nil
        _source = nil
        _loading = false
        super.destroySelf()
    }
}

// MARK: - VideoMetadata, VideoOptions & VideoRenderable

/// Metadata describing an opened video or frame sequence.
// parity: core/src/renderables/Video.ts#VideoMetadata [status=implemented hash=8f8698c22468]
public struct VideoMetadata: Equatable, Hashable, Sendable, Codable {
    public var width: Int
    public var height: Int
    public var fps: Double
    public var duration: Double
    public var hasAudio: Bool

    public init(width: Int, height: Int, fps: Double, duration: Double, hasAudio: Bool = false) {
        self.width = width
        self.height = height
        self.fps = fps
        self.duration = duration
        self.hasAudio = hasAudio
    }
}

/// Alias matching requested Swift option name.
public typealias VideoOptions = VideoRenderableOptions

/// Configuration options for `VideoRenderable`.
// parity: core/src/renderables/Video.ts#VideoRenderableOptions [status=implemented hash=60d0af4032e6]
public struct VideoRenderableOptions {
    public var base: RenderableOptions
    public var source: String?
    public var frames: [PixelImage]?
    public var fps: Double?
    public var fit: ImageFit?
    public var crop: ImageExtractOptions?
    public var autoplay: Bool?
    public var loop: Bool?
    public var audio: Bool?
    public var muted: Bool?
    public var volume: Double?
    public var avSyncOffsetMs: Double?
    public var maxFps: Int?
    public var onReady: ((VideoMetadata) -> Void)?
    public var onError: ((any Error) -> Void)?
    public var onEnd: (() -> Void)?
    public var onPlay: (() -> Void)?
    public var onPause: (() -> Void)?
    public var onSeek: ((Double) -> Void)?
    public var onTimeUpdate: ((Double) -> Void)?

    public init(
        id: String? = nil,
        width: FlexValue? = nil,
        height: FlexValue? = nil,
        minWidth: FlexValue? = nil,
        maxWidth: FlexValue? = nil,
        minHeight: FlexValue? = nil,
        maxHeight: FlexValue? = nil,
        flexGrow: Float? = nil,
        flexShrink: Float? = nil,
        position: PositionType? = nil,
        top: FlexValue? = nil,
        right: FlexValue? = nil,
        bottom: FlexValue? = nil,
        left: FlexValue? = nil,
        margin: FlexValue? = nil,
        padding: FlexValue? = nil,
        zIndex: Int? = nil,
        visible: Bool? = nil,
        buffered: Bool? = nil,
        source: String? = nil,
        frames: [PixelImage]? = nil,
        fps: Double? = nil,
        fit: ImageFit? = nil,
        crop: ImageExtractOptions? = nil,
        autoplay: Bool? = nil,
        loop: Bool? = nil,
        audio: Bool? = nil,
        muted: Bool? = nil,
        volume: Double? = nil,
        avSyncOffsetMs: Double? = nil,
        maxFps: Int? = nil,
        onReady: ((VideoMetadata) -> Void)? = nil,
        onError: ((any Error) -> Void)? = nil,
        onEnd: (() -> Void)? = nil,
        onPlay: (() -> Void)? = nil,
        onPause: (() -> Void)? = nil,
        onSeek: ((Double) -> Void)? = nil,
        onTimeUpdate: ((Double) -> Void)? = nil
    ) {
        self.base = RenderableOptions(
            id: id,
            width: width,
            height: height,
            minWidth: minWidth,
            maxWidth: maxWidth,
            minHeight: minHeight,
            maxHeight: maxHeight,
            flexGrow: flexGrow,
            flexShrink: flexShrink,
            position: position,
            top: top,
            right: right,
            bottom: bottom,
            left: left,
            margin: margin,
            padding: padding,
            zIndex: zIndex,
            visible: visible,
            buffered: buffered
        )
        self.source = source
        self.frames = frames
        self.fps = fps
        self.fit = fit
        self.crop = crop
        self.autoplay = autoplay
        self.loop = loop
        self.audio = audio
        self.muted = muted
        self.volume = volume
        self.avSyncOffsetMs = avSyncOffsetMs
        self.maxFps = maxFps
        self.onReady = onReady
        self.onError = onError
        self.onEnd = onEnd
        self.onPlay = onPlay
        self.onPause = onPause
        self.onSeek = onSeek
        self.onTimeUpdate = onTimeUpdate
    }
}

/// Frame-buffer backed video & animation presenter supporting `play`/`pause`/`seek`/`setFrame`,
/// animation-clock playback advancement, loop/end callbacks, crop/fit, and half-block rendering.
// parity: core/src/renderables/Video.ts#VideoRenderable [status=implemented hash=ead091cd06e9]
open class VideoRenderable: Renderable, @unchecked Sendable {
    private var _source: String? = nil
    private var _fit: ImageFit
    private var _crop: ImageExtractOptions? = nil
    private var _loop: Bool
    private var _audio: Bool
    private var _muted: Bool
    private var _volume: Double
    private var _avSyncOffsetMs: Double
    private var _maxFps: Int
    private var _autoplay: Bool

    private var _frames: [PixelImage] = []
    private var _currentFrame: PixelImage? = nil
    private var _metadata: VideoMetadata? = nil
    private var _playing: Bool = false
    private var _ended: Bool = false
    private var _currentTime: Double = 0
    private var _qualityTier: Int = 0
    private var stopTick: (() -> Void)? = nil

    public var onReady: ((VideoMetadata) -> Void)?
    public var onError: ((any Error) -> Void)?
    public var onEnd: (() -> Void)?
    public var onPlay: (() -> Void)?
    public var onPause: (() -> Void)?
    public var onSeek: ((Double) -> Void)?
    public var onTimeUpdate: ((Double) -> Void)?

    public init(ctx: any RenderContext, options: VideoRenderableOptions = VideoRenderableOptions()) {
        self._fit = options.fit ?? .fit
        self._loop = options.loop ?? false
        self._audio = options.audio ?? true
        self._muted = options.muted ?? false
        self._volume = max(0, options.volume ?? 1.0)
        self._avSyncOffsetMs = max(-60_000, min(60_000, options.avSyncOffsetMs ?? 0))
        self._maxFps = max(1, min(120, options.maxFps ?? 30))
        self._autoplay = options.autoplay ?? false
        self._source = options.source

        self.onReady = options.onReady
        self.onError = options.onError
        self.onEnd = options.onEnd
        self.onPlay = options.onPlay
        self.onPause = options.onPause
        self.onSeek = options.onSeek
        self.onTimeUpdate = options.onTimeUpdate

        super.init(ctx: ctx, options: options.base)

        if let crop = options.crop {
            self.crop = crop
        }
        if let frames = options.frames, !frames.isEmpty {
            setFrames(frames, fps: options.fps ?? Double(_maxFps))
        }
    }

    // MARK: - Frame Presentation API

    /// Sets a single pixel frame directly for live/streaming presentation.
    public func setFrame(_ frame: PixelImage?) {
        guard !isDestroyed else { return }
        _frames = frame.map { [$0] } ?? []
        _currentFrame = frame
        if let frame {
            if _metadata == nil {
                let meta = VideoMetadata(
                    width: frame.width,
                    height: frame.height,
                    fps: Double(_maxFps),
                    duration: 1.0 / Double(_maxFps),
                    hasAudio: false
                )
                _metadata = meta
                onReady?(meta)
            }
        } else {
            _metadata = nil
            _playing = false
            _ended = false
            _currentTime = 0
            syncPlayback()
        }
        requestRender()
    }

    /// Loads an animated sequence of RGBA pixel frames at `fps` frames per second.
    public func setFrames(_ frames: [PixelImage], fps: Double = 30) {
        guard !isDestroyed else { return }
        let safeFps = (fps.isFinite && fps > 0) ? fps : 30.0
        _frames = frames
        _currentTime = 0
        _ended = false
        _currentFrame = frames.first

        if let first = frames.first {
            let meta = VideoMetadata(
                width: first.width,
                height: first.height,
                fps: safeFps,
                duration: Double(frames.count) / safeFps,
                hasAudio: false
            )
            _metadata = meta
            onReady?(meta)
            if _autoplay {
                play()
            }
        } else {
            _metadata = nil
            _playing = false
            syncPlayback()
        }
        requestRender()
    }

    /// Currently active pixel frame for display.
    public var currentFrame: PixelImage? {
        if !_frames.isEmpty {
            let idx = currentFrameIndex
            if idx >= 0 && idx < _frames.count {
                return _frames[idx]
            }
        }
        return _currentFrame
    }

    /// Zero-based index of the active frame in the loaded frame sequence.
    public var currentFrameIndex: Int {
        guard !_frames.isEmpty, let meta = _metadata, meta.fps > 0 else { return 0 }
        let raw = Int((_currentTime * meta.fps).rounded(.down))
        return max(0, min(_frames.count - 1, raw))
    }

    // MARK: - Playback Properties

    // parity: core/src/renderables/Video.ts#VideoRenderable.source [status=implemented hash=8fb8ef0b7129]
    public var source: String? {
        get { _source }
        set {
            guard _source != newValue, !isDestroyed else { return }
            _source = newValue
            if newValue == nil {
                setFrame(nil)
            }
            requestRender()
        }
    }

    // parity: core/src/renderables/Video.ts#VideoRenderable.fit [status=implemented hash=4addcb51cfe1]
    public var fit: ImageFit {
        get { _fit }
        set {
            guard _fit != newValue, !isDestroyed else { return }
            _fit = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/Video.ts#VideoRenderable.crop [status=implemented hash=794a8407c7a9]
    public var crop: ImageExtractOptions? {
        get { _crop }
        set {
            guard !sameCrop(_crop, newValue), !isDestroyed else { return }
            guard let newValue else {
                _crop = nil
                requestRender()
                return
            }
            do {
                let checked = try checkCrop(newValue, width: _metadata?.width, height: _metadata?.height)
                _crop = checked
                requestRender()
            } catch {
                onError?(error)
            }
        }
    }

    // parity: core/src/renderables/Video.ts#VideoRenderable.loop [status=implemented hash=52b87f532e89]
    public var loop: Bool {
        get { _loop }
        set {
            guard _loop != newValue, !isDestroyed else { return }
            _loop = newValue
        }
    }

    // parity: core/src/renderables/Video.ts#VideoRenderable.audio [status=implemented hash=cc338810a821]
    public var audio: Bool {
        get { _audio }
        set {
            guard _audio != newValue, !isDestroyed else { return }
            _audio = newValue
        }
    }

    // parity: core/src/renderables/Video.ts#VideoRenderable.muted [status=implemented hash=2b37f3aa497b]
    public var muted: Bool {
        get { _muted }
        set {
            guard _muted != newValue, !isDestroyed else { return }
            _muted = newValue
        }
    }

    // parity: core/src/renderables/Video.ts#VideoRenderable.volume [status=implemented hash=1b36c67f390d]
    public var volume: Double {
        get { _volume }
        set {
            guard newValue.isFinite && newValue >= 0 else {
                onError?(MediaRenderableError.invalidVolume(newValue))
                return
            }
            guard _volume != newValue, !isDestroyed else { return }
            _volume = newValue
        }
    }

    // parity: core/src/renderables/Video.ts#VideoRenderable.avSyncOffsetMs [status=implemented hash=b7ae16264241]
    public var avSyncOffsetMs: Double {
        get { _avSyncOffsetMs }
        set {
            guard newValue.isFinite && abs(newValue) <= 60_000 else {
                onError?(MediaRenderableError.invalidAvSyncOffset(newValue))
                return
            }
            guard _avSyncOffsetMs != newValue, !isDestroyed else { return }
            _avSyncOffsetMs = newValue
        }
    }

    // parity: core/src/renderables/Video.ts#VideoRenderable.maxFps [status=implemented hash=0b796274dee6]
    public var maxFps: Int {
        get { _maxFps }
        set {
            guard newValue >= 1 && newValue <= 120 else {
                onError?(MediaRenderableError.invalidMaxFps(newValue))
                return
            }
            guard _maxFps != newValue, !isDestroyed else { return }
            _maxFps = newValue
            syncPlayback()
        }
    }

    // parity: core/src/renderables/Video.ts#VideoRenderable.autoplay [status=implemented hash=caacd5f56405]
    public var autoplay: Bool {
        get { _autoplay }
        set {
            guard _autoplay != newValue, !isDestroyed else { return }
            _autoplay = newValue
            if newValue && _metadata != nil && !_playing && !_ended && _currentTime == 0 {
                play()
            }
        }
    }

    // parity: core/src/renderables/Video.ts#VideoRenderable.ready [status=implemented hash=3fd83d000fe1]
    public var ready: Bool { _metadata != nil }

    // parity: core/src/renderables/Video.ts#VideoRenderable.videoMetadata [status=implemented hash=c3b6aeaf261a]
    public var videoMetadata: VideoMetadata? { _metadata }

    // parity: core/src/renderables/Video.ts#VideoRenderable.playing [status=implemented hash=5a0dbd692440]
    public var playing: Bool { !isDestroyed && _playing }

    // parity: core/src/renderables/Video.ts#VideoRenderable.paused [status=implemented hash=79ec74c3f6a4]
    public var paused: Bool { !playing }

    // parity: core/src/renderables/Video.ts#VideoRenderable.ended [status=implemented hash=21f365985bc8]
    public var ended: Bool { !isDestroyed && _metadata != nil && _ended }

    // parity: core/src/renderables/Video.ts#VideoRenderable.duration [status=implemented hash=e1882157cf56]
    public var duration: Double { _metadata?.duration ?? 0 }

    // parity: core/src/renderables/Video.ts#VideoRenderable.durationMs [status=implemented hash=fc6945453a4e]
    public var durationMs: Double { duration * 1000.0 }

    // parity: core/src/renderables/Video.ts#VideoRenderable.currentTime [status=implemented hash=7052cdb64bc6]
    public var currentTime: Double {
        get { (!isDestroyed && _metadata != nil) ? _currentTime : 0 }
        set { seek(newValue) }
    }

    // parity: core/src/renderables/Video.ts#VideoRenderable.qualityTier [status=implemented hash=21d94908cf10]
    public var qualityTier: Int { (!isDestroyed && _metadata != nil) ? _qualityTier : 0 }

    // parity: core/src/renderables/Video.ts#VideoRenderable.currentTimeMs [status=implemented hash=62fa0ea4c79a]
    public var currentTimeMs: Double { currentTime * 1000.0 }

    // MARK: - Playback Controls

    // parity: core/src/renderables/Video.ts#VideoRenderable.play [status=implemented hash=97919a4241bc]
    public func play() {
        guard !isDestroyed, _metadata != nil, !_playing else { return }
        if _ended {
            _currentTime = 0
            _ended = false
        }
        _playing = true
        syncPlayback()
        requestRender()
        onPlay?()
    }

    // parity: core/src/renderables/Video.ts#VideoRenderable.resume [status=implemented hash=bc972440bea6]
    public func resume() {
        play()
    }

    // parity: core/src/renderables/Video.ts#VideoRenderable.pause [status=implemented hash=5e88db5ec14c]
    public func pause() {
        guard !isDestroyed, _playing else { return }
        _playing = false
        syncPlayback()
        requestRender()
        let time = currentTime
        onPause?()
        onTimeUpdate?(time)
    }

    // parity: core/src/renderables/Video.ts#VideoRenderable.toggle [status=implemented hash=653d210c8220]
    public func toggle() {
        if playing {
            pause()
        } else {
            play()
        }
    }

    // parity: core/src/renderables/Video.ts#VideoRenderable.seek [status=implemented hash=4711cb877300]
    public func seek(_ time: Double) {
        guard time.isFinite else {
            onError?(MediaRenderableError.invalidTime("Video time must be finite"))
            return
        }
        guard !isDestroyed, let meta = _metadata else { return }
        let clamped = max(0, min(time, meta.duration))
        _currentTime = clamped
        _ended = meta.duration > 0 && clamped >= meta.duration && !_loop
        if !_frames.isEmpty {
            _currentFrame = _frames[currentFrameIndex]
        }
        requestRender()
        onSeek?(clamped)
        onTimeUpdate?(clamped)
    }

    // parity: core/src/renderables/Video.ts#VideoRenderable.seekBy [status=implemented hash=2abf0af69b92]
    public func seekBy(_ delta: Double) {
        guard delta.isFinite else {
            onError?(MediaRenderableError.invalidTime("Video seek delta must be finite"))
            return
        }
        seek(currentTime + delta)
    }

    // parity: core/src/renderables/Video.ts#VideoRenderable.seekToMs [status=implemented hash=89694adddc77]
    public func seekToMs(_ milliseconds: Double) {
        guard milliseconds.isFinite else {
            onError?(MediaRenderableError.invalidTime("Video time must be finite"))
            return
        }
        seek(milliseconds / 1000.0)
    }

    // MARK: - Playback Tick & Rendering

    private func syncPlayback() {
        stopTick?()
        stopTick = nil
        guard !isDestroyed, _playing, _metadata != nil else { return }
        stopTick = ctx.onAnimationTick(fps: Double(_maxFps)) { [weak self] deltaTimeMs, _, _ in
            self?.advancePlayback(deltaTimeMs: deltaTimeMs)
        }
    }

    private func advancePlayback(deltaTimeMs: Double) {
        guard !isDestroyed, _playing, let meta = _metadata else { return }
        let dtSec = max(0, deltaTimeMs / 1000.0)
        var nextTime = _currentTime + dtSec

        if meta.duration > 0 && nextTime >= meta.duration {
            if _loop {
                nextTime = nextTime.truncatingRemainder(dividingBy: meta.duration)
                _currentTime = nextTime
                if !_frames.isEmpty {
                    _currentFrame = _frames[currentFrameIndex]
                }
                onTimeUpdate?(_currentTime)
                requestRender()
            } else {
                _currentTime = meta.duration
                _ended = true
                _playing = false
                if !_frames.isEmpty {
                    _currentFrame = _frames.last
                }
                syncPlayback()
                onTimeUpdate?(_currentTime)
                onEnd?()
                requestRender()
            }
            return
        }

        _currentTime = nextTime
        if !_frames.isEmpty {
            _currentFrame = _frames[currentFrameIndex]
        }
        onTimeUpdate?(_currentTime)
        requestRender()
    }

    private var cellAspectRatio: Double {
        guard let res = ctxPixelResolution(ctx) else { return 2.0 }
        let cellWidth = Double(res.width) / Double(ctx.terminalWidth)
        let cellHeight = Double(res.height) / Double(ctx.terminalHeight)
        return (cellWidth > 0 && cellHeight > 0) ? (cellHeight / cellWidth) : 2.0
    }

    open override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        guard let frame = currentFrame, width > 0 && height > 0 else { return }
        let origin = paintOrigin(for: buffer)
        renderPixelImageHalfBlocks(
            image: frame,
            into: buffer,
            originX: origin.x,
            originY: origin.y,
            boxWidth: width,
            boxHeight: height,
            fit: _fit,
            crop: _crop,
            cellAspectRatio: cellAspectRatio
        )
    }

    open override func destroySelf() {
        stopTick?()
        stopTick = nil
        _playing = false
        _frames.removeAll()
        _currentFrame = nil
        _metadata = nil
        super.destroySelf()
    }
}
