import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables

// MARK: - TUIModifier Value Representation

/// Value-type representation of a declarative modifier applied to a `TUIViewNode`.
public enum TUIModifier {
    // Identity & Keying
    case id(String)
    case key(String)

    // Sizing & Flex
    case width(FlexValue)
    case height(FlexValue)
    case minWidth(FlexValue)
    case maxWidth(FlexValue)
    case minHeight(FlexValue)
    case maxHeight(FlexValue)
    case flexGrow(Float)
    case flexShrink(Float)
    case flexBasis(FlexValue)
    case flexDirection(FlexDirection)
    case flexWrap(Wrap)
    case alignItems(Align)
    case alignSelf(Align)
    case justifyContent(Justify)
    case gap(FlexValue)
    case rowGap(FlexValue)
    case columnGap(FlexValue)
    case padding(FlexValue)
    case paddingEdges(top: FlexValue?, right: FlexValue?, bottom: FlexValue?, left: FlexValue?)
    case paddingAxes(horizontal: FlexValue?, vertical: FlexValue?)
    case margin(FlexValue)
    case marginEdges(top: FlexValue?, right: FlexValue?, bottom: FlexValue?, left: FlexValue?)
    case marginAxes(horizontal: FlexValue?, vertical: FlexValue?)
    case position(type: PositionType, top: FlexValue?, right: FlexValue?, bottom: FlexValue?, left: FlexValue?)
    case overflow(Overflow)

    // Appearance
    case foreground(Color)
    case background(Color)
    case opacity(Double)
    case zIndex(Int)
    case visible(Bool)

    // Interaction
    case focusable(Bool)
    case focused(Bool)
    case onKeyDown((KeyEvent) -> Void)
    case onPaste((PasteEvent) -> Void)
    case onMouse((MouseEvent) -> Void)
    case onMouseDown((MouseEvent) -> Void)
    case onMouseUp((MouseEvent) -> Void)
    case onMouseScroll((MouseEvent) -> Void)
}

// MARK: - Modified View Wrapper

/// View wrapper that attaches one `TUIModifier` to all nodes produced by `content`.
public struct TUIModifiedView<Content: TUIView>: TUIView {
    public typealias Body = Never

    public let content: Content
    public let modifier: TUIModifier

    public init(content: Content, modifier: TUIModifier) {
        self.content = content
        self.modifier = modifier
    }

    public func resolveNodes() -> [TUIViewNode] {
        content.resolveNodes().map { $0.appending(modifier: modifier) }
    }
}

// MARK: - Chainable SwiftUI-Like Modifiers on TUIView

public extension TUIView {
    /// Attaches a raw `TUIModifier` value to this view.
    func modifier(_ modifier: TUIModifier) -> TUIModifiedView<Self> {
        TUIModifiedView(content: self, modifier: modifier)
    }

    // MARK: Identity & Keying

    /// Sets the underlying `Renderable.id` (searchable via `findDescendantById(_:)`).
    func id(_ id: String) -> TUIModifiedView<Self> {
        modifier(.id(id))
    }

    /// Sets an explicit reconciliation key so state (focus, cursor, scroll) follows this node across reorders.
    func key(_ key: String) -> TUIModifiedView<Self> {
        modifier(.key(key))
    }

    /// Sets an explicit reconciliation key from any `Hashable` identifier.
    func key<K: Hashable>(_ key: K) -> TUIModifiedView<Self> {
        modifier(.key(String(describing: key)))
    }

    // MARK: Sizing & Flex

    func width(_ value: FlexValue) -> TUIModifiedView<Self> {
        modifier(.width(value))
    }

    func width(_ value: Int) -> TUIModifiedView<Self> {
        modifier(.width(.point(Float(value))))
    }

    func height(_ value: FlexValue) -> TUIModifiedView<Self> {
        modifier(.height(value))
    }

    func height(_ value: Int) -> TUIModifiedView<Self> {
        modifier(.height(.point(Float(value))))
    }

    func minWidth(_ value: FlexValue) -> TUIModifiedView<Self> {
        modifier(.minWidth(value))
    }

    func minWidth(_ value: Int) -> TUIModifiedView<Self> {
        modifier(.minWidth(.point(Float(value))))
    }

