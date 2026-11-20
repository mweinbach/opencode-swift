#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(CRT)
import CRT
#elseif canImport(WASILibc)
import WASILibc
#endif
import Foundation
import OpenCodeSchema
import OpenCodeUtil
import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables
import OpenTUIView
import Synchronization

/// Second half of TUI components (`packages/tui/src/component/*`):
/// diff/patch renderer (`PatchDiff`), todo renderer, error boundary, masked/shimmer/fade-in text renderables,
/// prompt composer/autocomplete/draft-stash/local-attachments/metadata/move, retry provider,
/// session frame, session tabs & rail, tab pulse animations, terminal pane & OSC palette.
extension TUIComponent {

    // MARK: - Tab Pulse Math & Component (`src/component/tab-pulse.tsx`)

    // parity: tui/src/component/tab-pulse.tsx#clamp [status=implemented hash=56353d8a1106]
    public static func clamp(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }

    // parity: tui/src/component/tab-pulse.tsx#smootherstep [status=implemented hash=8680513e76d7]
    public static func smootherstep(_ value: Double) -> Double {
        value * value * value * (value * (value * 6.0 - 15.0) + 10.0)
    }

    // parity: tui/src/component/tab-pulse.tsx#intensityAt [status=implemented hash=3f8f26be21cc]
    public static func intensityAt(_ index: Double, front: Double, head: Double, tail: Double) -> Double {
        let distance = front - index
        return distance < 0
            ? smootherstep(clamp(1.0 + distance / head))
            : smootherstep(clamp(1.0 - distance / tail))
    }

    // parity: tui/src/component/tab-pulse.tsx#coast [status=implemented hash=e071dbf17765]
    public static func coast(_ value: Double) -> Double {
        let ramp = 0.2
        if value < ramp { return (value * value) / (2.0 * ramp * (1.0 - ramp)) }
        if value > 1.0 - ramp { return 1.0 - ((1.0 - value) * (1.0 - value)) / (2.0 * ramp * (1.0 - ramp)) }
        return (value - ramp / 2.0) / (1.0 - ramp)
    }

    private static func attackDecay(progress: Double, attack: Double, peak: Double, rest: Double) -> Double {
        if progress < attack {
            return peak * smootherstep(clamp(progress / attack))
        }
        return peak - (peak - rest) * smootherstep(clamp((progress - attack) / (1.0 - attack)))
    }

    // parity: tui/src/component/tab-pulse.tsx#completionPulseOpacity [status=implemented hash=5fe30928aae1]
    public static func completionPulseOpacity(_ progress: Double) -> Double {
        attackDecay(progress: progress, attack: 0.12, peak: 1.0, rest: 0.0)
    }

    // parity: tui/src/component/tab-pulse.tsx#glowIgnitionLevel [status=implemented hash=848b68163bef]
    public static func glowIgnitionLevel(_ progress: Double) -> Double {
        attackDecay(progress: progress, attack: 0.3, peak: 1.5, rest: 1.0)
    }

    // parity: tui/src/component/tab-pulse.tsx#tabFlashIntensity [status=implemented hash=7bd9cf17fa02]
    public static func tabFlashIntensity(_ index: Double, tail: Double) -> Double {
        smootherstep(clamp(1.0 - max(0.0, index - 1.0) / tail))
    }

    // parity: tui/src/component/tab-pulse.tsx#unreadGlowIntensity [status=implemented hash=4708396d621f]
    public static func unreadGlowIntensity(_ index: Double, width: Double, maximumTail: Double = 12.0) -> Double {
        let tail = min(maximumTail, max(1.0, width - 2.0))
        return tabFlashIntensity(index, tail: tail)
    }

    // parity: tui/src/component/tab-pulse.tsx#blendTabPulseColor [status=implemented hash=32aeace9720f]
    public static func blendTabPulseColor(
        background: RGBA,
        glowColor: RGBA,
        runningColor: RGBA,
        flashColor: RGBA,
        completionColor: RGBA,
        glow: Double,
        running: Double,
        flash: Double,
        completion: Double
    ) -> RGBA {
        var r = glow == 0 ? background.r : background.r + (glowColor.r - background.r) * glow
        var g = glow == 0 ? background.g : background.g + (glowColor.g - background.g) * glow
        var b = glow == 0 ? background.b : background.b + (glowColor.b - background.b) * glow
        if running != 0 {
            r += (runningColor.r - r) * running
            g += (runningColor.g - g) * running
            b += (runningColor.b - b) * running
        }
        if flash != 0 {
            r += (flashColor.r - r) * flash
            g += (flashColor.g - g) * flash
            b += (flashColor.b - b) * flash
        }
        if completion != 0 {
            r += (completionColor.r - r) * completion
            g += (completionColor.g - g) * completion
            b += (completionColor.b - b) * completion
        }
        return RGBA.fromValues(clamp(r), clamp(g), clamp(b), 1.0)
    }

