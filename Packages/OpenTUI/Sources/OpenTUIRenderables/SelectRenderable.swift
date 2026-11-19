import OpenTUICore
import OpenTUILayout

// MARK: - Select Types & Key Bindings

private let selectTransparent = RGBA.fromValues(0, 0, 0, 0)
private let selectIndicatorColor = parseColor("#666666")

// parity: core/src/renderables/Select.ts#SelectOption [status=implemented hash=8b4f1e79f5a4]
public struct SelectOption: Sendable {
    public var name: String
    public var description: String
    public var value: (any Sendable)?

    public init(name: String, description: String = "", value: (any Sendable)? = nil) {
        self.name = name
        self.description = description
        self.value = value
    }
}

// parity: core/src/renderables/Select.ts#SelectAction [status=implemented hash=396f0f9674d1]
public enum SelectAction: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case moveUp = "move-up"
    case moveDown = "move-down"
    case moveUpFast = "move-up-fast"
    case moveDownFast = "move-down-fast"
    case selectCurrent = "select-current"
}

// parity: core/src/renderables/Select.ts#SelectKeyBinding [status=implemented hash=4e4ef7878560]
public typealias SelectKeyBinding = KeyBinding<SelectAction>

public let defaultSelectKeybindings: [SelectKeyBinding] = [
    KeyBinding(name: "up", action: .moveUp),
    KeyBinding(name: "k", action: .moveUp),
    KeyBinding(name: "down", action: .moveDown),
    KeyBinding(name: "j", action: .moveDown),
    KeyBinding(name: "up", shift: true, action: .moveUpFast),
    KeyBinding(name: "down", shift: true, action: .moveDownFast),
    KeyBinding(name: "return", action: .selectCurrent),
    KeyBinding(name: "linefeed", action: .selectCurrent),
]

// parity: core/src/renderables/Select.ts#SelectRenderableEvents [status=implemented hash=bcd76561a010]
public enum SelectRenderableEvents: String, Equatable, Hashable, Sendable {
    case selectionChanged = "selectionChanged"
    case itemSelected = "itemSelected"
}

// MARK: - SelectRenderableOptions / SelectOptions