    func maxWidth(_ value: FlexValue) -> TUIModifiedView<Self> {
        modifier(.maxWidth(value))
    }

    func maxWidth(_ value: Int) -> TUIModifiedView<Self> {
        modifier(.maxWidth(.point(Float(value))))
    }

    func minHeight(_ value: FlexValue) -> TUIModifiedView<Self> {
        modifier(.minHeight(value))
    }

    func minHeight(_ value: Int) -> TUIModifiedView<Self> {
        modifier(.minHeight(.point(Float(value))))
    }

    func maxHeight(_ value: FlexValue) -> TUIModifiedView<Self> {
        modifier(.maxHeight(value))
    }

    func maxHeight(_ value: Int) -> TUIModifiedView<Self> {
        modifier(.maxHeight(.point(Float(value))))
    }

    func flexGrow(_ value: Float) -> TUIModifiedView<Self> {
        modifier(.flexGrow(value))
    }

    func flexShrink(_ value: Float) -> TUIModifiedView<Self> {
        modifier(.flexShrink(value))
    }

    func flexBasis(_ value: FlexValue) -> TUIModifiedView<Self> {
        modifier(.flexBasis(value))
    }

    func flexBasis(_ value: Int) -> TUIModifiedView<Self> {
        modifier(.flexBasis(.point(Float(value))))
    }

    func flexDirection(_ value: FlexDirection) -> TUIModifiedView<Self> {
        modifier(.flexDirection(value))
    }

    func flexWrap(_ value: Wrap) -> TUIModifiedView<Self> {
        modifier(.flexWrap(value))
    }

    func alignItems(_ value: Align) -> TUIModifiedView<Self> {
        modifier(.alignItems(value))
    }

    func alignSelf(_ value: Align) -> TUIModifiedView<Self> {
        modifier(.alignSelf(value))
    }

    func justifyContent(_ value: Justify) -> TUIModifiedView<Self> {
        modifier(.justifyContent(value))
    }

    func gap(_ value: FlexValue) -> TUIModifiedView<Self> {
        modifier(.gap(value))
    }

    func gap(_ value: Int) -> TUIModifiedView<Self> {
        modifier(.gap(.point(Float(value))))
    }

    func rowGap(_ value: FlexValue) -> TUIModifiedView<Self> {
        modifier(.rowGap(value))
    }

    func columnGap(_ value: FlexValue) -> TUIModifiedView<Self> {
        modifier(.columnGap(value))
    }

    func padding(_ value: FlexValue) -> TUIModifiedView<Self> {
        modifier(.padding(value))
    }

    func padding(_ value: Int) -> TUIModifiedView<Self> {
        modifier(.padding(.point(Float(value))))
    }

    func padding(
        top: FlexValue? = nil,
        right: FlexValue? = nil,
        bottom: FlexValue? = nil,
        left: FlexValue? = nil
    ) -> TUIModifiedView<Self> {
        modifier(.paddingEdges(top: top, right: right, bottom: bottom, left: left))
    }

    func padding(
        horizontal: FlexValue? = nil,
        vertical: FlexValue? = nil
    ) -> TUIModifiedView<Self> {
        modifier(.paddingAxes(horizontal: horizontal, vertical: vertical))
    }

    func margin(_ value: FlexValue) -> TUIModifiedView<Self> {
        modifier(.margin(value))
    }

    func margin(_ value: Int) -> TUIModifiedView<Self> {
        modifier(.margin(.point(Float(value))))
    }

    func margin(
        top: FlexValue? = nil,
        right: FlexValue? = nil,
        bottom: FlexValue? = nil,
        left: FlexValue? = nil
    ) -> TUIModifiedView<Self> {
        modifier(.marginEdges(top: top, right: right, bottom: bottom, left: left))
    }

    func margin(
        horizontal: FlexValue? = nil,
        vertical: FlexValue? = nil
    ) -> TUIModifiedView<Self> {
        modifier(.marginAxes(horizontal: horizontal, vertical: vertical))
    }

    func position(
        _ type: PositionType,
        top: FlexValue? = nil,
        right: FlexValue? = nil,
        bottom: FlexValue? = nil,
        left: FlexValue? = nil
    ) -> TUIModifiedView<Self> {
        modifier(.position(type: type, top: top, right: right, bottom: bottom, left: left))
    }

