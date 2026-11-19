import OpenTUICore
import OpenTUILayout

// MARK: - TabSelect Types & Key Bindings

private let tabSelectTransparent = RGBA.fromValues(0, 0, 0, 0)
private let tabSelectArrowColor = parseColor("#AAAAAA")

// parity: core/src/renderables/TabSelect.ts#TabSelectOption [status=implemented hash=8343c6d22a6a]
public struct TabSelectOption: Sendable {
    public var name: String
    public var description: String
    public var value: (any Sendable)?

    public init(name: String, description: String = "", value: (any Sendable)? = nil) {
        self.name = name
        self.description = description
        self.value = value
    }
}

// parity: core/src/renderables/TabSelect.ts#TabSelectAction [status=implemented hash=1ca828bcec45]
public enum TabSelectAction: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case moveLeft = "move-left"
    case moveRight = "move-right"
    case selectCurrent = "select-current"
}

// parity: core/src/renderables/TabSelect.ts#TabSelectKeyBinding [status=implemented hash=f76ffe709a17]
public typealias TabSelectKeyBinding = KeyBinding<TabSelectAction>

public let defaultTabSelectKeybindings: [TabSelectKeyBinding] = [
    KeyBinding(name: "left", action: .moveLeft),
    KeyBinding(name: "[", action: .moveLeft),
    KeyBinding(name: "right", action: .moveRight),
    KeyBinding(name: "]", action: .moveRight),
    KeyBinding(name: "return", action: .selectCurrent),
    KeyBinding(name: "linefeed", action: .selectCurrent),
]

// parity: core/src/renderables/TabSelect.ts#TabSelectRenderableEvents [status=implemented hash=2c0cd2da9716]
public enum TabSelectRenderableEvents: String, Equatable, Hashable, Sendable {
    case selectionChanged = "selectionChanged"
    case itemSelected = "itemSelected"
}

private func calculateTabSelectDynamicHeight(showUnderline: Bool, showDescription: Bool) -> Int {
    var height = 1
    if showUnderline { height += 1 }
    if showDescription { height += 1 }
    return height
}

// MARK: - TabSelectRenderableOptions / TabSelectOptions

// parity: core/src/renderables/TabSelect.ts#TabSelectRenderableOptions [status=implemented hash=c443758b2868]
public struct TabSelectRenderableOptions {
    public var renderable: RenderableOptions
    public var height: Int?
    public var options: [TabSelectOption]?
    public var selectedIndex: Int?
    public var tabWidth: Int?
    public var backgroundColor: Color?
    public var textColor: Color?
    public var focusedBackgroundColor: Color?
    public var focusedTextColor: Color?
    public var selectedBackgroundColor: Color?
    public var selectedTextColor: Color?
    public var selectedDescriptionColor: Color?
    public var showScrollArrows: Bool?
    public var showDescription: Bool?
    public var showUnderline: Bool?
    public var wrapSelection: Bool?
    public var keyBindings: [TabSelectKeyBinding]?
    public var keyAliasMap: KeyAliasMap?
    public var onChange: ((Int, TabSelectOption?) -> Void)?
    public var onSelect: ((Int, TabSelectOption) -> Void)?

