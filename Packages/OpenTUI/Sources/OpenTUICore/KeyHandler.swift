/// Mutable key event wrapper carrying `preventDefault()` and `stopPropagation()` state during dispatch.
// parity: core/src/lib/KeyHandler.ts#KeyEvent [status=implemented hash=7eecd3738e2f]
public final class KeyEvent {
    public var name: String
    public var ctrl: Bool
    public var meta: Bool
    public var shift: Bool
    public var option: Bool
    public var sequence: String
    public var number: Bool
    public var raw: String
    public var eventType: KeyEventType
    public var source: ParsedKeySource
    public var code: String?
    public var `super`: Bool?
    public var hyper: Bool?
    public var capsLock: Bool?
    public var numLock: Bool?
    public var baseCode: UInt32?
    public var repeated: Bool?

    private var _defaultPrevented: Bool = false
    private var _propagationStopped: Bool = false

    public init(_ key: ParsedKey) {
        self.name = key.name
        self.ctrl = key.ctrl
        self.meta = key.meta
        self.shift = key.shift
        self.option = key.option
        self.sequence = key.sequence
        self.number = key.number
        self.raw = key.raw
        self.eventType = key.eventType
        self.source = key.source
        self.code = key.code
        self.`super` = key.`super`
        self.hyper = key.hyper
        self.capsLock = key.capsLock
        self.numLock = key.numLock
        self.baseCode = key.baseCode
        self.repeated = key.repeated
    }

    // parity: core/src/lib/KeyHandler.ts#KeyEvent.defaultPrevented [status=implemented hash=ec2050d473ab]
    public var defaultPrevented: Bool {
        _defaultPrevented
    }

    // parity: core/src/lib/KeyHandler.ts#KeyEvent.propagationStopped [status=implemented hash=348ce051deb3]
    public var propagationStopped: Bool {
        _propagationStopped
    }

    // parity: core/src/lib/KeyHandler.ts#KeyEvent.preventDefault [status=implemented hash=5f0008064a76]
    public func preventDefault() {
        _defaultPrevented = true
    }

    // parity: core/src/lib/KeyHandler.ts#KeyEvent.stopPropagation [status=implemented hash=91aedcd2fea3]
    public func stopPropagation() {
        _propagationStopped = true
    }
}

/// Mutable paste event wrapper carrying raw pasted bytes, metadata, and propagation state.
// parity: core/src/lib/KeyHandler.ts#PasteEvent [status=implemented hash=07c45d0d7a7e]
public final class PasteEvent {
    public let type: String = "paste"
    public var bytes: [UInt8]
    public var metadata: PasteMetadata?

    private var _defaultPrevented: Bool = false
    private var _propagationStopped: Bool = false

    public init(bytes: [UInt8], metadata: PasteMetadata? = nil) {
        self.bytes = bytes
        self.metadata = metadata
    }

    // parity: core/src/lib/KeyHandler.ts#PasteEvent.defaultPrevented [status=implemented hash=ec2050d473ab]
    public var defaultPrevented: Bool {
        _defaultPrevented
    }

    // parity: core/src/lib/KeyHandler.ts#PasteEvent.propagationStopped [status=implemented hash=348ce051deb3]
    public var propagationStopped: Bool {
        _propagationStopped
    }

    // parity: core/src/lib/KeyHandler.ts#PasteEvent.preventDefault [status=implemented hash=5f0008064a76]
    public func preventDefault() {
        _defaultPrevented = true
    }

    // parity: core/src/lib/KeyHandler.ts#PasteEvent.stopPropagation [status=implemented hash=91aedcd2fea3]
    public func stopPropagation() {
        _propagationStopped = true
    }
}

/// Event channels emitted by `KeyHandler`.
// parity: core/src/lib/KeyHandler.ts#KeyHandlerEventMap [status=implemented hash=4c7a6c5753a9]
public enum KeyHandlerEventName: String, Equatable, Hashable, Sendable {
    case keypress
    case keyrelease
    case paste
}

