import OpenTUICore
import OpenTUILayout

// MARK: - Input Types & Events

// parity: core/src/renderables/Input.ts#InputAction [status=implemented hash=d833e38c92d4]
public typealias InputAction = TextareaAction

// parity: core/src/renderables/Input.ts#InputKeyBinding [status=implemented hash=1779a3935989]
public typealias InputKeyBinding = TextareaKeyBinding

// parity: core/src/renderables/Input.ts#InputRenderableEvents [status=implemented hash=4dfcda6f51fa]
public enum InputRenderableEvents: String, Equatable, Hashable, Sendable {
    case input = "input"
    case change = "change"
    case enter = "enter"
}

/// Direction for `InputRenderable.deleteCharacter(_:)`.
public enum InputDeleteDirection: String, Equatable, Hashable, Sendable {
    case backward
    case forward
}

// MARK: - InputOptions / InputRenderableOptions

// parity: core/src/renderables/Input.ts#InputRenderableOptions [status=implemented hash=429656026645]
public struct InputRenderableOptions {
    public var renderable: RenderableOptions
    /// Initial text value (newlines are stripped).
    public var value: String?
    /// Minimum length in UTF-16 code units required for submit.
    public var minLength: Int?
    /// Maximum length in UTF-16 code units.
    public var maxLength: Int?
    /// Placeholder text.
    public var placeholder: String?
    public var placeholderColor: Color?
    public var backgroundColor: Color?
    public var textColor: Color?
    public var focusedBackgroundColor: Color?
    public var focusedTextColor: Color?
    public var selectionBg: Color?
    public var selectionFg: Color?
    public var selectable: Bool?
    public var attributes: UInt32?
    public var scrollMargin: Double?
    public var scrollSpeed: Double?
    public var showCursor: Bool?
    public var cursorColor: Color?
    public var cursorStyle: CursorStyleOptions?
    public var selectionOccupancy: SelectionOccupancy?
    public var syntaxStyle: SyntaxStyle?
    public var tabIndicator: TabIndicatorValue?
    public var tabIndicatorColor: Color?
    public var keyBindings: [InputKeyBinding]?
    public var keyAliasMap: TextareaKeyAliasMap?
    public var onInput: ((String) -> Void)?
    public var onChange: ((String) -> Void)?
    public var onSubmit: ((String) -> Void)?
    public var onCursorChange: ((CursorChangeEvent) -> Void)?
    public var onContentChange: ((ContentChangeEvent) -> Void)?

