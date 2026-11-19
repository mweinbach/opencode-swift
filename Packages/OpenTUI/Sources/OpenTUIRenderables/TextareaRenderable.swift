import OpenTUICore
import OpenTUILayout

// MARK: - Placeholder & Action Types

/// Placeholder content for `TextareaRenderable`, accepting either plain text or `StyledText`.
public enum PlaceholderValue: Equatable, Hashable, Sendable, ExpressibleByStringLiteral {
    case text(String)
    case styled(StyledText)

    public init(stringLiteral value: String) {
        self = .text(value)
    }

    public var plainText: String {
        switch self {
        case .text(let s): return s
        case .styled(let st): return st.plainText
        }
    }

    internal func cloned() -> PlaceholderValue {
        switch self {
        case .text(let s):
            return .text(s)
        case .styled(let st):
            let clonedChunks = st.chunks.map { chunk in
                TextChunk(
                    text: chunk.text,
                    fg: chunk.fg.map { RGBA.clone($0) },
                    bg: chunk.bg.map { RGBA.clone($0) },
                    attributes: chunk.attributes,
                    link: chunk.link
                )
            }
            return .styled(StyledText(chunks: clonedChunks))
        }
    }
}

/// Editing and navigation actions supported by `TextareaRenderable` key bindings.
// parity: core/src/renderables/Textarea.ts#TextareaAction [status=implemented hash=e8b66015f437]
public enum TextareaAction: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case moveLeft = "move-left"
    case moveRight = "move-right"
    case moveUp = "move-up"
    case moveDown = "move-down"
    case selectLeft = "select-left"
    case selectRight = "select-right"
    case selectUp = "select-up"
    case selectDown = "select-down"
    case lineHome = "line-home"
    case lineEnd = "line-end"
    case selectLineHome = "select-line-home"
    case selectLineEnd = "select-line-end"
    case visualLineHome = "visual-line-home"
    case visualLineEnd = "visual-line-end"
    case selectVisualLineHome = "select-visual-line-home"
    case selectVisualLineEnd = "select-visual-line-end"
    case bufferHome = "buffer-home"
    case bufferEnd = "buffer-end"
    case selectBufferHome = "select-buffer-home"
    case selectBufferEnd = "select-buffer-end"
    case deleteLine = "delete-line"
    case deleteToLineEnd = "delete-to-line-end"
    case deleteToLineStart = "delete-to-line-start"
    case backspace = "backspace"
    case delete = "delete"
    case newline = "newline"
    case undo = "undo"
    case redo = "redo"
    case wordForward = "word-forward"
    case wordBackward = "word-backward"
    case selectWordForward = "select-word-forward"
    case selectWordBackward = "select-word-backward"
    case deleteWordForward = "delete-word-forward"
    case deleteWordBackward = "delete-word-backward"
    case selectAll = "select-all"
    case submit = "submit"
}

// parity: core/src/renderables/Textarea.ts#KeyBinding [status=implemented hash=8ecb31fb2a5b]
public typealias TextareaKeyBinding = KeyBinding<TextareaAction>

// parity: core/src/renderables/Textarea.ts#TextareaKeyAliasMap [status=implemented hash=66292753ff6e]
public typealias TextareaKeyAliasMap = KeyAliasMap