    func overflow(_ value: Overflow) -> TUIModifiedView<Self> {
        modifier(.overflow(value))
    }

    // MARK: Appearance

    func foreground(_ color: Color) -> TUIModifiedView<Self> {
        modifier(.foreground(color))
    }

    func foreground(_ rgba: RGBA) -> TUIModifiedView<Self> {
        modifier(.foreground(.rgba(rgba)))
    }

    func background(_ color: Color) -> TUIModifiedView<Self> {
        modifier(.background(color))
    }

    func background(_ rgba: RGBA) -> TUIModifiedView<Self> {
        modifier(.background(.rgba(rgba)))
    }

    func opacity(_ value: Double) -> TUIModifiedView<Self> {
        modifier(.opacity(value))
    }

    func zIndex(_ value: Int) -> TUIModifiedView<Self> {
        modifier(.zIndex(value))
    }

    func visible(_ value: Bool) -> TUIModifiedView<Self> {
        modifier(.visible(value))
    }

    // MARK: Interaction

    func focusable(_ value: Bool = true) -> TUIModifiedView<Self> {
        modifier(.focusable(value))
    }

    func focused(_ value: Bool = true) -> TUIModifiedView<Self> {
        modifier(.focused(value))
    }

    func onKeyDown(_ handler: @escaping (KeyEvent) -> Void) -> TUIModifiedView<Self> {
        modifier(.onKeyDown(handler))
    }

    func onPaste(_ handler: @escaping (PasteEvent) -> Void) -> TUIModifiedView<Self> {
        modifier(.onPaste(handler))
    }

    func onMouse(_ handler: @escaping (MouseEvent) -> Void) -> TUIModifiedView<Self> {
        modifier(.onMouse(handler))
    }

    func onMouseDown(_ handler: @escaping (MouseEvent) -> Void) -> TUIModifiedView<Self> {
        modifier(.onMouseDown(handler))
    }

    func onMouseUp(_ handler: @escaping (MouseEvent) -> Void) -> TUIModifiedView<Self> {
        modifier(.onMouseUp(handler))
    }

    func onMouseScroll(_ handler: @escaping (MouseEvent) -> Void) -> TUIModifiedView<Self> {
        modifier(.onMouseScroll(handler))
    }
}

// MARK: - Modifier Application & Diff-Reset Engine

private enum TUIModifierSlot: Hashable {
    case width, height, minWidth, maxWidth, minHeight, maxHeight
    case flexGrow, flexShrink, flexBasis, flexDirection, flexWrap
    case alignItems, alignSelf, justifyContent
    case gap, rowGap, columnGap
    case padding, paddingTop, paddingRight, paddingBottom, paddingLeft, paddingX, paddingY
    case margin, marginTop, marginRight, marginBottom, marginLeft, marginX, marginY
    case positionType, posTop, posRight, posBottom, posLeft
    case overflow
    case foreground, background, opacity, zIndex, visible
    case focusable
    case onKeyDown, onPaste, onMouse, onMouseDown, onMouseUp, onMouseScroll
}

