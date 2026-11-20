import Foundation
import OpenCodeCore
import OpenCodeSchema
import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables
import Synchronization

extension Merman {
    public struct MermaidPaletteColorOverrides: Equatable, Hashable, Sendable {
        public var text: Color?
        public var primary: Color?
        public var secondary: Color?
        public var muted: Color?
        public var warning: Color?
        public var background: Color?
        public var request: Color?
        public var response: Color?
        public var note: Color?
        public var noteBackground: Color?
        public var boxText: Color?
        public var boxBorder: Color?
        public var line: Color?
        public var labelBackground: Color?
        public var group: Color?
        public var groupText: Color?
        public var marker: Color?
        public var noteBorder: Color?
        public var noteText: Color?
        public var noteConnector: Color?

        public init(
            text: Color? = nil,
            primary: Color? = nil,
            secondary: Color? = nil,
            muted: Color? = nil,
            warning: Color? = nil,
            background: Color? = nil,
            request: Color? = nil,
            response: Color? = nil,
            note: Color? = nil,
            noteBackground: Color? = nil,
            boxText: Color? = nil,
            boxBorder: Color? = nil,
            line: Color? = nil,
            labelBackground: Color? = nil,
            group: Color? = nil,
            groupText: Color? = nil,
            marker: Color? = nil,
            noteBorder: Color? = nil,
            noteText: Color? = nil,
            noteConnector: Color? = nil
        ) {
            self.text = text
            self.primary = primary
            self.secondary = secondary
            self.muted = muted
            self.warning = warning
            self.background = background
            self.request = request
            self.response = response
            self.note = note
            self.noteBackground = noteBackground
            self.boxText = boxText
            self.boxBorder = boxBorder
            self.line = line
            self.labelBackground = labelBackground
            self.group = group
            self.groupText = groupText
            self.marker = marker
            self.noteBorder = noteBorder
            self.noteText = noteText
            self.noteConnector = noteConnector
        }
    }

    // parity: merman/src/markdown.ts#MermaidMarkdownRendererOptions [status=implemented hash=7b408dccc1d7]
    public struct MermaidMarkdownRendererOptions: Equatable, Hashable, Sendable {
        public var compact: Bool?
        public var layoutMaxWidth: Int?
        public var gantt: GanttDiagramRenderOptions?
        public var colors: MermaidPaletteColorOverrides?

        public init(
            compact: Bool? = nil,
            layoutMaxWidth: Int? = nil,
            gantt: GanttDiagramRenderOptions? = nil,
            colors: MermaidPaletteColorOverrides? = nil
        ) {
            self.compact = compact
            self.layoutMaxWidth = layoutMaxWidth
            self.gantt = gantt
            self.colors = colors
        }
    }

    public struct PreparedMermaidDiagram: Equatable, Sendable {
        public let kind: MermaidDiagramKind
        public let source: String
        public let text: StyledText
        public let height: Int
    }

    private final class StaticDiagramRenderable: TextRenderable, @unchecked Sendable {
        private var dragX: Int?

        init(ctx: any RenderContext, prepared: PreparedMermaidDiagram) {
            var baseOpts = RenderableOptions(
                width: .percent(100),
                height: .point(Float(prepared.height)),
                marginTop: .point(1)
            )
            baseOpts.selectable = false
            let bufOpts = TextBufferOptions(
                base: baseOpts,
                selectable: false,
                wrapMode: TextWrapMode.none
            )
            super.init(ctx: ctx, options: TextOptions(bufferOptions: bufOpts, content: .styled(prepared.text)))

            self.onMouseDown = { [weak self, weak ctx] event in
                guard event.button == 0, let self else { return }
                ctx?.clearSelection()
                self.dragX = event.x
                event.preventDefault()
                event.stopPropagation()
            }
            self.onMouseDrag = { [weak self] event in
                event.preventDefault()
                event.stopPropagation()
                guard let self, let prevX = self.dragX else { return }
                let dx = event.x - prevX
                self.dragX = event.x
                if dx != 0 { self.scrollX -= dx }
            }
            self.onMouseDragEnd = { [weak self] event in
                self?.dragX = nil
                event.preventDefault()
                event.stopPropagation()
            }
            self.onMouseUp = { [weak self] event in
                guard event.button == 0 else { return }
                self?.dragX = nil
                event.preventDefault()
                event.stopPropagation()
            }
            self.onMouseScroll = { event in
                guard let scroll = event.scroll, scroll.direction == .left || scroll.direction == .right else { return }
                event.preventDefault()
                event.stopPropagation()
            }
        }
    }

    private static func resolveColor(_ value: Color?) -> RGBA? {
        value?.resolved()
    }