    public init(
        id: String? = nil,
        width: FlexValue? = nil,
        minWidth: FlexValue? = nil,
        maxWidth: FlexValue? = nil,
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
        value: String? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        placeholder: String? = nil,
        placeholderColor: Color? = nil,
        backgroundColor: Color? = nil,
        textColor: Color? = nil,
        focusedBackgroundColor: Color? = nil,
        focusedTextColor: Color? = nil,
        selectionBg: Color? = nil,
        selectionFg: Color? = nil,
        selectable: Bool? = nil,
        attributes: UInt32? = nil,
        scrollMargin: Double? = nil,
        scrollSpeed: Double? = nil,
        showCursor: Bool? = nil,
        cursorColor: Color? = nil,
        cursorStyle: CursorStyleOptions? = nil,
        selectionOccupancy: SelectionOccupancy? = nil,
        syntaxStyle: SyntaxStyle? = nil,
        tabIndicator: TabIndicatorValue? = nil,
        tabIndicatorColor: Color? = nil,
        keyBindings: [InputKeyBinding]? = nil,
        keyAliasMap: TextareaKeyAliasMap? = nil,
        onInput: ((String) -> Void)? = nil,
        onChange: ((String) -> Void)? = nil,
        onSubmit: ((String) -> Void)? = nil,
        onCursorChange: ((CursorChangeEvent) -> Void)? = nil,
        onContentChange: ((ContentChangeEvent) -> Void)? = nil,
        onKeyDown: ((KeyEvent) -> Void)? = nil,
        onPaste: ((PasteEvent) -> Void)? = nil
    ) {
        self.renderable = RenderableOptions(
            id: id,
            width: width,
            height: .point(1),
            minWidth: minWidth,
            maxWidth: maxWidth,
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
            selectable: selectable,
            buffered: buffered,
            onKeyDown: onKeyDown,
            onPaste: onPaste
        )
        self.value = value
        self.minLength = minLength
        self.maxLength = maxLength
        self.placeholder = placeholder
        self.placeholderColor = placeholderColor
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.focusedBackgroundColor = focusedBackgroundColor
        self.focusedTextColor = focusedTextColor
        self.selectionBg = selectionBg
        self.selectionFg = selectionFg
        self.selectable = selectable
        self.attributes = attributes
        self.scrollMargin = scrollMargin
        self.scrollSpeed = scrollSpeed
        self.showCursor = showCursor
        self.cursorColor = cursorColor
        self.cursorStyle = cursorStyle
        self.selectionOccupancy = selectionOccupancy
        self.syntaxStyle = syntaxStyle
        self.tabIndicator = tabIndicator
        self.tabIndicatorColor = tabIndicatorColor
        self.keyBindings = keyBindings
        self.keyAliasMap = keyAliasMap
        self.onInput = onInput
        self.onChange = onChange
        self.onSubmit = onSubmit
        self.onCursorChange = onCursorChange
        self.onContentChange = onContentChange
    }
}

/// Alias matching `InputOptions` naming.
public typealias InputOptions = InputRenderableOptions

// MARK: - InputRenderable

/// Single-line text input renderable extending `TextareaRenderable`:
/// - Height is fixed to 1 row with `.none` wrapping.
/// - Newlines (`\n`, `\r`) are stripped before `maxLength` truncation.
/// - `maxLength` and `minLength` count UTF-16 code units without ever splitting characters/surrogate pairs/clusters.
/// - Enter/Return/Linefeed triggers `submit()` instead of inserting a newline.
// parity: core/src/renderables/Input.ts#InputRenderable [status=implemented hash=10f30e92cf75]
open class InputRenderable: TextareaRenderable, @unchecked Sendable {
    public static let defaultPlaceholder: String = ""
    public static let defaultMaxLength: Int = 1000
    public static let defaultMinLength: Int = 0

    private static let inputSubmitOverrides: [InputKeyBinding] = [
        KeyBinding(name: "return", action: .submit),
        KeyBinding(name: "kpenter", action: .submit),
        KeyBinding(name: "linefeed", action: .submit),
    ]

    private var _maxLength: Int
    private var _minLength: Int
    private var _lastCommittedValue: String = ""

    public var onInput: ((String) -> Void)?
    public var onChange: ((String) -> Void)?
    public var onEnter: ((String) -> Void)?

    private var _valueListeners: [InputRenderableEvents: [(id: UInt64, fn: (String) -> Void)]] = [:]
    private var _nextValueListenerId: UInt64 = 1

    open override var baseKeyBindings: [TextareaKeyBinding] {
        mergeKeyBindings(defaultTextareaKeyBindings, Self.inputSubmitOverrides)
    }