    public init(
        id: String? = nil,
        width: FlexValue? = nil,
        height: Int? = nil,
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
        options: [TabSelectOption]? = nil,
        selectedIndex: Int? = nil,
        tabWidth: Int? = nil,
        backgroundColor: Color? = nil,
        textColor: Color? = nil,
        focusedBackgroundColor: Color? = nil,
        focusedTextColor: Color? = nil,
        selectedBackgroundColor: Color? = nil,
        selectedTextColor: Color? = nil,
        selectedDescriptionColor: Color? = nil,
        showScrollArrows: Bool? = nil,
        showDescription: Bool? = nil,
        showUnderline: Bool? = nil,
        wrapSelection: Bool? = nil,
        keyBindings: [TabSelectKeyBinding]? = nil,
        keyAliasMap: KeyAliasMap? = nil,
        onChange: ((Int, TabSelectOption?) -> Void)? = nil,
        onSelect: ((Int, TabSelectOption) -> Void)? = nil,
        onKeyDown: ((KeyEvent) -> Void)? = nil,
        onMouse: ((MouseEvent) -> Void)? = nil
    ) {
        self.renderable = RenderableOptions(
            id: id,
            width: width,
            height: height.map { .point(Float($0)) },
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
        self.height = height
        self.options = options
        self.selectedIndex = selectedIndex
        self.tabWidth = tabWidth
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.focusedBackgroundColor = focusedBackgroundColor
        self.focusedTextColor = focusedTextColor
        self.selectedBackgroundColor = selectedBackgroundColor
        self.selectedTextColor = selectedTextColor
        self.selectedDescriptionColor = selectedDescriptionColor
        self.showScrollArrows = showScrollArrows
        self.showDescription = showDescription
        self.showUnderline = showUnderline
        self.wrapSelection = wrapSelection
        self.keyBindings = keyBindings
        self.keyAliasMap = keyAliasMap
        self.onChange = onChange
        self.onSelect = onSelect
    }
}

/// Alias matching `TabSelectOptions` naming.
public typealias TabSelectOptions = TabSelectRenderableOptions

// MARK: - TabSelectRenderable

/// Horizontal tab bar selection renderable with dynamic height, active underline,
/// description row, horizontal scroll windowing, scroll arrows, keyboard navigation, and mouse click/wheel support.
// parity: core/src/renderables/TabSelect.ts#TabSelectRenderable [status=implemented hash=38902b658497]
open class TabSelectRenderable: Renderable, @unchecked Sendable {
    public static let defaultBackgroundColor: Color = "transparent"
    public static let defaultTextColor: Color = "#FFFFFF"
    public static let defaultFocusedBackgroundColor: Color = "#1a1a1a"
    public static let defaultSelectedBackgroundColor: Color = "#334455"
    public static let defaultSelectedTextColor: Color = "#FFFF00"
    public static let defaultSelectedDescriptionColor: Color = "#CCCCCC"
    public static let defaultTabWidth: Int = 20

    private var _options: [TabSelectOption] = []
    private var _selectedIndex: Int = 0
    private var scrollOffset: Int = 0
    private var _tabWidth: Int
    private var maxVisibleTabs: Int = 1

    private var _backgroundColor: RGBA
    private var _hasBackgroundColor: Bool
    private var _textColor: RGBA
    private var _focusedBackgroundColor: RGBA
    private var _focusedTextColor: RGBA
    private var _selectedBackgroundColor: RGBA
    private var _selectedTextColor: RGBA
    private var _selectedDescriptionColor: RGBA
    private var _showScrollArrows: Bool
    private var _showDescription: Bool
    private var _showUnderline: Bool
    private var _wrapSelection: Bool
    private var _keyBindingsMap: [String: TabSelectAction] = [:]
    private var _keyAliasMap: KeyAliasMap
    private var _keyBindings: [TabSelectKeyBinding]

    public var onChange: ((Int, TabSelectOption?) -> Void)?
    public var onSelect: ((Int, TabSelectOption) -> Void)?

    private var _changeListeners: [(id: UInt64, fn: (Int, TabSelectOption?) -> Void)] = []
    private var _selectListeners: [(id: UInt64, fn: (Int, TabSelectOption) -> Void)] = []
    private var _nextTypedListenerId: UInt64 = 1