// parity: core/src/renderables/Textarea.ts#defaultTextareaKeyBindings [status=implemented hash=004bf28b9c7c]
public let defaultTextareaKeyBindings: [TextareaKeyBinding] = [
    KeyBinding(name: "left", action: .moveLeft),
    KeyBinding(name: "right", action: .moveRight),
    KeyBinding(name: "up", action: .moveUp),
    KeyBinding(name: "down", action: .moveDown),
    KeyBinding(name: "left", shift: true, action: .selectLeft),
    KeyBinding(name: "right", shift: true, action: .selectRight),
    KeyBinding(name: "up", shift: true, action: .selectUp),
    KeyBinding(name: "down", shift: true, action: .selectDown),
    KeyBinding(name: "home", action: .bufferHome),
    KeyBinding(name: "end", action: .bufferEnd),
    KeyBinding(name: "home", shift: true, action: .selectBufferHome),
    KeyBinding(name: "end", shift: true, action: .selectBufferEnd),
    KeyBinding(name: "a", ctrl: true, action: .lineHome),
    KeyBinding(name: "e", ctrl: true, action: .lineEnd),
    KeyBinding(name: "a", ctrl: true, shift: true, action: .selectLineHome),
    KeyBinding(name: "e", ctrl: true, shift: true, action: .selectLineEnd),
    KeyBinding(name: "a", meta: true, action: .visualLineHome),
    KeyBinding(name: "e", meta: true, action: .visualLineEnd),
    KeyBinding(name: "a", shift: true, meta: true, action: .selectVisualLineHome),
    KeyBinding(name: "e", shift: true, meta: true, action: .selectVisualLineEnd),
    KeyBinding(name: "f", ctrl: true, action: .moveRight),
    KeyBinding(name: "b", ctrl: true, action: .moveLeft),
    KeyBinding(name: "w", ctrl: true, action: .deleteWordBackward),
    KeyBinding(name: "backspace", ctrl: true, action: .deleteWordBackward),
    KeyBinding(name: "d", meta: true, action: .deleteWordForward),
    KeyBinding(name: "delete", meta: true, action: .deleteWordForward),
    KeyBinding(name: "delete", ctrl: true, action: .deleteWordForward),
    KeyBinding(name: "d", ctrl: true, shift: true, action: .deleteLine),
    KeyBinding(name: "k", ctrl: true, action: .deleteToLineEnd),
    KeyBinding(name: "u", ctrl: true, action: .deleteToLineStart),
    KeyBinding(name: "backspace", action: .backspace),
    KeyBinding(name: "backspace", shift: true, action: .backspace),
    KeyBinding(name: "d", ctrl: true, action: .delete),
    KeyBinding(name: "delete", action: .delete),
    KeyBinding(name: "delete", shift: true, action: .delete),
    KeyBinding(name: "return", action: .newline),
    KeyBinding(name: "kpenter", action: .newline),
    KeyBinding(name: "linefeed", action: .newline),
    KeyBinding(name: "return", meta: true, action: .submit),
    KeyBinding(name: "kpenter", meta: true, action: .submit),

    // undo/redo
    KeyBinding(name: "-", ctrl: true, action: .undo),
    KeyBinding(name: ".", ctrl: true, action: .redo),
    KeyBinding(name: "z", super: true, action: .undo),
    KeyBinding(name: "z", shift: true, super: true, action: .redo),

    KeyBinding(name: "f", meta: true, action: .wordForward),
    KeyBinding(name: "b", meta: true, action: .wordBackward),
    KeyBinding(name: "right", meta: true, action: .wordForward),
    KeyBinding(name: "left", meta: true, action: .wordBackward),
    KeyBinding(name: "right", ctrl: true, action: .wordForward),
    KeyBinding(name: "left", ctrl: true, action: .wordBackward),
    KeyBinding(name: "f", shift: true, meta: true, action: .selectWordForward),
    KeyBinding(name: "b", shift: true, meta: true, action: .selectWordBackward),
    KeyBinding(name: "right", shift: true, meta: true, action: .selectWordForward),
    KeyBinding(name: "left", shift: true, meta: true, action: .selectWordBackward),
    KeyBinding(name: "backspace", meta: true, action: .deleteWordBackward),

    // super (cmd/win) + arrow keys for Kitty Keyboard mode
    KeyBinding(name: "left", super: true, action: .visualLineHome),
    KeyBinding(name: "right", super: true, action: .visualLineEnd),
    KeyBinding(name: "up", super: true, action: .bufferHome),
    KeyBinding(name: "down", super: true, action: .bufferEnd),
    KeyBinding(name: "backspace", super: true, action: .deleteToLineStart),
    KeyBinding(name: "left", shift: true, super: true, action: .selectVisualLineHome),
    KeyBinding(name: "right", shift: true, super: true, action: .selectVisualLineEnd),
    KeyBinding(name: "up", shift: true, super: true, action: .selectBufferHome),
    KeyBinding(name: "down", shift: true, super: true, action: .selectBufferEnd),
    KeyBinding(name: "a", super: true, action: .selectAll),
]

/// Lowercase convenience alias for `defaultTextareaKeyBindings`.
public let defaultTextareaKeybindings: [TextareaKeyBinding] = defaultTextareaKeyBindings

// parity: core/src/renderables/Textarea.ts#SubmitEvent [status=implemented hash=8e231e9507f4]
public struct SubmitEvent: Equatable, Hashable, Sendable, Codable {
    public init() {}
}

