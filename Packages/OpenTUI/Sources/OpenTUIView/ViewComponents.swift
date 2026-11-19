import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables

// MARK: - Internal Helpers

private func resolveEffectiveBorderSpec(
    border: BorderSpec?,
    borderStyle: BorderStyle?,
    borderColor: Color?,
    focusedBorderColor: Color?,
    customBorderChars: BorderCharacters?
) -> BorderSpec {
    if let border { return border }
    if borderStyle != nil || borderColor != nil || focusedBorderColor != nil || customBorderChars != nil {
        return .enabled(true)
    }
    return .enabled(false)
}

private func patchBoxAppearance(
    _ box: BoxRenderable,
    border: BorderSpec?,
    borderStyle: BorderStyle?,
    borderColor: Color?,
    focusedBorderColor: Color?,
    backgroundColor: Color?,
    shouldFill: Bool?,
    title: String?,
    titleColor: Color?,
    titleAlignment: BoxTitleAlignment?,
    bottomTitle: String?,
    bottomTitleAlignment: BoxTitleAlignment?,
    customBorderChars: BorderCharacters?
) {
    let targetBorder = resolveEffectiveBorderSpec(
        border: border,
        borderStyle: borderStyle,
        borderColor: borderColor,
        focusedBorderColor: focusedBorderColor,
        customBorderChars: customBorderChars
    )
    let targetBg = backgroundColor?.resolved() ?? BoxRenderable.defaultBackgroundColor
    if box.backgroundColor != targetBg {
        box.backgroundColor = targetBg
    }
    let targetStyle = borderStyle ?? BoxRenderable.defaultBorderStyle
    if box.borderStyle != targetStyle {
        box.borderStyle = targetStyle
    }
    if let custom = customBorderChars {
        if box.customBorderChars != custom {
            box.customBorderChars = custom
        }
    } else if box.customBorderChars != nil {
        box.customBorderChars = nil
    }
    let targetBorderColor = borderColor?.resolved() ?? BoxRenderable.defaultBorderColor
    if box.borderColor != targetBorderColor {
        box.borderColor = targetBorderColor
    }
    let targetFocusedBorderColor = focusedBorderColor?.resolved() ?? BoxRenderable.defaultFocusedBorderColor
    if box.focusedBorderColor != targetFocusedBorderColor {
        box.focusedBorderColor = targetFocusedBorderColor
    }
    // Apply final border spec after style/color setters (which auto-enable borders in BoxRenderable).
    if box.border != targetBorder {
        box.border = targetBorder
    }
    let targetFill = shouldFill ?? BoxRenderable.defaultShouldFill
    if box.shouldFill != targetFill {
        box.shouldFill = targetFill
    }
    if box.title != title {
        box.title = title
    }
    let targetTitleColor = titleColor?.resolved()
    if box.titleColor != targetTitleColor {
        box.titleColor = targetTitleColor
    }
    let targetTitleAlignment = titleAlignment ?? BoxRenderable.defaultTitleAlignment
    if box.titleAlignment != targetTitleAlignment {
        box.titleAlignment = targetTitleAlignment
    }
    if box.bottomTitle != bottomTitle {
        box.bottomTitle = bottomTitle
    }
    let targetBottomAlignment = bottomTitleAlignment ?? BoxRenderable.defaultBottomTitleAlignment
    if box.bottomTitleAlignment != targetBottomAlignment {
        box.bottomTitleAlignment = targetBottomAlignment
    }
}

// MARK: - Layout Containers

/// Declarative container backed by `BoxRenderable` supporting borders, titles, and background fill.
public struct TUIBox: TUIView {
    public typealias Body = Never

    public let border: BorderSpec?
    public let borderStyle: BorderStyle?
    public let borderColor: Color?
    public let focusedBorderColor: Color?
    public let backgroundColor: Color?
    public let shouldFill: Bool?
    public let title: String?
    public let titleColor: Color?
    public let titleAlignment: BoxTitleAlignment?
    public let bottomTitle: String?
    public let bottomTitleAlignment: BoxTitleAlignment?
    public let customBorderChars: BorderCharacters?
    public let content: AnyTUIView

    public init(
        border: BorderSpec? = nil,
        borderStyle: BorderStyle? = nil,
        borderColor: Color? = nil,
        focusedBorderColor: Color? = nil,
        backgroundColor: Color? = nil,
        shouldFill: Bool? = nil,
        title: String? = nil,
        titleColor: Color? = nil,
        titleAlignment: BoxTitleAlignment? = nil,
        bottomTitle: String? = nil,
        bottomTitleAlignment: BoxTitleAlignment? = nil,
        customBorderChars: BorderCharacters? = nil,
        @TUIViewBuilder content: () -> AnyTUIView = { AnyTUIView(EmptyTUIView()) }
    ) {
        self.border = border
        self.borderStyle = borderStyle
        self.borderColor = borderColor
        self.focusedBorderColor = focusedBorderColor
        self.backgroundColor = backgroundColor
        self.shouldFill = shouldFill
        self.title = title
        self.titleColor = titleColor
        self.titleAlignment = titleAlignment
        self.bottomTitle = bottomTitle
        self.bottomTitleAlignment = bottomTitleAlignment
        self.customBorderChars = customBorderChars
        self.content = content()
    }

    public init(
        border: Bool,
        borderStyle: BorderStyle? = nil,
        borderColor: Color? = nil,
        focusedBorderColor: Color? = nil,
        backgroundColor: Color? = nil,
        shouldFill: Bool? = nil,
        title: String? = nil,
        titleColor: Color? = nil,
        titleAlignment: BoxTitleAlignment? = nil,
        bottomTitle: String? = nil,
        bottomTitleAlignment: BoxTitleAlignment? = nil,
        customBorderChars: BorderCharacters? = nil,
        @TUIViewBuilder content: () -> AnyTUIView = { AnyTUIView(EmptyTUIView()) }
    ) {
        self.init(
            border: .enabled(border),
            borderStyle: borderStyle,
            borderColor: borderColor,
            focusedBorderColor: focusedBorderColor,
            backgroundColor: backgroundColor,
            shouldFill: shouldFill,
            title: title,
            titleColor: titleColor,
            titleAlignment: titleAlignment,
            bottomTitle: bottomTitle,
            bottomTitleAlignment: bottomTitleAlignment,
            customBorderChars: customBorderChars,
            content: content
        )
    }

    public func resolveNodes() -> [TUIViewNode] {
        let snapshot = self
        var props: [String: Any] = [:]
        if let title { props["title"] = title }
        if let border { props["border"] = border }
        if let borderStyle { props["borderStyle"] = borderStyle }
        return [
            TUIViewNode(
                kind: "box",
                props: props,
                children: content.resolveNodes(),
                mount: { ctx in
                    BoxRenderable(
                        ctx: ctx,
                        options: BoxOptions(
                            backgroundColor: snapshot.backgroundColor,
                            borderStyle: snapshot.borderStyle,
                            border: snapshot.border,
                            borderColor: snapshot.borderColor,
                            customBorderChars: snapshot.customBorderChars,
                            shouldFill: snapshot.shouldFill,
                            title: snapshot.title,
                            titleColor: snapshot.titleColor,
                            titleAlignment: snapshot.titleAlignment,
                            bottomTitle: snapshot.bottomTitle,
                            bottomTitleAlignment: snapshot.bottomTitleAlignment,
                            focusedBorderColor: snapshot.focusedBorderColor
                        )
                    )
                },
                patch: { existing in
                    guard let box = existing as? BoxRenderable else { return false }
                    patchBoxAppearance(
                        box,
                        border: snapshot.border,
                        borderStyle: snapshot.borderStyle,
                        borderColor: snapshot.borderColor,
                        focusedBorderColor: snapshot.focusedBorderColor,
                        backgroundColor: snapshot.backgroundColor,
                        shouldFill: snapshot.shouldFill,
                        title: snapshot.title,
                        titleColor: snapshot.titleColor,
                        titleAlignment: snapshot.titleAlignment,
                        bottomTitle: snapshot.bottomTitle,
                        bottomTitleAlignment: snapshot.bottomTitleAlignment,
                        customBorderChars: snapshot.customBorderChars
                    )
                    return true
                }
            )
        ]
    }
}

/// Vertical column flex container backed by `BoxRenderable`.
public struct VStack: TUIView {
    public typealias Body = Never