private func collectModifierSlots(_ modifiers: [TUIModifier]) -> Set<TUIModifierSlot> {
    var slots: Set<TUIModifierSlot> = []
    for mod in modifiers {
        switch mod {
        case .id, .key, .focused:
            break
        case .width: slots.insert(.width)
        case .height: slots.insert(.height)
        case .minWidth: slots.insert(.minWidth)
        case .maxWidth: slots.insert(.maxWidth)
        case .minHeight: slots.insert(.minHeight)
        case .maxHeight: slots.insert(.maxHeight)
        case .flexGrow: slots.insert(.flexGrow)
        case .flexShrink: slots.insert(.flexShrink)
        case .flexBasis: slots.insert(.flexBasis)
        case .flexDirection: slots.insert(.flexDirection)
        case .flexWrap: slots.insert(.flexWrap)
        case .alignItems: slots.insert(.alignItems)
        case .alignSelf: slots.insert(.alignSelf)
        case .justifyContent: slots.insert(.justifyContent)
        case .gap: slots.insert(.gap)
        case .rowGap: slots.insert(.rowGap)
        case .columnGap: slots.insert(.columnGap)
        case .padding: slots.insert(.padding)
        case .paddingEdges(let top, let right, let bottom, let left):
            if top != nil { slots.insert(.paddingTop) }
            if right != nil { slots.insert(.paddingRight) }
            if bottom != nil { slots.insert(.paddingBottom) }
            if left != nil { slots.insert(.paddingLeft) }
        case .paddingAxes(let horizontal, let vertical):
            if horizontal != nil { slots.insert(.paddingX) }
            if vertical != nil { slots.insert(.paddingY) }
        case .margin: slots.insert(.margin)
        case .marginEdges(let top, let right, let bottom, let left):
            if top != nil { slots.insert(.marginTop) }
            if right != nil { slots.insert(.marginRight) }
            if bottom != nil { slots.insert(.marginBottom) }
            if left != nil { slots.insert(.marginLeft) }
        case .marginAxes(let horizontal, let vertical):
            if horizontal != nil { slots.insert(.marginX) }
            if vertical != nil { slots.insert(.marginY) }
        case .position(_, let top, let right, let bottom, let left):
            slots.insert(.positionType)
            if top != nil { slots.insert(.posTop) }
            if right != nil { slots.insert(.posRight) }
            if bottom != nil { slots.insert(.posBottom) }
            if left != nil { slots.insert(.posLeft) }
        case .overflow: slots.insert(.overflow)
        case .foreground: slots.insert(.foreground)
        case .background: slots.insert(.background)
        case .opacity: slots.insert(.opacity)
        case .zIndex: slots.insert(.zIndex)
        case .visible: slots.insert(.visible)
        case .focusable: slots.insert(.focusable)
        case .onKeyDown: slots.insert(.onKeyDown)
        case .onPaste: slots.insert(.onPaste)
        case .onMouse: slots.insert(.onMouse)
        case .onMouseDown: slots.insert(.onMouseDown)
        case .onMouseUp: slots.insert(.onMouseUp)
        case .onMouseScroll: slots.insert(.onMouseScroll)
        }
    }
    return slots
}