// MARK: - TextareaOptions

// parity: core/src/renderables/Textarea.ts#TextareaOptions [status=implemented hash=a8f70ed61878]
public struct TextareaOptions {
    public var editBuffer: EditBufferOptions
    public var initialValue: String?
    public var focusedBackgroundColor: Color?
    public var focusedTextColor: Color?
    public var placeholder: PlaceholderValue?
    public var placeholderColor: Color?
    public var keyBindings: [TextareaKeyBinding]?
    public var keyAliasMap: TextareaKeyAliasMap?
    public var onSubmit: ((SubmitEvent) -> Void)?

    public init(
        editBuffer: EditBufferOptions = EditBufferOptions(),
        initialValue: String? = nil,
        focusedBackgroundColor: Color? = nil,
        focusedTextColor: Color? = nil,
        placeholder: PlaceholderValue? = nil,
        placeholderColor: Color? = nil,
        keyBindings: [TextareaKeyBinding]? = nil,
        keyAliasMap: TextareaKeyAliasMap? = nil,
        onSubmit: ((SubmitEvent) -> Void)? = nil
    ) {
        self.editBuffer = editBuffer
        self.initialValue = initialValue
        self.focusedBackgroundColor = focusedBackgroundColor
        self.focusedTextColor = focusedTextColor
        self.placeholder = placeholder
        self.placeholderColor = placeholderColor
        self.keyBindings = keyBindings
        self.keyAliasMap = keyAliasMap
        self.onSubmit = onSubmit
    }

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
        initialValue: String? = nil,
        backgroundColor: Color? = nil,
        textColor: Color? = nil,
        focusedBackgroundColor: Color? = nil,
        focusedTextColor: Color? = nil,
        selectionBg: Color? = nil,
        selectionFg: Color? = nil,
        selectable: Bool? = nil,
        attributes: UInt32? = nil,
        wrapMode: TextWrapMode? = nil,
        scrollMargin: Double? = nil,
        scrollSpeed: Double? = nil,
        showCursor: Bool? = nil,
        cursorColor: Color? = nil,
        cursorStyle: CursorStyleOptions? = nil,
        selectionOccupancy: SelectionOccupancy? = nil,
        syntaxStyle: SyntaxStyle? = nil,
        tabIndicator: TabIndicatorValue? = nil,
        tabIndicatorColor: Color? = nil,
        placeholder: PlaceholderValue? = nil,
        placeholderColor: Color? = nil,
        keyBindings: [TextareaKeyBinding]? = nil,
        keyAliasMap: TextareaKeyAliasMap? = nil,
        onSubmit: ((SubmitEvent) -> Void)? = nil,
        onCursorChange: ((CursorChangeEvent) -> Void)? = nil,
        onContentChange: ((ContentChangeEvent) -> Void)? = nil,
        onKeyDown: ((KeyEvent) -> Void)? = nil,
        onPaste: ((PasteEvent) -> Void)? = nil
    ) {
        self.init(
            editBuffer: EditBufferOptions(
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
                textColor: textColor,
                backgroundColor: backgroundColor,
                focusedTextColor: focusedTextColor,
                focusedBackgroundColor: focusedBackgroundColor,
                selectionBg: selectionBg,
                selectionFg: selectionFg,
                selectable: selectable,
                attributes: attributes,
                wrapMode: wrapMode,
                scrollMargin: scrollMargin,
                scrollSpeed: scrollSpeed,
                showCursor: showCursor,
                cursorColor: cursorColor,
                cursorStyle: cursorStyle,
                selectionOccupancy: selectionOccupancy,
                syntaxStyle: syntaxStyle,
                tabIndicator: tabIndicator,
                tabIndicatorColor: tabIndicatorColor,
                onCursorChange: onCursorChange,
                onContentChange: onContentChange,
                onKeyDown: onKeyDown,
                onPaste: onPaste
            ),
            initialValue: initialValue,
            focusedBackgroundColor: focusedBackgroundColor,
            focusedTextColor: focusedTextColor,
            placeholder: placeholder,
            placeholderColor: placeholderColor,
            keyBindings: keyBindings,
            keyAliasMap: keyAliasMap,
            onSubmit: onSubmit
        )
    }
}

// MARK: - Helpers