    public let spacing: FlexValue
    public let alignment: Align
    public let justify: Justify
    public let content: AnyTUIView

    public init(
        spacing: FlexValue = 0,
        alignment: Align = .stretch,
        justify: Justify = .flexStart,
        @TUIViewBuilder content: () -> AnyTUIView
    ) {
        self.spacing = spacing
        self.alignment = alignment
        self.justify = justify
        self.content = content()
    }

    public init(
        alignment: Align,
        spacing: FlexValue,
        justify: Justify = .flexStart,
        @TUIViewBuilder content: () -> AnyTUIView
    ) {
        self.spacing = spacing
        self.alignment = alignment
        self.justify = justify
        self.content = content()
    }

    public func resolveNodes() -> [TUIViewNode] {
        let spacing = self.spacing
        let alignment = self.alignment
        let justify = self.justify
        return [
            TUIViewNode(
                kind: "vstack",
                props: [
                    "spacing": spacing,
                    "alignment": alignment,
                    "justify": justify,
                ],
                children: content.resolveNodes(),
                mount: { ctx in
                    BoxRenderable(
                        ctx: ctx,
                        options: BoxOptions(
                            flexDirection: .column,
                            alignItems: alignment,
                            justifyContent: justify,
                            gap: spacing
                        )
                    )
                },
                patch: { existing in
                    guard let box = existing as? BoxRenderable else { return false }
                    if box.flexDirection != .column { box.flexDirection = .column }
                    if box.alignItems != alignment { box.alignItems = alignment }
                    if box.justifyContent != justify { box.justifyContent = justify }
                    if box.gap != spacing { box.gap = spacing }
                    return true
                }
            )
        ]
    }
}

/// Horizontal row flex container backed by `BoxRenderable`.
public struct HStack: TUIView {
    public typealias Body = Never

    public let spacing: FlexValue
    public let alignment: Align
    public let justify: Justify
    public let content: AnyTUIView

    public init(
        spacing: FlexValue = 0,
        alignment: Align = .stretch,
        justify: Justify = .flexStart,
        @TUIViewBuilder content: () -> AnyTUIView
    ) {
        self.spacing = spacing
        self.alignment = alignment
        self.justify = justify
        self.content = content()
    }

    public init(
        alignment: Align,
        spacing: FlexValue,
        justify: Justify = .flexStart,
        @TUIViewBuilder content: () -> AnyTUIView
    ) {
        self.spacing = spacing
        self.alignment = alignment
        self.justify = justify
        self.content = content()
    }

    public func resolveNodes() -> [TUIViewNode] {
        let spacing = self.spacing
        let alignment = self.alignment
        let justify = self.justify
        return [
            TUIViewNode(
                kind: "hstack",
                props: [
                    "spacing": spacing,
                    "alignment": alignment,
                    "justify": justify,
                ],
                children: content.resolveNodes(),
                mount: { ctx in
                    BoxRenderable(
                        ctx: ctx,
                        options: BoxOptions(
                            flexDirection: .row,
                            alignItems: alignment,
                            justifyContent: justify,
                            gap: spacing
                        )
                    )
                },
                patch: { existing in
                    guard let box = existing as? BoxRenderable else { return false }
                    if box.flexDirection != .row { box.flexDirection = .row }
                    if box.alignItems != alignment { box.alignItems = alignment }
                    if box.justifyContent != justify { box.justifyContent = justify }
                    if box.gap != spacing { box.gap = spacing }
                    return true
                }
            )
        ]
    }
}

/// Layered overlay container backed by `BoxRenderable` where later children paint over earlier ones.
public struct ZStack: TUIView {
    public typealias Body = Never

    public let alignment: Align
    public let justify: Justify
    public let content: AnyTUIView

    public init(
        alignment: Align = .stretch,
        justify: Justify = .flexStart,
        @TUIViewBuilder content: () -> AnyTUIView
    ) {
        self.alignment = alignment
        self.justify = justify
        self.content = content()
    }

    public func resolveNodes() -> [TUIViewNode] {
        let alignment = self.alignment
        let justify = self.justify
        let rawChildren = content.resolveNodes()
        var layeredChildren: [TUIViewNode] = []
        layeredChildren.reserveCapacity(rawChildren.count)

        for (index, child) in rawChildren.enumerated() {
            // Keep layer 0 in normal flow so auto-sized ZStacks measure their base layer;
            // position overlay layers (index >= 1) absolutely unless the caller overrode `.position(...)`.
            if index > 0 {
                let hasExplicitPosition = child.modifiers.contains { mod in
                    if case .position = mod { return true }
                    return false
                }
                if !hasExplicitPosition {
                    layeredChildren.append(
                        child.prepending(
                            modifier: .position(type: .absolute, top: nil, right: nil, bottom: nil, left: nil)
                        )
                    )
                    continue
                }
            }
            layeredChildren.append(child)
        }

        return [
            TUIViewNode(
                kind: "zstack",
                props: [
                    "alignment": alignment,
                    "justify": justify,
                ],
                children: layeredChildren,
                mount: { ctx in
                    BoxRenderable(
                        ctx: ctx,
                        options: BoxOptions(
                            alignItems: alignment,
                            justifyContent: justify,
                            position: .relative
                        )
                    )
                },
                patch: { existing in
                    guard let box = existing as? BoxRenderable else { return false }
                    if box.position != .relative { box.position = .relative }
                    if box.alignItems != alignment { box.alignItems = alignment }
                    if box.justifyContent != justify { box.justifyContent = justify }
                    return true
                }
            )
        ]
    }
}

/// Flexible spacer that expands along the enclosing stack's main axis (`flexGrow = 1`).
public struct TUISpacer: TUIView {
    public typealias Body = Never

    public let minLength: FlexValue?

    public init(minLength: FlexValue? = nil) {
        self.minLength = minLength
    }

    public func resolveNodes() -> [TUIViewNode] {
        let minLength = self.minLength
        return [
            TUIViewNode(
                kind: "spacer",
                props: minLength.map { ["minLength": $0] } ?? [:],
                isLeaf: true,
                mount: { ctx in
                    Renderable(
                        ctx: ctx,
                        options: RenderableOptions(
                            flexGrow: 1,
                            flexShrink: 1,
                            flexBasis: minLength
                        )
                    )
                },
                patch: { existing in
                    if existing.flexGrow != 1 { existing.flexGrow = 1 }
                    if existing.flexShrink != 1 { existing.flexShrink = 1 }
                    let targetBasis = minLength ?? .auto
                    if existing.flexBasis != targetBasis { existing.flexBasis = targetBasis }
                    return true
                }
            )
        ]
    }
}

/// Scrollable container backed by `ScrollBoxRenderable`, preserving scroll offsets across re-renders.
public struct TUIScrollBox: TUIView {
    public typealias Body = Never

    public let stickyScroll: Bool
    public let stickyStart: ScrollBoxStickyStart?
    public let scrollX: Bool
    public let scrollY: Bool
    public let viewportCulling: Bool
    public let showVerticalScrollbar: Bool?
    public let showHorizontalScrollbar: Bool?
    public let border: BorderSpec?
    public let borderStyle: BorderStyle?
    public let borderColor: Color?
    public let focusedBorderColor: Color?
    public let backgroundColor: Color?
    public let title: String?
    public let titleColor: Color?
    public let titleAlignment: BoxTitleAlignment?
    public let scrollbarOptions: ScrollBarOptions?
    public let verticalScrollbarOptions: ScrollBarOptions?
    public let horizontalScrollbarOptions: ScrollBarOptions?
    public let content: AnyTUIView