// parity: core/src/renderables/Select.ts#SelectRenderableOptions [status=implemented hash=42b5cf4499e9]
public struct SelectRenderableOptions {
    public var renderable: RenderableOptions
    public var backgroundColor: Color?
    public var textColor: Color?
    public var focusedBackgroundColor: Color?
    public var focusedTextColor: Color?
    public var options: [SelectOption]?
    public var selectedIndex: Int?
    public var selectedBackgroundColor: Color?
    public var selectedTextColor: Color?
    public var descriptionColor: Color?
    public var selectedDescriptionColor: Color?
    public var showScrollIndicator: Bool?
    public var wrapSelection: Bool?
    public var showDescription: Bool?
    public var showSelectionIndicator: Bool?
    public var font: ASCIIFontName?
    public var itemSpacing: Int?
    public var fastScrollStep: Int?
    public var keyBindings: [SelectKeyBinding]?
    public var keyAliasMap: KeyAliasMap?
    public var onChange: ((Int, SelectOption?) -> Void)?
    public var onSelect: ((Int, SelectOption) -> Void)?

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
        flexBasis: FlexValue? = nil,
        position: PositionType? = nil,
        top: FlexValue? = nil,
        right: FlexValue? = nil,
        bottom: FlexValue? = nil,
        left: FlexValue? = nil,
        margin: FlexValue? = nil,
        padding: FlexValue? = nil,
        zIndex: Int? = nil,
        visible: Bool? = nil,
        opacity: Double? = nil,
        focusable: Bool? = nil,
        buffered: Bool? = nil,
        backgroundColor: Color? = nil,
        textColor: Color? = nil,
        focusedBackgroundColor: Color? = nil,
        focusedTextColor: Color? = nil,
        options: [SelectOption]? = nil,
        selectedIndex: Int? = nil,
        selectedBackgroundColor: Color? = nil,
        selectedTextColor: Color? = nil,
        descriptionColor: Color? = nil,
        selectedDescriptionColor: Color? = nil,
        showScrollIndicator: Bool? = nil,
        wrapSelection: Bool? = nil,
        showDescription: Bool? = nil,
        showSelectionIndicator: Bool? = nil,
        font: ASCIIFontName? = nil,
        itemSpacing: Int? = nil,
        fastScrollStep: Int? = nil,
        keyBindings: [SelectKeyBinding]? = nil,
        keyAliasMap: KeyAliasMap? = nil,
        onChange: ((Int, SelectOption?) -> Void)? = nil,
        onSelect: ((Int, SelectOption) -> Void)? = nil,
        onKeyDown: ((KeyEvent) -> Void)? = nil,
        onMouse: ((MouseEvent) -> Void)? = nil
    ) {
        self.renderable = RenderableOptions(
            id: id,
            width: width,
            height: height,
            minWidth: minWidth,
            maxWidth: maxWidth,
            minHeight: minHeight,
            maxHeight: maxHeight,
            flexGrow: flexGrow,
            flexShrink: flexShrink,
            flexBasis: flexBasis,
            position: position,
            top: top,
            right: right,
            bottom: bottom,
            left: left,
            margin: margin,
            padding: padding,
            zIndex: zIndex,
            visible: visible,
            opacity: opacity,
            focusable: focusable,
            buffered: buffered,
            onMouse: onMouse,
            onKeyDown: onKeyDown
        )
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.focusedBackgroundColor = focusedBackgroundColor
        self.focusedTextColor = focusedTextColor
        self.options = options
        self.selectedIndex = selectedIndex
        self.selectedBackgroundColor = selectedBackgroundColor
        self.selectedTextColor = selectedTextColor
        self.descriptionColor = descriptionColor
        self.selectedDescriptionColor = selectedDescriptionColor
        self.showScrollIndicator = showScrollIndicator
        self.wrapSelection = wrapSelection
        self.showDescription = showDescription
        self.showSelectionIndicator = showSelectionIndicator
        self.font = font
        self.itemSpacing = itemSpacing
        self.fastScrollStep = fastScrollStep
        self.keyBindings = keyBindings
        self.keyAliasMap = keyAliasMap
        self.onChange = onChange
        self.onSelect = onSelect
    }
}

/// Alias matching `SelectOptions` naming.
public typealias SelectOptions = SelectRenderableOptions

// MARK: - SelectRenderable

/// Scrollable vertical list selection renderable with keyboard navigation,
/// mouse click and wheel support, optional descriptions, ASCII banner fonts, and scroll indicator.
// parity: core/src/renderables/Select.ts#SelectRenderable [status=implemented hash=bcdac35b6a75]
open class SelectRenderable: Renderable, @unchecked Sendable {
    public static let defaultBackgroundColor: Color = "transparent"
    public static let defaultTextColor: Color = "#FFFFFF"
    public static let defaultFocusedBackgroundColor: Color = "#1a1a1a"
    public static let defaultFocusedTextColor: Color = "#FFFFFF"
    public static let defaultSelectedBackgroundColor: Color = "#334455"
    public static let defaultSelectedTextColor: Color = "#FFFF00"
    public static let defaultDescriptionColor: Color = "#888888"
    public static let defaultSelectedDescriptionColor: Color = "#CCCCCC"
    public static let defaultShowScrollIndicator: Bool = false
    public static let defaultWrapSelection: Bool = false
    public static let defaultShowDescription: Bool = true
    public static let defaultShowSelectionIndicator: Bool = true
    public static let defaultItemSpacing: Int = 0
    public static let defaultFastScrollStep: Int = 5

    private var _options: [SelectOption] = []
    private var _selectedIndex: Int = 0
    private var scrollOffset: Int = 0
    private var maxVisibleItems: Int = 1