private func containsUnsupportedKeyCharacters(_ sequence: String) -> Bool {
    for scalar in sequence.unicodeScalars {
        let v = scalar.value
        if v <= 0x1F || (v >= 0x7F && v <= 0x9F) {
            return true
        }
    }
    return false
}

// MARK: - TextareaRenderable

/// Multi-line interactive text editor renderable with full keybinding dispatch,
/// shift-selection, bracketed paste handling, undo/redo, placeholders, and extmarks.
// parity: core/src/renderables/Textarea.ts#TextareaRenderable [status=implemented hash=956c7c20251d]
open class TextareaRenderable: EditBufferRenderable, @unchecked Sendable {
    public static let defaultTextareaBackgroundColor: Color = "transparent"
    public static let defaultTextareaTextColor: Color = "#FFFFFF"
    public static let defaultTextareaFocusedBackgroundColor: Color = "transparent"
    public static let defaultTextareaFocusedTextColor: Color = "#FFFFFF"
    public static let defaultPlaceholderColor: Color = "#666666"

    private var _placeholder: PlaceholderValue?
    private var _placeholderColor: RGBA
    private var _unfocusedBackgroundColor: RGBA
    private var _unfocusedTextColor: RGBA
    private var _textareaFocusedBackgroundColor: RGBA
    private var _textareaFocusedTextColor: RGBA
    private var _keyBindingsMap: [String: TextareaAction] = [:]
    private var _keyAliasMap: TextareaKeyAliasMap
    private var _keyBindings: [TextareaKeyBinding]
    private var _initialValueSet: Bool = false
    private var _submitListener: ((SubmitEvent) -> Void)?

    /// Base keybindings merged beneath user-supplied `keyBindings`.
    /// `InputRenderable` overrides this to bind Enter/Return/Linefeed to `.submit`.
    open var baseKeyBindings: [TextareaKeyBinding] {
        defaultTextareaKeyBindings
    }

    public init(ctx: any RenderContext, options: TextareaOptions = TextareaOptions()) {
        let resolvedBg = options.editBuffer.backgroundColor ?? Self.defaultTextareaBackgroundColor
        let resolvedFg = options.editBuffer.textColor ?? Self.defaultTextareaTextColor
        let resolvedFocusedBg = options.focusedBackgroundColor
            ?? options.editBuffer.focusedBackgroundColor
            ?? options.editBuffer.backgroundColor
            ?? Self.defaultTextareaFocusedBackgroundColor
        let resolvedFocusedFg = options.focusedTextColor
            ?? options.editBuffer.focusedTextColor
            ?? options.editBuffer.textColor
            ?? Self.defaultTextareaFocusedTextColor

        var baseOptions = options.editBuffer
        baseOptions.backgroundColor = resolvedBg
        baseOptions.textColor = resolvedFg
        baseOptions.focusedBackgroundColor = resolvedFocusedBg
        baseOptions.focusedTextColor = resolvedFocusedFg

        self._unfocusedBackgroundColor = RGBA.clone(resolvedBg.resolved())
        self._unfocusedTextColor = RGBA.clone(resolvedFg.resolved())
        self._textareaFocusedBackgroundColor = RGBA.clone(resolvedFocusedBg.resolved())
        self._textareaFocusedTextColor = RGBA.clone(resolvedFocusedFg.resolved())
        self._placeholder = options.placeholder?.cloned()
        self._placeholderColor = RGBA.clone((options.placeholderColor ?? Self.defaultPlaceholderColor).resolved())
        self._keyAliasMap = mergeKeyAliases(defaultKeyAliases, options.keyAliasMap ?? [:])
        self._keyBindings = options.keyBindings ?? []
        self._submitListener = options.onSubmit

        super.init(ctx: ctx, options: baseOptions)

        rebuildKeyBindingsMap()

        if let initial = options.initialValue, !initial.isEmpty {
            setText(initial)
            _initialValueSet = true
        }
        updateColors()
        applyPlaceholder(_placeholder, color: _placeholderColor)
    }

    private func rebuildKeyBindingsMap() {
        let merged = mergeKeyBindings(baseKeyBindings, _keyBindings)
        _keyBindingsMap = buildKeyBindingsMap(merged, aliasMap: _keyAliasMap)
    }