    public init(
        stickyScroll: Bool = false,
        stickyStart: ScrollBoxStickyStart? = nil,
        scrollX: Bool = false,
        scrollY: Bool = true,
        viewportCulling: Bool = true,
        showVerticalScrollbar: Bool? = nil,
        showHorizontalScrollbar: Bool? = nil,
        border: BorderSpec? = nil,
        borderStyle: BorderStyle? = nil,
        borderColor: Color? = nil,
        focusedBorderColor: Color? = nil,
        backgroundColor: Color? = nil,
        title: String? = nil,
        titleColor: Color? = nil,
        titleAlignment: BoxTitleAlignment? = nil,
        scrollbarOptions: ScrollBarOptions? = nil,
        verticalScrollbarOptions: ScrollBarOptions? = nil,
        horizontalScrollbarOptions: ScrollBarOptions? = nil,
        @TUIViewBuilder content: () -> AnyTUIView
    ) {
        self.stickyScroll = stickyScroll
        self.stickyStart = stickyStart
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.viewportCulling = viewportCulling
        self.showVerticalScrollbar = showVerticalScrollbar
        self.showHorizontalScrollbar = showHorizontalScrollbar
        self.border = border
        self.borderStyle = borderStyle
        self.borderColor = borderColor
        self.focusedBorderColor = focusedBorderColor
        self.backgroundColor = backgroundColor
        self.title = title
        self.titleColor = titleColor
        self.titleAlignment = titleAlignment
        self.scrollbarOptions = scrollbarOptions
        self.verticalScrollbarOptions = verticalScrollbarOptions
        self.horizontalScrollbarOptions = horizontalScrollbarOptions
        self.content = content()
    }

    public init(
        stickyScroll: Bool = false,
        stickyStart: ScrollBoxStickyStart? = nil,
        scrollX: Bool = false,
        scrollY: Bool = true,
        viewportCulling: Bool = true,
        showVerticalScrollbar: Bool? = nil,
        showHorizontalScrollbar: Bool? = nil,
        border: Bool,
        borderStyle: BorderStyle? = nil,
        borderColor: Color? = nil,
        focusedBorderColor: Color? = nil,
        backgroundColor: Color? = nil,
        title: String? = nil,
        titleColor: Color? = nil,
        titleAlignment: BoxTitleAlignment? = nil,
        scrollbarOptions: ScrollBarOptions? = nil,
        verticalScrollbarOptions: ScrollBarOptions? = nil,
        horizontalScrollbarOptions: ScrollBarOptions? = nil,
        @TUIViewBuilder content: () -> AnyTUIView
    ) {
        self.init(
            stickyScroll: stickyScroll,
            stickyStart: stickyStart,
            scrollX: scrollX,
            scrollY: scrollY,
            viewportCulling: viewportCulling,
            showVerticalScrollbar: showVerticalScrollbar,
            showHorizontalScrollbar: showHorizontalScrollbar,
            border: .enabled(border),
            borderStyle: borderStyle,
            borderColor: borderColor,
            focusedBorderColor: focusedBorderColor,
            backgroundColor: backgroundColor,
            title: title,
            titleColor: titleColor,
            titleAlignment: titleAlignment,
            scrollbarOptions: scrollbarOptions,
            verticalScrollbarOptions: verticalScrollbarOptions,
            horizontalScrollbarOptions: horizontalScrollbarOptions,
            content: content
        )
    }

    public func resolveNodes() -> [TUIViewNode] {
        let snapshot = self
        return [
            TUIViewNode(
                kind: "scrollbox",
                props: [
                    "stickyScroll": stickyScroll,
                    "scrollX": scrollX,
                    "scrollY": scrollY,
                ],
                children: content.resolveNodes(),
                mount: { ctx in
                    let sb = ScrollBoxRenderable(
                        ctx: ctx,
                        options: ScrollBoxOptions(
                            backgroundColor: snapshot.backgroundColor,
                            borderStyle: snapshot.borderStyle,
                            border: snapshot.border,
                            borderColor: snapshot.borderColor,
                            title: snapshot.title,
                            titleColor: snapshot.titleColor,
                            titleAlignment: snapshot.titleAlignment,
                            focusedBorderColor: snapshot.focusedBorderColor,
                            scrollbarOptions: snapshot.scrollbarOptions,
                            verticalScrollbarOptions: snapshot.verticalScrollbarOptions,
                            horizontalScrollbarOptions: snapshot.horizontalScrollbarOptions,
                            stickyScroll: snapshot.stickyScroll,
                            stickyStart: snapshot.stickyStart,
                            scrollX: snapshot.scrollX,
                            scrollY: snapshot.scrollY,
                            viewportCulling: snapshot.viewportCulling
                        )
                    )
                    if let showV = snapshot.showVerticalScrollbar {
                        sb.verticalScrollBar.visible = showV
                    }
                    if let showH = snapshot.showHorizontalScrollbar {
                        sb.horizontalScrollBar.visible = showH
                    }
                    return sb
                },
                patch: { existing in
                    guard let sb = existing as? ScrollBoxRenderable else { return false }
                    patchBoxAppearance(
                        sb,
                        border: snapshot.border,
                        borderStyle: snapshot.borderStyle,
                        borderColor: snapshot.borderColor,
                        focusedBorderColor: snapshot.focusedBorderColor,
                        backgroundColor: snapshot.backgroundColor,
                        shouldFill: nil,
                        title: snapshot.title,
                        titleColor: snapshot.titleColor,
                        titleAlignment: snapshot.titleAlignment,
                        bottomTitle: nil,
                        bottomTitleAlignment: nil,
                        customBorderChars: nil
                    )
                    if sb.stickyScroll != snapshot.stickyScroll {
                        sb.stickyScroll = snapshot.stickyScroll
                    }
                    if sb.stickyStart != snapshot.stickyStart {
                        sb.stickyStart = snapshot.stickyStart
                    }
                    if sb.scrollX != snapshot.scrollX {
                        sb.scrollX = snapshot.scrollX
                    }
                    if sb.scrollY != snapshot.scrollY {
                        sb.scrollY = snapshot.scrollY
                    }
                    if sb.viewportCulling != snapshot.viewportCulling {
                        sb.viewportCulling = snapshot.viewportCulling
                    }
                    if let opts = snapshot.scrollbarOptions {
                        sb.scrollbarOptions = opts
                    }
                    if let vOpts = snapshot.verticalScrollbarOptions {
                        sb.verticalScrollbarOptions = vOpts
                    }
                    if let hOpts = snapshot.horizontalScrollbarOptions {
                        sb.horizontalScrollbarOptions = hOpts
                    }
                    if let showV = snapshot.showVerticalScrollbar {
                        sb.verticalScrollBar.visible = showV
                    }
                    if let showH = snapshot.showHorizontalScrollbar {
                        sb.horizontalScrollBar.visible = showH
                    }
                    return true
                }
            )
        ]
    }
}

// MARK: - Text & Display Components

/// Declarative rich or plain text component backed by `TextRenderable`.
public struct TUIText: TUIView {
    public typealias Body = Never

    public let content: TextContent
    public let fg: Color?
    public let bg: Color?
    public let attributes: UInt32?
    public let wrapMode: TextWrapMode?
    public let textAlign: TextAlign?
    public let selectable: Bool?
    public let truncate: Bool?

    public init(
        _ text: String,
        fg: Color? = nil,
        bg: Color? = nil,
        attributes: UInt32? = nil,
        wrapMode: TextWrapMode? = nil,
        textAlign: TextAlign? = nil,
        selectable: Bool? = nil,
        truncate: Bool? = nil
    ) {
        self.content = .string(text)
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
        self.wrapMode = wrapMode
        self.textAlign = textAlign
        self.selectable = selectable
        self.truncate = truncate
    }

    public init(
        _ styledText: StyledText,
        fg: Color? = nil,
        bg: Color? = nil,
        attributes: UInt32? = nil,
        wrapMode: TextWrapMode? = nil,
        textAlign: TextAlign? = nil,
        selectable: Bool? = nil,
        truncate: Bool? = nil
    ) {
        self.content = .styled(styledText)
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
        self.wrapMode = wrapMode
        self.textAlign = textAlign
        self.selectable = selectable
        self.truncate = truncate
    }