    public init(ctx: any RenderContext, options: TabSelectRenderableOptions = TabSelectRenderableOptions()) {
        let showUnderline = options.showUnderline ?? true
        let showDescription = options.showDescription ?? true
        let calculatedHeight = calculateTabSelectDynamicHeight(
            showUnderline: showUnderline,
            showDescription: showDescription
        )

        var renderableOpts = options.renderable
        if renderableOpts.focusable == nil {
            renderableOpts.focusable = true
        }
        renderableOpts.height = .point(Float(calculatedHeight))

        let bgColor = RGBA.clone((options.backgroundColor ?? Self.defaultBackgroundColor).resolved())
        let textColor = RGBA.clone((options.textColor ?? Self.defaultTextColor).resolved())
        let focusedBg = RGBA.clone(
            (options.focusedBackgroundColor ?? options.backgroundColor ?? Self.defaultFocusedBackgroundColor).resolved()
        )
        let focusedText = RGBA.clone((options.focusedTextColor?.resolved()) ?? textColor)

        self._backgroundColor = bgColor
        self._hasBackgroundColor = options.backgroundColor != nil
        self._textColor = textColor
        self._focusedBackgroundColor = focusedBg
        self._focusedTextColor = focusedText

        let initialOptions = options.options ?? []
        self._options = initialOptions
        let requestedIndex = options.selectedIndex ?? 0
        self._selectedIndex = initialOptions.isEmpty
            ? 0
            : max(0, min(requestedIndex, initialOptions.count - 1))

        self._tabWidth = max(1, options.tabWidth ?? Self.defaultTabWidth)
        self._showDescription = showDescription
        self._showUnderline = showUnderline
        self._showScrollArrows = options.showScrollArrows ?? true
        self._wrapSelection = options.wrapSelection ?? false

        self._selectedBackgroundColor = RGBA.clone((options.selectedBackgroundColor ?? Self.defaultSelectedBackgroundColor).resolved())
        self._selectedTextColor = RGBA.clone((options.selectedTextColor ?? Self.defaultSelectedTextColor).resolved())
        self._selectedDescriptionColor = RGBA.clone((options.selectedDescriptionColor ?? Self.defaultSelectedDescriptionColor).resolved())

        self._keyAliasMap = mergeKeyAliases(defaultKeyAliases, options.keyAliasMap ?? [:])
        self._keyBindings = options.keyBindings ?? []
        let merged = mergeKeyBindings(defaultTabSelectKeybindings, self._keyBindings)
        self._keyBindingsMap = buildKeyBindingsMap(merged, aliasMap: self._keyAliasMap)

        self.onChange = options.onChange
        self.onSelect = options.onSelect

        super.init(ctx: ctx, options: renderableOpts)

        self.maxVisibleTabs = max(1, self.width / self._tabWidth)
        updateScrollOffset()
    }

    // MARK: - Typed Event Subscriptions

    @discardableResult
    public func onSelectionChanged(_ listener: @escaping (Int, TabSelectOption?) -> Void) -> UInt64 {
        let id = _nextTypedListenerId
        _nextTypedListenerId &+= 1
        _changeListeners.append((id: id, fn: listener))
        return id
    }

    @discardableResult
    public func onItemSelected(_ listener: @escaping (Int, TabSelectOption) -> Void) -> UInt64 {
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
        emit(TabSelectRenderableEvents.selectionChanged.rawValue)
    }