private func resetModifierSlot(_ slot: TUIModifierSlot, on renderable: Renderable) {
    switch slot {
    case .width: renderable.setWidth(.auto)
    case .height: renderable.setHeight(.auto)
    case .minWidth: renderable.minWidth = .undefined
    case .maxWidth: renderable.maxWidth = .undefined
    case .minHeight: renderable.minHeight = .undefined
    case .maxHeight: renderable.maxHeight = .undefined
    case .flexGrow: renderable.flexGrow = 0
    case .flexShrink: renderable.flexShrink = 1
    case .flexBasis: renderable.flexBasis = .auto
    case .flexDirection: renderable.flexDirection = .column
    case .flexWrap: renderable.flexWrap = .noWrap
    case .alignItems: renderable.alignItems = .stretch
    case .alignSelf: renderable.alignSelf = .auto
    case .justifyContent: renderable.justifyContent = .flexStart
    case .gap:
        if let scroll = renderable as? ScrollBoxRenderable {
            scroll.content.gap = .undefined
        } else {
            renderable.gap = .undefined
        }
    case .rowGap:
        if let scroll = renderable as? ScrollBoxRenderable {
            scroll.content.rowGap = .undefined
        } else {
            renderable.rowGap = .undefined
        }
    case .columnGap:
        if let scroll = renderable as? ScrollBoxRenderable {
            scroll.content.columnGap = .undefined
        } else {
            renderable.columnGap = .undefined
        }
    case .padding:
        if let scroll = renderable as? ScrollBoxRenderable {
            scroll.content.padding = .undefined
        } else {
            renderable.padding = .undefined
        }
    case .paddingTop:
        if let scroll = renderable as? ScrollBoxRenderable {
            scroll.content.paddingTop = .undefined
        } else {
            renderable.paddingTop = .undefined
        }
    case .paddingRight:
        if let scroll = renderable as? ScrollBoxRenderable {
            scroll.content.paddingRight = .undefined
        } else {
            renderable.paddingRight = .undefined
        }
    case .paddingBottom:
        if let scroll = renderable as? ScrollBoxRenderable {
            scroll.content.paddingBottom = .undefined
        } else {
            renderable.paddingBottom = .undefined
        }
    case .paddingLeft:
        if let scroll = renderable as? ScrollBoxRenderable {
            scroll.content.paddingLeft = .undefined
        } else {
            renderable.paddingLeft = .undefined
        }
    case .paddingX:
        if let scroll = renderable as? ScrollBoxRenderable {
            scroll.content.paddingX = .undefined
        } else {
            renderable.paddingX = .undefined
        }
    case .paddingY:
        if let scroll = renderable as? ScrollBoxRenderable {
            scroll.content.paddingY = .undefined
        } else {
            renderable.paddingY = .undefined
        }
    case .margin: renderable.margin = .undefined
    case .marginTop: renderable.marginTop = .undefined
    case .marginRight: renderable.marginRight = .undefined
    case .marginBottom: renderable.marginBottom = .undefined
    case .marginLeft: renderable.marginLeft = .undefined
    case .marginX: renderable.marginX = .undefined
    case .marginY: renderable.marginY = .undefined
    case .positionType: renderable.position = .relative
    case .posTop: renderable.top = .undefined
    case .posRight: renderable.right = .undefined
    case .posBottom: renderable.bottom = .undefined
    case .posLeft: renderable.left = .undefined
    case .overflow: renderable.overflow = .visible
    case .foreground:
        if let text = renderable as? TextBufferRenderable {
            text.fg = RGBA.fromValues(1, 1, 1, 1)
        } else if let edit = renderable as? EditBufferRenderable {
            edit.textColor = EditBufferRenderable.defaultTextColor
        } else if let select = renderable as? SelectRenderable {
            select.textColor = SelectRenderable.defaultTextColor.resolved()
        } else if let tabSelect = renderable as? TabSelectRenderable {
            tabSelect.textColor = TabSelectRenderable.defaultTextColor.resolved()
        } else if let slider = renderable as? SliderRenderable {
            slider.foregroundColor = SliderRenderable.defaultThumbBackgroundColor
        } else if let ascii = renderable as? ASCIIFontRenderable {
            ascii.color = [ASCIIFontRenderable.defaultColor]
        } else if let qr = renderable as? BaseQRCodeRenderable {
            qr.foregroundColor = RGBA.fromHex("#000000")
        } else if let table = renderable as? TextTableRenderable {
            table.fg = parseColor("#FFFFFF")
        } else if let box = renderable as? BoxRenderable {
            box.borderColor = BoxRenderable.defaultBorderColor
        }
    case .background:
        if let box = renderable as? BoxRenderable {
            box.backgroundColor = BoxRenderable.defaultBackgroundColor
        } else if let text = renderable as? TextBufferRenderable {
            text.bg = RGBA.fromValues(0, 0, 0, 0)
        } else if let edit = renderable as? EditBufferRenderable {
            edit.backgroundColor = EditBufferRenderable.defaultBackgroundColor
        } else if let select = renderable as? SelectRenderable {
            select.backgroundColor = SelectRenderable.defaultBackgroundColor.resolved()
        } else if let tabSelect = renderable as? TabSelectRenderable {
            tabSelect.backgroundColor = TabSelectRenderable.defaultBackgroundColor.resolved()
        } else if let slider = renderable as? SliderRenderable {
            slider.backgroundColor = SliderRenderable.defaultTrackBackgroundColor
        } else if let ascii = renderable as? ASCIIFontRenderable {
            ascii.backgroundColor = ASCIIFontRenderable.defaultBackgroundColor
        } else if let qr = renderable as? BaseQRCodeRenderable {
            qr.backgroundColor = RGBA.fromHex("#FFFFFF")
        }
    case .opacity: renderable.opacity = 1.0
    case .zIndex: renderable.zIndex = 0
    case .visible: renderable.visible = true
    case .focusable:
        let defaultFocusable = (renderable is EditBufferRenderable)
            || (renderable is SelectRenderable)
            || (renderable is TabSelectRenderable)
            || (renderable is ScrollBoxRenderable)
        renderable.focusable = defaultFocusable
    case .onKeyDown: renderable.onKeyDown = nil
    case .onPaste: renderable.onPaste = nil
    case .onMouse: renderable.onMouse = nil
    case .onMouseDown: renderable.onMouseDown = nil
    case .onMouseUp: renderable.onMouseUp = nil
    case .onMouseScroll: renderable.onMouseScroll = nil
    }
}