/// Payload enum corresponding to `KeyHandlerEventMap`.
public enum KeyHandlerEventPayload {
    case keypress(KeyEvent)
    case keyrelease(KeyEvent)
    case paste(PasteEvent)

    public var eventName: KeyHandlerEventName {
        switch self {
        case .keypress: return .keypress
        case .keyrelease: return .keyrelease
        case .paste: return .paste
        }
    }

    public var defaultPrevented: Bool {
        switch self {
        case .keypress(let event), .keyrelease(let event):
            return event.defaultPrevented
        case .paste(let event):
            return event.defaultPrevented
        }
    }

    public var propagationStopped: Bool {
        switch self {
        case .keypress(let event), .keyrelease(let event):
            return event.propagationStopped
        case .paste(let event):
            return event.propagationStopped
        }
    }
}

/// Opaque registration handle returned when adding a listener to `KeyHandler` / `InternalKeyHandler`.
public struct KeyHandlerToken: Equatable, Hashable, Sendable {
    fileprivate let id: UInt64
    fileprivate let event: KeyHandlerEventName
    fileprivate let isInternal: Bool
}

/// Dispatches decoded key and paste events to registered listeners.
// parity: core/src/lib/KeyHandler.ts#KeyHandler [status=implemented hash=9e142470df66]
open class KeyHandler {
    private struct KeyListenerEntry {
        let id: UInt64
        let handler: (KeyEvent) -> Void
    }

    private struct PasteListenerEntry {
        let id: UInt64
        let handler: (PasteEvent) -> Void
    }

    private var nextListenerId: UInt64 = 1
    private var keypressListeners: [KeyListenerEntry] = []
    private var keyreleaseListeners: [KeyListenerEntry] = []
    private var pasteListeners: [PasteListenerEntry] = []

    public init() {}

    fileprivate func allocateId() -> UInt64 {
        let id = nextListenerId
        nextListenerId &+= 1
        return id
    }

    @discardableResult
    public func onKeypress(_ handler: @escaping (KeyEvent) -> Void) -> KeyHandlerToken {
        let id = allocateId()
        keypressListeners.append(KeyListenerEntry(id: id, handler: handler))
        return KeyHandlerToken(id: id, event: .keypress, isInternal: false)
    }

    @discardableResult
    public func onKeyrelease(_ handler: @escaping (KeyEvent) -> Void) -> KeyHandlerToken {
        let id = allocateId()
        keyreleaseListeners.append(KeyListenerEntry(id: id, handler: handler))
        return KeyHandlerToken(id: id, event: .keyrelease, isInternal: false)
    }

    @discardableResult
    public func onPaste(_ handler: @escaping (PasteEvent) -> Void) -> KeyHandlerToken {
        let id = allocateId()
        pasteListeners.append(PasteListenerEntry(id: id, handler: handler))
        return KeyHandlerToken(id: id, event: .paste, isInternal: false)
    }

    public func off(_ token: KeyHandlerToken) {
        guard !token.isInternal else { return }
        switch token.event {
        case .keypress:
            keypressListeners.removeAll { $0.id == token.id }
        case .keyrelease:
            keyreleaseListeners.removeAll { $0.id == token.id }
        case .paste:
            pasteListeners.removeAll { $0.id == token.id }
        }
    }

    public func removeAllListeners(for event: KeyHandlerEventName? = nil) {
        switch event {
        case .none:
            keypressListeners.removeAll()
            keyreleaseListeners.removeAll()
            pasteListeners.removeAll()
        case .keypress:
            keypressListeners.removeAll()
        case .keyrelease:
            keyreleaseListeners.removeAll()
        case .paste:
            pasteListeners.removeAll()
        }
    }

    fileprivate func snapshotGlobalKeyListeners(for event: KeyHandlerEventName) -> [(KeyEvent) -> Void] {
        switch event {
        case .keypress: return keypressListeners.map(\.handler)
        case .keyrelease: return keyreleaseListeners.map(\.handler)
        case .paste: return []
        }
    }