    private func emitItemSelected(_ option: TabSelectOption) {
        onSelect?(_selectedIndex, option)
        for entry in _selectListeners {
            entry.fn(_selectedIndex, option)
        }
        emit(TabSelectRenderableEvents.itemSelected.rawValue)
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
        let selectedX = (_selectedIndex - scrollOffset) * _tabWidth
        let selectedWidth = min(_tabWidth, drawWidth - selectedX)
        let selectedRows = (_showUnderline && drawHeight >= 2) ? 2 : 1
        let hasOpaqueSelection = _selectedBackgroundColor.toInts().3 == 255
        let hole = !_options.isEmpty && selectedX >= 0 && selectedX < drawWidth && selectedWidth > 0 && hasOpaqueSelection
        let rows = hole ? selectedRows : 0

        if let fb = frameBuffer, buffer === fb {
            buffer.clear(bg: bgColor)
        } else {
            if rows > 0 {
                if selectedX > 0 {
                    buffer.fillRect(x: x, y: y, width: selectedX, height: rows, bg: bgColor)
                }
                let rightWidth = drawWidth - selectedX - selectedWidth
                if rightWidth > 0 {
                    buffer.fillRect(x: x + selectedX + selectedWidth, y: y, width: rightWidth, height: rows, bg: bgColor)
                }
            }
            if drawHeight - rows > 0 {
                buffer.fillRect(x: x, y: y + rows, width: drawWidth, height: drawHeight - rows, bg: bgColor)
            }
        }

        let startIdx = max(0, min(scrollOffset, _options.count))
        let endIdx = max(startIdx, min(startIdx + maxVisibleTabs, _options.count))
        let baseTextColor = _focused ? _focusedTextColor : _textColor

        for i in 0..<(endIdx - startIdx) {
            let optionIndex = startIdx + i
            let option = _options[optionIndex]
            let isSelected = optionIndex == _selectedIndex
            let tabX = x + i * _tabWidth

            if tabX >= x + drawWidth { break }

            let actualTabWidth = min(_tabWidth, drawWidth - i * _tabWidth)
            guard actualTabWidth > 0 else { break }
            let nameColor = isSelected ? _selectedTextColor : baseTextColor

            if isSelected {
                buffer.fillRect(x: tabX, y: y, width: actualTabWidth, height: selectedRows, bg: _selectedBackgroundColor)
            }
            if actualTabWidth > 2 {
                buffer.drawTextFit(
                    option.name,
                    x: tabX + 1,
                    y: y,
                    maxWidth: actualTabWidth - 2,
                    fg: nameColor,
                    bg: tabSelectTransparent,
                    ellipsis: true
                )
            }
            if isSelected && selectedRows == 2 {
                buffer.drawText(
                    String(repeating: "▬", count: actualTabWidth),
                    x: tabX,
                    y: y + 1,
                    fg: nameColor,
                    bg: tabSelectTransparent
                )
            }
        }

        if let selectedOption = getSelectedOption(),
           _showDescription,
           drawHeight >= (_showUnderline ? 3 : 2)
        {
            let descriptionY = y + (_showUnderline ? 2 : 1)
            if drawWidth > 2 {
                buffer.drawTextFit(
                    selectedOption.description,
                    x: x + 1,
                    y: descriptionY,
                    maxWidth: drawWidth - 2,
                    fg: _selectedDescriptionColor,
                    bg: tabSelectTransparent,
                    ellipsis: true
                )
            }
        }

        if _showScrollArrows && _options.count > maxVisibleTabs {
            if scrollOffset > 0 {
                buffer.drawText("‹", x: x, y: y, fg: tabSelectArrowColor, bg: tabSelectTransparent)
            }
            if scrollOffset + maxVisibleTabs < _options.count {
                buffer.drawText("›", x: x + drawWidth - 1, y: y, fg: tabSelectArrowColor, bg: tabSelectTransparent)
            }
        }
    }

    // MARK: - Selection & Navigation

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.setOptions [status=implemented hash=9a99f417036e]
    public func setOptions(_ options: [TabSelectOption]) {
        _options = options
        _selectedIndex = min(_selectedIndex, max(0, options.count - 1))
        updateScrollOffset()
        requestRender()
    }

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.getSelectedOption [status=implemented hash=f7d7ff34d43b]
    public func getSelectedOption() -> TabSelectOption? {
        guard _selectedIndex >= 0 && _selectedIndex < _options.count else { return nil }
        return _options[_selectedIndex]
    }

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.getSelectedIndex [status=implemented hash=01a8552582cc]
    public func getSelectedIndex() -> Int {
        _selectedIndex
    }

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

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.moveLeft [status=implemented hash=c2f20c08ae32]
    public func moveLeft() {
        if _selectedIndex > 0 {
            _selectedIndex -= 1
        } else if _wrapSelection && !_options.isEmpty {
            _selectedIndex = _options.count - 1
        } else {
            return
        }
        updateScrollOffset()
        requestRender()
        emitSelectionChanged()
    }

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.moveRight [status=implemented hash=d1613c3735aa]
    public func moveRight() {
        if _selectedIndex < _options.count - 1 {
            _selectedIndex += 1
        } else if _wrapSelection && !_options.isEmpty {
            _selectedIndex = 0
        } else {
            return
        }
        updateScrollOffset()
        requestRender()
        emitSelectionChanged()
    }

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.selectCurrent [status=implemented hash=3da285455f31]
    public func selectCurrent() {
        if let selected = getSelectedOption() {
            emitItemSelected(selected)
        }
    }

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.setSelectedIndex [status=implemented hash=f62a50718f73]
    public func setSelectedIndex(_ index: Int) {
        guard index >= 0 && index < _options.count else { return }
        _selectedIndex = index
        updateScrollOffset()
        requestRender()
        emitSelectionChanged()
    }