    private var _backgroundColor: RGBA
    private var _textColor: RGBA
    private var _focusedBackgroundColor: RGBA
    private var _focusedTextColor: RGBA
    private var _selectedBackgroundColor: RGBA
    private var _selectedTextColor: RGBA
    private var _descriptionColor: RGBA
    private var _selectedDescriptionColor: RGBA
    private var _showScrollIndicator: Bool
    private var _wrapSelection: Bool
    private var _showDescription: Bool
    private var _showSelectionIndicator: Bool
    private var _font: ASCIIFontName?
    private var _itemSpacing: Int
    private var linesPerItem: Int = 1
    private var fontHeight: Int = 1
    private var _fastScrollStep: Int
    private var _keyBindingsMap: [String: SelectAction] = [:]
    private var _keyAliasMap: KeyAliasMap
    private var _keyBindings: [SelectKeyBinding]

    public var onChange: ((Int, SelectOption?) -> Void)?
    public var onSelect: ((Int, SelectOption) -> Void)?

    private var _changeListeners: [(id: UInt64, fn: (Int, SelectOption?) -> Void)] = []
    private var _selectListeners: [(id: UInt64, fn: (Int, SelectOption) -> Void)] = []
    private var _nextTypedListenerId: UInt64 = 1

    public init(ctx: any RenderContext, options: SelectRenderableOptions = SelectRenderableOptions()) {
        var renderableOpts = options.renderable
        if renderableOpts.focusable == nil {
            renderableOpts.focusable = true
        }

        let initialOptions = options.options ?? []
        let requestedIndex = options.selectedIndex ?? 0
        self._options = initialOptions
        self._selectedIndex = initialOptions.isEmpty
            ? 0
            : max(0, min(requestedIndex, initialOptions.count - 1))

        self._backgroundColor = RGBA.clone((options.backgroundColor ?? Self.defaultBackgroundColor).resolved())
        self._textColor = RGBA.clone((options.textColor ?? Self.defaultTextColor).resolved())
        self._focusedBackgroundColor = RGBA.clone((options.focusedBackgroundColor ?? Self.defaultFocusedBackgroundColor).resolved())
        self._focusedTextColor = RGBA.clone((options.focusedTextColor ?? Self.defaultFocusedTextColor).resolved())
        self._selectedBackgroundColor = RGBA.clone((options.selectedBackgroundColor ?? Self.defaultSelectedBackgroundColor).resolved())
        self._selectedTextColor = RGBA.clone((options.selectedTextColor ?? Self.defaultSelectedTextColor).resolved())
        self._descriptionColor = RGBA.clone((options.descriptionColor ?? Self.defaultDescriptionColor).resolved())
        self._selectedDescriptionColor = RGBA.clone((options.selectedDescriptionColor ?? Self.defaultSelectedDescriptionColor).resolved())

        self._showScrollIndicator = options.showScrollIndicator ?? Self.defaultShowScrollIndicator
        self._wrapSelection = options.wrapSelection ?? Self.defaultWrapSelection
        self._showDescription = options.showDescription ?? Self.defaultShowDescription
        self._showSelectionIndicator = options.showSelectionIndicator ?? Self.defaultShowSelectionIndicator
        self._font = options.font
        self._itemSpacing = max(0, options.itemSpacing ?? Self.defaultItemSpacing)
        self._fastScrollStep = max(1, options.fastScrollStep ?? Self.defaultFastScrollStep)
        self.fontHeight = options.font.map { measureAsciiText("A", font: $0).height } ?? 1

        self._keyAliasMap = mergeKeyAliases(defaultKeyAliases, options.keyAliasMap ?? [:])
        self._keyBindings = options.keyBindings ?? []
        let merged = mergeKeyBindings(defaultSelectKeybindings, self._keyBindings)
        self._keyBindingsMap = buildKeyBindingsMap(merged, aliasMap: self._keyAliasMap)

        self.onChange = options.onChange
        self.onSelect = options.onSelect

        super.init(ctx: ctx, options: renderableOpts)

        updateItemLayout()
        updateScrollOffset()
        requestRender()
    }