    fileprivate func snapshotGlobalPasteListeners() -> [(PasteEvent) -> Void] {
        pasteListeners.map(\.handler)
    }

    @discardableResult
    open func emit(_ payload: KeyHandlerEventPayload) -> Bool {
        switch payload {
        case .keypress(let event):
            let listeners = snapshotGlobalKeyListeners(for: .keypress)
            if listeners.isEmpty { return false }
            for listener in listeners {
                listener(event)
                if event.propagationStopped {
                    return true
                }
            }
            return true
        case .keyrelease(let event):
            let listeners = snapshotGlobalKeyListeners(for: .keyrelease)
            if listeners.isEmpty { return false }
            for listener in listeners {
                listener(event)
                if event.propagationStopped {
                    return true
                }
            }
            return true
        case .paste(let event):
            let listeners = snapshotGlobalPasteListeners()
            if listeners.isEmpty { return false }
            for listener in listeners {
                listener(event)
                if event.propagationStopped {
                    return true
                }
            }
            return true
        }
    }

    // parity: core/src/lib/KeyHandler.ts#KeyHandler.processParsedKey [status=implemented hash=6c75fa32e32d]
    @discardableResult
    public func processParsedKey(_ parsedKey: ParsedKey) -> Bool {
        switch parsedKey.eventType {
        case .press:
            _ = emit(.keypress(KeyEvent(parsedKey)))
        case .release:
            _ = emit(.keyrelease(KeyEvent(parsedKey)))
        case .repeat:
            _ = emit(.keypress(KeyEvent(parsedKey)))
        }
        return true
    }

    // parity: core/src/lib/KeyHandler.ts#KeyHandler.processPaste [status=implemented hash=24e57c7f0a64]
    public func processPaste(_ bytes: [UInt8], metadata: PasteMetadata? = nil) {
        _ = emit(.paste(PasteEvent(bytes: bytes, metadata: metadata)))
    }
}

/// Priority-ordered key handler used by the renderer so global handlers can `preventDefault()` or
/// `stopPropagation()` before internal renderable handlers run.
// parity: core/src/lib/KeyHandler.ts#InternalKeyHandler [status=implemented hash=b044941bd9ca]
public final class InternalKeyHandler: KeyHandler {
    private struct KeyListenerEntry {
        let id: UInt64
        let handler: (KeyEvent) -> Void
    }

    private struct PasteListenerEntry {
        let id: UInt64
        let handler: (PasteEvent) -> Void
    }

    private var internalKeypressListeners: [KeyListenerEntry] = []
    private var internalKeyreleaseListeners: [KeyListenerEntry] = []
    private var internalPasteListeners: [PasteListenerEntry] = []

    public override init() {
        super.init()
    }

    // parity: core/src/lib/KeyHandler.ts#InternalKeyHandler.emit [status=implemented hash=b52a8b3fe01c]
    @discardableResult
    public override func emit(_ payload: KeyHandlerEventPayload) -> Bool {
        switch payload {
        case .keypress(let event):
            return emitKeyWithPriority(eventName: .keypress, event: event)
        case .keyrelease(let event):
            return emitKeyWithPriority(eventName: .keyrelease, event: event)
        case .paste(let event):
            return emitPasteWithPriority(event: event)
        }
    }