    public func resolveNodes() -> [TUIViewNode] {
        let snapshot = self
        return [
            TUIViewNode(
                kind: "text",
                props: ["content": content],
                isLeaf: true,
                mount: { ctx in
                    TextRenderable(
                        ctx: ctx,
                        options: TextOptions(
                            content: snapshot.content,
                            fg: snapshot.fg,
                            bg: snapshot.bg,
                            selectable: snapshot.selectable,
                            attributes: snapshot.attributes,
                            wrapMode: snapshot.wrapMode,
                            textAlign: snapshot.textAlign,
                            truncate: snapshot.truncate
                        )
                    )
                },
                patch: { existing in
                    guard let text = existing as? TextRenderable else { return false }
                    switch snapshot.content {
                    case .string(let s):
                        if text.plainText != s || text.chunks.count > 1 {
                            text.setContent(s)
                        }
                    case .styled(let st):
                        if text.content != st {
                            text.setContent(st)
                        }
                    }
                    let targetFg = snapshot.fg?.resolved() ?? RGBA.fromValues(1, 1, 1, 1)
                    if text.fg != targetFg { text.fg = targetFg }
                    let targetBg = snapshot.bg?.resolved() ?? RGBA.fromValues(0, 0, 0, 0)
                    if text.bg != targetBg { text.bg = targetBg }
                    let targetAttrs = snapshot.attributes ?? TextAttributes.none
                    if text.attributes != targetAttrs { text.attributes = targetAttrs }
                    let targetWrap = snapshot.wrapMode ?? .word
                    if text.wrapMode != targetWrap { text.wrapMode = targetWrap }
                    let targetAlign = snapshot.textAlign ?? .left
                    if text.textAlign != targetAlign { text.textAlign = targetAlign }
                    let targetSelectable = snapshot.selectable ?? true
                    if text.selectable != targetSelectable { text.selectable = targetSelectable }
                    let targetTruncate = snapshot.truncate ?? false
                    if text.truncate != targetTruncate { text.truncate = targetTruncate }
                    return true
                }
            )
        ]
    }
}

/// Declarative ASCII banner font component backed by `ASCIIFontRenderable`.
public struct TUIASCIIFont: TUIView {
    public typealias Body = Never

    public let text: String
    public let font: ASCIIFontName
    public let color: Color?
    public let colors: [Color]?
    public let backgroundColor: Color?
    public let selectable: Bool?

    public init(
        _ text: String,
        font: ASCIIFontName = .tiny,
        color: Color? = nil,
        colors: [Color]? = nil,
        backgroundColor: Color? = nil,
        selectable: Bool? = nil
    ) {
        self.text = text
        self.font = font
        self.color = color
        self.colors = colors
        self.backgroundColor = backgroundColor
        self.selectable = selectable
    }

    public func resolveNodes() -> [TUIViewNode] {
        let snapshot = self
        return [
            TUIViewNode(
                kind: "ascii-font",
                props: ["text": text, "font": font],
                isLeaf: true,
                mount: { ctx in
                    ASCIIFontRenderable(
                        ctx: ctx,
                        options: ASCIIFontOptions(
                            text: snapshot.text,
                            font: snapshot.font,
                            color: snapshot.color,
                            colors: snapshot.colors,
                            backgroundColor: snapshot.backgroundColor,
                            selectable: snapshot.selectable
                        )
                    )
                },
                patch: { existing in
                    guard let ascii = existing as? ASCIIFontRenderable else { return false }
                    if ascii.text != snapshot.text { ascii.text = snapshot.text }
                    if ascii.font != snapshot.font { ascii.font = snapshot.font }
                    let targetColors: [RGBA]
                    if let colors = snapshot.colors, !colors.isEmpty {
                        targetColors = colors.map { $0.resolved() }
                    } else if let color = snapshot.color {
                        targetColors = [color.resolved()]
                    } else {
                        targetColors = [ASCIIFontRenderable.defaultColor]
                    }
                    if ascii.color != targetColors { ascii.color = targetColors }
                    let targetBg = snapshot.backgroundColor?.resolved() ?? ASCIIFontRenderable.defaultBackgroundColor
                    if ascii.backgroundColor != targetBg { ascii.backgroundColor = targetBg }
                    if let selectable = snapshot.selectable, ascii.selectable != selectable {
                        ascii.selectable = selectable
                    }
                    return true
                }
            )
        ]
    }
}

/// Declarative QR Code component backed by `QRCodeRenderable`.
public struct TUIQRCode: TUIView {
    public typealias Body = Never

    public let text: String
    public let ecl: ErrorCorrectionLevel
    public let fg: Color?
    public let bg: Color?
    public let quietZone: Int?
    public let scale: Int?
    public let fit: QRCodeFitMode?
    public let invert: Bool
    public let fallbackContent: String?

    public init(
        _ text: String,
        ecl: ErrorCorrectionLevel = .M,
        fg: Color? = nil,
        bg: Color? = nil,
        quietZone: Int? = nil,
        scale: Int? = nil,
        fit: QRCodeFitMode? = nil,
        invert: Bool = false,
        fallbackContent: String? = nil
    ) {
        self.text = text
        self.ecl = ecl
        self.fg = fg
        self.bg = bg
        self.quietZone = quietZone
        self.scale = scale
        self.fit = fit
        self.invert = invert
        self.fallbackContent = fallbackContent
    }

    public func resolveNodes() -> [TUIViewNode] {
        let snapshot = self
        return [
            TUIViewNode(
                kind: "qrcode",
                props: ["text": text, "ecl": ecl],
                isLeaf: true,
                mount: { ctx in
                    QRCodeRenderable(
                        ctx: ctx,
                        options: QRCodeOptions(
                            content: snapshot.text,
                            errorCorrectionLevel: snapshot.ecl,
                            quietZone: snapshot.quietZone,
                            scale: snapshot.scale,
                            fit: snapshot.fit,
                            fg: snapshot.fg,
                            bg: snapshot.bg,
                            invert: snapshot.invert,
                            fallbackContent: snapshot.fallbackContent
                        )
                    )
                },
                patch: { existing in
                    guard let qr = existing as? QRCodeRenderable else { return false }
                    if qr.content != snapshot.text { qr.content = snapshot.text }
                    if qr.errorCorrectionLevel != snapshot.ecl { qr.errorCorrectionLevel = snapshot.ecl }
                    if let fg = snapshot.fg {
                        let resolved = fg.resolved()
                        if qr.foregroundColor != resolved { qr.foregroundColor = resolved }
                    }
                    if let bg = snapshot.bg {
                        let resolved = bg.resolved()
                        if qr.backgroundColor != resolved { qr.backgroundColor = resolved }
                    }
                    if let qz = snapshot.quietZone, qr.quietZone != qz { qr.quietZone = qz }
                    if let sc = snapshot.scale, qr.scale != sc { qr.scale = sc }
                    if let fit = snapshot.fit, qr.fit != fit { qr.fit = fit }
                    if qr.invert != snapshot.invert { qr.invert = snapshot.invert }
                    let targetFallback = snapshot.fallbackContent ?? ""
                    if qr.fallbackContent != targetFallback { qr.fallbackContent = targetFallback }
                    return true
                }
            )
        ]
    }
}

/// Declarative structured table component backed by `TextTableRenderable`.
public struct TUITable: TUIView {
    public typealias Body = Never

    public let content: TextTableContent
    public let showBorders: Bool
    public let border: Bool
    public let outerBorder: Bool?
    public let borderStyle: BorderStyle
    public let borderColor: Color?
    public let columnWidthMode: TextTableColumnWidthMode
    public let columnFitter: TextTableColumnFitter
    public let columnAlignments: [TextTableColumnAlignment]
    public let wrapMode: TextWrapMode
    public let cellPadding: Int?
    public let cellPaddingX: Int?
    public let cellPaddingY: Int?
    public let columnGap: Int?
    public let fg: Color?
    public let bg: Color?
    public let backgroundColor: Color?
    public let selectable: Bool?

    public init(
        content: TextTableContent,
        showBorders: Bool = true,
        border: Bool = true,
        outerBorder: Bool? = nil,
        borderStyle: BorderStyle = .single,
        borderColor: Color? = nil,
        columnWidthMode: TextTableColumnWidthMode = .full,
        columnFitter: TextTableColumnFitter = .proportional,
        columnAlignments: [TextTableColumnAlignment] = [],
        wrapMode: TextWrapMode = .word,
        cellPadding: Int? = nil,
        cellPaddingX: Int? = nil,
        cellPaddingY: Int? = nil,
        columnGap: Int? = nil,
        fg: Color? = nil,
        bg: Color? = nil,
        backgroundColor: Color? = nil,
        selectable: Bool? = nil
    ) {
        self.content = content
        self.showBorders = showBorders
        self.border = border
        self.outerBorder = outerBorder
        self.borderStyle = borderStyle
        self.borderColor = borderColor
        self.columnWidthMode = columnWidthMode
        self.columnFitter = columnFitter
        self.columnAlignments = columnAlignments
        self.wrapMode = wrapMode
        self.cellPadding = cellPadding
        self.cellPaddingX = cellPaddingX
        self.cellPaddingY = cellPaddingY
        self.columnGap = columnGap
        self.fg = fg
        self.bg = bg
        self.backgroundColor = backgroundColor
        self.selectable = selectable
    }