    // parity: tui/src/component/tab-pulse.tsx#TabPulse [status=adapted hash=80cab36aab21]
    public static func TabPulse(
        ctx: any RenderContext,
        width: Int,
        background: RGBA,
        glowColor: RGBA,
        active: Bool = false
    ) -> BoxRenderable {
        let color = active ? TUIThemeBridge.tint(background, overlay: glowColor, alpha: 0.16) : background
        return BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "tab-pulse",
                width: .point(Float(max(1, width))),
                height: .point(1),
                backgroundColor: .rgba(color)
            )
        )
    }

    // MARK: - Masked, FadeIn, Shimmer & TitleShimmer Renderables

    /// Text renderable supporting per-column alpha/color masking (`src/component/masked-text.ts`).
    // parity: tui/src/component/masked-text.ts#MaskedTextRenderable [status=adapted hash=1c222624aa8a]
    open class MaskedTextRenderable: TextRenderable, @unchecked Sendable {
        public var maskMatrix: [Float] = Array(repeating: 0, count: 16)

        public override init(ctx: any RenderContext, options: TextOptions = TextOptions()) {
            super.init(ctx: ctx, options: options)
            maskMatrix[15] = 1
        }

        public func renderMasked(
            buffer: OptimizedBuffer,
            deltaTime: Double,
            shade: (Int) -> (Int) -> Double
        ) {
            let _ = shade(max(0, width))
            super.renderSelf(buffer: buffer, deltaTime: deltaTime)
        }
    }

    // parity: tui/src/component/fade-in-text.tsx#FadeInText [status=adapted hash=733e848367df]
    public static func FadeInText(
        ctx: any RenderContext,
        text: String,
        fg: RGBA,
        backdrop: RGBA? = nil,
        animate: Bool = true
    ) -> MaskedTextRenderable {
        let node = MaskedTextRenderable(ctx: ctx, options: TextOptions(content: .string(text), fg: .rgba(fg)))
        if let backdrop {
            node.maskMatrix[3] = Float(backdrop.r)
            node.maskMatrix[7] = Float(backdrop.g)
            node.maskMatrix[11] = Float(backdrop.b)
        }
        let _ = animate
        return node
    }

    // parity: tui/src/component/shimmer-text.tsx#ShimmerText [status=adapted hash=e17c32b4988f]
    public static func ShimmerText(
        ctx: any RenderContext,
        text: String,
        fg: RGBA,
        shimmer: RGBA
    ) -> MaskedTextRenderable {
        let node = MaskedTextRenderable(ctx: ctx, options: TextOptions(content: .string(text), fg: .rgba(fg)))
        node.maskMatrix[3] = Float(shimmer.r)
        node.maskMatrix[7] = Float(shimmer.g)
        node.maskMatrix[11] = Float(shimmer.b)
        return node
    }

    /// Session tab title shimmer renderable for pending automatic renames (`src/component/title-shimmer.tsx`).
    // parity: tui/src/component/title-shimmer.tsx#TitleShimmerRenderable [status=adapted hash=0224d9e98cab]
    public final class TitleShimmerRenderable: TextRenderable, @unchecked Sendable {
        public struct RenameState: Equatable, Hashable, Sendable {
            public var title: String
            public var pending: Bool

            public init(title: String, pending: Bool) {
                self.title = title
                self.pending = pending
            }
        }

        private var _rename: RenameState?
        private var _enabled: Bool
        private var _backdrop: RGBA
        private var pendingTitle: String?
        public private(set) var elapsed: Double = 0
        public private(set) var blend: Double = 0
        public private(set) var arrival: Double?
        public private(set) var backdropMatrix: [Float] = [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ]

        public init(
            ctx: any RenderContext,
            text: String,
            fg: RGBA,
            renameTitle: String? = nil,
            renamePending: Bool = false,
            enabled: Bool = true,
            backdrop: RGBA = RGBA.fromInts(0, 0, 0)
        ) {
            let initialRename = renameTitle.map { RenameState(title: $0, pending: renamePending) }
            self._rename = initialRename
            self.pendingTitle = initialRename?.title
            self._enabled = enabled
            self._backdrop = backdrop
            super.init(ctx: ctx, options: TextOptions(content: .string(text), fg: .rgba(fg)))
            updateBackdrop()
            updateAnimationState()
        }

        public var renameTitle: String? {
            get { _rename?.title }
            set {
                if let newValue {
                    rename = RenameState(title: newValue, pending: _rename?.pending ?? false)
                } else {
                    rename = nil
                }
            }
        }

        public var renamePending: Bool {
            get { _rename?.pending ?? false }
            set {
                if let current = _rename {
                    rename = RenameState(title: current.title, pending: newValue)
                } else if newValue {
                    rename = RenameState(title: "", pending: true)
                }
            }
        }

        public var shimmerEnabled: Bool {
            get { _enabled }
            set { enabled = newValue }
        }

        // parity: tui/src/component/title-shimmer.tsx#TitleShimmerRenderable.rename [status=implemented hash=b67b98481f7c]
        public var rename: RenameState? {
            get { _rename }
            set {
                if newValue == _rename { return }
                if newValue?.pending == true && _rename?.pending != true {
                    if pendingTitle != newValue?.title { blend = 0 }
                    pendingTitle = newValue?.title
                    if blend == 0 { elapsed = 0 }
                    arrival = nil
                }
                if newValue?.title != _rename?.title {
                    arrival = (newValue != nil && _rename?.pending == true && _enabled) ? 0 : nil
                    if arrival == nil { blend = 0 }
                }
                _rename = newValue
                changed()
            }
        }

        // parity: tui/src/component/title-shimmer.tsx#TitleShimmerRenderable.enabled [status=implemented hash=38555c22577b]
        public var enabled: Bool {
            get { _enabled }
            set {
                guard newValue != _enabled else { return }
                _enabled = newValue
                if !newValue {
                    arrival = nil
                    blend = 0
                }
                changed()
            }
        }

        // parity: tui/src/component/title-shimmer.tsx#TitleShimmerRenderable.backdrop [status=implemented hash=7aafccff8c68]
        public var backdrop: RGBA {
            get { _backdrop }
            set {
                guard newValue != _backdrop else { return }
                _backdrop = newValue
                updateBackdrop()
                requestRender()
            }
        }

        public var isShimmering: Bool {
            _enabled && (_rename?.pending == true) && (_rename?.title == pendingTitle)
        }

        private var isAnimating: Bool {
            _enabled && (isShimmering || arrival != nil || blend > 0)
        }

        private func updateBackdrop() {
            backdropMatrix[3] = Float(_backdrop.r)
            backdropMatrix[7] = Float(_backdrop.g)
            backdropMatrix[11] = Float(_backdrop.b)
        }

        private static let shimmerDuration: Double = 1200
        private static let shimmerFade: Double = 240
        private static let arrivalDuration: Double = 450

        /// The app's frame rate, on the shared clock, only while animating and drawn. The clock's first tick measures
        /// from the subscription, so a fade never inherits time spent idle before it started.
        private func updateAnimationState() {
            animationFps = isAnimating ? 60 : nil
        }

        private func changed() {
            updateAnimationState()
            requestRender()
        }

        public override func onAnimationTick(deltaTime: Double, ticks: Int, time: Double) {
            elapsed = (elapsed + deltaTime).truncatingRemainder(dividingBy: Self.shimmerDuration)
            if let current = arrival {
                let next = current + deltaTime
                if next >= Self.arrivalDuration {
                    arrival = nil
                    blend = 0
                } else {
                    arrival = next
                }
            }
            let rising = isShimmering || arrival != nil
            blend = max(0, min(1, blend + (rising ? deltaTime : -deltaTime) / Self.shimmerFade))
            changed()
        }
    }

    // MARK: - Error Component, Media Source, Model Options, Panel Host, PatchDiff, PluginRouteMissing, TodoItem

    // parity: tui/src/component/error-component.tsx#ErrorComponent [status=adapted hash=0833b7f924f5]
    public static func ErrorComponent(
        ctx: any RenderContext,
        error: any Error,
        mode: Mode = .dark,
        version: String = "2.0.0",
        onReset: (@Sendable () -> Void)? = nil,
        onQuit: (@Sendable () -> Void)? = nil
    ) -> BoxRenderable {
        let isLight = mode == .light
        let bg = RGBA.fromHex(isLight ? "#ffffff" : "#0a0a0a")
        let text = RGBA.fromHex(isLight ? "#1a1a1a" : "#eeeeee")
        let muted = RGBA.fromHex(isLight ? "#8a8a8a" : "#808080")
        let errColor = RGBA.fromHex(isLight ? "#d1383d" : "#e06c75")
        let msg = TUIUtil.errorMessage(error)
        let box = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "error-boundary",
                width: .percent(100),
                flexDirection: .column,
                paddingTop: .point(1),
                paddingRight: .point(2),
                paddingBottom: .point(1),
                paddingLeft: .point(2),
                gap: .point(1),
                backgroundColor: .rgba(bg)
            )
        )
        box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("Something went wrong (v\(version))"), fg: .rgba(errColor), attributes: TextAttributes.bold)))
        box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(msg), fg: .rgba(text), wrapMode: .word)))
        box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(TUIUtil.describeOS()) · \(TUIUtil.describeTerminal())"), fg: .rgba(muted))))
        let actionsRow = BoxRenderable(ctx: ctx, options: BoxOptions(flexDirection: .row, gap: .point(2)))
        let restart = TextRenderable(ctx: ctx, options: TextOptions(content: .string("[r] Restart"), fg: .rgba(text)))
        if let onReset { restart.onMouseUp = { _ in onReset() } }
        let quit = TextRenderable(ctx: ctx, options: TextOptions(content: .string("[q] Quit"), fg: .rgba(muted)))
        if let onQuit { quit.onMouseUp = { _ in onQuit() } }
        actionsRow.add(restart)
        actionsRow.add(quit)
        box.add(actionsRow)
        return box
    }

    public final class MediaSourceHandle: Sendable {
        private struct State: Sendable {
            var uri: String
            var bytes: [UInt8]?
            var failed: Bool = false
        }

        private let state: Mutex<State>
        private let cache: TUIUtil.MediaCache?

        public init(uri: String, cache: TUIUtil.MediaCache? = nil) {
            self.cache = cache
            self.state = Mutex(State(uri: uri, bytes: nil, failed: false))
        }

        public var failed: Bool { state.withLock { $0.failed } }
        public var uri: String { state.withLock { $0.uri } }
        public var bytes: [UInt8]? { state.withLock { $0.bytes } }

        public func onError() { state.withLock { $0.failed = true } }

        public func load() async {
            let currentUri = state.withLock { $0.uri }
            guard TUIUtil.MediaCache.mediaHash(from: currentUri) != nil else { return }
            guard let cache else {
                state.withLock { $0.failed = true }
                return
            }
            if let cached = await cache.peek(currentUri) {
                state.withLock { $0.bytes = cached; $0.failed = false }
                return
            }
            do {
                let loaded = try await cache.read(currentUri)
                state.withLock { $0.bytes = loaded; $0.failed = false }
            } catch {
                state.withLock { $0.failed = true }
            }
        }
    }

    // parity: tui/src/component/media-source.ts#createMediaSource [status=adapted hash=c60df9c565fe]
    public static func createMediaSource(uri: String, cache: TUIUtil.MediaCache? = nil) -> MediaSourceHandle {
        MediaSourceHandle(uri: uri, cache: cache)
    }

    // MARK: Model Options (`src/component/model-options.tsx`)

    public struct SortableModelOption: Equatable, Hashable, Sendable {
        public let providerID: String
        public let modelID: String
        public let providerName: String
        public let free: Bool

        public init(providerID: String, modelID: String, providerName: String = "", free: Bool = false) {
            self.providerID = providerID
            self.modelID = modelID
            self.providerName = providerName
            self.free = free
        }

        public var preferenceKey: String { "\(providerID)/\(modelID)" }
    }

    // parity: tui/src/component/model-options.tsx#prioritizeFavorites [status=implemented hash=2ec7808efd22]
    public static func prioritizeFavorites(_ options: [SortableModelOption], favorites: Set<String>) -> [SortableModelOption] {
        options.enumerated().sorted { lhs, rhs in
            let lf = favorites.contains(lhs.element.preferenceKey)
            let rf = favorites.contains(rhs.element.preferenceKey)
            if lf != rf { return lf }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    // parity: tui/src/component/model-options.tsx#sortModelOptions [status=implemented hash=d28d1a6577e1]
    public static func sortModelOptions(_ options: [SortableModelOption], grouped: Bool = true) -> [SortableModelOption] {
        options.enumerated().sorted { lhs, rhs in
            let a = lhs.element
            let b = rhs.element
            if grouped {
                let aGo = a.providerID == "opencode-go" ? 1 : 0
                let bGo = b.providerID == "opencode-go" ? 1 : 0
                if aGo != bGo { return aGo > bGo }
                let aOc = a.providerID == "opencode" ? 1 : 0
                let bOc = b.providerID == "opencode" ? 1 : 0
                if aOc != bOc { return aOc > bOc }
                let cmp = a.providerName.localizedStandardCompare(b.providerName)
                if cmp != .orderedSame { return cmp == .orderedAscending }
            }
            if a.free != b.free { return a.free }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    // parity: tui/src/component/model-options.tsx#isFreeModel [status=implemented hash=0da1e26cff21]
    public static func isFreeModel(inputCosts: [Double]) -> Bool {
        !inputCosts.isEmpty && inputCosts.allSatisfy { $0 == 0 }
    }

    // parity: tui/src/component/model-options.tsx#FavoriteMarker [status=implemented hash=de9ddef4e5e2]
    public static func FavoriteMarker(theme: ResolvedTheme) -> TextChunk {
        TextChunk(text: "*", fg: theme.surface(.dialog).text.formfield.selected)
    }

    // parity: tui/src/component/model-options.tsx#ModelDetail [status=adapted hash=efe4600dae1a]
    public static func ModelDetail(
        ctx: any RenderContext,
        inputCost: Double?,
        outputCost: Double?,
        modalities: [String],
        contextLimit: Int,
        hasReasoning: Bool,
        showPrice: Bool = true,
        usage: LimitLabelResult? = nil,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let surface = theme.surface(.dialog)
        let row = BoxRenderable(ctx: ctx, options: BoxOptions(width: .percent(100), flexDirection: .row, justifyContent: .spaceBetween, gap: .point(2)))
        var facts: [String] = []
        if !modalities.isEmpty { facts.append(modalities.joined(separator: ", ")) }
        facts.append(TUIUtil.number(contextLimit))
        if hasReasoning { facts.append("Reasoning") }

        if let usage {
            row.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(usage.text), fg: .rgba(usage.danger ? surface.text.feedback.error.base : surface.text.muted), wrapMode: TextWrapMode.none)))
        } else if showPrice {
            let priceText: String
            if let i = inputCost, i == 0 {
                priceText = "Free"
            } else if let i = inputCost, let o = outputCost {
                priceText = "\(TUIUtil.formatDollars(i))/\(TUIUtil.formatDollars(o))"
            } else {
                priceText = ""
            }
            row.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(priceText), fg: .rgba(surface.text.muted), wrapMode: TextWrapMode.none)))
        }
        row.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(facts.joined(separator: " · ")), fg: .rgba(surface.text.muted), wrapMode: TextWrapMode.none)))
        return row
    }

    // MARK: Panel Host, PatchDiff, PluginRouteMissing, TodoItem

    // parity: tui/src/component/panel-host.tsx#PanelHost [status=adapted hash=d9c0532b5869]
    public static func PanelHost(
        ctx: any RenderContext,
        manager: TUIPluginHost.PluginManager,
        panelName: String,
        sessionID: String,
        presentation: String = "panel",
        theme: ResolvedTheme,
        toast: TUIPrimitive.ToastContext,
        onFocus: (@Sendable () -> Void)? = nil
    ) -> BoxRenderable {
        let bg = presentation == "panel" ? theme.background.raised.base : theme.background.base
        let host = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "session-panel",
                flexGrow: 1,
                focusable: true,
                onMouseDown: { _ in onFocus?() },
                backgroundColor: .rgba(bg)
            )
        )
        if let slot = try? TUIPluginHost.Slot(
            ctx: ctx,
            manager: manager,
            path: "session.panel",
            input: ["name": .string(panelName), "sessionID": .string(sessionID)],
            toast: toast
        ) {
            host.add(slot)
        }
        return host
    }

    // parity: tui/src/component/patch-diff.tsx#PatchDiffRef [status=implemented hash=5efa47ac3029]
    public struct PatchDiffRef: Sendable {
        public let hunks: [TUIUtil.PatchHunk]
        public let gutterMinDigits: Int

        public init(hunks: [TUIUtil.PatchHunk], gutterMinDigits: Int) {
            self.hunks = hunks
            self.gutterMinDigits = gutterMinDigits
        }
    }

    /// Renders a multi-hunk unified diff patch using `OpenTUIRenderables.DiffRenderable`, matching `patch-diff.tsx`.
    // parity: tui/src/component/patch-diff.tsx#PatchDiff [status=adapted hash=0e1c94d10a7f]
    public static func PatchDiff(
        ctx: any RenderContext,
        diff: String,
        filetype: String? = nil,
        view: DiffViewMode = .unified,
        gutterPadding: Int = 0,
        theme: ResolvedTheme,
        onRef: ((PatchDiffRef) -> Void)? = nil
    ) -> BoxRenderable {
        let hunks = TUIUtil.splitPatchHunks(diff)
        let maxLine = maxLineNumberInPatch(diff)
        let minDigits = String(max(1, maxLine)).count
        onRef?(PatchDiffRef(hunks: hunks, gutterMinDigits: minDigits))

        let container = BoxRenderable(ctx: ctx, options: BoxOptions(id: "patch-diff", width: .percent(100), flexDirection: .column))
        let syntax = generateSyntax(theme.tokens)
        for (idx, hunk) in hunks.enumerated() {
            if idx > 0, let header = hunk.header {
                let headerBar = BoxRenderable(
                    ctx: ctx,
                    options: BoxOptions(width: .percent(100), height: .point(1), backgroundColor: .rgba(theme.diff.background.context))
                )
                headerBar.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(" \(header)"), fg: .rgba(theme.diff.text.hunkHeader), bg: .rgba(theme.diff.background.context))))
                container.add(headerBar)
            }
            let diffNode = DiffRenderable(
                ctx: ctx,
                options: DiffOptions(
                    diff: hunk.patch,
                    view: view,
                    fg: .rgba(theme.text.base),
                    filetype: filetype,
                    syntaxStyle: syntax,
                    showLineNumbers: true,
                    lineNumberFg: .rgba(theme.diff.lineNumber.text),
                    lineNumberBg: .rgba(theme.diff.background.context),
                    addedBg: .rgba(theme.diff.background.added),
                    removedBg: .rgba(theme.diff.background.removed),
                    contextBg: .rgba(theme.diff.background.context),
                    addedSignColor: .rgba(theme.diff.text.added),
                    removedSignColor: .rgba(theme.diff.text.removed),
                    addedLineNumberBg: .rgba(theme.diff.lineNumber.background.added),
                    removedLineNumberBg: .rgba(theme.diff.lineNumber.background.removed),
                    minHeight: hunk.rows.map { .point(Float($0)) }
                )
            )
            let _ = gutterPadding
            container.add(diffNode)
        }
        return container
    }

    private static func maxLineNumberInPatch(_ diff: String) -> Int {
        let pattern = #"(?m)^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 1 }
        let matches = regex.matches(in: diff, range: NSRange(diff.startIndex..., in: diff))
        var maxLine = 1
        for m in matches {
            let oldStart = Range(m.range(at: 1), in: diff).flatMap { Int(diff[$0]) } ?? 1
            let oldCount = Range(m.range(at: 2), in: diff).flatMap { Int(diff[$0]) } ?? 1
            let newStart = Range(m.range(at: 3), in: diff).flatMap { Int(diff[$0]) } ?? 1
            let newCount = Range(m.range(at: 4), in: diff).flatMap { Int(diff[$0]) } ?? 1
            maxLine = max(maxLine, oldStart + oldCount - 1, newStart + newCount - 1)
        }
        return maxLine
    }

    // parity: tui/src/component/plugin-route-missing.tsx#PluginRouteMissing [status=adapted hash=d1ef60887e67]
    public static func PluginRouteMissing(
        ctx: any RenderContext,
        id: String,
        name: String,
        theme: ResolvedTheme,
        onHome: @escaping @Sendable () -> Void
    ) -> BoxRenderable {
        let box = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "plugin-route-missing",
                width: .percent(100),
                height: .percent(100),
                flexDirection: .column,
                alignItems: .center,
                justifyContent: .center,
                gap: .point(1)
            )
        )
        box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("Unknown plugin route: \(id)/\(name)"), fg: .rgba(theme.text.feedback.warning.base))))
        let btn = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                paddingRight: .point(1),
                paddingLeft: .point(1),
                onMouseUp: { _ in onHome() },
                backgroundColor: .rgba(theme.background.action.primary.hovered)
            )
        )
        btn.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("go home"), fg: .rgba(theme.text.action.primary.hovered))))
        box.add(btn)
        return box
    }

    // parity: tui/src/component/todo-item.tsx#TodoItem [status=adapted hash=648e48c68e60]
    public static func TodoItem(
        ctx: any RenderContext,
        todo: TUIUtil.Todo,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let fg: RGBA
        switch todo.status {
        case .inProgress: fg = theme.text.feedback.warning.base
        case .cancelled: fg = theme.text.faint
        case .pending, .completed: fg = theme.text.muted
        }
        let row = BoxRenderable(ctx: ctx, options: BoxOptions(flexDirection: .row))
        row.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(TUIUtil.todoMarker(todo.status)) "), fg: .rgba(fg))))
        row.add(
            TextRenderable(
                ctx: ctx,
                options: TextOptions(
                    content: .string(todo.content),
                    flexGrow: 1,
                    fg: .rgba(fg),
                    attributes: todo.status == .cancelled ? TextAttributes.strikethrough : TextAttributes.none,
                    wrapMode: .word
                )
            )
        )
        return row
    }

    // MARK: - Prompt Subsystem (`src/component/prompt/*`)

    public enum AutocompleteVisibility: String, Equatable, Hashable, Sendable {
        case hidden
        case reference
        case command
        case directory
    }

    // parity: tui/src/component/prompt/autocomplete.tsx#AutocompleteOption [status=implemented hash=fafe4e1798e3]
    public struct AutocompleteOption: Equatable, Hashable, Sendable {
        public let display: String
        public let value: String?
        public let aliases: [String]
        public let disabled: Bool
        public let description: String?
        public let isDirectory: Bool
        public let path: String?
        public let kind: String?
        public let queueable: Bool

        public init(
            display: String,
            value: String? = nil,
            aliases: [String] = [],
            disabled: Bool = false,
            description: String? = nil,
            isDirectory: Bool = false,
            path: String? = nil,
            kind: String? = nil,
            queueable: Bool = false
        ) {
            self.display = display
            self.value = value
            self.aliases = aliases
            self.disabled = disabled
            self.description = description
            self.isDirectory = isDirectory
            self.path = path
            self.kind = kind
            self.queueable = queueable
        }
    }

    // parity: tui/src/component/prompt/autocomplete.tsx#AutocompleteRef [status=adapted hash=e251c263644d]
    public final class AutocompleteRef: Sendable {
        private struct State: Sendable {
            var visible: AutocompleteVisibility = .hidden
            var query: String = ""
            var selectedIndex: Int = 0
        }

        private let state = Mutex(State())

        public init() {}

        public var visible: AutocompleteVisibility { state.withLock { $0.visible } }
        public var query: String { state.withLock { $0.query } }
        public var selectedIndex: Int { state.withLock { $0.selectedIndex } }

        public func onInput(_ value: String) {
            state.withLock { s in
                if value.hasPrefix("/") {
                    s.visible = .command
                    s.query = String(value.dropFirst())
                } else if let at = value.lastIndex(of: "@") {
                    s.visible = .reference
                    s.query = String(value[value.index(after: at)...])
                } else {
                    s.visible = .hidden
                    s.query = ""
                }
                s.selectedIndex = 0
            }
        }

        public func completeQueueableCommand() -> Bool {
            state.withLock { $0.visible == .command }
        }
    }

    // parity: tui/src/component/prompt/autocomplete.tsx#Autocomplete [status=adapted hash=518ca1d95020]
    public static func Autocomplete(
        ctx: any RenderContext,
        options: [AutocompleteOption],
        selectedIndex: Int = 0,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let box = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "prompt-autocomplete",
                width: .percent(100),
                flexDirection: .column,
                backgroundColor: .rgba(theme.background.raised.high)
            )
        )
        for (idx, opt) in options.filter({ !$0.disabled }).prefix(10).enumerated() {
            let active = idx == selectedIndex
            let fg = active ? theme.text.action.primary.focused : theme.text.base
            let bg: Color? = active ? .rgba(theme.background.action.primary.focused) : nil
            let desc = opt.description.map { " \($0)" } ?? ""
            box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(opt.display)\(desc)"), fg: .rgba(fg), bg: bg, wrapMode: TextWrapMode.none, truncate: true)))
        }
        return box
    }

    // MARK: Prompt Draft Stash (`src/component/prompt/draft-stash.ts`)

    public struct PromptTextState: Equatable, Hashable, Sendable {
        public var text: String
        public var mode: String

        public init(text: String = "", mode: String = "normal") {
            self.text = text
            self.mode = mode
        }
    }

    // parity: tui/src/component/prompt/draft-stash.ts#DraftEntry [status=implemented hash=b9b6518321f9]
    public struct DraftEntry: Equatable, Hashable, Sendable {
        public let prompt: PromptTextState
        public let cursor: Int

        public init(prompt: PromptTextState, cursor: Int) {
            self.prompt = prompt
            self.cursor = cursor
        }
    }

    // parity: tui/src/component/prompt/index.tsx#PromptProps [status=implemented hash=0006fbf304ed]
    public struct PromptProps: Equatable, Hashable, Sendable {
        public let sessionID: String?
        public let placeholder: String
        public let mode: String
        public let disabled: Bool

        public init(sessionID: String? = nil, placeholder: String = "Ask anything…", mode: String = "normal", disabled: Bool = false) {
            self.sessionID = sessionID
            self.placeholder = placeholder
            self.mode = mode
            self.disabled = disabled
        }
    }

    // parity: tui/src/component/prompt/index.tsx#PromptRef [status=adapted hash=82145e03bc53]
    public final class PromptRef: Sendable {
        private let state: Mutex<PromptTextState>

        public init(initial: PromptTextState = PromptTextState()) {
            self.state = Mutex(initial)
        }

        public var current: PromptTextState { state.withLock { $0 } }

        public func set(_ next: PromptTextState) { state.withLock { $0 = next } }
        public func setMode(_ mode: String) { state.withLock { $0.mode = mode } }
        public func reset() { state.withLock { $0 = PromptTextState() } }
    }

    private struct DraftStashStorage: Sendable {
        var byTab: [String: DraftEntry] = [:]
        var composers: [String: PromptRef] = [:]
    }

    private static let draftStash = Mutex(DraftStashStorage())

    // parity: tui/src/component/prompt/draft-stash.ts#takeDraft [status=implemented hash=e2ce1c3cf9dd]
    public static func takeDraft(sessionID: String?) -> DraftEntry? {
        let key = sessionID ?? "__home__"
        return draftStash.withLock { $0.byTab.removeValue(forKey: key) }
    }

    // parity: tui/src/component/prompt/draft-stash.ts#saveDraft [status=implemented hash=4ca592610189]
    public static func saveDraft(sessionID: String?, entry: DraftEntry) {
        let key = sessionID ?? "__home__"
        draftStash.withLock { $0.byTab[key] = entry }
    }

    // parity: tui/src/component/prompt/draft-stash.ts#registerComposer [status=implemented hash=fc703e662bb4]
    @discardableResult
    public static func registerComposer(sessionID: String?, composer: PromptRef) -> @Sendable () -> Void {
        let key = sessionID ?? "__home__"
        draftStash.withLock { $0.composers[key] = composer }
        return {
            draftStash.withLock { s in
                if s.composers[key] === composer {
                    _ = s.composers.removeValue(forKey: key)
                }
            }
        }
    }

    // parity: tui/src/component/prompt/draft-stash.ts#appendToSessionPrompt [status=implemented hash=11cb89cb7850]
    @discardableResult
    public static func appendToSessionPrompt(sessionID: String, text: String) -> PromptRef? {
        let composer = draftStash.withLock { $0.composers[sessionID] }
        guard let composer else {
            let existing = takeDraft(sessionID: sessionID)?.prompt.text ?? ""
            let combined = existing.isEmpty ? text : "\(existing)\n\(text)"
            saveDraft(sessionID: sessionID, entry: DraftEntry(prompt: PromptTextState(text: combined), cursor: combined.utf16.count))
            return nil
        }
        composer.setMode("normal")
        let cur = composer.current.text
        let combined = cur.isEmpty ? text : "\(cur)\n\(text)"
        composer.set(PromptTextState(text: combined, mode: "normal"))
        return composer
    }

    // parity: tui/src/component/prompt/index.tsx#PromptInterruptStatus [status=adapted hash=ecb7c141fadb]
    public static func PromptInterruptStatus(
        ctx: any RenderContext,
        interrupting: Bool,
        theme: ResolvedTheme
    ) -> TextRenderable? {
        guard interrupting else { return nil }
        return TextRenderable(ctx: ctx, options: TextOptions(content: .string("Press esc again to interrupt"), fg: .rgba(theme.text.feedback.warning.base)))
    }

    // MARK: Prompt editor context and chips (`src/component/prompt/index.tsx`)

    private static func hasEditorRangeSelection(_ range: TUIContext.EditorSelectionRange) -> Bool {
        range.selection.start.line != range.selection.end.line
            || range.selection.start.character != range.selection.end.character
    }

    private static func editorRangeLabel(_ range: TUIContext.EditorSelectionRange) -> String? {
        guard hasEditorRangeSelection(range) else { return nil }
        if range.selection.start.line == range.selection.end.line { return "#\(range.selection.start.line)" }
        return "#\(range.selection.start.line)-\(range.selection.end.line)"
    }

    /// The editor context the prompt sends with a message, wrapped in a `<system-update>` note.
    public static func formatEditorContext(_ selection: TUIContext.EditorSelection) -> String {
        let selected = selection.ranges.filter(hasEditorRangeSelection)
        if selected.isEmpty {
            return "<system-update>Note: The user opened the file \"\(selection.filePath)\". This may or may not be relevant to the current task.</system-update>\n"
        }
        let ranges = selected.enumerated().map { index, range in
            let prefix = selected.count > 1 ? "Selection \(index + 1): " : ""
            return "Note: The user selected \(prefix)\(editorRangeLabel(range) ?? "") from \"\(selection.filePath)\". ```\(range.text)```\n\n"
        }
        return "<system-update>\(ranges.joined(separator: "\n")) This may or may not be relevant to the current task.</system-update>\n"
    }

    /// Undo restores a deleted chip's mark, with its ``TUIPrompt/ChipData``, after its part left the prompt. Rebinds
    /// the chip to a copy of its part appended to `prompt`, and returns the new part reference.
    ///
    /// A second chip for an attached file moves the first part's mention instead of adding one, so a file already in
    /// the prompt is not appended again.
    public static func rebindChip(_ prompt: inout TUIPrompt.PromptInfo, data: TUIPrompt.ChipData?) -> TUIPrompt.PromptPartRef? {
        if let file = data?.file, !prompt.files.contains(where: { $0.uri == file.uri }) {
            prompt.files.append(file)
            return TUIPrompt.PromptPartRef(type: .file, index: prompt.files.count - 1)
        }
        if let agent = data?.agent {
            prompt.agents.append(agent)
            return TUIPrompt.PromptPartRef(type: .agent, index: prompt.agents.count - 1)
        }
        if let skill = data?.skill {
            prompt.skills.append(skill)
            return TUIPrompt.PromptPartRef(type: .skill, index: prompt.skills.count - 1)
        }
        return nil
    }

    /// The chip data each restored prompt part stores on its mark, so undo can bring a deleted chip back.
    public static func chipData(for ref: TUIPrompt.PromptPartRef, in prompt: TUIPrompt.PromptInfo) -> TUIPrompt.ChipData? {
        switch ref.type {
        case .file: return prompt.files.indices.contains(ref.index) ? TUIPrompt.ChipData(file: prompt.files[ref.index]) : nil
        case .agent: return prompt.agents.indices.contains(ref.index) ? TUIPrompt.ChipData(agent: prompt.agents[ref.index]) : nil
        case .skill: return prompt.skills.indices.contains(ref.index) ? TUIPrompt.ChipData(skill: prompt.skills[ref.index]) : nil
        case .pasted: return nil
        }
    }

    // parity: tui/src/component/prompt/index.tsx#Prompt [status=adapted hash=b73c46441519]
    public static func Prompt(
        ctx: any RenderContext,
        props: PromptProps,
        value: String = "",
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let box = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "prompt-composer",
                width: .percent(100),
                flexDirection: .column,
                paddingRight: .point(2),
                paddingLeft: .point(2),
                backgroundColor: .rgba(theme.background.raised.base),
                border: .sides([.left]),
                borderColor: .rgba(props.mode == "shell" ? theme.text.feedback.warning.base : theme.border.base),
                customBorderChars: TUIPrimitive.SplitBorder.customBorderChars
            )
        )
        let display = value.isEmpty ? props.placeholder : value
        box.add(
            TextRenderable(
                ctx: ctx,
                options: TextOptions(
                    id: "prompt-input",
                    content: .string(display),
                    fg: .rgba(value.isEmpty ? theme.text.muted : theme.text.base),
                    wrapMode: .word
                )
            )
        )
        return box
    }

    // MARK: Local Attachments (`src/component/prompt/local-attachment.ts`)

    private static let maxPastedFilepaths = 32

    // parity: tui/src/component/prompt/local-attachment.ts#MAX_LOCAL_ATTACHMENT_BYTES [status=implemented hash=0ec7acf7eba7]
    public static let MAX_LOCAL_ATTACHMENT_BYTES = 20 * 1024 * 1024

    // parity: tui/src/component/prompt/local-attachment.ts#LocalFiles [status=implemented hash=35e1c7c3675a]
    public protocol LocalFiles: Sendable {
        func readText(path: String, maxBytes: Int) async throws -> String
        func readBytes(path: String, maxBytes: Int) async throws -> [UInt8]
        func mime(path: String) async throws -> String
    }

    // parity: tui/src/component/prompt/local-attachment.ts#LocalAttachment [status=implemented hash=bf0135c0509e]
    public enum LocalAttachment: Equatable, Sendable {
        case text(mime: String, content: String)
        case binary(mime: String, content: [UInt8])
    }

    private static let attachmentMimeTypes: [String: String] = [
        ".avif": "image/avif", ".gif": "image/gif", ".jpeg": "image/jpeg",
        ".jpg": "image/jpeg", ".pdf": "application/pdf", ".png": "image/png",
        ".svg": "image/svg+xml", ".webp": "image/webp",
    ]

    private struct DefaultLocalFiles: LocalFiles {
        func mime(path: String) async throws -> String {
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            return attachmentMimeTypes[ext.isEmpty ? "" : ".\(ext)"] ?? "application/octet-stream"
        }

        func readBytes(path: String, maxBytes: Int) async throws -> [UInt8] {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            if let size = attrs[.size] as? Int, size > maxBytes {
                throw ThemeError("Attachment exceeds the local file limit")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            if data.count > maxBytes {
                throw ThemeError("Attachment exceeds the local file limit")
            }
            return Array(data)
        }

        func readText(path: String, maxBytes: Int) async throws -> String {
            let bytes = try await readBytes(path: path, maxBytes: maxBytes)
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    // parity: tui/src/component/prompt/local-attachment.ts#readLocalAttachmentWith [status=implemented hash=ca24e487bed7]
    public static func readLocalAttachmentWith(
        files: any LocalFiles,
        path: String,
        maxBytes: Int = MAX_LOCAL_ATTACHMENT_BYTES
    ) async -> LocalAttachment? {
        guard let mime = try? await files.mime(path: path) else { return nil }
        guard mime.hasPrefix("image/") || mime == "application/pdf" else { return nil }
        if mime == "image/svg+xml" {
            guard let content = try? await files.readText(path: path, maxBytes: maxBytes),
                  !content.isEmpty, content.utf8.count <= maxBytes
            else { return nil }
            return .text(mime: mime, content: content)
        }
        guard let content = try? await files.readBytes(path: path, maxBytes: maxBytes),
              !content.isEmpty, content.count <= maxBytes
        else { return nil }
        return .binary(mime: mime, content: content)
    }

    // parity: tui/src/component/prompt/local-attachment.ts#readLocalAttachment [status=implemented hash=142299388fe9]
    public static func readLocalAttachment(_ file: String, maxBytes: Int = MAX_LOCAL_ATTACHMENT_BYTES) async -> LocalAttachment? {
        await readLocalAttachmentWith(files: DefaultLocalFiles(), path: file, maxBytes: maxBytes)
    }

    // parity: tui/src/component/prompt/local-attachment.ts#normalizePastedFilepath [status=implemented hash=418a7f8dbd25]
    public static func normalizePastedFilepath(_ value: String, platform: String) -> String {
        var raw = value
        while let first = raw.first, first == "'" || first == "\"" { raw.removeFirst() }
        while let last = raw.last, last == "'" || last == "\"" { raw.removeLast() }
        if let decoded = decodeFileURL(raw, platform: platform) { return decoded }
        if platform == "win32" { return raw }
        var out = ""
        var escaped = false
        for ch in raw {
            if escaped {
                out.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        if escaped { out.append("\\") }
        return out
    }

    private static func decodeFileURL(_ value: String, platform: String) -> String? {
        guard value.hasPrefix("file://"), let url = URL(string: value) else { return nil }
        let rawPath = url.path(percentEncoded: true)
        let lower = rawPath.lowercased()
        if lower.contains("%2f") || lower.contains("%5c") { return nil }
        guard let decoded = rawPath.removingPercentEncoding else { return nil }
        let host = url.host ?? ""
        if platform != "win32" {
            if !host.isEmpty && host != "localhost" { return nil }
            return decoded
        }
        var local = decoded
        if local.count >= 3, local.hasPrefix("/") {
            let arr = Array(local)
            if arr[1].isASCII && arr[1].isLetter && arr[2] == ":" {
                local.removeFirst()
            }
        }
        local = local.replacingOccurrences(of: "/", with: "\\")
        if !host.isEmpty && host != "localhost" { return "\\\\\(host)\(local)" }
        return local
    }

    // parity: tui/src/component/prompt/local-attachment.ts#parsePastedFilepaths [status=implemented hash=8dda886fe204]
    public static func parsePastedFilepaths(_ value: String, platform: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character? = nil

        func push() {
            guard !current.isEmpty else { return }
            result.append(decodeFileURL(current, platform: platform) ?? current)
            current = ""
        }

        let input: String
        if value.contains("file://") {
            input = value
                .replacingOccurrences(of: "\r\n", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.drop(while: \.isWhitespace).hasPrefix("#") }
                .joined(separator: "\n")
        } else {
            input = value
        }

        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if let q = quote {
                if ch == q {
                    quote = nil
                    i += 1
                    continue
                }
                if ch == "\\" && platform != "win32" && q == "\"" && i + 1 < chars.count {
                    i += 1
                    current.append(chars[i])
                    i += 1
                    continue
                }
                current.append(ch)
                i += 1
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                i += 1
                continue
            }
            if ch == "\\" && platform != "win32" && i + 1 < chars.count {
                i += 1
                current.append(chars[i])
                i += 1
                continue
            }
            if ch.isWhitespace {
                push()
                if result.count > maxPastedFilepaths { return [] }
                i += 1
                continue
            }
            current.append(ch)
            i += 1
        }
        if quote != nil { return [] }
        push()
        if result.count > maxPastedFilepaths { return [] }
        return result
    }

    public enum ResolvedPastedAttachment: Equatable, Sendable {
        case text(content: String, filename: String)
        case file(uri: String, filename: String, path: String)
    }

    // parity: tui/src/component/prompt/local-attachment.ts#resolvePastedAttachments [status=implemented hash=47e37837bac9]
    public static func resolvePastedAttachments(_ text: String, platform: String) async -> [ResolvedPastedAttachment]? {
        let pastedContent = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let filepath = normalizePastedFilepath(pastedContent, platform: platform)
        if filepath.hasPrefix("http://") || filepath.hasPrefix("https://") { return nil }

        var items: [(String, LocalAttachment)] = []
        if let single = await readLocalAttachment(filepath) {
            items.append((filepath, single))
        } else {
            let paths = parsePastedFilepaths(pastedContent, platform: platform)
            guard paths.count > 1 else { return nil }
            var remaining = MAX_LOCAL_ATTACHMENT_BYTES
            for candidate in paths {
                guard let next = await readLocalAttachment(candidate, maxBytes: remaining) else { return nil }
                switch next {
                case .text(_, let s): remaining -= s.utf8.count
                case .binary(_, let b): remaining -= b.count
                }
                items.append((candidate, next))
            }
        }
        return items.map { path, att in
            let filename = URL(fileURLWithPath: path).lastPathComponent
            switch att {
            case .text(_, let content):
                return .text(content: content, filename: filename)
            case .binary(let mime, let bytes):
                let b64 = Data(bytes).base64EncodedString()
                return .file(uri: "data:\(mime);base64,\(b64)", filename: filename, path: URL(fileURLWithPath: path).standardized.path)
            }
        }
    }

    public struct PromptFileAttachment: Equatable, Hashable, Sendable {
        public let uri: String
        public let path: String?
        public let sourceURI: String?

        public init(uri: String, path: String? = nil, sourceURI: String? = nil) {
            self.uri = uri
            self.path = path
            self.sourceURI = sourceURI
        }
    }

    // parity: tui/src/component/prompt/local-attachment.ts#promptFilesForServer [status=implemented hash=da15578f6cdf]
    public static func promptFilesForServer(_ files: [PromptFileAttachment]?, localServer: Bool) -> [PromptFileAttachment]? {
        files?.map { item in
            if localServer, let file = item.path {
                return PromptFileAttachment(uri: item.uri, path: nil, sourceURI: URL(fileURLWithPath: file).absoluteString)
            }
            return PromptFileAttachment(uri: item.uri, path: nil, sourceURI: nil)
        }
    }

    // MARK: Prompt Metadata & Move (`src/component/prompt/metadata.tsx`, `move.tsx`)

    // parity: tui/src/component/prompt/metadata.tsx#PromptMetadataRow [status=adapted hash=40fd503e2b5b]
    public static func PromptMetadataRow(
        ctx: any RenderContext,
        mode: String = "normal",
        agent: String? = nil,
        model: String = "",
        provider: String = "",
        variant: String? = nil,
        limit: LimitLabelResult? = nil,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let row = BoxRenderable(ctx: ctx, options: BoxOptions(id: "prompt-metadata", flexDirection: .row, gap: .point(1)))
        if mode == "shell" {
            row.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(agent ?? "Shell"), fg: .rgba(theme.text.feedback.warning.base))))
            return row
        }
        if let agent, !agent.isEmpty {
            row.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(agent), fg: .rgba(theme.hue.accent[.s200]))))
        }
        if !model.isEmpty {
            let detail = [model, provider.isEmpty ? nil : provider, variant].compactMap { $0 }.joined(separator: " · ")
            row.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(detail), fg: .rgba(theme.text.base), wrapMode: TextWrapMode.none, truncate: true)))
        }
        if let limit {
            row.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(limit.text), fg: .rgba(limit.danger ? theme.text.feedback.error.base : theme.text.muted), wrapMode: TextWrapMode.none)))
        }
        return row
    }

    public final class PromptMoveController: Sendable {
        private struct State: Sendable {
            var creating: Bool = false
            var progress: String? = nil
            var destination: WorkspaceSelection? = nil
        }

        private let state = Mutex(State())

        public init() {}

        public var creating: Bool { state.withLock { $0.creating } }
        public var progress: String? { state.withLock { $0.progress } }
        public var destination: WorkspaceSelection? { state.withLock { $0.destination } }

        public func setDestination(_ next: WorkspaceSelection?) { state.withLock { $0.destination = next } }
        public func setProgress(_ text: String?, creating: Bool) {
            state.withLock { s in
                s.progress = text
                s.creating = creating
            }
        }
    }

    // parity: tui/src/component/prompt/move.tsx#usePromptMove [status=adapted hash=868cad7f96a0]
    public static func usePromptMove() -> PromptMoveController {
        PromptMoveController()
    }

    // MARK: - Retry Provider (`src/component/retry-provider.tsx`)

    // parity: tui/src/component/retry-provider.tsx#RetryProviderRenderable [status=adapted hash=6bbeee5d778a]
    public final class RetryProviderRenderable: TextRenderable, @unchecked Sendable {
        public struct Value: Equatable, Hashable, Sendable {
            public var id: String
            public var provider: String
            public var running: Bool

            public init(id: String, provider: String, running: Bool) {
                self.id = id
                self.provider = provider
                self.running = running
            }
        }

        private static let fadeDuration: Double = 80
        private static let resizeDuration: Double = 60
        private static let totalDuration: Double = 220

        public private(set) var providerName: String
        private var currentValue: Value?
        private var enabledValue: Bool = true
        private var disposed: Bool = false
        private var transitionElapsed: Double?
        private var sourceText: String = ""
        private var targetText: String = ""
        private var displayedText: String = ""
        public private(set) var transitionOpacity: Double = 1.0
        private var fromOpacity: Double = 1.0

        public init(ctx: any RenderContext, provider: String, fg: RGBA? = nil, enabled: Bool = true) {
            let formatted = TUIUtil.webSearchProviderName(provider)
            self.providerName = formatted
            self.targetText = formatted
            self.displayedText = formatted
            self.enabledValue = enabled
            super.init(ctx: ctx, options: TextOptions(content: .string(formatted), fg: fg.map { .rgba($0) }))
        }

        // parity: tui/src/component/retry-provider.tsx#RetryProviderRenderable.value [status=implemented hash=0d5b6070f850]
        public var value: Value? {
            get { currentValue }
            set {
                guard !disposed, let newValue else { return }
                let previous = currentValue
                currentValue = newValue
                if previous?.id == newValue.id && previous?.provider == newValue.provider { return }
                targetText = TUIUtil.webSearchProviderName(newValue.provider)
                providerName = targetText
                let shouldAnimate = enabledValue
                    && previous?.id == newValue.id
                    && previous?.running == true
                    && newValue.running
                if !shouldAnimate {
                    finishTransition()
                    return
                }
                if let elapsed = transitionElapsed, elapsed < Self.fadeDuration { return }
                sourceText = displayedText
                fromOpacity = transitionOpacity
                let starting = transitionElapsed == nil
                transitionElapsed = 0
                if starting {
                    animationFps = 60
                    requestRender()
                }
            }
        }

        // parity: tui/src/component/retry-provider.tsx#RetryProviderRenderable.enabled [status=implemented hash=2ef0db77733d]
        public var enabled: Bool {
            get { enabledValue }
            set {
                guard newValue != enabledValue else { return }
                enabledValue = newValue
                if !newValue { finishTransition() }
            }
        }

        public func update(provider: String) {
            let next = TUIUtil.webSearchProviderName(provider)
            guard next != providerName else { return }
            providerName = next
            targetText = next
            showText(next, opacity: 1.0)
        }

        public override func onAnimationTick(deltaTime: Double, ticks: Int, time: Double) {
            guard let elapsed = transitionElapsed else { return }
            let nextElapsed = elapsed + deltaTime
            transitionElapsed = nextElapsed
            if nextElapsed >= Self.totalDuration {
                finishTransition()
                return
            }
            if nextElapsed < Self.fadeDuration {
                let progress = TUIComponent.smootherstep(nextElapsed / Self.fadeDuration)
                showText(sourceText, opacity: fromOpacity * (1.0 - progress))
                return
            }
            if nextElapsed < Self.fadeDuration + Self.resizeDuration {
                let fromW = Double(TUIUtil.stringWidth(sourceText))
                let toW = Double(TUIUtil.stringWidth(targetText))
                let p = TUIComponent.smootherstep((nextElapsed - Self.fadeDuration) / Self.resizeDuration)
                let width = max(0, Int((fromW + (toW - fromW) * p).rounded()))
                showText(String(repeating: " ", count: width), opacity: 0.0)
                return
            }
            let p = TUIComponent.smootherstep((nextElapsed - Self.fadeDuration - Self.resizeDuration) / Self.fadeDuration)
            showText(targetText, opacity: p)
        }

        private func showText(_ text: String, opacity nextOpacity: Double) {
            if text == displayedText && nextOpacity == transitionOpacity { return }
            displayedText = text
            transitionOpacity = nextOpacity
            self.opacity = nextOpacity
            content = stringToStyledText(text)
            requestRender()
        }

        private func stopTransition() {
            if transitionElapsed != nil {
                animationFps = nil
            }
            transitionElapsed = nil
        }

        private func finishTransition() {
            stopTransition()
            showText(targetText, opacity: 1.0)
        }

        // parity: tui/src/component/retry-provider.tsx#RetryProviderRenderable.mergeStyles [status=implemented hash=a20b02b12210]
        public func mergeStyles(_ parentStyle: TextNodeStyle) -> TextNodeStyle {
            guard transitionOpacity < 1.0 else { return parentStyle }
            let baseFg = parentStyle.fg ?? RGBA.defaultForeground()
            let faded = RGBA.fromValues(baseFg.r, baseFg.g, baseFg.b, baseFg.a * transitionOpacity)
            return TextNodeStyle(fg: faded, bg: parentStyle.bg, attributes: parentStyle.attributes, link: parentStyle.link)
        }

        // parity: tui/src/component/retry-provider.tsx#RetryProviderRenderable.destroy [status=implemented hash=2b54aa1dc0f0]
        public override func destroy() {
            guard !disposed else { return }
            disposed = true
            stopTransition()
            super.destroy()
        }

        // parity: tui/src/component/retry-provider.tsx#RetryProviderRenderable.destroyRecursively [status=implemented hash=38c10cdeaa8c]
        public override func destroyRecursively() {
            destroy()
        }
    }

    // parity: tui/src/component/retry-provider.tsx#RetryProvider [status=adapted hash=7d3c8085bd0a]
    public static func RetryProvider(
        ctx: any RenderContext,
        provider: String,
        fg: RGBA? = nil
    ) -> RetryProviderRenderable {
        RetryProviderRenderable(ctx: ctx, provider: provider, fg: fg)
    }

    // MARK: - Session Frame, Session Tabs & Rail (`session-frame.tsx`, `session-tabs.tsx`, `session-tabs-rail.tsx`)

    // parity: tui/src/component/session-frame.tsx#SessionFrame [status=adapted hash=c9c518693f80]
    public static func SessionFrame(
        ctx: any RenderContext,
        sessionID: String,
        verticalTabsWidth: Int = 0,
        content: Renderable,
        rightPane: Renderable? = nil,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let frame = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "session-frame-\(sessionID)",
                width: .percent(100),
                height: .percent(100),
                flexDirection: .row,
                backgroundColor: .rgba(theme.background.base)
            )
        )
        let _ = verticalTabsWidth
        frame.add(content)
        if let rightPane { frame.add(rightPane) }
        return frame
    }

    public struct TabSpinnerSpec: Equatable, Hashable, Sendable {
        public let frames: [String]
        public let interval: Double

        public init(frames: [String], interval: Double) {
            self.frames = frames
            self.interval = interval
        }
    }

    // parity: tui/src/component/session-tabs.tsx#TabSpinner [status=implemented hash=a7914a94cc4b]
    public enum TabSpinner: String, Equatable, Hashable, Sendable, CaseIterable {
        case dots
        case arcs
        case quadrants
        case line
    }

    // parity: tui/src/component/session-tabs.tsx#TAB_SPINNERS [status=implemented hash=c5249b4e3f46]
    public static let TAB_SPINNERS: [TabSpinner: TabSpinnerSpec] = [
        .dots: TabSpinnerSpec(frames: SPINNER_FRAMES, interval: 80),
        .arcs: TabSpinnerSpec(frames: ["◜", "◝", "◞", "◟"], interval: 120),
        .quadrants: TabSpinnerSpec(frames: ["◴", "◷", "◶", "◵"], interval: 120),
        .line: TabSpinnerSpec(frames: ["|", "/", "-", "\\"], interval: 120),
    ]

    // parity: tui/src/component/session-tabs.tsx#TabUnreadMarker [status=implemented hash=996ae817e2db]
    public enum TabUnreadMarker: String, Equatable, Hashable, Sendable, CaseIterable {
        case smallDot = "small-dot"
        case dot
        case square
        case largeSquare = "large-square"
    }

    // parity: tui/src/component/session-tabs.tsx#TAB_UNREAD_MARKERS [status=implemented hash=c2873177a4af]
    public static let TAB_UNREAD_MARKERS: [TabUnreadMarker: String] = [
        .smallDot: "•",
        .dot: "●",
        .square: "▪",
        .largeSquare: "■",
    ]

    // parity: tui/src/component/session-tabs.tsx#SessionTabsStatus [status=implemented hash=d0eabf42725b]
    public struct SessionTabsStatus: Equatable, Hashable, Sendable {
        public let unread: String?
        public let promptPulse: Int
        public let attention: SessionAttentionKind?
        public let busy: Bool
        public let renaming: Bool

        public init(
            unread: String? = nil,
            promptPulse: Int = 0,
            attention: SessionAttentionKind? = nil,
            busy: Bool = false,
            renaming: Bool = false
        ) {
            self.unread = unread
            self.promptPulse = promptPulse
            self.attention = attention
            self.busy = busy
            self.renaming = renaming
        }
    }

    // parity: tui/src/component/session-tabs.tsx#EMPTY_SESSION_TAB_STATUS [status=implemented hash=e4004532020d]
    public static let EMPTY_SESSION_TAB_STATUS = SessionTabsStatus()

    public struct SessionTabDescriptor: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let title: String

        public init(sessionID: String, title: String) {
            self.sessionID = sessionID
            self.title = title
        }
    }

    // parity: tui/src/component/session-tabs.tsx#SessionTabsController [status=adapted hash=12b554745fab]
    public struct SessionTabsController: Sendable {
        public let tabs: @Sendable () -> [SessionTabDescriptor]
        public let current: @Sendable () -> String?
        public let select: @Sendable (String) -> Void
        public let close: @Sendable (String) -> Void
        public let status: @Sendable (String) -> SessionTabsStatus
        public let search: (@Sendable () -> Void)?

        public init(
            tabs: @escaping @Sendable () -> [SessionTabDescriptor],
            current: @escaping @Sendable () -> String?,
            select: @escaping @Sendable (String) -> Void = { _ in },
            close: @escaping @Sendable (String) -> Void = { _ in },
            status: @escaping @Sendable (String) -> SessionTabsStatus = { _ in EMPTY_SESSION_TAB_STATUS },
            search: (@Sendable () -> Void)? = nil
        ) {
            self.tabs = tabs
            self.current = current
            self.select = select
            self.close = close
            self.status = status
            self.search = search
        }
    }

    /// Hover marquee for overflowing session tab titles.
    ///
    /// Entering an overflowing title waits ``delay`` ms (the host calls ``begin()`` from its clock timer), then
    /// scrolls one cell per ``interval`` ms on the shared animation clock: ``animationFps`` is non-nil only while
    /// scrolling, and ``tick(_:)`` takes the clock's tick count, so missed frames catch up. One full cycle ends the
    /// scroll back at offset 0.
    public final class MarqueeController: Sendable {
        /// Hover delay before the title starts to scroll (`MARQUEE_DELAY`).
        public static let delay: Double = 600
        /// Milliseconds per scrolled cell (`MARQUEE_INTERVAL`).
        public static let interval: Double = 80

        private struct State: Sendable {
            var offset: Int = 0
            var active: String? = nil
            var cycleWidth: Int = 0
            var hovered: String? = nil
            var scrolling: Bool = false
            /// Set while the hover delay runs; cleared by ``begin()`` or any reset.
            var delayed: Bool = false
        }

        private let state = Mutex(State())

        public init() {}

        public var offset: Int { state.withLock { $0.offset } }
        public var active: String? { state.withLock { $0.active } }
        public var hovered: String? { state.withLock { $0.hovered } }
        public var scrolling: Bool { state.withLock { $0.scrolling } }
        /// Whether the hover delay is pending, so the host should call ``begin()`` after ``delay`` ms.
        public var delayPending: Bool { state.withLock { $0.delayed } }

        /// The shared clock rate while scrolling; `nil` stops the ticks.
        public var animationFps: Double? { state.withLock { $0.scrolling ? 1000 / Self.interval : nil } }

        private static func clear(_ s: inout State) {
            s.delayed = false
            s.scrolling = false
        }

        private static func reset(_ s: inout State) {
            clear(&s)
            s.active = nil
            s.offset = 0
        }

        public func enter(sessionID: String, title: String, width: Int) {
            state.withLock { s in
                s.hovered = sessionID
                guard TUIUtil.marqueeOverflows(title, width: width) else {
                    Self.reset(&s)
                    return
                }
                if s.active == sessionID { return }
                Self.clear(&s)
                s.cycleWidth = TUIUtil.marqueeCycleWidth(title)
                s.active = sessionID
                s.offset = 0
                s.delayed = true
            }
        }

        /// The end of the hover delay: the title moves one cell and starts scrolling.
        public func begin() {
            state.withLock { s in
                guard s.delayed, s.active != nil else { return }
                s.delayed = false
                s.offset = 1
                s.scrolling = true
            }
        }

        /// Advances by the clock's `ticks`; reaching the cycle width ends the scroll at offset 0.
        public func tick(_ ticks: Int = 1) {
            state.withLock { s in
                guard s.scrolling else { return }
                if s.offset + ticks < s.cycleWidth {
                    s.offset += ticks
                    return
                }
                Self.clear(&s)
                s.offset = 0
            }
        }

        public func leave(sessionID: String) {
            state.withLock { s in
                if s.hovered == sessionID { s.hovered = nil }
                if s.active == sessionID { Self.reset(&s) }
            }
        }

        public func reset() {
            state.withLock { s in
                Self.reset(&s)
                s.hovered = nil
                s.cycleWidth = 0
            }
        }
    }

    // parity: tui/src/component/session-tabs.tsx#createMarquee [status=adapted hash=0156237c174c]
    public static func createMarquee() -> MarqueeController {
        MarqueeController()
    }

    // parity: tui/src/component/session-tabs.tsx#createTabMarquee [status=adapted hash=104db89819c6]
    public static func createTabMarquee() -> MarqueeController {
        MarqueeController()
    }

    // parity: tui/src/component/session-tabs.tsx#SessionTabs [status=adapted hash=58dd4d865931]
    public static func SessionTabs(
        ctx: any RenderContext,
        controller: SessionTabsController,
        vertical: Bool = false,
        width: Int = 80,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let strip = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "session-tabs",
                width: .point(Float(width)),
                flexDirection: vertical ? .column : .row,
                gap: .point(1),
                backgroundColor: .rgba(theme.background.raised.base)
            )
        )
        let currentID = controller.current()
        for tab in controller.tabs() {
            let isCurrent = tab.sessionID == currentID
            let st = controller.status(tab.sessionID)
            let marker: String
            if let att = st.attention {
                marker = att == .permission ? "! " : "? "
            } else if st.busy {
                marker = "⠋ "
            } else if st.unread != nil {
                marker = "• "
            } else {
                marker = ""
            }
            let item = TextRenderable(
                ctx: ctx,
                options: TextOptions(
                    content: .string("\(marker)\(tab.title)"),
                    fg: .rgba(isCurrent ? theme.text.base : theme.text.muted),
                    bg: isCurrent ? .rgba(theme.background.raised.high) : nil,
                    attributes: isCurrent ? TextAttributes.bold : TextAttributes.none,
                    wrapMode: TextWrapMode.none,
                    truncate: true
                )
            )
            let sid = tab.sessionID
            item.onMouseUp = { _ in controller.select(sid) }
            strip.add(item)
        }
        return strip
    }

    // parity: tui/src/component/session-tabs-rail.tsx#SessionTabHalfRow [status=adapted hash=5de57a719088]
    public static func SessionTabHalfRow(
        ctx: any RenderContext,
        top: Int,
        edge: String,
        width: Int,
        color: RGBA,
        background: RGBA
    ) -> TextRenderable {
        let glyph = edge == "top" ? "▄" : "▀"
        return TextRenderable(
            ctx: ctx,
            options: TextOptions(
                content: .string(String(repeating: glyph, count: max(0, width))),
                width: .point(Float(max(0, width))),
                height: .point(1),
                position: .absolute,
                top: .point(Float(top)),
                left: .point(0),
                zIndex: 1,
                fg: .rgba(color),
                bg: .rgba(background),
                wrapMode: TextWrapMode.none
            )
        )
    }

    // parity: tui/src/component/session-tabs-rail.tsx#SessionTabsRailControls [status=adapted hash=cea8a1b1b434]
    public static func SessionTabsRailControls(
        ctx: any RenderContext,
        width: Int,
        tabs: SessionTabsController,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let box = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "session-tabs-rail-controls",
                width: .point(Float(max(1, width))),
                height: .point(1),
                justifyContent: .center,
                onMouseUp: { _ in tabs.search?() },
                backgroundColor: .rgba(theme.background.raised.base)
            )
        )
        box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("⌕"), fg: .rgba(theme.text.action.secondary.base), wrapMode: TextWrapMode.none)))
        return box
    }

    // MARK: - Terminal Pane & Palette (`src/component/terminal-pane.tsx`)

    /// Builds OSC 4 / OSC 10 / OSC 11 terminal palette bytes from a resolved semantic theme.
    // parity: tui/src/component/terminal-pane.tsx#terminalPalette [status=implemented hash=571cbda1cdb6]
    public static func terminalPalette(
        theme: ResolvedThemeTokens,
        mode: Mode,
        background: RGBA
    ) -> [UInt8] {
        let black = theme.hue.neutral[mode == .dark ? .s800 : .s200]
        let white = theme.hue.neutral[mode == .dark ? .s200 : .s800]
        let brightWhite = theme.hue.neutral[mode == .dark ? .s100 : .s900]
        let blue = nearestTerminalHue(theme: theme, targetHue: rgbToOklch(0, 0, 1).h)
        let magenta = nearestTerminalHue(theme: theme, targetHue: rgbToOklch(1, 0, 1).h)
        let normal = [
            theme.text.feedback.error.base,
            theme.text.feedback.success.base,
            theme.text.feedback.warning.base,
            blue,
            magenta,
            theme.text.feedback.info.base,
            white,
        ]
        var colors = [black] + normal + [theme.text.muted]
        colors.append(contentsOf: normal.dropLast().map { theme.decrease($0) })
        colors.append(brightWhite)

        func hexRGB(_ color: RGBA) -> String {
            let (r, g, b, _) = color.toInts()
            return "#\(byte(r))\(byte(g))\(byte(b))"
        }

        var seq = ""
        for (idx, color) in colors.enumerated() {
            seq += "\u{1B}]4;\(idx);\(hexRGB(color))\u{1B}\\"
        }
        seq += "\u{1B}]10;\(hexRGB(theme.text.base))\u{1B}\\"
        seq += "\u{1B}]11;\(hexRGB(background))\u{1B}\\"
        return Array(seq.utf8)
    }

    private static func nearestTerminalHue(theme: ResolvedThemeTokens, targetHue: Double) -> RGBA {
        var best: (color: RGBA, distance: Double)? = nil
        for scale in theme.hue.scales.values {
            let color = scale[.s400]
            let (r, g, b, a) = color.toInts()
            guard a > 0 else { continue }
            let oklch = rgbToOklch(Double(r) / 255.0, Double(g) / 255.0, Double(b) / 255.0)
            guard oklch.c >= 0.03 else { continue }
            let diff = abs(oklch.h - targetHue)
            let dist = min(diff, 360.0 - diff)
            if best == nil || dist < best!.distance {
                best = (color, dist)
            }
        }
        if let best, best.distance <= 30.0 {
            return best.color
        }
        return theme.hue.accent[.s400]
    }

    // parity: tui/src/component/terminal-pane.tsx#TerminalPane [status=adapted hash=8ff7136822d1]
    public static func TerminalPane(
        ctx: any RenderContext,
        ptyID: String,
        failure: String? = nil,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let pane = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "terminal-pane-\(ptyID)",
                flexGrow: 1,
                backgroundColor: .rgba(theme.background.base)
            )
        )
        if let failure {
            pane.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(failure), fg: .rgba(theme.text.feedback.error.base))))
        } else {
            pane.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("Terminal \(ptyID)"), fg: .rgba(theme.text.muted))))
        }
        return pane
    }
}