    private func emitKeyWithPriority(
        eventName: KeyHandlerEventName,
        event: KeyEvent
    ) -> Bool {
        let globalListeners = snapshotGlobalKeyListeners(for: eventName)
        let hasGlobalListeners = !globalListeners.isEmpty

        if hasGlobalListeners {
            for listener in globalListeners {
                listener(event)
                if event.propagationStopped {
                    return hasGlobalListeners
                }
            }
        }

        // Snapshot renderable handlers after global dispatch so listeners added during renderable dispatch
        // (e.g. via focus changes) do not receive the in-flight key event.
        let renderableHandlers: [(KeyEvent) -> Void]
        switch eventName {
        case .keypress:
            renderableHandlers = internalKeypressListeners.map(\.handler)
        case .keyrelease:
            renderableHandlers = internalKeyreleaseListeners.map(\.handler)
        case .paste:
            renderableHandlers = []
        }

        let hasRenderableListeners = !renderableHandlers.isEmpty
        if hasRenderableListeners {
            if event.defaultPrevented || event.propagationStopped {
                return hasGlobalListeners || hasRenderableListeners
            }

            for handler in renderableHandlers {
                handler(event)
                if event.propagationStopped {
                    return hasGlobalListeners || hasRenderableListeners
                }
            }
        }

        return hasGlobalListeners || hasRenderableListeners
    }

    private func emitPasteWithPriority(event: PasteEvent) -> Bool {
        let globalListeners = snapshotGlobalPasteListeners()
        let hasGlobalListeners = !globalListeners.isEmpty

        if hasGlobalListeners {
            for listener in globalListeners {
                listener(event)
                if event.propagationStopped {
                    return hasGlobalListeners
                }
            }
        }

        let renderableHandlers = internalPasteListeners.map(\.handler)
        let hasRenderableListeners = !renderableHandlers.isEmpty
        if hasRenderableListeners {
            if event.defaultPrevented || event.propagationStopped {
                return hasGlobalListeners || hasRenderableListeners
            }

            for handler in renderableHandlers {
                handler(event)
                if event.propagationStopped {
                    return hasGlobalListeners || hasRenderableListeners
                }
            }
        }

        return hasGlobalListeners || hasRenderableListeners
    }

    // parity: core/src/lib/KeyHandler.ts#InternalKeyHandler.onInternal [status=implemented hash=93a04efdab31]
    @discardableResult
    public func onInternalKeypress(_ handler: @escaping (KeyEvent) -> Void) -> KeyHandlerToken {
        let id = allocateId()
        internalKeypressListeners.append(KeyListenerEntry(id: id, handler: handler))
        return KeyHandlerToken(id: id, event: .keypress, isInternal: true)
    }

    @discardableResult
    public func onInternalKeyrelease(_ handler: @escaping (KeyEvent) -> Void) -> KeyHandlerToken {
        let id = allocateId()
        internalKeyreleaseListeners.append(KeyListenerEntry(id: id, handler: handler))
        return KeyHandlerToken(id: id, event: .keyrelease, isInternal: true)
    }

    @discardableResult
    public func onInternalPaste(_ handler: @escaping (PasteEvent) -> Void) -> KeyHandlerToken {
        let id = allocateId()
        internalPasteListeners.append(PasteListenerEntry(id: id, handler: handler))
        return KeyHandlerToken(id: id, event: .paste, isInternal: true)
    }

    // parity: core/src/lib/KeyHandler.ts#InternalKeyHandler.offInternal [status=implemented hash=1d4a7dbd9735]
    public func offInternal(_ token: KeyHandlerToken) {
        guard token.isInternal else { return }
        switch token.event {
        case .keypress:
            internalKeypressListeners.removeAll { $0.id == token.id }
        case .keyrelease:
            internalKeyreleaseListeners.removeAll { $0.id == token.id }
        case .paste:
            internalPasteListeners.removeAll { $0.id == token.id }
        }
    }

    public override func removeAllListeners(for event: KeyHandlerEventName? = nil) {
        super.removeAllListeners(for: event)
        switch event {
        case .none:
            internalKeypressListeners.removeAll()
            internalKeyreleaseListeners.removeAll()
            internalPasteListeners.removeAll()
        case .keypress:
            internalKeypressListeners.removeAll()
        case .keyrelease:
            internalKeyreleaseListeners.removeAll()
        case .paste:
            internalPasteListeners.removeAll()
        }
    }
}