    public init(
        rows: [[String]],
        showBorders: Bool = true,
        border: Bool = true,
        outerBorder: Bool? = nil,
        borderStyle: BorderStyle = .single,
        borderColor: Color? = nil,
        columnWidthMode: TextTableColumnWidthMode = .full,
        columnFitter: TextTableColumnFitter = .proportional,
        columnAlignments: [TextTableColumnAlignment] = [],
        wrapMode: TextWrapMode = .word,
        cellPadding: Int? = nil,
        cellPaddingX: Int? = nil,
        cellPaddingY: Int? = nil,
        columnGap: Int? = nil,
        fg: Color? = nil,
        bg: Color? = nil,
        backgroundColor: Color? = nil,
        selectable: Bool? = nil
    ) {
        self.init(
            content: rows.map { row in row.map { .text($0) } },
            showBorders: showBorders,
            border: border,
            outerBorder: outerBorder,
            borderStyle: borderStyle,
            borderColor: borderColor,
            columnWidthMode: columnWidthMode,
            columnFitter: columnFitter,
            columnAlignments: columnAlignments,
            wrapMode: wrapMode,
            cellPadding: cellPadding,
            cellPaddingX: cellPaddingX,
            cellPaddingY: cellPaddingY,
            columnGap: columnGap,
            fg: fg,
            bg: bg,
            backgroundColor: backgroundColor,
            selectable: selectable
        )
    }

    public func resolveNodes() -> [TUIViewNode] {
        let snapshot = self
        return [
            TUIViewNode(
                kind: "table",
                props: [
                    "rowCount": content.count,
                    "showBorders": showBorders,
                    "columnWidthMode": columnWidthMode,
                ],
                isLeaf: true,
                mount: { ctx in
                    TextTableRenderable(
                        ctx: ctx,
                        options: TextTableOptions(
                            content: snapshot.content,
                            wrapMode: snapshot.wrapMode,
                            columnWidthMode: snapshot.columnWidthMode,
                            columnFitter: snapshot.columnFitter,
                            columnAlignments: snapshot.columnAlignments,
                            cellPadding: snapshot.cellPadding,
                            cellPaddingX: snapshot.cellPaddingX,
                            cellPaddingY: snapshot.cellPaddingY,
                            columnGap: snapshot.columnGap,
                            showBorders: snapshot.showBorders,
                            border: snapshot.border,
                            outerBorder: snapshot.outerBorder,
                            selectable: snapshot.selectable,
                            borderStyle: snapshot.borderStyle,
                            borderColor: snapshot.borderColor,
                            backgroundColor: snapshot.backgroundColor,
                            fg: snapshot.fg,
                            bg: snapshot.bg
                        )
                    )
                },
                patch: { existing in
                    guard let table = existing as? TextTableRenderable else { return false }
                    if table.content != snapshot.content { table.content = snapshot.content }
                    if table.showBorders != snapshot.showBorders { table.showBorders = snapshot.showBorders }
                    if table.border != snapshot.border { table.border = snapshot.border }
                    if let outer = snapshot.outerBorder, table.outerBorder != outer {
                        table.outerBorder = outer
                    }
                    if table.borderStyle != snapshot.borderStyle { table.borderStyle = snapshot.borderStyle }
                    if let borderColor = snapshot.borderColor {
                        let resolved = borderColor.resolved()
                        if table.borderColor != resolved { table.borderColor = resolved }
                    }
                    if table.columnWidthMode != snapshot.columnWidthMode {
                        table.columnWidthMode = snapshot.columnWidthMode
                    }
                    if table.columnFitter != snapshot.columnFitter {
                        table.columnFitter = snapshot.columnFitter
                    }
                    if table.columnAlignments != snapshot.columnAlignments {
                        table.columnAlignments = snapshot.columnAlignments
                    }
                    if table.wrapMode != snapshot.wrapMode { table.wrapMode = snapshot.wrapMode }
                    let targetPadX = max(0, snapshot.cellPaddingX ?? snapshot.cellPadding ?? 0)
                    let targetPadY = max(0, snapshot.cellPaddingY ?? snapshot.cellPadding ?? 0)
                    if table.cellPaddingX != targetPadX { table.cellPaddingX = targetPadX }
                    if table.cellPaddingY != targetPadY { table.cellPaddingY = targetPadY }
                    let targetGap = max(0, snapshot.columnGap ?? 0)
                    if table.tableColumnGap != targetGap { table.tableColumnGap = targetGap }
                    if let fg = snapshot.fg {
                        let resolved = fg.resolved()
                        if table.fg != resolved { table.fg = resolved }
                    }
                    if let selectable = snapshot.selectable, table.selectable != selectable {
                        table.selectable = selectable
                    }
                    return true
                }
            )
        ]
    }
}

/// Declarative offscreen pixel/cell canvas backed by `FrameBufferRenderable`.
public struct TUIFrameBuffer: TUIView {
    public typealias Body = Never

    public let width: Int
    public let height: Int
    public let respectAlpha: Bool
    public let draw: ((OptimizedBuffer) -> Void)?

    public init(
        width: Int,
        height: Int,
        respectAlpha: Bool = false,
        draw: ((OptimizedBuffer) -> Void)? = nil
    ) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.respectAlpha = respectAlpha
        self.draw = draw
    }

    public func resolveNodes() -> [TUIViewNode] {
        let snapshot = self
        return [
            TUIViewNode(
                kind: "framebuffer",
                props: ["width": width, "height": height, "respectAlpha": respectAlpha],
                isLeaf: true,
                mount: { ctx in
                    let fbNode = FrameBufferRenderable(
                        ctx: ctx,
                        options: FrameBufferOptions(
                            width: snapshot.width,
                            height: snapshot.height,
                            respectAlpha: snapshot.respectAlpha
                        )
                    )
                    if let surface = fbNode.frameBuffer {
                        snapshot.draw?(surface)
                    }
                    return fbNode
                },
                patch: { existing in
                    guard let fbNode = existing as? FrameBufferRenderable else { return false }
                    fbNode.setWidth(.point(Float(snapshot.width)))
                    fbNode.setHeight(.point(Float(snapshot.height)))
                    if fbNode.respectAlpha != snapshot.respectAlpha {
                        fbNode.setRespectAlpha(snapshot.respectAlpha)
                    }
                    if let surface = fbNode.frameBuffer {
                        if surface.width != snapshot.width || surface.height != snapshot.height {
                            try? surface.resize(width: snapshot.width, height: snapshot.height)
                        }
                        if let draw = snapshot.draw {
                            draw(surface)
                            fbNode.requestRender()
                        }
                    }
                    return true
                }
            )
        ]
    }
}

/// Declarative terminal image component backed by `ImageRenderable`.
public struct TUIImage: TUIView {
    public typealias Body = Never

    public let source: ImageRenderableSource?
    public let fit: ImageFit
    public let crop: ImageExtractOptions?
    public let imageProtocol: ImageRenderProtocol
    public let onLoad: ((PixelImage) -> Void)?
    public let onError: ((any Error) -> Void)?

    public init(
        source: ImageRenderableSource?,
        fit: ImageFit = .fit,
        crop: ImageExtractOptions? = nil,
        protocol imageProtocol: ImageRenderProtocol = .auto,
        onLoad: ((PixelImage) -> Void)? = nil,
        onError: ((any Error) -> Void)? = nil
    ) {
        self.source = source
        self.fit = fit
        self.crop = crop
        self.imageProtocol = imageProtocol
        self.onLoad = onLoad
        self.onError = onError
    }

    public init(
        _ pixelImage: PixelImage,
        fit: ImageFit = .fit,
        crop: ImageExtractOptions? = nil,
        protocol imageProtocol: ImageRenderProtocol = .auto,
        onLoad: ((PixelImage) -> Void)? = nil,
        onError: ((any Error) -> Void)? = nil
    ) {
        self.init(
            source: .pixelImage(pixelImage),
            fit: fit,
            crop: crop,
            protocol: imageProtocol,
            onLoad: onLoad,
            onError: onError
        )
    }