    private func applyPlaceholder(_ placeholder: PlaceholderValue?, color: RGBA) {
        guard !editorView.isDestroyed else { return }
        guard let placeholder else {
            editorView.setPlaceholderStyledText([])
            return
        }
        switch placeholder {
        case .text(let s):
            if s.isEmpty {
                editorView.setPlaceholderStyledText([])
            } else {
                editorView.setPlaceholderStyledText([TextChunk(text: s, fg: color)])
            }
        case .styled(let st):
            // Reject linked placeholder chunks without poisoning placeholder state
            if st.chunks.contains(where: { $0.link != nil }) {
                return
            }
            editorView.setPlaceholderStyledText(st.chunks)
        }
    }

    private func dispatchAction(_ action: TextareaAction) -> Bool {
        switch action {
        case .moveLeft: return moveCursorLeft()
        case .moveRight: return moveCursorRight()
        case .moveUp: return moveCursorUp()
        case .moveDown: return moveCursorDown()
        case .selectLeft: return moveCursorLeft(select: true)
        case .selectRight: return moveCursorRight(select: true)
        case .selectUp: return moveCursorUp(select: true)
        case .selectDown: return moveCursorDown(select: true)
        case .lineHome: return gotoLineHome()
        case .lineEnd: return gotoLineEnd()
        case .selectLineHome: return gotoLineHome(select: true)
        case .selectLineEnd: return gotoLineEnd(select: true)
        case .visualLineHome: return gotoVisualLineHome()
        case .visualLineEnd: return gotoVisualLineEnd()
        case .selectVisualLineHome: return gotoVisualLineHome(select: true)
        case .selectVisualLineEnd: return gotoVisualLineEnd(select: true)
        case .bufferHome: return gotoBufferHome()
        case .bufferEnd: return gotoBufferEnd()
        case .selectBufferHome: return gotoBufferHome(select: true)
        case .selectBufferEnd: return gotoBufferEnd(select: true)
        case .deleteLine: return deleteLine()
        case .deleteToLineEnd: return deleteToLineEnd()
        case .deleteToLineStart: return deleteToLineStart()
        case .backspace: return deleteCharBackward()
        case .delete: return deleteChar()
        case .newline: return newLine()
        case .undo: return undo()
        case .redo: return redo()
        case .wordForward: return moveWordForward()
        case .wordBackward: return moveWordBackward()
        case .selectWordForward: return moveWordForward(select: true)
        case .selectWordBackward: return moveWordBackward(select: true)
        case .deleteWordForward: return deleteWordForward()
        case .deleteWordBackward: return deleteWordBackward()
        case .selectAll: return selectAll()
        case .submit: return submit()
        }
    }

    // MARK: - Input Handling

    // parity: core/src/renderables/Textarea.ts#TextareaRenderable.handlePaste [status=implemented hash=6f4e2c2f52c7]
    open override func handlePaste(_ event: PasteEvent) {
        insertText(stripAnsiSequences(decodePasteBytes(event.bytes)))
    }

    // parity: core/src/renderables/Textarea.ts#TextareaRenderable.handleKeyPress [status=implemented hash=7dd80b865a28]
    @discardableResult
    open override func handleKeyPress(_ key: KeyEvent) -> Bool {
        if traits.suspend != true {
            if let action = getKeyBindingAction(_keyBindingsMap, key) {
                return dispatchAction(action)
            }
        }

        if !key.ctrl && !key.meta && (key.`super` != true) && (key.hyper != true) {
            if key.name == "space" {
                insertText(" ")
                return true
            }
            if !key.sequence.isEmpty && !containsUnsupportedKeyCharacters(key.sequence) {
                insertText(key.sequence)
                return true
            }
        }

        return false
    }

    // MARK: - Colors & Focus

    private func updateColors() {
        guard !isDestroyed else { return }
        _textColor = _unfocusedTextColor
        _backgroundColor = _unfocusedBackgroundColor
        _focusedTextColor = _textareaFocusedTextColor
        _focusedBackgroundColor = _textareaFocusedBackgroundColor
        syncDefaultBufferColors()
        requestRender()
    }

    // parity: core/src/renderables/Textarea.ts#TextareaRenderable.focus [status=implemented hash=d35860e5d769]
    open override func focus() {
        super.focus()
        updateColors()
    }

    // parity: core/src/renderables/Textarea.ts#TextareaRenderable.blur [status=implemented hash=66125d685019]
    open override func blur() {
        super.blur()
        updateColors()
    }

    // MARK: - Properties