    public static func prepareMermaidDiagram(
        kind: MermaidDiagramKind,
        source: String,
        options: MermaidMarkdownRendererOptions = MermaidMarkdownRendererOptions(),
        layoutMaxWidth: Int = 120
    ) throws -> PreparedMermaidDiagram {
        let colors = options.colors ?? MermaidPaletteColorOverrides()
        let compact = options.compact ?? true
        switch kind {
        case .flowchart:
            let grid = try drawFlowchartDiagramGrid(
                try parseMermaidFlowchartDiagram(source),
                options: FlowchartDiagramRenderOptions(compact: compact, layoutMaxWidth: layoutMaxWidth)
            )
            let size = grid.getTextSize(DiagramCanvasTextOptions(trimTop: true, trimBottom: true))
            var bg: FlowchartStyleBackgroundColors = [:]
            if let labelBg = resolveColor(colors.labelBackground) { bg[.label] = labelBg }
            let styled = renderGridStyledText(
                grid,
                colors: resolveFlowchartStyleColors([
                    .node: resolveColor(colors.boxText ?? colors.primary),
                    .nodeBorder: resolveColor(colors.boxBorder ?? colors.muted),
                    .database: resolveColor(colors.boxText ?? colors.primary),
                    .databaseBorder: resolveColor(colors.boxBorder ?? colors.muted),
                    .edge: resolveColor(colors.line ?? colors.secondary),
                    .label: resolveColor(colors.text),
                    .group: resolveColor(colors.group ?? colors.muted),
                    .groupLabel: resolveColor(colors.groupText ?? colors.group ?? colors.muted),
                ]),
                backgrounds: bg.isEmpty ? nil : bg
            )
            return PreparedMermaidDiagram(kind: kind, source: source, text: styled, height: size.height)

        case .gitGraph:
            let grid = try drawGitGraphDiagramGrid(try parseMermaidGitGraphDiagram(source))
            let size = grid.getTextSize(DiagramCanvasTextOptions(trimBottom: true))
            let styled = renderGitGraphGridStyledText(
                grid,
                colors: resolveGitGraphStyleColors([
                    .primary: resolveColor(colors.primary),
                    .secondary: resolveColor(colors.secondary),
                    .muted: resolveColor(colors.muted),
                    .warning: resolveColor(colors.warning),
                    .text: resolveColor(colors.text),
                ])
            )
            return PreparedMermaidDiagram(kind: kind, source: source, text: styled, height: size.height)

        case .gantt:
            var ganttOpts = options.gantt ?? GanttDiagramRenderOptions()
            ganttOpts.layoutMaxWidth = layoutMaxWidth
            let grid = try drawGanttDiagramGrid(try parseMermaidGanttDiagram(source), options: ganttOpts)
            let size = grid.getTextSize(DiagramCanvasTextOptions(trimBottom: true))
            let styled = renderGanttGridStyledText(
                grid,
                colors: resolveGanttStyleColors([
                    .title: resolveColor(colors.text),
                    .axis: resolveColor(colors.muted),
                    .background: resolveColor(colors.background),
                    .section: resolveColor(colors.secondary),
                    .task: resolveColor(colors.primary),
                    .active: resolveColor(colors.primary),
                    .critical: resolveColor(colors.warning),
                    .done: resolveColor(colors.muted),
                ])
            )
            return PreparedMermaidDiagram(kind: kind, source: source, text: styled, height: size.height)

        case .sequence:
            let grid = try drawSequenceDiagramGrid(
                try parseMermaidSequenceDiagram(source),
                options: SequenceDiagramRenderOptions(compact: compact)
            )
            let size = grid.getTextSize()
            let styled = renderSequenceGridStyledText(
                grid,
                colors: resolveSequenceStyleColors(SequenceStyleColors(
                    participant: resolveColor(colors.primary),
                    lifeline: resolveColor(colors.muted),
                    group: resolveColor(colors.secondary),
                    request: resolveColor(colors.request ?? colors.primary),
                    response: resolveColor(colors.response ?? colors.primary),
                    fragment: resolveColor(colors.secondary),
                    fragmentLabelBg: resolveColor(colors.background),
                    note: resolveColor(colors.note ?? colors.warning),
                    noteBg: resolveColor(colors.noteBackground ?? colors.background)
                ))
            )
            return PreparedMermaidDiagram(kind: kind, source: source, text: styled, height: size.height)

        case .state:
            let grid = try drawStateDiagramGrid(
                try parseMermaidStateDiagram(source),
                options: StateDiagramRenderOptions(layoutMaxWidth: layoutMaxWidth)
            )
            let size = grid.getTextSize(DiagramCanvasTextOptions(trimTop: true, trimBottom: true))
            var bg: [StateCellStyle: RGBA] = [:]
            if let labelBg = resolveColor(colors.labelBackground) { bg[.label] = labelBg }
            let styled = renderStateGridStyledText(
                grid,
                colors: resolveStateStyleColors([
                    .state: resolveColor(colors.boxText ?? colors.primary),
                    .stateBorder: resolveColor(colors.boxBorder ?? colors.primary),
                    .composite: resolveColor(colors.group ?? colors.muted),
                    .compositeLabel: resolveColor(colors.groupText ?? colors.group ?? colors.muted),
                    .transition: resolveColor(colors.line ?? colors.secondary),
                    .label: resolveColor(colors.text),
                    .noteBorder: resolveColor(colors.noteBorder ?? colors.warning),
                    .noteText: resolveColor(colors.noteText ?? colors.warning),
                    .noteConnector: resolveColor(colors.noteConnector ?? colors.muted),
                    .start: resolveColor(colors.marker ?? colors.muted),
                    .end: resolveColor(colors.marker ?? colors.muted),
                    .choice: resolveColor(colors.marker ?? colors.secondary),
                ]),
                backgrounds: bg.isEmpty ? nil : bg
            )
            return PreparedMermaidDiagram(kind: kind, source: source, text: styled, height: size.height)

        case .timeline:
            let grid = try drawTimelineDiagramGrid(try parseMermaidTimelineDiagram(source))
            let size = grid.getTextSize(DiagramCanvasTextOptions(trimBottom: true))
            let styled = renderTimelineGridStyledText(
                grid,
                colors: resolveTimelineStyleColors([
                    .title: resolveColor(colors.text),
                    .section: resolveColor(colors.secondary),
                    .period: resolveColor(colors.warning),
                    .spine: resolveColor(colors.muted),
                    .event: resolveColor(colors.primary),
                ])
            )
            return PreparedMermaidDiagram(kind: kind, source: source, text: styled, height: size.height)
        }
    }