    // MARK: - Typed Event Subscriptions

    @discardableResult
    public func onSelectionChanged(_ listener: @escaping (Int, SelectOption?) -> Void) -> UInt64 {
        let id = _nextTypedListenerId
        _nextTypedListenerId &+= 1
        _changeListeners.append((id: id, fn: listener))
        return id
    }

    @discardableResult
    public func onItemSelected(_ listener: @escaping (Int, SelectOption) -> Void) -> UInt64 {
        let id = _nextTypedListenerId
        _nextTypedListenerId &+= 1
        _selectListeners.append((id: id, fn: listener))
        return id
    }

    public func offTypedListener(_ id: UInt64) {
        _changeListeners.removeAll { $0.id == id }
        _selectListeners.removeAll { $0.id == id }
    }

    private func emitSelectionChanged() {
        let opt = getSelectedOption()
        onChange?(_selectedIndex, opt)
        for entry in _changeListeners {
            entry.fn(_selectedIndex, opt)
        }
        emit(SelectRenderableEvents.selectionChanged.rawValue)
    }

    private func emitItemSelected(_ option: SelectOption) {
        onSelect?(_selectedIndex, option)
        for entry in _selectListeners {
            entry.fn(_selectedIndex, option)
        }
        emit(SelectRenderableEvents.itemSelected.rawValue)
    }

    // MARK: - Rendering

    open override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        let origin = paintOrigin(for: buffer)
        let x = origin.x
        let y = origin.y
        let drawWidth = width
        let drawHeight = height
        guard drawWidth > 0 && drawHeight > 0 else { return }

        let bgColor = _focused ? _focusedBackgroundColor : _backgroundColor
        let selectedY = (_selectedIndex - scrollOffset) * linesPerItem
        let selectedHeight = max(1, linesPerItem - _itemSpacing)
        let hasOpaqueSelection = _selectedBackgroundColor.toInts().3 == 255
        let hole = !_options.isEmpty && selectedY >= 0 && selectedY + linesPerItem <= drawHeight && hasOpaqueSelection
        let top = hole ? selectedY : drawHeight
        let bottom = hole ? selectedY + selectedHeight : drawHeight

        let scrolls = _showScrollIndicator && _options.count > maxVisibleItems
        let scrollDenom = max(1, _options.count - maxVisibleItems)
        let scrollPercent = Double(scrollOffset) / Double(scrollDenom)
        let indicatorY = scrolls ? y + 1 + Int((scrollPercent * Double(max(1, drawHeight - 2))).rounded(.down)) : -1

        func draw(_ text: String, textX: Int, textY: Int, color: RGBA) {
            let end = (textY == indicatorY) ? (x + drawWidth - 1) : (x + drawWidth)
            let fitWidth = end - textX
            if fitWidth > 0 {
                buffer.drawTextFit(text, x: textX, y: textY, maxWidth: fitWidth, fg: color, bg: selectTransparent)
            }
        }

        buffer.pushScissorRect(x: x, y: y, width: drawWidth, height: drawHeight)
        defer { buffer.popScissorRect() }

        if let fb = frameBuffer, buffer === fb {
            buffer.clear(bg: bgColor)
        } else {
            buffer.fillRect(x: x, y: y, width: drawWidth, height: top, bg: bgColor)
            buffer.fillRect(x: x, y: y + bottom, width: drawWidth, height: drawHeight - bottom, bg: bgColor)
        }

        let startIdx = max(0, min(scrollOffset, _options.count))
        let endIdx = max(startIdx, min(startIdx + maxVisibleItems, _options.count))
        let baseTextColor = _focused ? _focusedTextColor : _textColor