private func applyForegroundColor(_ color: Color, to renderable: Renderable) {
    let rgba = color.resolved()
    if let text = renderable as? TextBufferRenderable {
        text.fg = rgba
    } else if let edit = renderable as? EditBufferRenderable {
        edit.textColor = rgba
    } else if let select = renderable as? SelectRenderable {
        select.textColor = rgba
    } else if let tabSelect = renderable as? TabSelectRenderable {
        tabSelect.textColor = rgba
    } else if let slider = renderable as? SliderRenderable {
        slider.foregroundColor = rgba
    } else if let ascii = renderable as? ASCIIFontRenderable {
        ascii.color = [rgba]
    } else if let qr = renderable as? BaseQRCodeRenderable {
        qr.foregroundColor = rgba
    } else if let table = renderable as? TextTableRenderable {
        table.fg = rgba
    } else if let box = renderable as? BoxRenderable {
        box.borderColor = rgba
    }
}

private func applyBackgroundColor(_ color: Color, to renderable: Renderable) {
    let rgba = color.resolved()
    if let box = renderable as? BoxRenderable {
        box.backgroundColor = rgba
    } else if let text = renderable as? TextBufferRenderable {
        text.bg = rgba
    } else if let edit = renderable as? EditBufferRenderable {
        edit.backgroundColor = rgba
    } else if let select = renderable as? SelectRenderable {
        select.backgroundColor = rgba
    } else if let tabSelect = renderable as? TabSelectRenderable {
        tabSelect.backgroundColor = rgba
    } else if let slider = renderable as? SliderRenderable {
        slider.backgroundColor = rgba
    } else if let ascii = renderable as? ASCIIFontRenderable {
        ascii.backgroundColor = rgba
    } else if let qr = renderable as? BaseQRCodeRenderable {
        qr.backgroundColor = rgba
    }
}

/// Resets any modifier slots present in `previous` that were removed in `next`.
internal func resetRemovedTUIModifiers(
    previous: [TUIModifier],
    next: [TUIModifier],
    on renderable: Renderable
) {
    guard !previous.isEmpty else { return }
    let prevSlots = collectModifierSlots(previous)
    let nextSlots = collectModifierSlots(next)
    let removed = prevSlots.subtracting(nextSlots)
    for slot in removed {
        resetModifierSlot(slot, on: renderable)
    }
}