    // parity: core/src/renderables/Textarea.ts#TextareaRenderable.placeholder [status=implemented hash=3efc07e4d2cc]
    open var placeholder: PlaceholderValue? {
        get { _placeholder?.cloned() }
        set {
            let normalized = newValue?.cloned()
            if case .styled(let st) = normalized, st.chunks.contains(where: { $0.link != nil }) {
                return
            }
            if _placeholder != normalized {
                applyPlaceholder(normalized, color: _placeholderColor)
                _placeholder = normalized
                requestRender()
            }
        }
    }

    // parity: core/src/renderables/Textarea.ts#TextareaRenderable.placeholderColor [status=implemented hash=0f1d57d0d8c8]
    public var placeholderColor: RGBA {
        get { RGBA.clone(_placeholderColor) }
        set {
            let color = RGBA.clone(newValue)
            applyPlaceholder(_placeholder, color: color)
            _placeholderColor = color
            requestRender()
        }
    }

    public func setPlaceholderColor(_ color: Color?) {
        placeholderColor = (color ?? Self.defaultPlaceholderColor).resolved()
    }

    // parity: core/src/renderables/Textarea.ts#TextareaRenderable.backgroundColor [status=implemented hash=8423d86a4d5d]
    open override var backgroundColor: RGBA {
        get { RGBA.clone(_unfocusedBackgroundColor) }
        set {
            _unfocusedBackgroundColor = RGBA.clone(newValue)
            updateColors()
        }
    }

    // parity: core/src/renderables/Textarea.ts#TextareaRenderable.textColor [status=implemented hash=6b053d0ee316]
    open override var textColor: RGBA {
        get { RGBA.clone(_unfocusedTextColor) }
        set {
            _unfocusedTextColor = RGBA.clone(newValue)
            updateColors()
        }
    }

    // parity: core/src/renderables/Textarea.ts#TextareaRenderable.focusedBackgroundColor [status=implemented hash=3b27c2943b71]
    open override var focusedBackgroundColor: RGBA? {
        get { RGBA.clone(_textareaFocusedBackgroundColor) }
        set {
            _textareaFocusedBackgroundColor = RGBA.clone(newValue ?? Self.defaultTextareaFocusedBackgroundColor.resolved())
            updateColors()
        }
    }

    // parity: core/src/renderables/Textarea.ts#TextareaRenderable.focusedTextColor [status=implemented hash=ec1903f1f072]
    open override var focusedTextColor: RGBA? {
        get { RGBA.clone(_textareaFocusedTextColor) }
        set {
            _textareaFocusedTextColor = RGBA.clone(newValue ?? Self.defaultTextareaFocusedTextColor.resolved())
            updateColors()
        }
    }

    // parity: core/src/renderables/Textarea.ts#TextareaRenderable.initialValue [status=implemented hash=46b017ffc244]
    open var initialValue: String {
        get { plainText }
        set {
            if !_initialValueSet {
                setText(newValue)
                _initialValueSet = true
            }
        }
    }

    // parity: core/src/renderables/Textarea.ts#TextareaRenderable.submit [status=implemented hash=e4616c6ffa73]
    @discardableResult
    open func submit() -> Bool {
        _submitListener?(SubmitEvent())
        return true
    }

    // parity: core/src/renderables/Textarea.ts#TextareaRenderable.onSubmit [status=implemented hash=8ae37a31e429]
    public var onSubmit: ((SubmitEvent) -> Void)? {
        get { _submitListener }
        set { _submitListener = newValue }
    }

    // parity: core/src/renderables/Textarea.ts#TextareaRenderable.keyBindings [status=implemented hash=8a9df5d74ce7]
    public var keyBindings: [TextareaKeyBinding] {
        get { _keyBindings }
        set {
            _keyBindings = newValue
            rebuildKeyBindingsMap()
        }
    }

    // parity: core/src/renderables/Textarea.ts#TextareaRenderable.keyAliasMap [status=implemented hash=50e70f41a823]
    public var keyAliasMap: TextareaKeyAliasMap {
        get { _keyAliasMap }
        set {
            _keyAliasMap = mergeKeyAliases(defaultKeyAliases, newValue)
            rebuildKeyBindingsMap()
        }
    }

    // parity: core/src/renderables/Textarea.ts#TextareaRenderable.extmarks [status=implemented hash=66b09bf53393]
    open override var extmarks: ExtmarksController {
        super.extmarks
    }
}