    public init(ctx: any RenderContext, options: InputRenderableOptions = InputRenderableOptions()) {
        let clampedMax = max(0, options.maxLength ?? Self.defaultMaxLength)
        let clampedMin = max(0, options.minLength ?? Self.defaultMinLength)
        precondition(
            clampedMin <= clampedMax,
            "InputRenderable: minLength (\(clampedMin)) cannot be greater than maxLength (\(clampedMax))"
        )

        let rawValue = options.value ?? ""
        let initialValue = fitUTF16(stripInputNewlines(rawValue), maxLength: clampedMax)

        var renderableOpts = options.renderable
        renderableOpts.height = .point(1)

        let ebOptions = EditBufferOptions(
            renderable: renderableOpts,
            textColor: options.textColor,
            backgroundColor: options.backgroundColor,
            focusedTextColor: options.focusedTextColor,
            focusedBackgroundColor: options.focusedBackgroundColor,
            selectionBg: options.selectionBg,
            selectionFg: options.selectionFg,
            selectable: options.selectable,
            attributes: options.attributes,
            wrapMode: TextWrapMode.none,
            scrollMargin: options.scrollMargin,
            scrollSpeed: options.scrollSpeed,
            showCursor: options.showCursor,
            cursorColor: options.cursorColor,
            cursorStyle: options.cursorStyle,
            selectionOccupancy: options.selectionOccupancy,
            syntaxStyle: options.syntaxStyle,
            tabIndicator: options.tabIndicator,
            tabIndicatorColor: options.tabIndicatorColor,
            onCursorChange: options.onCursorChange,
            onContentChange: options.onContentChange
        )

        let textareaOptions = TextareaOptions(
            editBuffer: ebOptions,
            initialValue: initialValue,
            focusedBackgroundColor: options.focusedBackgroundColor,
            focusedTextColor: options.focusedTextColor,
            placeholder: .text(options.placeholder ?? Self.defaultPlaceholder),
            placeholderColor: options.placeholderColor,
            keyBindings: options.keyBindings,
            keyAliasMap: options.keyAliasMap,
            onSubmit: nil
        )

        self._maxLength = clampedMax
        self._minLength = clampedMin
        self.onInput = options.onInput
        self.onChange = options.onChange
        self.onEnter = options.onSubmit

        super.init(ctx: ctx, options: textareaOptions)

        self._lastCommittedValue = self.plainText
        if !initialValue.isEmpty {
            self.cursorOffset = self.editBuffer.getEOL().offset
        }
    }

    // MARK: - Typed Event Subscriptions

    @discardableResult
    public func on(_ event: InputRenderableEvents, _ listener: @escaping (String) -> Void) -> UInt64 {
        let id = _nextValueListenerId
        _nextValueListenerId &+= 1
        _valueListeners[event, default: []].append((id: id, fn: listener))
        return id
    }

    public func off(_ event: InputRenderableEvents, id: UInt64) {
        _valueListeners[event]?.removeAll { $0.id == id }
    }

    private func emitInputEvent(_ event: InputRenderableEvents, value: String) {
        switch event {
        case .input:
            onInput?(value)
        case .change:
            onChange?(value)
        case .enter:
            onEnter?(value)
        }
        if let entries = _valueListeners[event] {
            for entry in entries {
                entry.fn(value)
            }
        }
        emit(event.rawValue)
    }

    // MARK: - Single-Line Editing Overrides

    @discardableResult
    open override func newLine() -> Bool {
        false
    }

    open override func insertChar(_ char: String) {
        insertText(char)
    }

    open override func insertText(_ text: String) {
        let sanitized = stripInputNewlines(text)
        guard !sanitized.isEmpty else { return }

        // The insert replaces any active selection, freeing its UTF-16 length.
        let room = _maxLength - plainText.utf16.count + getSelectedText().utf16.count
        let toInsert = fitUTF16(sanitized, maxLength: room)
        guard !toInsert.isEmpty else { return }

        super.insertText(toInsert)
        emitInputEvent(.input, value: plainText)
    }

    // MARK: - Value, Length Limits & Placeholder

    /// Single-line text value (measured in UTF-16 code units for `maxLength` / `minLength`).
    // parity: core/src/renderables/Input.ts#InputRenderable.value [status=implemented hash=fe89ee09e2b1]
    public var value: String {
        get { plainText }
        set {
            let newValue = fitUTF16(stripInputNewlines(newValue), maxLength: _maxLength)
            if plainText != newValue {
                setText(newValue)
                cursorOffset = editBuffer.getEOL().offset
                emitInputEvent(.input, value: newValue)
            }
        }
    }