/// Applies `modifiers` to `renderable` in order (applying `.focused(_)` last so `.focusable(_)` takes effect first).
internal func applyTUIModifiers(
    _ modifiers: [TUIModifier],
    to renderable: Renderable
) {
    var deferredFocused: Bool? = nil

    for mod in modifiers {
        switch mod {
        case .id(let value):
            if renderable.id != value {
                renderable.id = value
            }
        case .key:
            break

        case .width(let value):
            renderable.setWidth(value)
        case .height(let value):
            renderable.setHeight(value)
        case .minWidth(let value):
            if renderable.minWidth != value { renderable.minWidth = value }
        case .maxWidth(let value):
            if renderable.maxWidth != value { renderable.maxWidth = value }
        case .minHeight(let value):
            if renderable.minHeight != value { renderable.minHeight = value }
        case .maxHeight(let value):
            if renderable.maxHeight != value { renderable.maxHeight = value }
        case .flexGrow(let value):
            if renderable.flexGrow != value { renderable.flexGrow = value }
        case .flexShrink(let value):
            if renderable.flexShrink != value { renderable.flexShrink = value }
        case .flexBasis(let value):
            if renderable.flexBasis != value { renderable.flexBasis = value }
        case .flexDirection(let value):
            if renderable.flexDirection != value { renderable.flexDirection = value }
        case .flexWrap(let value):
            if renderable.flexWrap != value { renderable.flexWrap = value }
        case .alignItems(let value):
            if renderable.alignItems != value { renderable.alignItems = value }
        case .alignSelf(let value):
            if renderable.alignSelf != value { renderable.alignSelf = value }
        case .justifyContent(let value):
            if renderable.justifyContent != value { renderable.justifyContent = value }
        case .gap(let value):
            if let scroll = renderable as? ScrollBoxRenderable {
                if scroll.content.gap != value { scroll.content.gap = value }
            } else if renderable.gap != value {
                renderable.gap = value
            }
        case .rowGap(let value):
            if let scroll = renderable as? ScrollBoxRenderable {
                if scroll.content.rowGap != value { scroll.content.rowGap = value }
            } else if renderable.rowGap != value {
                renderable.rowGap = value
            }
        case .columnGap(let value):
            if let scroll = renderable as? ScrollBoxRenderable {
                if scroll.content.columnGap != value { scroll.content.columnGap = value }
            } else if renderable.columnGap != value {
                renderable.columnGap = value
            }
        case .padding(let value):
            if let scroll = renderable as? ScrollBoxRenderable {
                if scroll.content.padding != value { scroll.content.padding = value }
            } else if renderable.padding != value {
                renderable.padding = value
            }
        case .paddingEdges(let top, let right, let bottom, let left):
            if let scroll = renderable as? ScrollBoxRenderable {
                if let top, scroll.content.paddingTop != top { scroll.content.paddingTop = top }
                if let right, scroll.content.paddingRight != right { scroll.content.paddingRight = right }
                if let bottom, scroll.content.paddingBottom != bottom { scroll.content.paddingBottom = bottom }
                if let left, scroll.content.paddingLeft != left { scroll.content.paddingLeft = left }
            } else {
                if let top, renderable.paddingTop != top { renderable.paddingTop = top }
                if let right, renderable.paddingRight != right { renderable.paddingRight = right }
                if let bottom, renderable.paddingBottom != bottom { renderable.paddingBottom = bottom }
                if let left, renderable.paddingLeft != left { renderable.paddingLeft = left }
            }
        case .paddingAxes(let horizontal, let vertical):
            if let scroll = renderable as? ScrollBoxRenderable {
                if let horizontal, scroll.content.paddingX != horizontal { scroll.content.paddingX = horizontal }
                if let vertical, scroll.content.paddingY != vertical { scroll.content.paddingY = vertical }
            } else {
                if let horizontal, renderable.paddingX != horizontal { renderable.paddingX = horizontal }
                if let vertical, renderable.paddingY != vertical { renderable.paddingY = vertical }
            }
        case .margin(let value):
            if renderable.margin != value { renderable.margin = value }
        case .marginEdges(let top, let right, let bottom, let left):
            if let top, renderable.marginTop != top { renderable.marginTop = top }
            if let right, renderable.marginRight != right { renderable.marginRight = right }
            if let bottom, renderable.marginBottom != bottom { renderable.marginBottom = bottom }
            if let left, renderable.marginLeft != left { renderable.marginLeft = left }
        case .marginAxes(let horizontal, let vertical):
            if let horizontal, renderable.marginX != horizontal { renderable.marginX = horizontal }
            if let vertical, renderable.marginY != vertical { renderable.marginY = vertical }
        case .position(let type, let top, let right, let bottom, let left):
            if renderable.position != type { renderable.position = type }
            if let top, renderable.top != top { renderable.top = top }
            if let right, renderable.right != right { renderable.right = right }
            if let bottom, renderable.bottom != bottom { renderable.bottom = bottom }
            if let left, renderable.left != left { renderable.left = left }
        case .overflow(let value):
            if renderable.overflow != value { renderable.overflow = value }

        case .foreground(let color):
            applyForegroundColor(color, to: renderable)
        case .background(let color):
            applyBackgroundColor(color, to: renderable)
        case .opacity(let value):
            renderable.opacity = value
        case .zIndex(let value):
            renderable.zIndex = value
        case .visible(let value):
            renderable.visible = value

        case .focusable(let value):
            renderable.focusable = value
        case .focused(let value):
            deferredFocused = value
        case .onKeyDown(let handler):
            renderable.onKeyDown = handler
        case .onPaste(let handler):
            renderable.onPaste = handler
        case .onMouse(let handler):
            renderable.onMouse = handler
        case .onMouseDown(let handler):
            renderable.onMouseDown = handler
        case .onMouseUp(let handler):
            renderable.onMouseUp = handler
        case .onMouseScroll(let handler):
            renderable.onMouseScroll = handler
        }
    }

    // Apply focus after `.focusable(_)` so modifier chaining order never prevents focusing.
    if let shouldFocus = deferredFocused {
        if shouldFocus {
            renderable.focus()
        } else {
            renderable.blur()
        }
    }
}