    public func resolveNodes() -> [TUIViewNode] {
        let snapshot = self
        return [
            TUIViewNode(
                kind: "image",
                props: ["fit": fit, "protocol": imageProtocol],
                isLeaf: true,
                mount: { ctx in
                    ImageRenderable(
                        ctx: ctx,
                        options: ImageRenderableOptions(
                            source: snapshot.source,
                            fit: snapshot.fit,
                            crop: snapshot.crop,
                            protocol: snapshot.imageProtocol,
                            onLoad: snapshot.onLoad,
                            onError: snapshot.onError
                        )
                    )
                },
                patch: { existing in
                    guard let img = existing as? ImageRenderable else { return false }
                    img.onLoad = snapshot.onLoad
                    img.onError = snapshot.onError
                    if img.fit != snapshot.fit { img.fit = snapshot.fit }
                    if img.`protocol` != snapshot.imageProtocol { img.`protocol` = snapshot.imageProtocol }
                    if img.source != snapshot.source { img.source = snapshot.source }
                    if img.crop != snapshot.crop { img.crop = snapshot.crop }
                    return true
                }
            )
        ]
    }
}

// MARK: - Interactive Controls

/// Declarative single-line text input backed by `InputRenderable`.
///
/// Pass `value: nil` for uncontrolled input (preserving live user edits and cursor state across
/// re-renders), or pass a controlled `value` string (which only overwrites the buffer if it
/// diverges from `plainText`, preserving cursor & selection when unchanged).
public struct TUIInput: TUIView {
    public typealias Body = Never

    public let value: String?
    public let placeholder: String?
    public let placeholderColor: Color?
    public let minLength: Int?
    public let maxLength: Int?
    public let textColor: Color?
    public let backgroundColor: Color?
    public let focusedTextColor: Color?
    public let focusedBackgroundColor: Color?
    public let showCursor: Bool?
    public let cursorColor: Color?
    public let onInput: ((String) -> Void)?
    public let onChange: ((String) -> Void)?
    public let onSubmit: ((String) -> Void)?

    public init(
        value: String? = nil,
        placeholder: String? = nil,
        placeholderColor: Color? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        textColor: Color? = nil,
        backgroundColor: Color? = nil,
        focusedTextColor: Color? = nil,
        focusedBackgroundColor: Color? = nil,
        showCursor: Bool? = nil,
        cursorColor: Color? = nil,
        onInput: ((String) -> Void)? = nil,
        onChange: ((String) -> Void)? = nil,
        onSubmit: ((String) -> Void)? = nil
    ) {
        self.value = value
        self.placeholder = placeholder
        self.placeholderColor = placeholderColor
        self.minLength = minLength
        self.maxLength = maxLength
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.focusedTextColor = focusedTextColor
        self.focusedBackgroundColor = focusedBackgroundColor
        self.showCursor = showCursor
        self.cursorColor = cursorColor
        self.onInput = onInput
        self.onChange = onChange
        self.onSubmit = onSubmit
    }

    public func resolveNodes() -> [TUIViewNode] {
        let snapshot = self
        var props: [String: Any] = [:]
        if let value { props["value"] = value }
        if let placeholder { props["placeholder"] = placeholder }
        if let maxLength { props["maxLength"] = maxLength }
        return [
            TUIViewNode(
                kind: "input",
                props: props,
                isLeaf: true,
                mount: { ctx in
                    InputRenderable(
                        ctx: ctx,
                        options: InputRenderableOptions(
                            value: snapshot.value,
                            minLength: snapshot.minLength,
                            maxLength: snapshot.maxLength,
                            placeholder: snapshot.placeholder,
                            placeholderColor: snapshot.placeholderColor,
                            backgroundColor: snapshot.backgroundColor,
                            textColor: snapshot.textColor,
                            focusedBackgroundColor: snapshot.focusedBackgroundColor,
                            focusedTextColor: snapshot.focusedTextColor,
                            showCursor: snapshot.showCursor,
                            cursorColor: snapshot.cursorColor,
                            onInput: snapshot.onInput,
                            onChange: snapshot.onChange,
                            onSubmit: snapshot.onSubmit
                        )
                    )
                },
                patch: { existing in
                    guard let input = existing as? InputRenderable else { return false }
                    input.onInput = snapshot.onInput
                    input.onChange = snapshot.onChange
                    input.onEnter = snapshot.onSubmit

                    let targetMax = max(0, snapshot.maxLength ?? InputRenderable.defaultMaxLength)
                    let targetMin = max(0, snapshot.minLength ?? InputRenderable.defaultMinLength)
                    if targetMin <= input.maxLength {
                        if input.minLength != targetMin { input.minLength = targetMin }
                        if input.maxLength != targetMax { input.maxLength = targetMax }
                    } else {
                        if input.maxLength != targetMax { input.maxLength = targetMax }
                        if input.minLength != targetMin { input.minLength = targetMin }
                    }

                    let targetPlaceholder = snapshot.placeholder ?? InputRenderable.defaultPlaceholder
                    if input.placeholderText != targetPlaceholder {
                        input.placeholderText = targetPlaceholder
                    }
                    if let pColor = snapshot.placeholderColor {
                        let resolved = pColor.resolved()
                        if input.placeholderColor != resolved { input.placeholderColor = resolved }
                    }
                    if let textColor = snapshot.textColor {
                        let resolved = textColor.resolved()
                        if input.textColor != resolved { input.textColor = resolved }
                    }
                    if let bg = snapshot.backgroundColor {
                        let resolved = bg.resolved()
                        if input.backgroundColor != resolved { input.backgroundColor = resolved }
                    }
                    if let focusedText = snapshot.focusedTextColor {
                        input.focusedTextColor = focusedText.resolved()
                    }
                    if let focusedBg = snapshot.focusedBackgroundColor {
                        input.focusedBackgroundColor = focusedBg.resolved()
                    }
                    if let showCursor = snapshot.showCursor, input.showCursor != showCursor {
                        input.showCursor = showCursor
                    }
                    if let cursorColor = snapshot.cursorColor {
                        let resolved = cursorColor.resolved()
                        if input.cursorColor != resolved { input.cursorColor = resolved }
                    }
                    // Only synchronize controlled value when caller explicitly passed one that differs.
                    if let controlledValue = snapshot.value, input.plainText != controlledValue {
                        let prevOnInput = input.onInput
                        input.onInput = nil
                        input.value = controlledValue
                        input.onInput = prevOnInput
                    }
                    return true
                }
            )
        ]
    }
}

/// Declarative multi-line text editor backed by `TextareaRenderable`.
public struct TUITextarea: TUIView {
    public typealias Body = Never

    public let initialValue: String?
    public let placeholder: PlaceholderValue?
    public let placeholderColor: Color?
    public let wrapMode: TextWrapMode?
    public let textColor: Color?
    public let backgroundColor: Color?
    public let focusedTextColor: Color?
    public let focusedBackgroundColor: Color?
    public let showCursor: Bool?
    public let cursorColor: Color?
    public let onContentChange: ((ContentChangeEvent) -> Void)?
    public let onCursorChange: ((CursorChangeEvent) -> Void)?
    public let onSubmit: ((SubmitEvent) -> Void)?

    public init(
        initialValue: String? = nil,
        placeholder: PlaceholderValue? = nil,
        placeholderColor: Color? = nil,
        wrapMode: TextWrapMode? = nil,
        textColor: Color? = nil,
        backgroundColor: Color? = nil,
        focusedTextColor: Color? = nil,
        focusedBackgroundColor: Color? = nil,
        showCursor: Bool? = nil,
        cursorColor: Color? = nil,
        onContentChange: ((ContentChangeEvent) -> Void)? = nil,
        onCursorChange: ((CursorChangeEvent) -> Void)? = nil,
        onSubmit: ((SubmitEvent) -> Void)? = nil
    ) {
        self.initialValue = initialValue
        self.placeholder = placeholder
        self.placeholderColor = placeholderColor
        self.wrapMode = wrapMode
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.focusedTextColor = focusedTextColor
        self.focusedBackgroundColor = focusedBackgroundColor
        self.showCursor = showCursor
        self.cursorColor = cursorColor
        self.onContentChange = onContentChange
        self.onCursorChange = onCursorChange
        self.onSubmit = onSubmit
    }