    private final class LastGoodCacheBox: @unchecked Sendable {
        struct Entry {
            let token: UInt64
            let prepared: PreparedMermaidDiagram
        }

        private let lock = Mutex<(nextToken: UInt64, entries: [String: Entry])>((1, [:]))

        func get(_ key: String) -> PreparedMermaidDiagram? {
            lock.withLock { $0.entries[key]?.prepared }
        }

        func claim(key: String, value: PreparedMermaidDiagram, owner: Renderable) {
            let token = lock.withLock { state -> UInt64 in
                let tok = state.nextToken
                state.nextToken += 1
                state.entries[key] = Entry(token: tok, prepared: value)
                return tok
            }
            _ = owner.on(RenderableEvents.destroyed) { [weak self] in
                guard let self else { return }
                self.lock.withLock { state in
                    if state.entries[key]?.token == token {
                        state.entries.removeValue(forKey: key)
                    }
                }
            }
        }
    }

    /// Create an OpenTUI Markdown node renderer for fenced Mermaid diagrams.
    // parity: merman/src/markdown.ts#createMermaidMarkdownRenderer [status=implemented hash=09acdbcabca7]
    public static func createMermaidMarkdownRenderer(
        ctx: any RenderContext,
        options: MermaidMarkdownRendererOptions = MermaidMarkdownRendererOptions()
    ) -> MarkdownRenderBlockCallback {
        createMermaidMarkdownRenderer(ctx: ctx) { options }
    }

    public static func createMermaidMarkdownRenderer(
        ctx: any RenderContext,
        optionsProvider: @escaping () -> MermaidMarkdownRendererOptions
    ) -> MarkdownRenderBlockCallback {
        createMarkdownCodeBlockRenderer([
            "mermaid": createMermaidCodeBlockRenderer(ctx: ctx, optionsProvider: optionsProvider),
        ])
    }

    // parity: merman/src/markdown.ts#createMermaidCodeBlockRenderer [status=implemented hash=257acbf26dba]
    public static func createMermaidCodeBlockRenderer(
        ctx: any RenderContext,
        options: MermaidMarkdownRendererOptions = MermaidMarkdownRendererOptions()
    ) -> MarkdownCodeBlockRenderer {
        createMermaidCodeBlockRenderer(ctx: ctx) { options }
    }