        for i in 0..<(endIdx - startIdx) {
            let optionIndex = startIdx + i
            let option = _options[optionIndex]
            let isSelected = optionIndex == _selectedIndex
            let itemY = y + i * linesPerItem

            if itemY + linesPerItem - 1 >= y + drawHeight {
                break
            }

            if isSelected {
                buffer.fillRect(x: x, y: itemY, width: drawWidth, height: selectedHeight, bg: _selectedBackgroundColor)
            }

            let indicator = _showSelectionIndicator ? (isSelected ? "▶ " : "  ") : ""
            let nameColor = isSelected ? _selectedTextColor : baseTextColor
            let textX = x + 1 + (_showSelectionIndicator ? 2 : 0)

            if let font = _font {
                if !indicator.isEmpty {
                    draw(indicator, textX: x + 1, textY: itemY, color: nameColor)
                }
                _ = renderFontToFrameBuffer(
                    buffer,
                    options: RenderFontOptions(
                        text: option.name,
                        x: textX,
                        y: itemY,
                        color: nameColor,
                        backgroundColor: selectTransparent,
                        font: font
                    )
                )
            } else {
                draw("\(indicator)\(option.name)", textX: x + 1, textY: itemY, color: nameColor)
            }

            if _showDescription && itemY + fontHeight < y + drawHeight {
                let descColor = isSelected ? _selectedDescriptionColor : _descriptionColor
                draw(option.description, textX: textX, textY: itemY + fontHeight, color: descColor)
            }
        }