    public func resolveNodes() -> [TUIViewNode] {
        let snapshot = self
        var props: [String: Any] = [:]
        if let wrapMode { props["wrapMode"] = wrapMode }
        return [
            TUIViewNode(
                kind: "textarea",
                props: props,
                isLeaf: true,
                mount: { ctx in
                    TextareaRenderable(
                        ctx: ctx,
                        options: TextareaOptions(
                            initialValue: snapshot.initialValue,
                            backgroundColor: snapshot.backgroundColor,
                            textColor: snapshot.textColor,
                            focusedBackgroundColor: snapshot.focusedBackgroundColor,
                            focusedTextColor: snapshot.focusedTextColor,
                            wrapMode: snapshot.wrapMode,
                            showCursor: snapshot.showCursor,
                            cursorColor: snapshot.cursorColor,
                            placeholder: snapshot.placeholder,
                            placeholderColor: snapshot.placeholderColor,
                            onSubmit: snapshot.onSubmit,
                            onCursorChange: snapshot.onCursorChange,
                            onContentChange: snapshot.onContentChange
                        )
                    )
                },
                patch: { existing in
                    guard let textarea = existing as? TextareaRenderable else { return false }
                    textarea.onContentChange = snapshot.onContentChange
                    textarea.onCursorChange = snapshot.onCursorChange
                    textarea.onSubmit = snapshot.onSubmit
                    if textarea.placeholder != snapshot.placeholder {
                        textarea.placeholder = snapshot.placeholder
                    }
                    if let pColor = snapshot.placeholderColor {
                        let resolved = pColor.resolved()
                        if textarea.placeholderColor != resolved { textarea.placeholderColor = resolved }
                    }
                    if let wrapMode = snapshot.wrapMode, textarea.wrapMode != wrapMode {
                        textarea.wrapMode = wrapMode
                    }
                    if let textColor = snapshot.textColor {
                        let resolved = textColor.resolved()
                        if textarea.textColor != resolved { textarea.textColor = resolved }
                    }
                    if let bg = snapshot.backgroundColor {
                        let resolved = bg.resolved()
                        if textarea.backgroundColor != resolved { textarea.backgroundColor = resolved }
                    }
                    if let focusedText = snapshot.focusedTextColor {
                        textarea.focusedTextColor = focusedText.resolved()
                    }
                    if let focusedBg = snapshot.focusedBackgroundColor {
                        textarea.focusedBackgroundColor = focusedBg.resolved()
                    }
                    if let showCursor = snapshot.showCursor, textarea.showCursor != showCursor {
                        textarea.showCursor = showCursor
                    }
                    if let cursorColor = snapshot.cursorColor {
                        let resolved = cursorColor.resolved()
                        if textarea.cursorColor != resolved { textarea.cursorColor = resolved }
                    }
                    return true
                }
            )
        ]
    }
}

/// Declarative vertical list selector backed by `SelectRenderable`.
public struct TUISelect: TUIView {
    public typealias Body = Never

    public let options: [SelectOption]
    public let selectedIndex: Int?
    public let wrapSelection: Bool
    public let showDescription: Bool
    public let showSelectionIndicator: Bool
    public let showScrollIndicator: Bool
    public let itemSpacing: Int
    public let fastScrollStep: Int
    public let textColor: Color?
    public let backgroundColor: Color?
    public let focusedTextColor: Color?
    public let focusedBackgroundColor: Color?
    public let selectedTextColor: Color?
    public let selectedBackgroundColor: Color?
    public let descriptionColor: Color?
    public let selectedDescriptionColor: Color?
    public let onChange: ((Int, SelectOption?) -> Void)?
    public let onSelect: ((Int, SelectOption) -> Void)?

    public init(
        options: [SelectOption],
        selectedIndex: Int? = nil,
        wrapSelection: Bool = false,
        showDescription: Bool = true,
        showSelectionIndicator: Bool = true,
        showScrollIndicator: Bool = false,
        itemSpacing: Int = 0,
        fastScrollStep: Int = 5,
        textColor: Color? = nil,
        backgroundColor: Color? = nil,
        focusedTextColor: Color? = nil,
        focusedBackgroundColor: Color? = nil,
        selectedTextColor: Color? = nil,
        selectedBackgroundColor: Color? = nil,
        descriptionColor: Color? = nil,
        selectedDescriptionColor: Color? = nil,
        onChange: ((Int, SelectOption?) -> Void)? = nil,
        onSelect: ((Int, SelectOption) -> Void)? = nil
    ) {
        self.options = options
        self.selectedIndex = selectedIndex
        self.wrapSelection = wrapSelection
        self.showDescription = showDescription
        self.showSelectionIndicator = showSelectionIndicator
        self.showScrollIndicator = showScrollIndicator
        self.itemSpacing = itemSpacing
        self.fastScrollStep = fastScrollStep
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.focusedTextColor = focusedTextColor
        self.focusedBackgroundColor = focusedBackgroundColor
        self.selectedTextColor = selectedTextColor
        self.selectedBackgroundColor = selectedBackgroundColor
        self.descriptionColor = descriptionColor
        self.selectedDescriptionColor = selectedDescriptionColor
        self.onChange = onChange
        self.onSelect = onSelect
    }

    public func resolveNodes() -> [TUIViewNode] {
        let snapshot = self
        var props: [String: Any] = [
            "optionCount": options.count,
            "wrapSelection": wrapSelection,
        ]
        if let selectedIndex { props["selectedIndex"] = selectedIndex }
        return [
            TUIViewNode(
                kind: "select",
                props: props,
                isLeaf: true,
                mount: { ctx in
                    SelectRenderable(
                        ctx: ctx,
                        options: SelectRenderableOptions(
                            backgroundColor: snapshot.backgroundColor,
                            textColor: snapshot.textColor,
                            focusedBackgroundColor: snapshot.focusedBackgroundColor,
                            focusedTextColor: snapshot.focusedTextColor,
                            options: snapshot.options,
                            selectedIndex: snapshot.selectedIndex,
                            selectedBackgroundColor: snapshot.selectedBackgroundColor,
                            selectedTextColor: snapshot.selectedTextColor,
                            descriptionColor: snapshot.descriptionColor,
                            selectedDescriptionColor: snapshot.selectedDescriptionColor,
                            showScrollIndicator: snapshot.showScrollIndicator,
                            wrapSelection: snapshot.wrapSelection,
                            showDescription: snapshot.showDescription,
                            showSelectionIndicator: snapshot.showSelectionIndicator,
                            itemSpacing: snapshot.itemSpacing,
                            fastScrollStep: snapshot.fastScrollStep,
                            onChange: snapshot.onChange,
                            onSelect: snapshot.onSelect
                        )
                    )
                },
                patch: { existing in
                    guard let select = existing as? SelectRenderable else { return false }
                    select.onChange = snapshot.onChange
                    select.onSelect = snapshot.onSelect
                    select.options = snapshot.options
                    if let idx = snapshot.selectedIndex, select.selectedIndex != idx {
                        select.selectedIndex = idx
                    }
                    select.wrapSelection = snapshot.wrapSelection
                    if select.showDescription != snapshot.showDescription {
                        select.showDescription = snapshot.showDescription
                    }
                    if select.showSelectionIndicator != snapshot.showSelectionIndicator {
                        select.showSelectionIndicator = snapshot.showSelectionIndicator
                    }
                    if select.showScrollIndicator != snapshot.showScrollIndicator {
                        select.showScrollIndicator = snapshot.showScrollIndicator
                    }
                    if select.itemSpacing != snapshot.itemSpacing {
                        select.itemSpacing = snapshot.itemSpacing
                    }
                    if select.fastScrollStep != snapshot.fastScrollStep {
                        select.fastScrollStep = snapshot.fastScrollStep
                    }
                    if let c = snapshot.textColor { select.textColor = c.resolved() }
                    if let c = snapshot.backgroundColor { select.backgroundColor = c.resolved() }
                    if let c = snapshot.focusedTextColor { select.focusedTextColor = c.resolved() }
                    if let c = snapshot.focusedBackgroundColor { select.focusedBackgroundColor = c.resolved() }
                    if let c = snapshot.selectedTextColor { select.selectedTextColor = c.resolved() }
                    if let c = snapshot.selectedBackgroundColor { select.selectedBackgroundColor = c.resolved() }
                    if let c = snapshot.descriptionColor { select.descriptionColor = c.resolved() }
                    if let c = snapshot.selectedDescriptionColor { select.selectedDescriptionColor = c.resolved() }
                    return true
                }
            )
        ]
    }
}