    private func updateScrollOffset() {
        let halfVisible = maxVisibleTabs / 2
        let newScrollOffset = max(0, min(_selectedIndex - halfVisible, _options.count - maxVisibleTabs))
        if newScrollOffset != scrollOffset {
            scrollOffset = newScrollOffset
            requestRender()
        }
    }

    open override func onResize(width: Int, height: Int) {
        maxVisibleTabs = max(1, width / max(1, _tabWidth))
        updateScrollOffset()
        requestRender()
        super.onResize(width: width, height: height)
    }

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.setTabWidth [status=implemented hash=08e9545d20f2]
    public func setTabWidth(_ tabWidth: Int) {
        let clamped = max(1, tabWidth)
        guard _tabWidth != clamped else { return }
        _tabWidth = clamped
        maxVisibleTabs = max(1, width / _tabWidth)
        updateScrollOffset()
        requestRender()
    }

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.getTabWidth [status=implemented hash=23c0eb8176b5]
    public func getTabWidth() -> Int {
        _tabWidth
    }

    // MARK: - Keyboard & Mouse Handling

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.handleKeyPress [status=implemented hash=0c85adc5e00e]
    @discardableResult
    open override func handleKeyPress(_ key: KeyEvent) -> Bool {
        if let action = getKeyBindingAction(_keyBindingsMap, key) {
            switch action {
            case .moveLeft:
                moveLeft()
                return true
            case .moveRight:
                moveRight()
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
            let localX = event.x - screenX
            let localY = event.y - screenY
            let tabRows = (_showUnderline && height >= 2) ? 2 : 1
            guard localX >= 0 && localX < width && localY >= 0 && localY < tabRows else { return }

            if _showScrollArrows && _options.count > maxVisibleTabs && localY == 0 {
                if localX == 0 && scrollOffset > 0 {
                    moveLeft()
                    return
                }
                if localX == width - 1 && scrollOffset + maxVisibleTabs < _options.count {
                    moveRight()
                    return
                }
            }

            let slot = localX / max(1, _tabWidth)
            guard slot >= 0 && slot < maxVisibleTabs else { return }
            let tabIndex = scrollOffset + slot
            guard tabIndex >= 0 && tabIndex < _options.count else { return }

            if tabIndex != _selectedIndex {
                setSelectedIndex(tabIndex)
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
                if dir == .left || dir == .up {
                    self.moveLeft()
                } else if dir == .right || dir == .down {
                    self.moveRight()
                }
                return self._selectedIndex != before
            }
        }
    }

    // MARK: - Properties

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.options [status=implemented hash=dab52ff953de]
    public var options: [TabSelectOption] {
        get { _options }
        set { setOptions(newValue) }
    }

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.backgroundColor [status=implemented hash=9fb4dc45e2a8]
    public var backgroundColor: RGBA {
        get { RGBA.clone(_backgroundColor) }
        set {
            _backgroundColor = RGBA.clone(newValue)
            _hasBackgroundColor = true
            requestRender()
        }
    }

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.textColor [status=implemented hash=532306bc514f]
    public var textColor: RGBA {
        get { RGBA.clone(_textColor) }
        set {
            _textColor = RGBA.clone(newValue)
            requestRender()
        }
    }

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.focusedBackgroundColor [status=implemented hash=69d31f56c0e5]
    public var focusedBackgroundColor: RGBA {
        get { RGBA.clone(_focusedBackgroundColor) }
        set {
            _focusedBackgroundColor = RGBA.clone(newValue)
            requestRender()
        }
    }

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.focusedTextColor [status=implemented hash=79201935c67b]
    public var focusedTextColor: RGBA {
        get { RGBA.clone(_focusedTextColor) }
        set {
            _focusedTextColor = RGBA.clone(newValue)
            requestRender()
        }
    }

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.selectedBackgroundColor [status=implemented hash=7f33d350315a]
    public var selectedBackgroundColor: RGBA {
        get { RGBA.clone(_selectedBackgroundColor) }
        set {
            _selectedBackgroundColor = RGBA.clone(newValue)
            requestRender()
        }
    }

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.selectedTextColor [status=implemented hash=5a35dbf4da6f]
    public var selectedTextColor: RGBA {
        get { RGBA.clone(_selectedTextColor) }
        set {
            _selectedTextColor = RGBA.clone(newValue)
            requestRender()
        }
    }

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.selectedDescriptionColor [status=implemented hash=dcbc1ca5ad93]
    public var selectedDescriptionColor: RGBA {
        get { RGBA.clone(_selectedDescriptionColor) }
        set {
            _selectedDescriptionColor = RGBA.clone(newValue)
            requestRender()
        }
    }

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.showDescription [status=implemented hash=dd8a3f13187a]
    public var showDescription: Bool {
        get { _showDescription }
        set {
            if _showDescription != newValue {
                _showDescription = newValue
                let newHeight = calculateTabSelectDynamicHeight(
                    showUnderline: _showUnderline,
                    showDescription: _showDescription
                )
                height = newHeight
                requestRender()
            }
        }
    }

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.showUnderline [status=implemented hash=68df97f827b8]
    public var showUnderline: Bool {
        get { _showUnderline }
        set {
            if _showUnderline != newValue {
                _showUnderline = newValue
                let newHeight = calculateTabSelectDynamicHeight(
                    showUnderline: _showUnderline,
                    showDescription: _showDescription
                )
                height = newHeight
                requestRender()
            }
        }
    }

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.showScrollArrows [status=implemented hash=0ff43a09e66c]
    public var showScrollArrows: Bool {
        get { _showScrollArrows }
        set {
            if _showScrollArrows != newValue {
                _showScrollArrows = newValue
                requestRender()
            }
        }
    }

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.wrapSelection [status=implemented hash=eb0e664b81fb]
    public var wrapSelection: Bool {
        get { _wrapSelection }
        set { _wrapSelection = newValue }
    }

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.tabWidth [status=implemented hash=de4454f1a84b]
    public var tabWidth: Int {
        get { _tabWidth }
        set { setTabWidth(newValue) }
    }

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.keyBindings [status=implemented hash=5852b20a13d5]
    public var keyBindings: [TabSelectKeyBinding] {
        get { _keyBindings }
        set {
            _keyBindings = newValue
            let merged = mergeKeyBindings(defaultTabSelectKeybindings, _keyBindings)
            _keyBindingsMap = buildKeyBindingsMap(merged, aliasMap: _keyAliasMap)
        }
    }

    // parity: core/src/renderables/TabSelect.ts#TabSelectRenderable.keyAliasMap [status=implemented hash=f3071aba468d]
    public var keyAliasMap: KeyAliasMap {
        get { _keyAliasMap }
        set {
            _keyAliasMap = mergeKeyAliases(defaultKeyAliases, newValue)
            let merged = mergeKeyBindings(defaultTabSelectKeybindings, _keyBindings)
            _keyBindingsMap = buildKeyBindingsMap(merged, aliasMap: _keyAliasMap)
        }
    }

    open override func destroySelf() {
        _changeListeners.removeAll()
        _selectListeners.removeAll()
        super.destroySelf()
    }
}