    /// Maximum input length in UTF-16 code units.
    // parity: core/src/renderables/Input.ts#InputRenderable.maxLength [status=implemented hash=5117a96fb9ac]
    public var maxLength: Int {
        get { _maxLength }
        set {
            let clamped = max(0, newValue)
            let current = plainText
            if current.utf16.count > clamped {
                setText(fitUTF16(current, maxLength: clamped))
            }
            _maxLength = clamped
        }
    }

    /// Minimum length required for submission in UTF-16 code units.
    // parity: core/src/renderables/Input.ts#InputRenderable.minLength [status=implemented hash=210f8907b778]
    public var minLength: Int {
        get { _minLength }
        set {
            let clamped = max(0, newValue)
            precondition(
                clamped <= _maxLength,
                "InputRenderable: minLength (\(clamped)) cannot be greater than maxLength (\(_maxLength))"
            )
            _minLength = clamped
        }
    }

    /// String-only placeholder accessor convenience (mirrors `placeholder`).
    public var placeholderText: String {
        get { placeholder?.plainText ?? "" }
        set { placeholder = .text(newValue) }
    }

    open override var initialValue: String {
        get { plainText }
        set { _ = newValue }
    }

    // MARK: - Focus, Submit & Deletions

    open override func focus() {
        super.focus()
        _lastCommittedValue = plainText
    }

    open override func blur() {
        if !isDestroyed {
            let currentValue = plainText
            if currentValue != _lastCommittedValue {
                _lastCommittedValue = currentValue
                emitInputEvent(.change, value: currentValue)
            }
        }
        super.blur()
    }

    @discardableResult
    open override func submit() -> Bool {
        let currentValue = plainText
        if currentValue.utf16.count < _minLength {
            return false
        }
        if currentValue != _lastCommittedValue {
            _lastCommittedValue = currentValue
            emitInputEvent(.change, value: currentValue)
        }
        emitInputEvent(.enter, value: currentValue)
        if let superSubmit = onSubmit {
            superSubmit(SubmitEvent())
        }
        return true
    }

    @discardableResult
    open override func deleteCharBackward() -> Bool {
        let result = super.deleteCharBackward()
        emitInputEvent(.input, value: plainText)
        return result
    }

    @discardableResult
    open override func deleteChar() -> Bool {
        let result = super.deleteChar()
        emitInputEvent(.input, value: plainText)
        return result
    }

    @discardableResult
    open override func deleteLine() -> Bool {
        let result = super.deleteLine()
        emitInputEvent(.input, value: plainText)
        return result
    }

    @discardableResult
    open override func deleteWordBackward() -> Bool {
        let result = super.deleteWordBackward()
        emitInputEvent(.input, value: plainText)
        return result
    }

    @discardableResult
    open override func deleteWordForward() -> Bool {
        let result = super.deleteWordForward()
        emitInputEvent(.input, value: plainText)
        return result
    }

    @discardableResult
    open override func deleteToLineStart() -> Bool {
        let result = super.deleteToLineStart()
        emitInputEvent(.input, value: plainText)
        return result
    }

    @discardableResult
    open override func deleteToLineEnd() -> Bool {
        let result = super.deleteToLineEnd()
        emitInputEvent(.input, value: plainText)
        return result
    }

    @discardableResult
    open override func undo() -> Bool {
        let result = super.undo()
        emitInputEvent(.input, value: plainText)
        return result
    }

    @discardableResult
    open override func redo() -> Bool {
        let result = super.redo()
        emitInputEvent(.input, value: plainText)
        return result
    }

    // parity: core/src/renderables/Input.ts#InputRenderable.deleteCharacter [status=implemented hash=20c7eb888982]
    public func deleteCharacter(_ direction: InputDeleteDirection) {
        switch direction {
        case .backward:
            _ = deleteCharBackward()
        case .forward:
            _ = deleteChar()
        }
    }

    open override func destroySelf() {
        _valueListeners.removeAll()
        super.destroySelf()
    }
}