/// Declarative horizontal tab bar selector backed by `TabSelectRenderable`.
public struct TUITabSelect: TUIView {
    public typealias Body = Never

    public let options: [TabSelectOption]
    public let selectedIndex: Int?
    public let tabWidth: Int
    public let wrapSelection: Bool
    public let showDescription: Bool
    public let showUnderline: Bool
    public let showScrollArrows: Bool
    public let textColor: Color?
    public let backgroundColor: Color?
    public let focusedTextColor: Color?
    public let focusedBackgroundColor: Color?
    public let selectedTextColor: Color?
    public let selectedBackgroundColor: Color?
    public let selectedDescriptionColor: Color?
    public let onChange: ((Int, TabSelectOption?) -> Void)?
    public let onSelect: ((Int, TabSelectOption) -> Void)?

    public init(
        options: [TabSelectOption],
        selectedIndex: Int? = nil,
        tabWidth: Int = TabSelectRenderable.defaultTabWidth,
        wrapSelection: Bool = false,
        showDescription: Bool = true,
        showUnderline: Bool = true,
        showScrollArrows: Bool = true,
        textColor: Color? = nil,
        backgroundColor: Color? = nil,
        focusedTextColor: Color? = nil,
        focusedBackgroundColor: Color? = nil,
        selectedTextColor: Color? = nil,
        selectedBackgroundColor: Color? = nil,
        selectedDescriptionColor: Color? = nil,
        onChange: ((Int, TabSelectOption?) -> Void)? = nil,
        onSelect: ((Int, TabSelectOption) -> Void)? = nil
    ) {
        self.options = options
        self.selectedIndex = selectedIndex
        self.tabWidth = tabWidth
        self.wrapSelection = wrapSelection
        self.showDescription = showDescription
        self.showUnderline = showUnderline
        self.showScrollArrows = showScrollArrows
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.focusedTextColor = focusedTextColor
        self.focusedBackgroundColor = focusedBackgroundColor
        self.selectedTextColor = selectedTextColor
        self.selectedBackgroundColor = selectedBackgroundColor
        self.selectedDescriptionColor = selectedDescriptionColor
        self.onChange = onChange
        self.onSelect = onSelect
    }

    public func resolveNodes() -> [TUIViewNode] {
        let snapshot = self
        var props: [String: Any] = [
            "optionCount": options.count,
            "tabWidth": tabWidth,
        ]
        if let selectedIndex { props["selectedIndex"] = selectedIndex }
        return [
            TUIViewNode(
                kind: "tab-select",
                props: props,
                isLeaf: true,
                mount: { ctx in
                    TabSelectRenderable(
                        ctx: ctx,
                        options: TabSelectRenderableOptions(
                            options: snapshot.options,
                            selectedIndex: snapshot.selectedIndex,
                            tabWidth: snapshot.tabWidth,
                            backgroundColor: snapshot.backgroundColor,
                            textColor: snapshot.textColor,
                            focusedBackgroundColor: snapshot.focusedBackgroundColor,
                            focusedTextColor: snapshot.focusedTextColor,
                            selectedBackgroundColor: snapshot.selectedBackgroundColor,
                            selectedTextColor: snapshot.selectedTextColor,
                            selectedDescriptionColor: snapshot.selectedDescriptionColor,
                            showScrollArrows: snapshot.showScrollArrows,
                            showDescription: snapshot.showDescription,
                            showUnderline: snapshot.showUnderline,
                            wrapSelection: snapshot.wrapSelection,
                            onChange: snapshot.onChange,
                            onSelect: snapshot.onSelect
                        )
                    )
                },
                patch: { existing in
                    guard let tabs = existing as? TabSelectRenderable else { return false }
                    tabs.onChange = snapshot.onChange
                    tabs.onSelect = snapshot.onSelect
                    tabs.setOptions(snapshot.options)
                    if let idx = snapshot.selectedIndex, tabs.selectedIndex != idx {
                        tabs.selectedIndex = idx
                    }
                    if tabs.tabWidth != snapshot.tabWidth { tabs.tabWidth = snapshot.tabWidth }
                    tabs.wrapSelection = snapshot.wrapSelection
                    if tabs.showDescription != snapshot.showDescription {
                        tabs.showDescription = snapshot.showDescription
                    }
                    if tabs.showUnderline != snapshot.showUnderline {
                        tabs.showUnderline = snapshot.showUnderline
                    }
                    if tabs.showScrollArrows != snapshot.showScrollArrows {
                        tabs.showScrollArrows = snapshot.showScrollArrows
                    }
                    if let c = snapshot.textColor { tabs.textColor = c.resolved() }
                    if let c = snapshot.backgroundColor { tabs.backgroundColor = c.resolved() }
                    if let c = snapshot.focusedTextColor { tabs.focusedTextColor = c.resolved() }
                    if let c = snapshot.focusedBackgroundColor { tabs.focusedBackgroundColor = c.resolved() }
                    if let c = snapshot.selectedTextColor { tabs.selectedTextColor = c.resolved() }
                    if let c = snapshot.selectedBackgroundColor { tabs.selectedBackgroundColor = c.resolved() }
                    if let c = snapshot.selectedDescriptionColor { tabs.selectedDescriptionColor = c.resolved() }
                    return true
                }
            )
        ]
    }
}

/// Declarative half-block slider control backed by `SliderRenderable`.
public struct TUISlider: TUIView {
    public typealias Body = Never

    public let min: Double
    public let max: Double
    public let value: Double?
    public let orientation: SliderOrientation
    public let viewPortSize: Double?
    public let foregroundColor: Color?
    public let backgroundColor: Color?
    public let onChange: ((Double) -> Void)?

    public init(
        min: Double = 0,
        max: Double = 100,
        value: Double? = nil,
        orientation: SliderOrientation = .horizontal,
        viewPortSize: Double? = nil,
        foregroundColor: Color? = nil,
        backgroundColor: Color? = nil,
        onChange: ((Double) -> Void)? = nil
    ) {
        self.min = min
        self.max = max
        self.value = value
        self.orientation = orientation
        self.viewPortSize = viewPortSize
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.onChange = onChange
    }

    public func resolveNodes() -> [TUIViewNode] {
        let snapshot = self
        var props: [String: Any] = [
            "min": min,
            "max": max,
            "orientation": orientation,
        ]
        if let value { props["value"] = value }
        return [
            TUIViewNode(
                kind: "slider",
                props: props,
                isLeaf: true,
                mount: { ctx in
                    SliderRenderable(
                        ctx: ctx,
                        options: SliderOptions(
                            orientation: snapshot.orientation,
                            value: snapshot.value,
                            min: snapshot.min,
                            max: snapshot.max,
                            viewPortSize: snapshot.viewPortSize,
                            backgroundColor: snapshot.backgroundColor,
                            foregroundColor: snapshot.foregroundColor,
                            onChange: snapshot.onChange
                        )
                    )
                },
                patch: { existing in
                    guard let slider = existing as? SliderRenderable else { return false }
                    // Suppress echo `onChange` notifications while syncing controlled bounds/value.
                    slider.onChange = nil
                    if slider.orientation != snapshot.orientation {
                        slider.orientation = snapshot.orientation
                    }
                    if slider.min != snapshot.min { slider.min = snapshot.min }
                    if slider.max != snapshot.max { slider.max = snapshot.max }
                    if let vp = snapshot.viewPortSize, slider.viewPortSize != vp {
                        slider.viewPortSize = vp
                    }
                    if let controlledValue = snapshot.value, slider.value != controlledValue {
                        slider.value = controlledValue
                    }
                    if let fg = snapshot.foregroundColor {
                        let resolved = fg.resolved()
                        if slider.foregroundColor != resolved { slider.foregroundColor = resolved }
                    }
                    if let bg = snapshot.backgroundColor {
                        let resolved = bg.resolved()
                        if slider.backgroundColor != resolved { slider.backgroundColor = resolved }
                    }
                    slider.onChange = snapshot.onChange
                    return true
                }
            )
        ]
    }
}