    public static func createMermaidCodeBlockRenderer(
        ctx: any RenderContext,
        optionsProvider: @escaping () -> MermaidMarkdownRendererOptions
    ) -> MarkdownCodeBlockRenderer {
        let lastGood = LastGoodCacheBox()
        return { token, context in
            guard let kind = detectMermaidDiagram(token.text) else { return nil }
            let key = context.defaultRender()?.id
            let options = optionsProvider()
            let configuredMaxWidth = options.layoutMaxWidth.map { max(1, $0) } ?? 120
            let layoutMaxWidth = min(configuredMaxWidth, max(1, ctx.width))

            do {
                let prepared = try prepareMermaidDiagram(kind: kind, source: token.text, options: options, layoutMaxWidth: layoutMaxWidth)
                let diagram = StaticDiagramRenderable(ctx: ctx, prepared: prepared)
                if let key { lastGood.claim(key: key, value: prepared, owner: diagram) }
                return diagram
            } catch let error as MermaidSyntaxError {
                if let key, let previous = lastGood.get(key), previous.kind == kind {
                    let diagram = StaticDiagramRenderable(ctx: ctx, prepared: previous)
                    lastGood.claim(key: key, value: previous, owner: diagram)
                    return diagram
                }

                let lines = token.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                let hasTrailingContent = error.lineNumber < lines.count && lines[error.lineNumber...].contains { !jsTrim($0).isEmpty }
                if error.lineNumber <= 2 || hasTrailingContent { return nil }

                do {
                    let prefix = lines.prefix(error.lineNumber - 1).joined(separator: "\n")
                    let prepared = try prepareMermaidDiagram(kind: kind, source: prefix, options: options, layoutMaxWidth: layoutMaxWidth)
                    if prepared.height == 0 { return nil }
                    let diagram = StaticDiagramRenderable(ctx: ctx, prepared: prepared)
                    if let key { lastGood.claim(key: key, value: prepared, owner: diagram) }
                    return diagram
                } catch is MermaidSyntaxError {
                    return nil
                } catch is DiagramCanvasSizeError {
                    return nil
                } catch {
                    return nil
                }
            } catch is DiagramCanvasSizeError {
                return nil
            } catch {
                return nil
            }
        }
    }

    /// Renders any supported Mermaid diagram text directly to plain Unicode box-drawing text.
    public static func renderMermaidDiagram(
        _ content: String,
        layoutMaxWidth: Int = 120,
        compact: Bool = true
    ) throws -> String? {
        guard let kind = detectMermaidDiagram(content) else { return nil }
        let prepared = try prepareMermaidDiagram(
            kind: kind,
            source: content,
            options: MermaidMarkdownRendererOptions(compact: compact, layoutMaxWidth: layoutMaxWidth),
            layoutMaxWidth: layoutMaxWidth
        )
        return prepared.text.plainText
    }

    // MARK: - TUI Plugin (`plugin.ts`)

    /// Built-in `opencode.merman` TUI plugin registering the fenced `mermaid` Markdown code-block renderer.
    // parity: merman/src/plugin.ts#default [status=implemented hash=63a344f4164d]
    public static let plugin: PluginTui.Definition = PluginTui.define(
        PluginTui.Definition(
            id: "opencode.merman",
            setup: { context in
                let mode: Mode = context.themeMode.lowercased() == "light" ? .light : .dark
                let unregister = context.registerCodeBlockRenderer("mermaid") { source in
                    guard let kind = detectMermaidDiagram(source) else {
                        return PluginTui.RenderNode(kind: "code", text: source, props: ["lang": .string("mermaid")])
                    }
                    let palette: OpenCodeDiagramPalette? = (try? resolveThemeDocument(ThemeDefaults.opencode, mode: mode))
                        .map { resolveOpenCodeDiagramPalette(theme: $0, mode: mode) }
                    let opts = MermaidMarkdownRendererOptions(colors: palette?.asColorOverrides())
                    do {
                        let prepared = try prepareMermaidDiagram(kind: kind, source: source, options: opts, layoutMaxWidth: 120)
                        return PluginTui.RenderNode(
                            kind: "mermaid",
                            text: prepared.text.plainText,
                            props: [
                                "diagramKind": .string(kind.rawValue),
                                "height": .int(Int64(prepared.height)),
                            ]
                        )
                    } catch {
                        return PluginTui.RenderNode(kind: "code", text: source, props: ["lang": .string("mermaid")])
                    }
                }
                return { unregister() }
            }
        )
    )

    /// Registers Merman's `mermaid` code-block renderer on a live `TUIPluginHost.PluginRuntimeContext`.
    @discardableResult
    public static func setupHostPlugin(_ context: TUIPluginHost.PluginRuntimeContext) throws -> @Sendable () -> Void {
        try context.registerCodeBlockRenderer(language: "mermaid") { source in
            guard let kind = detectMermaidDiagram(source) else { return source }
            let theme = context.host.theme()
            let mode = context.host.themeMode()
            let palette = resolveOpenCodeDiagramPalette(theme: theme, mode: mode)
            let opts = MermaidMarkdownRendererOptions(colors: palette.asColorOverrides())
            if let prepared = try? prepareMermaidDiagram(kind: kind, source: source, options: opts, layoutMaxWidth: 120) {
                return prepared.text.plainText
            }
            return source
        }
    }
}
