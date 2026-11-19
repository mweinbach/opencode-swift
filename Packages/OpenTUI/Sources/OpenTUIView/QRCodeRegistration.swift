import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables
import Synchronization

/// Declarative `QRCodeRenderable` registration and Swift `TUIView` integration,
/// providing the Swift counterpart to `@opentui/qrcode/react` (`"qr-code"`) and
/// `@opentui/qrcode/solid` (`"qr_code"`).
///
/// Zero Foundation or OS-specific imports — compiles on every Swift 6 platform.

// MARK: - QRCodeComponentRegistry

/// Factory signature for instantiating a registered `QRCodeRenderable` component.
public typealias QRCodeComponentFactory = @Sendable (any RenderContext, QRCodeOptions) -> QRCodeRenderable

/// Thread-safe declarative component registry mapping custom element tag names
/// (e.g. `"qr-code"` and `"qr_code"`) to `QRCodeRenderable` factories.
public final class QRCodeComponentRegistry: Sendable {
    public static let shared = QRCodeComponentRegistry()

    /// Upstream `@opentui/react` intrinsic component tag (`"qr-code"`).
    public static let reactTag = "qr-code"
    /// Upstream `@opentui/solid` intrinsic component tag (`"qr_code"`).
    public static let solidTag = "qr_code"

    private let factories = Mutex<[String: QRCodeComponentFactory]>([:])

    public init() {}

    /// Registers a `QRCodeRenderable` factory under `tag`.
    public func register(tag: String, factory: @escaping QRCodeComponentFactory) {
        factories.withLock { $0[tag] = factory }
    }

    /// Removes a previously registered tag.
    public func unregister(tag: String) {
        _ = factories.withLock { $0.removeValue(forKey: tag) }
    }

    /// Removes all registered tags (useful for isolated tests).
    public func reset() {
        factories.withLock { $0.removeAll() }
    }

    /// Reports whether `tag` has been registered.
    public func isRegistered(_ tag: String) -> Bool {
        factories.withLock { $0[tag] != nil }
    }

    /// Returns all currently registered tag names in deterministic sorted order.
    public var registeredTags: [String] {
        factories.withLock { $0.keys.sorted() }
    }

    /// Instantiates a `QRCodeRenderable` using the factory registered under `tag`, or returns `nil`.
    public func createRenderable(
        tag: String,
        ctx: any RenderContext,
        options: QRCodeOptions = QRCodeOptions()
    ) -> QRCodeRenderable? {
        let factory = factories.withLock { $0[tag] }
        return factory?(ctx, options)
    }
    /// Creates a declarative `TUIViewNode` for a registered QR tag (`"qr-code"` or `"qr_code"`), or `nil` if unregistered.
    public func makeViewNode(
        tag: String,
        options: QRCodeOptions = QRCodeOptions()
    ) -> TUIViewNode? {
        guard let factory = factories.withLock({ $0[tag] }) else { return nil }
        return TUIViewNode(
            kind: tag,
            props: [
                "content": options.content ?? "",
                "scale": options.scale ?? 1,
                "invert": options.invert ?? false,
            ],
            isLeaf: true,
            mount: { ctx in
                factory(ctx, options)
            },
            patch: { existing in
                guard let qr = existing as? QRCodeRenderable else { return false }
                if let content = options.content, qr.content != content { qr.content = content }
                if let ecl = options.errorCorrectionLevel, qr.errorCorrectionLevel != ecl {
                    qr.errorCorrectionLevel = ecl
                }
                if let qz = options.quietZone, qr.quietZone != qz { qr.quietZone = qz }
                if let sc = options.scale, qr.scale != sc { qr.scale = sc }
                if let fit = options.fit, qr.fit != fit { qr.fit = fit }
                if let fg = options.foregroundColor {
                    let resolved = fg.resolved()
                    if qr.foregroundColor != resolved { qr.foregroundColor = resolved }
                }
                if let bg = options.backgroundColor {
                    let resolved = bg.resolved()
                    if qr.backgroundColor != resolved { qr.backgroundColor = resolved }
                }
                if let inv = options.invert, qr.invert != inv { qr.invert = inv }
                if let fb = options.fallbackContent, qr.fallbackContent != fb { qr.fallbackContent = fb }
                if let fbc = options.fallbackColor {
                    let resolved = fbc.resolved()
                    if qr.fallbackColor != resolved { qr.fallbackColor = resolved }
                }
                return true
            }
        )
    }
}

/// Registers `QRCodeRenderable` in `registry` under both upstream declarative component tags
/// (`"qr-code"` from `qrcode/src/react.ts` and `"qr_code"` from `qrcode/src/solid.ts`).
// parity: qrcode/src/react.ts#registerQRCode [status=adapted hash=6ef753bd9ff1]
// parity: qrcode/src/solid.ts#registerQRCode [status=adapted hash=d2b5b27f61da]
public func registerQRCode(in registry: QRCodeComponentRegistry = .shared) {
    let factory: QRCodeComponentFactory = { ctx, options in
        QRCodeRenderable(ctx: ctx, options: options)
    }
    registry.register(tag: QRCodeComponentRegistry.reactTag, factory: factory)
    registry.register(tag: QRCodeComponentRegistry.solidTag, factory: factory)
}

public extension TUIQRCode {
    /// Registers `QRCodeRenderable` in `registry` under `"qr-code"` and `"qr_code"`.
    static func register(in registry: QRCodeComponentRegistry = .shared) {
        registerQRCode(in: registry)
    }
}