        if scrolls && indicatorY >= y && indicatorY < y + drawHeight {
            buffer.drawText("█", x: x + drawWidth - 1, y: indicatorY, fg: selectIndicatorColor, bg: selectTransparent)
        }
    }

    // MARK: - Selection & Navigation

    // parity: core/src/renderables/Select.ts#SelectRenderable.options [status=implemented hash=b4549b603299]
    public var options: [SelectOption] {
        get { _options }
        set {
            _options = newValue
            _selectedIndex = min(_selectedIndex, max(0, _options.count - 1))
            updateScrollOffset()
            requestRender()
        }
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.getSelectedOption [status=implemented hash=749978ef61ec]
    public func getSelectedOption() -> SelectOption? {
        guard _selectedIndex >= 0 && _selectedIndex < _options.count else { return nil }
        return _options[_selectedIndex]
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.getSelectedIndex [status=implemented hash=82d5ba22da55]
    public func getSelectedIndex() -> Int {
        _selectedIndex
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.moveUp [status=implemented hash=c2da926a3c67]
    public func moveUp(_ steps: Int = 1) {
        let newIndex = _selectedIndex - steps
        if newIndex >= 0 {
            _selectedIndex = newIndex
        } else if _wrapSelection && !_options.isEmpty {
            _selectedIndex = _options.count - 1
        } else {
            _selectedIndex = 0
        }
        updateScrollOffset()
        requestRender()
        emitSelectionChanged()
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.moveDown [status=implemented hash=f4a2f93ac05a]
    public func moveDown(_ steps: Int = 1) {
        let newIndex = _selectedIndex + steps
        if newIndex < _options.count {
            _selectedIndex = newIndex
        } else if _wrapSelection && !_options.isEmpty {
            _selectedIndex = 0
        } else {
            _selectedIndex = max(0, _options.count - 1)
        }
        updateScrollOffset()
        requestRender()
        emitSelectionChanged()
    }

    public func moveUpFast() {
        moveUp(_fastScrollStep)
    }

    public func moveDownFast() {
        moveDown(_fastScrollStep)
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.selectCurrent [status=implemented hash=7d5e5e6a66aa]
    public func selectCurrent() {
        if let selected = getSelectedOption() {
            emitItemSelected(selected)
        }
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.setSelectedIndex [status=implemented hash=a8d8a973038c]
    public func setSelectedIndex(_ index: Int) {
        guard index >= 0 && index < _options.count else { return }
        _selectedIndex = index
        updateScrollOffset()
        requestRender()
        emitSelectionChanged()
    }

    private func updateItemLayout() {
        let nameLines = _font != nil ? fontHeight : 1
        linesPerItem = max(1, nameLines + (_showDescription ? 1 : 0) + _itemSpacing)
        maxVisibleItems = max(1, height / linesPerItem)
    }

    private func updateScrollOffset() {
        let halfVisible = maxVisibleItems / 2
        let newScrollOffset = max(0, min(_selectedIndex - halfVisible, _options.count - maxVisibleItems))
        if newScrollOffset != scrollOffset {
            scrollOffset = newScrollOffset
            requestRender()
        }
    }

    open override func onResize(width: Int, height: Int) {
        maxVisibleItems = max(1, height / max(1, linesPerItem))
        updateScrollOffset()
        requestRender()
        super.onResize(width: width, height: height)
    }

    // MARK: - Keyboard & Mouse Handling

    // parity: core/src/renderables/Select.ts#SelectRenderable.handleKeyPress [status=implemented hash=f699bd71e37c]
    @discardableResult
    open override func handleKeyPress(_ key: KeyEvent) -> Bool {
        if let action = getKeyBindingAction(_keyBindingsMap, key) {
            switch action {
            case .moveUp:
                moveUp(1)
                return true
            case .moveDown:
                moveDown(1)
                return true
            case .moveUpFast:
                moveUp(_fastScrollStep)
                return true
            case .moveDownFast:
                moveDown(_fastScrollStep)
                return true
            case .selectCurrent:
                selectCurrent()
                return true
            }
        }
        return false
    }

    open override func onMouseEvent(_ event: MouseEvent) {
        if event.type == .down && event.button == MouseButton.left.rawValue {
            let localY = event.y - screenY
            guard localY >= 0 && localY < height else { return }
            let slot = localY / max(1, linesPerItem)
            let lineOffsetInSlot = localY % max(1, linesPerItem)
            let itemHeight = max(1, linesPerItem - _itemSpacing)
            guard slot >= 0 && slot < maxVisibleItems && lineOffsetInSlot < itemHeight else { return }
            let itemIndex = scrollOffset + slot
            guard itemIndex >= 0 && itemIndex < _options.count else { return }
            if itemIndex != _selectedIndex {
                setSelectedIndex(itemIndex)
            } else {
                selectCurrent()
            }
        } else if event.type == .scroll, let scroll = event.scroll {
            _ = scrollOnce(event: event.scrollChainToken, scroller: self) {
                let dir = wheelDirection(
                    direction: scrollDirectionToWheelDirection(scroll.direction),
                    shift: event.modifiers.shift
                )
                let before = self._selectedIndex
                let step = max(1, scroll.delta)
                if dir == .up {
                    self.moveUp(step)
                } else if dir == .down {
                    self.moveDown(step)
                }
                return self._selectedIndex != before
            }
        }
    }

    // MARK: - Configuration Properties

    // parity: core/src/renderables/Select.ts#SelectRenderable.showScrollIndicator [status=implemented hash=83f8e94c571c]
    public var showScrollIndicator: Bool {
        get { _showScrollIndicator }
        set {
            _showScrollIndicator = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.showDescription [status=implemented hash=dd8a3f13187a]
    public var showDescription: Bool {
        get { _showDescription }
        set {
            if _showDescription != newValue {
                _showDescription = newValue
                updateItemLayout()
                updateScrollOffset()
                requestRender()
            }
        }
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.showSelectionIndicator [status=implemented hash=87e66d3cd3e8]
    public var showSelectionIndicator: Bool {
        get { _showSelectionIndicator }
        set {
            if _showSelectionIndicator != newValue {
                _showSelectionIndicator = newValue
                requestRender()
            }
        }
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.wrapSelection [status=implemented hash=eb0e664b81fb]
    public var wrapSelection: Bool {
        get { _wrapSelection }
        set { _wrapSelection = newValue }
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.backgroundColor [status=implemented hash=a04686f20402]
    public var backgroundColor: RGBA {
        get { RGBA.clone(_backgroundColor) }
        set {
            _backgroundColor = RGBA.clone(newValue)
            requestRender()
        }
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.textColor [status=implemented hash=b46a17b19a79]
    public var textColor: RGBA {
        get { RGBA.clone(_textColor) }
        set {
            _textColor = RGBA.clone(newValue)
            requestRender()
        }
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.focusedBackgroundColor [status=implemented hash=4ac2724dd415]
    public var focusedBackgroundColor: RGBA {
        get { RGBA.clone(_focusedBackgroundColor) }
        set {
            _focusedBackgroundColor = RGBA.clone(newValue)
            requestRender()
        }
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.focusedTextColor [status=implemented hash=1ac36a8ab54b]
    public var focusedTextColor: RGBA {
        get { RGBA.clone(_focusedTextColor) }
        set {
            _focusedTextColor = RGBA.clone(newValue)
            requestRender()
        }
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.selectedBackgroundColor [status=implemented hash=cbc901aecd17]
    public var selectedBackgroundColor: RGBA {
        get { RGBA.clone(_selectedBackgroundColor) }
        set {
            _selectedBackgroundColor = RGBA.clone(newValue)
            requestRender()
        }
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.selectedTextColor [status=implemented hash=cb831a3bf486]
    public var selectedTextColor: RGBA {
        get { RGBA.clone(_selectedTextColor) }
        set {
            _selectedTextColor = RGBA.clone(newValue)
            requestRender()
        }
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.descriptionColor [status=implemented hash=54a989192b2c]
    public var descriptionColor: RGBA {
        get { RGBA.clone(_descriptionColor) }
        set {
            _descriptionColor = RGBA.clone(newValue)
            requestRender()
        }
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.selectedDescriptionColor [status=implemented hash=c23d39d99cad]
    public var selectedDescriptionColor: RGBA {
        get { RGBA.clone(_selectedDescriptionColor) }
        set {
            _selectedDescriptionColor = RGBA.clone(newValue)
            requestRender()
        }
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.font [status=implemented hash=11d561392cfb]
    public var font: ASCIIFontName? {
        get { _font }
        set {
            _font = newValue
            fontHeight = newValue.map { measureAsciiText("A", font: $0).height } ?? 1
            updateItemLayout()
            updateScrollOffset()
            requestRender()
        }
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.itemSpacing [status=implemented hash=86efbfa76836]
    public var itemSpacing: Int {
        get { _itemSpacing }
        set {
            _itemSpacing = max(0, newValue)
            updateItemLayout()
            updateScrollOffset()
            requestRender()
        }
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.fastScrollStep [status=implemented hash=75f01f1a283f]
    public var fastScrollStep: Int {
        get { _fastScrollStep }
        set { _fastScrollStep = max(1, newValue) }
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.keyBindings [status=implemented hash=41c59964c8b1]
    public var keyBindings: [SelectKeyBinding] {
        get { _keyBindings }
        set {
            _keyBindings = newValue
            let merged = mergeKeyBindings(defaultSelectKeybindings, _keyBindings)
            _keyBindingsMap = buildKeyBindingsMap(merged, aliasMap: _keyAliasMap)
        }
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.keyAliasMap [status=implemented hash=19f6179bfcaf]
    public var keyAliasMap: KeyAliasMap {
        get { _keyAliasMap }
        set {
            _keyAliasMap = mergeKeyAliases(defaultKeyAliases, newValue)
            let merged = mergeKeyBindings(defaultSelectKeybindings, _keyBindings)
            _keyBindingsMap = buildKeyBindingsMap(merged, aliasMap: _keyAliasMap)
        }
    }

    // parity: core/src/renderables/Select.ts#SelectRenderable.selectedIndex [status=implemented hash=57e48b57cc2b]
    public var selectedIndex: Int {
        get { _selectedIndex }
        set {
            let clamped = _options.isEmpty ? 0 : max(0, min(newValue, _options.count - 1))
            if _selectedIndex != clamped {
                _selectedIndex = clamped
                updateScrollOffset()
                requestRender()
            }
        }
    }

    open override func destroySelf() {
        _changeListeners.removeAll()
        _selectListeners.removeAll()
        super.destroySelf()
    }
}
