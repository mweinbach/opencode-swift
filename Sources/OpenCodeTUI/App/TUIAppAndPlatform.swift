#if canImport(Foundation)
import Foundation
#elseif canImport(FoundationEssentials)
import FoundationEssentials
#endif
import Synchronization
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil
import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables
import OpenTUITerminal
import OpenTUIView

// MARK: - Logo (`packages/tui/src/logo.ts`)

/// ASCII/Unicode OpenCode logo mark definitions used by Home and Mini splash banners.
public enum TUILogo {
    public struct Mark: Equatable, Hashable, Sendable, Codable {
        public let left: [String]
        public let right: [String]

        public init(left: [String], right: [String]) {
            self.left = left
            self.right = right
        }
    }

    // parity: tui/src/logo.ts#logo [status=implemented hash=9eb224be1a42]
    public static let logo = Mark(
        left: [
            "                   ",
            "█▀▀█ █▀▀█ █▀▀█ █▀▀▄",
            "█__█ █__█ █^^^ █__█",
            "▀▀▀▀ █▀▀▀ ▀▀▀▀ ▀~~▀",
        ],
        right: [
            "             ▄     ",
            "█▀▀▀ █▀▀█ █▀▀█ █▀▀█",
            "█___ █__█ █__█ █^^^",
            "▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀",
        ]
    )

    // parity: tui/src/logo.ts#go [status=implemented hash=30ef06009274]
    public static let go = Mark(
        left: ["    ", "█▀▀▀", "█_^█", "▀▀▀▀"],
        right: ["    ", "█▀▀█", "█__█", "▀▀▀▀"]
    )
}

// MARK: - Attention & Audio (`packages/tui/src/attention*.ts`, `packages/tui/src/audio.ts`)

/// Attention notifications, built-in bundled MP3 sound paths, and cross-platform native audio playback.
public enum TUIAttention {
    private static func resolveSoundPath(_ kind: TUIAttentionAudio.SoundKind) -> String {
        TUIAttentionAudio.resolveAssetPath(for: kind)
    }

    // parity: tui/src/attention-sounds.node.ts#defaultSoundPath [status=adapted hash=0439840fefa5]
    public static let defaultSoundPath: String = resolveSoundPath(.default)

    // parity: tui/src/attention-sounds.node.ts#questionSoundPath [status=adapted hash=89f2a2e593bf]
    public static let questionSoundPath: String = resolveSoundPath(.question)

    // parity: tui/src/attention-sounds.node.ts#permissionSoundPath [status=adapted hash=fc41f65e02e6]
    public static let permissionSoundPath: String = resolveSoundPath(.permission)

    // parity: tui/src/attention-sounds.node.ts#errorSoundPath [status=adapted hash=847e0190f52b]
    public static let errorSoundPath: String = resolveSoundPath(.error)

    // parity: tui/src/attention-sounds.node.ts#subagentDoneSoundPath [status=adapted hash=82ca268612ce]
    public static let subagentDoneSoundPath: String = resolveSoundPath(.subagentDone)

    /// Bundled attention sound asset paths matching `packages/tui/src/attention-sounds.bun.ts`.
    public enum BunSounds {
        // parity: tui/src/attention-sounds.bun.ts#defaultSoundPath [status=adapted hash=7592e8582743]
        public static let defaultSoundPath: String = TUIAttention.defaultSoundPath

        // parity: tui/src/attention-sounds.bun.ts#questionSoundPath [status=adapted hash=7592e8582743]
        public static let questionSoundPath: String = TUIAttention.questionSoundPath

        // parity: tui/src/attention-sounds.bun.ts#permissionSoundPath [status=adapted hash=7592e8582743]
        public static let permissionSoundPath: String = TUIAttention.permissionSoundPath

        // parity: tui/src/attention-sounds.bun.ts#errorSoundPath [status=adapted hash=7592e8582743]
        public static let errorSoundPath: String = TUIAttention.errorSoundPath

        // parity: tui/src/attention-sounds.bun.ts#subagentDoneSoundPath [status=adapted hash=7592e8582743]
        public static let subagentDoneSoundPath: String = TUIAttention.subagentDoneSoundPath
    }

    /// Returns the resolved bundled `.mp3` path for `name` (mapping `.done` to `.default`).
    public static func soundPath(for name: PluginTui.AttentionSoundName) -> String {
        builtinSounds[name] ?? defaultSoundPath
    }

    private struct AudioBox: @unchecked Sendable {
        var engine: Audio? = nil
        var attempted: Bool = false
        var cache: [String: AudioSound] = [:]
        var nativePaths: [AudioSound: String] = [:]
        var nextNativeSoundID: AudioSound = 0x8000_0001
        var nextNativeVoiceID: AudioVoice = 0x8000_0001
    }

    private static let audioState = Mutex(AudioBox())

    private static func getAudio() -> Audio? {
        audioState.withLock { box in
            if box.attempted { return box.engine }
            box.attempted = true
            let engine = Audio()
            box.engine = engine
            return engine
        }
    }

    /// Loads and caches an audio file (native bundled/custom `.mp3` or OpenTUI PCM/WAV buffer).
    // parity: tui/src/audio.ts#loadSoundFile [status=adapted hash=57a70076b70f]
    public static func loadSoundFile(_ file: String) async -> AudioSound? {
        if let cached = audioState.withLock({ $0.cache[file] }) {
            return cached
        }
        let resolved = TUIAttentionAudio.resolveBundledFilePath(file)
        guard let bytes = try? await LocalFileSystem.shared.readFile(at: resolved) else {
            return nil
        }
        if TUIAttentionAudio.isValidMP3Data(bytes) {
            return audioState.withLock { box in
                if let existing = box.cache[file] {
                    return existing
                }
                let handle = box.nextNativeSoundID
                box.nextNativeSoundID &+= 1
                box.nativePaths[handle] = resolved
                box.cache[file] = handle
                return handle
            }
        }
        guard let engine = getAudio(),
              let sound = engine.loadSound(bytes)
        else {
            return nil
        }
        audioState.withLock { $0.cache[file] = sound }
        return sound
    }

    /// Plays a loaded `AudioSound` non-blockingly through the native player (for `.mp3`) or OpenTUI `Audio` engine.
    // parity: tui/src/audio.ts#play [status=adapted hash=a990c86aed20]
    @discardableResult
    public static func play(_ sound: AudioSound, options: AudioPlayOptions = AudioPlayOptions()) -> AudioVoice? {
        if let nativePath = audioState.withLock({ $0.nativePaths[sound] }) {
            let handle = TUIAttentionAudio.Player.shared.playNonBlocking(
                filePath: nativePath,
                volume: options.volume
            )
            guard handle.outcome.didTriggerFeedback else {
                return nil
            }
            return audioState.withLock { box in
                let voice = box.nextNativeVoiceID
                box.nextNativeVoiceID &+= 1
                return voice
            }
        }
        guard let engine = getAudio() else { return nil }
        if !engine.isStarted() {
            _ = engine.start()
        }
        return engine.play(sound, options: options)
    }

    /// Resolves the real bundled (or overridden) `.mp3` path for `name` and plays it non-blockingly via `player`.
    @discardableResult
    public static func playSound(
        _ name: PluginTui.AttentionSoundName = .default,
        volume: Double? = nil,
        overrides: TUIConfig.AttentionSoundPaths = [:],
        player: TUIAttentionAudio.Player = .shared
    ) -> TUIAttentionAudio.Player.PlaybackHandle {
        var candidates: [String] = []
        if let overridePath = overrides[name], !overridePath.isEmpty {
            candidates.append(overridePath)
        }
        let builtin = soundPath(for: name)
        if !candidates.contains(builtin) {
            candidates.append(builtin)
        }
        var lastHandle = TUIAttentionAudio.Player.PlaybackHandle(outcome: .suppressed(.missingAsset))
        for file in candidates {
            let handle = player.playNonBlocking(filePath: file, volume: volume)
            switch handle.outcome {
            case .played, .bellFallback:
                return handle
            case .suppressed(.muted), .suppressed(.zeroVolume), .suppressed(.headless), .suppressed(.unsupportedPlatform):
                return handle
            case .unavailable:
                return handle
            case .suppressed(.missingAsset), .suppressed(.invalidAudioData):
                lastHandle = handle
            }
        }
        return lastHandle
    }

    /// Plays a bundled `TUIAttentionAudio.SoundKind` non-blockingly through `player`.
    @discardableResult
    public static func playSound(
        kind: TUIAttentionAudio.SoundKind,
        volume: Double? = nil,
        player: TUIAttentionAudio.Player = .shared
    ) -> TUIAttentionAudio.Player.PlaybackHandle {
        player.playNonBlocking(kind: kind, volume: volume)
    }

    /// Disposes the shared OpenTUI `Audio` engine, cancels active native audio tasks, and clears cached sounds.
    // parity: tui/src/audio.ts#dispose [status=implemented hash=f26596009941]
    public static func dispose() {
        TUIAttentionAudio.Player.shared.cancelAll()
        let engine: Audio? = audioState.withLock { box in
            let current = box.engine
            box.engine = nil
            box.attempted = false
            box.cache.removeAll()
            box.nativePaths.removeAll()
            box.nextNativeSoundID = 0x8000_0001
            box.nextNativeVoiceID = 0x8000_0001
            return current
        }
        engine?.dispose()
    }

    /// Narrow renderer boundary consumed by `createTuiAttention`.
    public protocol AttentionRenderer: AnyObject, Sendable {
        var isDestroyed: Bool { get }
        func addFocusListener(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void
        func addBlurListener(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void
        func triggerNotification(_ message: String, title: String?) -> Bool
    }

    /// Adapter bridging an OpenTUI `CliRenderer` to `AttentionRenderer`.
    public final class CliAttentionRendererAdapter: AttentionRenderer, @unchecked Sendable {
        private let renderer: CliRenderer

        public init(renderer: CliRenderer) {
            self.renderer = renderer
        }

        public var isDestroyed: Bool { renderer.isDestroyed }

        public func addFocusListener(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
            let token = renderer.on(.focus) { listener() }
            let r = renderer
            return { r.off(token) }
        }

        public func addBlurListener(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
            let token = renderer.on(.blur) { listener() }
            let r = renderer
            return { r.off(token) }
        }

        public func triggerNotification(_ message: String, title: String?) -> Bool {
            renderer.triggerNotification(message, title: title)
        }
    }

    /// Injectable audio backend for `createTuiAttention`.
    public struct AudioBackend: Sendable {
        public let loadSoundFile: @Sendable (String) async -> AudioSound?
        public let play: @Sendable (AudioSound, AudioPlayOptions) -> AudioVoice?

        public init(
            loadSoundFile: @escaping @Sendable (String) async -> AudioSound? = TUIAttention.loadSoundFile,
            play: @escaping @Sendable (AudioSound, AudioPlayOptions) -> AudioVoice? = TUIAttention.play
        ) {
            self.loadSoundFile = loadSoundFile
            self.play = play
        }

        /// Creates an isolated `AudioBackend` backed by a specific `TUIAttentionAudio.Player` instance
        /// without mutating global audio state.
        public static func native(
            player: TUIAttentionAudio.Player = .shared,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
        ) -> AudioBackend {
            struct HandleTable: Sendable {
                var byPath: [String: AudioSound] = [:]
                var byHandle: [AudioSound: String] = [:]
                var nextSoundID: AudioSound = 1
                var nextVoiceID: AudioVoice = 1
            }
            let table = Mutex(HandleTable())
            return AudioBackend(
                loadSoundFile: { file in
                    if let cached = table.withLock({ $0.byPath[file] }) {
                        return cached
                    }
                    let resolved = TUIAttentionAudio.resolveBundledFilePath(file)
                    let status = await player.validateAudioFile(at: resolved, fileSystem: fileSystem)
                    guard status == .valid else {
                        return nil
                    }
                    return table.withLock { t in
                        if let existing = t.byPath[file] {
                            return existing
                        }
                        let handle = t.nextSoundID
                        t.nextSoundID &+= 1
                        t.byPath[file] = handle
                        t.byHandle[handle] = resolved
                        return handle
                    }
                },
                play: { sound, options in
                    guard let path = table.withLock({ $0.byHandle[sound] }) else {
                        return nil
                    }
                    let playback = player.playNonBlocking(filePath: path, volume: options.volume)
                    guard playback.outcome.didTriggerFeedback else {
                        return nil
                    }
                    return table.withLock { t in
                        let voice = t.nextVoiceID
                        t.nextVoiceID &+= 1
                        return voice
                    }
                }
            )
        }
    }

    /// Disposable host handle returned by `createTuiAttention`.
    public struct AttentionHost: Sendable {
        public let attention: PluginTui.Attention
        public let dispose: @Sendable () -> Void

        public init(attention: PluginTui.Attention, dispose: @escaping @Sendable () -> Void) {
            self.attention = attention
            self.dispose = dispose
        }

        public func notify(_ options: PluginTui.AttentionNotifyOptions) async -> PluginTui.AttentionNotifyResult {
            await attention.notify(options)
        }
    }

    private enum FocusState: Sendable {
        case unknown
        case focused
        case blurred
    }

    private static let defaultTitle = "OpenCode"
    private static let titleLimit = 80
    private static let messageLimit = 240

    private static let builtinSounds: [PluginTui.AttentionSoundName: String] = [
        .default: defaultSoundPath,
        .question: questionSoundPath,
        .permission: permissionSoundPath,
        .error: errorSoundPath,
        .done: defaultSoundPath,
        .subagentDone: subagentDoneSoundPath,
    ]

    private static func normalizeText(_ input: String?, fallback: String, limit: Int) -> String {
        let stripped = stripAnsiSequences(input ?? "")
        // Collapse CR/LF surrounded by horizontal whitespace into a single space, drop C0/C1 control chars.
        var collapsed = ""
        let scalars = Array(stripped.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let v = scalars[i].value
            if v == 0x20 || v == 0x09 {
                var j = i
                while j < scalars.count && (scalars[j].value == 0x20 || scalars[j].value == 0x09) { j += 1 }
                if j < scalars.count && (scalars[j].value == 0x0A || scalars[j].value == 0x0D) {
                    while j < scalars.count && (scalars[j].value == 0x0A || scalars[j].value == 0x0D) { j += 1 }
                    while j < scalars.count && (scalars[j].value == 0x20 || scalars[j].value == 0x09) { j += 1 }
                    collapsed.append(" ")
                    i = j
                    continue
                }
                collapsed.unicodeScalars.append(scalars[i])
                i += 1
            } else if v == 0x0A || v == 0x0D {
                var j = i + 1
                while j < scalars.count && (scalars[j].value == 0x0A || scalars[j].value == 0x0D) { j += 1 }
                while j < scalars.count && (scalars[j].value == 0x20 || scalars[j].value == 0x09) { j += 1 }
                collapsed.append(" ")
                i = j
            } else if (v <= 0x09) || v == 0x0B || v == 0x0C || (v >= 0x0E && v <= 0x1F) || (v >= 0x7F && v <= 0x9F) {
                i += 1
            } else {
                collapsed.unicodeScalars.append(scalars[i])
                i += 1
            }
        }
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? fallback : trimmed
        return String(normalized.unicodeScalars.prefix(limit))
    }

    private static func clampVolume(_ volume: Double) -> Double {
        guard volume.isFinite else { return 0 }
        return min(1.0, max(0.0, volume))
    }

    private static func focusSkip(_ when: PluginTui.AttentionWhen, focus: FocusState) -> PluginTui.AttentionNotifySkipReason? {
        switch when {
        case .always: return nil
        case .blurred:
            switch focus {
            case .unknown: return .focusUnknown
            case .focused: return .focused
            case .blurred: return nil
            }
        case .focused:
            switch focus {
            case .unknown: return .focusUnknown
            case .blurred: return .blurred
            case .focused: return nil
            }
        }
    }

    private static func skipped(_ reason: PluginTui.AttentionNotifySkipReason) -> PluginTui.AttentionNotifyResult {
        PluginTui.AttentionNotifyResult(ok: false, notification: false, sound: false, skipped: reason)
    }

    /// Creates a focus-aware TUI attention host coordinating terminal OSC notifications and audio cues.
    // parity: tui/src/attention.ts#createTuiAttention [status=implemented hash=d3cc34e2cecd]
    public static func createTuiAttention(
        renderer: any AttentionRenderer,
        config: TUIConfig.ResolvedAttention,
        audio: AudioBackend = AudioBackend()
    ) -> AttentionHost {
        struct State: Sendable {
            var focus: FocusState = .unknown
            var disposed: Bool = false
        }
        let state = Mutex(State())
        let offFocus = renderer.addFocusListener {
            state.withLock { $0.focus = .focused }
        }
        let offBlur = renderer.addBlurListener {
            state.withLock { $0.focus = .blurred }
        }

        let attention = PluginTui.Attention { request in
            if !config.notifications && !config.sound {
                return skipped(.attentionDisabled)
            }
            let snapshot = state.withLock { $0 }
            if snapshot.disposed || renderer.isDestroyed {
                return skipped(.rendererDestroyed)
            }
            let message = normalizeText(request.message, fallback: "", limit: messageLimit)
            if message.isEmpty {
                return skipped(.emptyMessage)
            }

            let requestedNotifWhen: PluginTui.AttentionWhen
            let notifExplicitOff: Bool
            switch request.notification {
            case .enabled(false):
                notifExplicitOff = true
                requestedNotifWhen = .blurred
            case .configured(let when):
                notifExplicitOff = false
                requestedNotifWhen = when ?? .blurred
            case .enabled(true), nil:
                notifExplicitOff = false
                requestedNotifWhen = .blurred
            }
            let notificationSkip = focusSkip(requestedNotifWhen, focus: snapshot.focus)
            let notificationRequested = config.notifications && !notifExplicitOff
            let shouldNotify = notificationRequested && notificationSkip == nil
            let notification: Bool
            if shouldNotify {
                let title = normalizeText(request.title, fallback: defaultTitle, limit: titleLimit)
                notification = renderer.triggerNotification(message, title: title)
            } else {
                notification = false
            }

            let soundVolume: Double?
            let requestedSoundWhen: PluginTui.AttentionWhen
            let soundName: PluginTui.AttentionSoundName
            if !config.sound {
                soundVolume = nil
                requestedSoundWhen = .always
                soundName = .default
            } else {
                switch request.sound {
                case .enabled(false):
                    soundVolume = nil
                    requestedSoundWhen = .always
                    soundName = .default
                case .enabled(true), nil:
                    soundVolume = clampVolume(config.volume)
                    requestedSoundWhen = .always
                    soundName = .default
                case .configured(let name, let volume, let when):
                    soundVolume = clampVolume(volume ?? config.volume)
                    requestedSoundWhen = when ?? .always
                    soundName = name ?? .default
                }
            }
            let soundSkip = soundVolume == nil ? nil : focusSkip(requestedSoundWhen, focus: snapshot.focus)

            var soundPlayed = false
            if let vol = soundVolume, soundSkip == nil {
                var candidates: [String] = []
                if let overridePath = config.sounds[soundName], !overridePath.isEmpty {
                    candidates.append(overridePath)
                }
                if let builtin = builtinSounds[soundName], !candidates.contains(builtin) {
                    candidates.append(builtin)
                }
                for file in candidates {
                    if let loaded = await audio.loadSoundFile(file) {
                        if state.withLock({ $0.disposed }) { break }
                        if audio.play(loaded, AudioPlayOptions(volume: vol)) != nil {
                            soundPlayed = true
                            break
                        }
                    }
                }
            }

            if !notification && !soundPlayed {
                if notificationRequested, let skip = notificationSkip {
                    return skipped(skip)
                }
                if let skip = soundSkip {
                    return skipped(skip)
                }
            }
            return PluginTui.AttentionNotifyResult(
                ok: notification || soundPlayed,
                notification: notification,
                sound: soundPlayed,
                skipped: nil
            )
        }

        return AttentionHost(attention: attention) {
            let shouldDispose = state.withLock { s -> Bool in
                if s.disposed { return false }
                s.disposed = true
                return true
            }
            if shouldDispose {
                offFocus()
                offBlur()
            }
        }
    }

    /// Convenience overload wiring `createTuiAttention` directly to an injectable `TUIAttentionAudio.Player`.
    public static func createTuiAttention(
        renderer: any AttentionRenderer,
        config: TUIConfig.ResolvedAttention,
        player: TUIAttentionAudio.Player
    ) -> AttentionHost {
        createTuiAttention(
            renderer: renderer,
            config: config,
            audio: .native(player: player)
        )
    }
}

// MARK: - Model Preference (`packages/tui/src/model-preference.ts`)

/// Model recent/favorite/variant preference resolution and file-locked persistence.
public enum TUIModelPreference {
    // parity: tui/src/model-preference.ts#ModelPreferenceModel [status=implemented hash=427d14bd957a]
    public struct ModelPreferenceModel: Equatable, Hashable, Sendable, Codable {
        public var providerID: String
        public var modelID: String

        public init(providerID: String, modelID: String) {
            self.providerID = providerID
            self.modelID = modelID
        }
    }

    // parity: tui/src/model-preference.ts#ModelPreference [status=implemented hash=14d3efffbadf]
    public struct ModelPreference: Equatable, Hashable, Sendable, Codable {
        public var recent: [ModelPreferenceModel]
        public var favorite: [ModelPreferenceModel]
        public var variant: [String: String]

        public init(
            recent: [ModelPreferenceModel] = [],
            favorite: [ModelPreferenceModel] = [],
            variant: [String: String] = [:]
        ) {
            self.recent = recent
            self.favorite = favorite
            self.variant = variant
        }
    }

    // parity: tui/src/model-preference.ts#ModelPreferenceDocument [status=implemented hash=6a117ed66b84]
    public struct ModelPreferenceDocument: Equatable, Sendable {
        public var extra: [String: JSONValue]
        public var preference: ModelPreference

        public var recent: [ModelPreferenceModel] {
            get { preference.recent }
            set { preference.recent = newValue }
        }
        public var favorite: [ModelPreferenceModel] {
            get { preference.favorite }
            set { preference.favorite = newValue }
        }
        public var variant: [String: String] {
            get { preference.variant }
            set { preference.variant = newValue }
        }

        public init(extra: [String: JSONValue] = [:], preference: ModelPreference = ModelPreference()) {
            self.extra = extra
            self.preference = preference
        }

        public func toJSONObject() -> [String: JSONValue] {
            var dict = extra
            dict["recent"] = .array(preference.recent.map {
                .object(["providerID": .string($0.providerID), "modelID": .string($0.modelID)])
            })
            dict["favorite"] = .array(preference.favorite.map {
                .object(["providerID": .string($0.providerID), "modelID": .string($0.modelID)])
            })
            dict["variant"] = .object(preference.variant.mapValues { .string($0) })
            return dict
        }
    }

    /// Normalizes explicit `"default"` variant marker to `nil` (agent/provider default).
    // parity: tui/src/model-preference.ts#normalizeModelVariant [status=implemented hash=9cdee10dd524]
    public static func normalizeModelVariant(_ value: String?) -> String? {
        value == "default" ? nil : value
    }

    /// Canonical `providerID/modelID` preference key.
    // parity: tui/src/model-preference.ts#modelPreferenceKey [status=implemented hash=a26366988bbd]
    public static func modelPreferenceKey(_ model: ModelPreferenceModel) -> String {
        "\(model.providerID)/\(model.modelID)"
    }

    /// Prepends `model` to `recent`, deduplicating by `providerID/modelID` and capping at 10 entries.
    // parity: tui/src/model-preference.ts#recentModels [status=implemented hash=14bfdbd596a5]
    public static func recentModels(
        _ model: ModelPreferenceModel,
        recent: [ModelPreferenceModel]
    ) -> [ModelPreferenceModel] {
        var seen = Set<String>()
        var result: [ModelPreferenceModel] = []
        for item in [model] + recent {
            let key = modelPreferenceKey(item)
            if seen.insert(key).inserted {
                result.append(ModelPreferenceModel(providerID: item.providerID, modelID: item.modelID))
                if result.count == 10 { break }
            }
        }
        return result
    }

    /// Adds or removes `model` from the favorite list.
    // parity: tui/src/model-preference.ts#favoriteModels [status=implemented hash=00b23996a333]
    public static func favoriteModels(
        _ model: ModelPreferenceModel,
        favorite: [ModelPreferenceModel],
        enabled: Bool
    ) -> [ModelPreferenceModel] {
        let key = modelPreferenceKey(model)
        let filtered = favorite.filter { modelPreferenceKey($0) != key }
        return enabled ? [model] + filtered : filtered
    }

    /// Cycles through named model variants (`nil -> named[0] -> ... -> named.last -> nil`).
    // parity: tui/src/model-preference.ts#cycleModelVariant [status=implemented hash=9b55bf6ccd9a]
    public static func cycleModelVariant(_ current: String?, variants: [String]) -> String? {
        let named = variants.filter { $0 != "default" }
        guard !named.isEmpty else { return nil }
        guard let value = normalizeModelVariant(current) else {
            return named[0]
        }
        guard let index = named.firstIndex(of: value), index < named.count - 1 else {
            return nil
        }
        return named[index + 1]
    }

    private static func decodeModels(_ value: JSONValue?) -> [ModelPreferenceModel] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item in
            guard case .object(let dict) = item,
                  case .string(let providerID) = dict["providerID"], !providerID.isEmpty,
                  case .string(let modelID) = dict["modelID"], !modelID.isEmpty
            else { return nil }
            return ModelPreferenceModel(providerID: providerID, modelID: modelID)
        }
    }

    private static func decodeVariants(_ value: JSONValue?) -> [String: String] {
        guard case .object(let dict) = value else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in dict where !k.isEmpty {
            if case .string(let s) = v, !s.isEmpty {
                out[k] = s
            }
        }
        return out
    }

    /// Decodes an untrusted `JSONValue` into a `ModelPreferenceDocument`, preserving unknown fields.
    // parity: tui/src/model-preference.ts#decodeModelPreference [status=implemented hash=e44e114ad5e0]
    public static func decodeModelPreference(_ value: JSONValue?) -> ModelPreferenceDocument {
        let root: [String: JSONValue]
        if case .object(let dict) = value {
            root = dict
        } else {
            root = [:]
        }
        let pref = ModelPreference(
            recent: decodeModels(root["recent"]),
            favorite: decodeModels(root["favorite"]),
            variant: decodeVariants(root["variant"])
        )
        return ModelPreferenceDocument(extra: root, preference: pref)
    }

    /// Repository handle returned by `createModelPreferenceRepository`.
    public final class Repository: @unchecked Sendable {
        public let filePath: String
        private let fs: any OpenCodeFileSystem
        private let listeners = Mutex<[UInt64: @Sendable (ModelPreference) -> Void]>([:])
        private let nextID = Mutex<UInt64>(1)
        private let lockDir: String

        public init(filePath: String, fs: any OpenCodeFileSystem = LocalFileSystem.shared) {
            self.filePath = filePath
            self.fs = fs
            let parent = getDirectory(filePath)
            self.lockDir = parent.isEmpty ? "locks" : "\(parent)/locks"
        }

        private func readDocument() async -> ModelPreferenceDocument {
            guard let bytes = try? await fs.readFile(at: filePath),
                  let json = try? JSONDecoder().decode(JSONValue.self, from: Data(bytes))
            else {
                return decodeModelPreference(nil)
            }
            return decodeModelPreference(json)
        }

        public func load() async -> ModelPreference {
            await readDocument().preference
        }

        private func update(_ mutate: @escaping @Sendable (ModelPreference) -> ModelPreference) async throws {
            let path = self.filePath
            let fs = self.fs
            try await Flock.withLock(path, options: Flock.Options(dir: lockDir)) {
                var doc = await self.readDocument()
                doc.preference = mutate(doc.preference)
                let data = try JSONEncoder().encode(JSONValue.object(doc.toJSONObject()))
                try await fs.writeFile(Array(data), to: path, createDirectories: true)
            }
            let updated = await readDocument().preference
            let snapshot = listeners.withLock { Array($0.values) }
            for listener in snapshot {
                listener(updated)
            }
        }

        public func addRecent(_ model: ModelPreferenceModel) async throws {
            try await update { current in
                var next = current
                next.recent = recentModels(model, recent: current.recent)
                return next
            }
        }

        public func setFavorite(_ model: ModelPreferenceModel, enabled: Bool) async throws {
            try await update { current in
                var next = current
                next.favorite = favoriteModels(model, favorite: current.favorite, enabled: enabled)
                return next
            }
        }

        public func subscribe(_ listener: @escaping @Sendable (ModelPreference) -> Void) -> @Sendable () -> Void {
            let id = nextID.withLock { val -> UInt64 in
                let cur = val
                val &+= 1
                return cur
            }
            listeners.withLock { $0[id] = listener }
            Task { [weak self] in
                guard let self else { return }
                let value = await self.load()
                listener(value)
            }
            return { [weak self] in
                _ = self?.listeners.withLock { $0.removeValue(forKey: id) }
            }
        }

        public func resolveVariant(for model: ModelPreferenceModel) async -> String? {
            let pref = await load()
            return normalizeModelVariant(pref.variant[modelPreferenceKey(model)])
        }

        public func saveVariant(_ model: ModelPreferenceModel, value: String?) async throws {
            let key = modelPreferenceKey(model)
            let stored = normalizeModelVariant(value) ?? "default"
            try await update { current in
                var next = current
                next.variant[key] = stored
                return next
            }
        }
    }

    /// Creates a file-locked persistent repository for `model.json` preferences.
    // parity: tui/src/model-preference.ts#createModelPreferenceRepository [status=implemented hash=397b41a513da]
    public static func createModelPreferenceRepository(
        _ filePath: String,
        fs: any OpenCodeFileSystem = LocalFileSystem.shared
    ) -> Repository {
        Repository(filePath: filePath, fs: fs)
    }
}

// MARK: - Editor & Zed Integration (`packages/tui/src/editor*.ts`)

/// External editor spawning, IDE lock-file discovery, and Zed SQLite selection resolution.
public enum TUIEditor {
    public enum EditorError: Error, Equatable, Sendable, CustomStringConvertible {
        case missingEditorEnvironment
        case editorExited(code: Int32)

        public var description: String {
            switch self {
            case .missingEditorEnvironment:
                return "Set $VISUAL or $EDITOR to open an external editor"
            case .editorExited(let code):
                return "Editor exited with code \(code)"
            }
        }
    }

    /// Read-only SQLite wrapper used for Zed editor workspace selection queries.
    // parity: tui/src/editor-zed-sqlite.node.ts#Database [status=adapted hash=869051fa4c3a]
    public final class Database: @unchecked Sendable {
        private let db: any SQLiteDatabase

        public init(_ file: String, readonly: Bool = true) throws {
            self.db = try SQLiteDatabaseFactory.open(
                path: file,
                options: SQLiteOpenOptions(readOnly: readonly, createIfMissing: false)
            )
        }

        public struct QueryHandle {
            private let db: any SQLiteDatabase
            private let sql: String

            init(db: any SQLiteDatabase, sql: String) {
                self.db = db
                self.sql = sql
            }

            public func all(_ parameters: [SQLiteValue] = []) throws -> [SQLiteRow] {
                try db.query(sql, parameters: parameters)
            }

            public func get(_ parameters: [SQLiteValue] = []) throws -> SQLiteRow? {
                try db.queryOne(sql, parameters: parameters)
            }
        }

        // parity: tui/src/editor-zed-sqlite.node.ts#Database.query [status=implemented hash=a7ecf730cf1f]
        public func query(_ sql: String) -> QueryHandle {
            QueryHandle(db: db, sql: sql)
        }

        // parity: tui/src/editor-zed-sqlite.node.ts#Database.close [status=implemented hash=9f98a788d0cb]
        public func close() {
            try? db.close()
        }
    }

    /// Outcome of querying Zed's active editor selection database.
    // parity: tui/src/editor-zed.ts#ZedSelectionResult [status=implemented hash=2fa592d9b3d7]
    public enum ZedSelectionResult: Equatable, Hashable, Sendable {
        case selection(TUIContext.EditorSelection)
        case empty
        case unavailable
    }

    public static func currentWorkingDirectory() -> String {
        #if os(WASI)
        return "/"
        #else
        return FileManager.default.currentDirectoryPath
        #endif
    }

    /// Resolves the active Zed editor selection for `cwd` from a Zed SQLite database path.
    // parity: tui/src/editor-zed.ts#resolveZedSelection [status=implemented hash=418424228ae2]
    public static func resolveZedSelection(
        dbPath: String,
        cwd: String = TUIEditor.currentWorkingDirectory(),
        fs: any OpenCodeFileSystem = LocalFileSystem.shared
    ) async -> ZedSelectionResult {
        guard !dbPath.isEmpty, let db = try? Database(dbPath, readonly: true) else {
            return .unavailable
        }
        defer { db.close() }

        let sql = """
        select
          i.kind as item_kind,
          e.item_id as editor_id,
          i.workspace_id as workspace_id,
          w.paths as workspace_paths,
          w.timestamp as timestamp,
          e.buffer_path as buffer_path
        from items i
        join panes p on p.pane_id = i.pane_id and p.workspace_id = i.workspace_id
        join workspaces w on w.workspace_id = i.workspace_id
        left join editors e on e.item_id = i.item_id and e.workspace_id = i.workspace_id
        where i.active = 1 and p.active = 1
        order by w.timestamp desc
        """
        guard let rawRows = try? db.query(sql).all() else {
            return .unavailable
        }

        struct EditorRow {
            let itemKind: String
            let editorID: Int64?
            let workspaceID: Int64
            let workspacePaths: String?
            let timestamp: String
            let bufferPath: String?
        }

        let rows: [EditorRow] = rawRows.compactMap { row in
            guard let itemKind = row.string("item_kind"),
                  let workspaceID = row.int64("workspace_id"),
                  let timestamp = row.string("timestamp")
            else { return nil }
            return EditorRow(
                itemKind: itemKind,
                editorID: row.int64("editor_id"),
                workspaceID: workspaceID,
                workspacePaths: row.string("workspace_paths"),
                timestamp: timestamp,
                bufferPath: row.string("buffer_path")
            )
        }
        if !rawRows.isEmpty && rows.isEmpty { return .unavailable }

        let scored = rows
            .map { (row: $0, score: scoreZedWorkspace($0.workspacePaths, cwd: cwd)) }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.row.timestamp > rhs.row.timestamp
            }
        guard let best = scored.first?.row else { return .empty }
        guard best.itemKind == "Editor" else { return .unavailable }
        guard let editorID = best.editorID else { return .empty }
        guard let bufferPath = best.bufferPath, !bufferPath.isEmpty else { return .empty }

        let selSQL = """
        select start as selection_start, end as selection_end
        from editor_selections
        where editor_id = ? and workspace_id = ?
        """
        guard let selRows = try? db.query(selSQL).all([.integer(editorID), .integer(best.workspaceID)]) else {
            return .unavailable
        }
        var byteRanges: [(start: Int, end: Int)] = []
        for sRow in selRows {
            if let s = sRow.int64("selection_start"), let e = sRow.int64("selection_end") {
                byteRanges.append((start: Int(min(s, e)), end: Int(max(s, e))))
            }
        }
        byteRanges.sort { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        if byteRanges.isEmpty { return .unavailable }

        let contentsSQL = "select contents from editors where item_id = ? and workspace_id = ?"
        let dbContents = (try? db.query(contentsSQL).get([.integer(editorID), .integer(best.workspaceID)]))?.string("contents")
        let text: String
        if let dbContents {
            text = dbContents
        } else if let bytes = try? await fs.readFile(at: bufferPath) {
            text = String(decoding: bytes, as: UTF8.self)
        } else {
            return .unavailable
        }

        let ranges = byteRanges.map { range -> TUIContext.EditorSelectionRange in
            let startUTF16 = utf8ByteOffsetToUTF16Index(text, byteOffset: range.start)
            let endUTF16 = utf8ByteOffsetToUTF16Index(text, byteOffset: range.end)
            let utf16 = Array(text.utf16)
            let clampedStart = max(0, min(startUTF16, utf16.count))
            let clampedEnd = max(clampedStart, min(endUTF16, utf16.count))
            let slice = String(decoding: utf16[clampedStart..<clampedEnd], as: UTF16.self)
            return TUIContext.EditorSelectionRange(
                text: slice,
                selection: utf16OffsetsToSelection(utf16, start: clampedStart, end: clampedEnd)
            )
        }
        return .selection(TUIContext.EditorSelection(filePath: bufferPath, source: .zed, ranges: ranges))
    }

    /// Locates the default Zed SQLite database path from `OPENCODE_ZED_DB` or standard OS locations.
    // parity: tui/src/editor-zed.ts#resolveZedDbPath [status=implemented hash=6ddb9a8c5daf]
    public static func resolveZedDbPath(
        env: any EnvironmentProviding = SystemEnvironment.shared
    ) -> String? {
        let home = env.homeDirectory ?? ""
        var candidates: [String] = []
        if let overridePath = env.variable("OPENCODE_ZED_DB"), !overridePath.isEmpty {
            candidates.append(overridePath)
        }
        if !home.isEmpty {
            candidates.append("\(home)/Library/Application Support/Zed/db/0-stable/db.sqlite")
            candidates.append("\(home)/.local/share/zed/db/0-stable/db.sqlite")
        }
        #if os(WASI)
        return nil
        #else
        return candidates.first { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
        }
        #endif
    }

    private static func scoreZedWorkspace(_ workspacePaths: String?, cwd: String) -> Int {
        guard let workspacePaths, !workspacePaths.isEmpty else { return 0 }
        let items: [String]
        if let data = workspacePaths.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data)
        {
            items = decoded
        } else {
            items = workspacePaths.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        }
        var best = 0
        for item in items where containsDirectory(item, cwd) {
            best = max(best, comparablePath(item).count)
        }
        return best
    }

    private static func utf8ByteOffsetToUTF16Index(_ text: String, byteOffset: Int) -> Int {
        if byteOffset <= 0 { return 0 }
        var bytes = 0
        var utf16Index = 0
        for scalar in text.unicodeScalars {
            let nextUTF16 = utf16Index + (scalar.value > 0xFFFF ? 2 : 1)
            bytes += scalar.utf8.count
            if bytes >= byteOffset { return nextUTF16 }
            utf16Index = nextUTF16
        }
        return utf16Index
    }

    private static func utf16OffsetsToSelection(_ utf16: [UInt16], start: Int, end: Int) -> TUIContext.EditorSelectionSpan {
        var line = 1
        var lineStart = 0
        var startPos = TUIContext.EditorPosition(line: 1, character: start + 1)
        var endPos = TUIContext.EditorPosition(line: 1, character: end + 1)
        for index in 0...end {
            if index == start {
                startPos = TUIContext.EditorPosition(line: line, character: index - lineStart + 1)
            }
            if index == end {
                endPos = TUIContext.EditorPosition(line: line, character: index - lineStart + 1)
                break
            }
            if index < utf16.count && utf16[index] == 0x0A {
                line += 1
                lineStart = index + 1
            }
        }
        return TUIContext.EditorSelectionSpan(start: startPos, end: endPos)
    }

    /// Suspends `renderer`, opens `$VISUAL` or `$EDITOR` on a temporary markdown buffer, and returns the edited text.
    // parity: tui/src/editor.ts#openEditor [status=adapted hash=ad9b88ad3217]
    public static func openEditor(
        value: String,
        renderer: CliRenderer,
        cwd: String? = nil,
        env: any EnvironmentProviding = SystemEnvironment.shared,
        fs: any OpenCodeFileSystem = LocalFileSystem.shared,
        spawner: any ProcessSpawner = CrossSpawnSpawner.HostProcessSpawner.shared
    ) async throws -> String? {
        let editorCmd = env.variable("VISUAL").flatMap { $0.isEmpty ? nil : $0 }
            ?? env.variable("EDITOR").flatMap { $0.isEmpty ? nil : $0 }
        guard let editorCmd else {
            throw EditorError.missingEditorEnvironment
        }
        let tempDir = env.temporaryDirectory
        let stamp = Flock.currentEpochMs()
        let file = tempDir.hasSuffix("/") ? "\(tempDir)\(stamp).md" : "\(tempDir)/\(stamp).md"
        try await fs.writeFile(Array(value.utf8), to: file, createDirectories: true)
        renderer.suspend()
        let result: String?
        do {
            let parts = editorCmd.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let executable = parts.first else {
                throw EditorError.missingEditorEnvironment
            }
            let workdir: String?
            if let cwd, await fs.exists(at: cwd) {
                workdir = cwd
            } else {
                workdir = currentWorkingDirectory()
            }
            let output = try await spawner.run(ProcessSpec(
                executable: executable,
                arguments: Array(parts.dropFirst()) + [file],
                workingDirectory: workdir
            ))
            if output.exitCode != 0 {
                throw EditorError.editorExited(code: output.exitCode)
            }
            let readBytes = (try? await fs.readFile(at: file)) ?? []
            let text = String(decoding: readBytes, as: UTF8.self)
            result = text.isEmpty ? nil : text
        } catch {
            try? await fs.remove(at: file)
            renderer.resume()
            throw error
        }
        try? await fs.remove(at: file)
        renderer.resume()
        return result
    }

    /// Discovers an active IDE WebSocket connection lock file under `~/.claude/ide/*.lock` matching `directory`.
    // parity: tui/src/editor.ts#discoverEditorConnection [status=implemented hash=d4c9e0731fad]
    public static func discoverEditorConnection(
        directory: String,
        env: any EnvironmentProviding = SystemEnvironment.shared
    ) -> TUIContext.EditorConnection? {
        #if os(WASI)
        return nil
        #else
        guard let home = env.homeDirectory, !home.isEmpty else { return nil }
        let root = "\(home)/.claude/ide"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
        struct Candidate {
            let connection: TUIContext.EditorConnection
            let score: Int
            let order: String
        }
        var candidates: [Candidate] = []
        for entry in entries where entry.hasSuffix(".lock") {
            let base = String(entry.dropLast(5))
            guard let port = Int(base), port > 0 && port <= 65535 else { continue }
            let file = "\(root)/\(entry)"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
                  let json = try? JSONDecoder().decode(JSONValue.self, from: data),
                  case .object(let dict) = json
            else { continue }
            if let transport = dict["transport"] {
                if case .string(let t) = transport, t == "ws" {
                    // valid
                } else {
                    continue
                }
            }
            var bestScore = 0
            if case .array(let folders) = dict["workspaceFolders"] {
                for folder in folders {
                    if case .string(let f) = folder, containsDirectory(f, directory) {
                        bestScore = max(bestScore, comparablePath(f).count)
                    }
                }
            }
            guard bestScore > 0 else { continue }
            let authToken: String?
            if case .string(let tok) = dict["authToken"] { authToken = tok } else { authToken = nil }
            candidates.append(Candidate(
                connection: TUIContext.EditorConnection(
                    url: "ws://127.0.0.1:\(port)",
                    authToken: authToken,
                    source: "lock:\(port)"
                ),
                score: bestScore,
                order: entry
            ))
        }
        return candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.order > rhs.order
        }.first?.connection
        #endif
    }

    /// Default editor integration combining IDE lock discovery and Zed SQLite selection resolution.
    // parity: tui/src/editor.ts#editorIntegration [status=implemented hash=c498fd50b7fe]
    public static let editorIntegration = TUIContext.EditorIntegration(
        connection: { directory in
            discoverEditorConnection(directory: directory)
        },
        selection: { directory in
            await resolveZedSelection(dbPath: resolveZedDbPath() ?? "", cwd: directory)
        }
    )
}

// MARK: - TUI App, Clipboard Adapter, DevTools & Simulation Semantics

/// Top-level TUI application bootstrap, clipboard bridge, DevTools registry, and simulation semantics.
public enum TUIApp {
    // MARK: - Clipboard (`packages/tui/src/clipboard.ts`)

    public enum ClipboardError: Error, Equatable, Sendable, CustomStringConvertible {
        case timedOut
        case unsupported
        case limitExceeded
        case unexpectedMimeType(String)
        case readFailed(String)
        case writeFailed(host: String, terminal: String)

        public var description: String {
            switch self {
            case .timedOut: return "Clipboard read timed out"
            case .unsupported: return "Clipboard read is not supported on this system"
            case .limitExceeded: return "Clipboard content exceeded configured read or image conversion limits"
            case .unexpectedMimeType(let mime): return "Unexpected clipboard MIME type: \(mime)"
            case .readFailed(let msg): return msg
            case .writeFailed(let host, let terminal):
                return "Clipboard write failed (host: \(host), terminal: \(terminal))"
            }
        }
    }

    /// TUI clipboard service with explicit `dispose()` ownership.
    // parity: tui/src/clipboard.ts#OwnedClipboardService [status=implemented hash=96ac72b78f5f]
    public struct OwnedClipboardService: Sendable {
        public let service: TUIContext.ClipboardService
        public let dispose: @Sendable () async throws -> Void

        public init(
            service: TUIContext.ClipboardService,
            dispose: @escaping @Sendable () async throws -> Void
        ) {
            self.service = service
            self.dispose = dispose
        }

        public func read() async throws -> TUIContext.ClipboardContent? {
            try await service.read()
        }

        public func write(_ text: String) async throws {
            try await service.write(text)
        }
    }

    /// Creates a TUI clipboard backed by OpenTUI's host clipboard and terminal OSC 52 adapter.
    // parity: tui/src/clipboard.ts#createTuiClipboard [status=implemented hash=0e3a20bc361d]
    public static func createTuiClipboard(_ renderer: any RendererClipboardBoundary) throws -> OwnedClipboardService {
        let host = try createHostClipboard()
        let terminal = createRendererClipboardAdapter(renderer)
        let composed = createClipboard(ClipboardOptions(host: host, terminal: terminal))
        return createClipboardAdapter(composed)
    }

    /// Adapts an OpenTUI `ClipboardService` to the TUI's `OwnedClipboardService` boundary.
    // parity: tui/src/clipboard.ts#createClipboardAdapter [status=implemented hash=451d208be92a]
    public static func createClipboardAdapter(_ clipboard: any OpenTUICore.ClipboardService) -> OwnedClipboardService {
        let service = TUIContext.ClipboardService(
            read: {
                let result = try await clipboard.read(ClipboardReadOptions(
                    preferredTypes: ["image/png", "text/plain"],
                    selection: .clipboard
                ))
                switch result {
                case .read(let rep):
                    if rep.mimeType == "image/png" {
                        return TUIContext.ClipboardContent(data: bytesToBase64(rep.bytes), mime: rep.mimeType)
                    }
                    if rep.mimeType == "text/plain" {
                        if rep.bytes.isEmpty { return nil }
                        return TUIContext.ClipboardContent(data: decodePasteBytes(rep.bytes), mime: rep.mimeType)
                    }
                    throw ClipboardError.unexpectedMimeType(rep.mimeType)
                case .failed(let failure):
                    throw ClipboardError.readFailed(failure.message)
                case .timedOut:
                    throw ClipboardError.timedOut
                case .unsupported:
                    throw ClipboardError.unsupported
                case .limitExceeded:
                    throw ClipboardError.limitExceeded
                case .empty, .cancelled:
                    return nil
                }
            },
            write: { text in
                let sanitized = text.replacingOccurrences(of: "\u{0}", with: "")
                let result = try await clipboard.writeText(
                    sanitized,
                    options: ClipboardWriteOptions(destination: .allAvailable, selection: .clipboard)
                )
                if case .written = result.host { return }
                if result.terminal.status == .attempted { return }
                if case .failed(let failure) = result.host {
                    throw ClipboardError.readFailed(failure.message)
                }
                throw ClipboardError.writeFailed(
                    host: result.host.status,
                    terminal: result.terminal.status.rawValue
                )
            }
        )
        return OwnedClipboardService(service: service) {
            try await clipboard.dispose()
        }
    }

    // MARK: - DevTools (`packages/tui/src/devtools/index.ts`)

    public enum DevTools {
        /// Scalar telemetry value tracked in the TUI DevTools panel.
        // parity: tui/src/devtools/index.ts#Value [status=implemented hash=6099004a4bd9]
        public enum Value: Equatable, Hashable, Sendable, Codable {
            case string(String)
            case number(Double)
            case bool(Bool)
            case null
        }

        public struct Entry: Equatable, Hashable, Sendable, Codable {
            public let key: String
            public var value: Value

            public init(key: String, value: Value) {
                self.key = key
                self.value = value
            }
        }

        /// Named DevTools telemetry group.
        // parity: tui/src/devtools/index.ts#Group [status=implemented hash=7ba164964176]
        public struct Group: Equatable, Hashable, Sendable, Codable {
            public let id: String
            public var title: String
            public var entries: [Entry]

            public init(id: String, title: String, entries: [Entry] = []) {
                self.id = id
                self.title = title
                self.entries = entries
            }
        }

        public struct GroupHandle: Sendable {
            public let id: String
            private let setter: @Sendable (String, Value) -> Void

            init(id: String, setter: @escaping @Sendable (String, Value) -> Void) {
                self.id = id
                self.setter = setter
            }

            public func set(_ key: String, _ value: Value) {
                setter(key, value)
            }

            public func set(_ key: String, _ value: String) {
                setter(key, .string(value))
            }
        }

        private static let groupsStorage = Mutex<[Group]>([])

        /// Registers or updates a DevTools group and returns a handle for setting key/value telemetry.
        // parity: tui/src/devtools/index.ts#register [status=implemented hash=37f9d8f08be4]
        public static func register(id: String, title: String) -> GroupHandle {
            groupsStorage.withLock { groups in
                if let idx = groups.firstIndex(where: { $0.id == id }) {
                    groups[idx].title = title
                } else {
                    groups.append(Group(id: id, title: title, entries: []))
                }
            }
            return GroupHandle(id: id) { key, value in
                groupsStorage.withLock { groups in
                    guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
                    if let eIdx = groups[idx].entries.firstIndex(where: { $0.key == key }) {
                        groups[idx].entries[eIdx].value = value
                    } else {
                        groups[idx].entries.append(Entry(key: key, value: value))
                    }
                }
            }
        }

        /// Snapshot accessor for all registered DevTools telemetry groups.
        // parity: tui/src/devtools/index.ts#data [status=implemented hash=d02c5e07cc15]
        public static var data: [Group] {
            groupsStorage.withLock { $0 }
        }

        /// Resets all registered DevTools groups (for test isolation).
        public static func reset() {
            groupsStorage.withLock { $0.removeAll() }
        }
    }

    // MARK: - Simulation Semantics (`packages/tui/src/simulation/semantics.ts`)

    public struct SemanticDefinition: Equatable, Hashable, Sendable, Codable {
        public let instance: String?
        public let role: String
        public let label: String
        public let focused: Bool?
        public let selected: Bool?
        public let expanded: Bool?
        public let disabled: Bool?

        public init(
            instance: String? = nil,
            role: String,
            label: String,
            focused: Bool? = nil,
            selected: Bool? = nil,
            expanded: Bool? = nil,
            disabled: Bool? = nil
        ) {
            self.instance = instance
            self.role = role
            self.label = label
            self.focused = focused
            self.selected = selected
            self.expanded = expanded
            self.disabled = disabled
        }
    }

    /// Attaches semantic accessibility/simulation metadata to OpenTUI `Renderable` instances.
    // parity: tui/src/simulation/semantics.ts#SimulationSemantics [status=adapted hash=f6991e8c358d]
    public enum SimulationSemantics {
        private static let registry = Mutex<[ObjectIdentifier: @Sendable () -> SemanticDefinition]>([:])

        public static func bind(
            _ definition: @escaping @Sendable () -> SemanticDefinition
        ) -> @Sendable (Renderable) -> Void {
            { renderable in
                let key = ObjectIdentifier(renderable)
                registry.withLock { $0[key] = definition }
            }
        }

        public static func read(from renderable: Renderable) -> SemanticDefinition? {
            let key = ObjectIdentifier(renderable)
            let provider = registry.withLock { $0[key] }
            return provider?()
        }

        public static func unbind(_ renderable: Renderable) {
            let key = ObjectIdentifier(renderable)
            _ = registry.withLock { $0.removeValue(forKey: key) }
        }
    }

    // MARK: - App Entrypoint (`packages/tui/src/app.tsx`)

    public struct ServerEndpointConfig: Sendable {
        public let baseUrl: String
        public let headers: [String: String]
        public let local: Bool
        public let reconnect: (@Sendable (AbortSignal) async throws -> (url: String, headers: [String: String]))?
        public let restart: (@Sendable () async throws -> Void)?

        public init(
            baseUrl: String,
            headers: [String: String] = [:],
            local: Bool = true,
            reconnect: (@Sendable (AbortSignal) async throws -> (url: String, headers: [String: String]))? = nil,
            restart: (@Sendable () async throws -> Void)? = nil
        ) {
            self.baseUrl = baseUrl
            self.headers = headers
            self.local = local
            self.reconnect = reconnect
            self.restart = restart
        }
    }

    public struct TerminalHandoff: @unchecked Sendable {
        public let renderer: CliRenderer
        public let mode: Mode?
        public let complete: @Sendable () -> Void

        public init(renderer: CliRenderer, mode: Mode? = nil, complete: @escaping @Sendable () -> Void = {}) {
            self.renderer = renderer
            self.mode = mode
            self.complete = complete
        }
    }

    /// Launch configuration accepted by `TUIApp.run(_:)`.
    // parity: tui/src/app.tsx#TuiInput [status=adapted hash=9d3b60a57a59]
    public struct TuiInput: Sendable {
        public let app: TUIContext.TuiApp
        public let server: ServerEndpointConfig
        public let args: TUIContext.Args
        public let config: any TUIConfig.Interface
        public let updater: TUIContext.UpdateSource?
        public let environment: [String: String]
        public let terminalHandoff: (@Sendable () async -> TerminalHandoff?)?
        public let log: TUIContext.LogSink?
        public let interactive: Bool?

        public init(
            app: TUIContext.TuiApp,
            server: ServerEndpointConfig,
            args: TUIContext.Args = TUIContext.Args(),
            config: any TUIConfig.Interface,
            updater: TUIContext.UpdateSource? = nil,
            environment: [String: String] = [:],
            terminalHandoff: (@Sendable () async -> TerminalHandoff?)? = nil,
            log: TUIContext.LogSink? = nil,
            interactive: Bool? = nil
        ) {
            self.app = app
            self.server = server
            self.args = args
            self.config = config
            self.updater = updater
            self.environment = environment
            self.terminalHandoff = terminalHandoff
            self.log = log
            self.interactive = interactive
        }
    }

    /// Result produced when a `TUIApp.run(_:)` session exits cleanly.
    public struct RunResult: Equatable, Sendable {
        public let resolvedConfig: TUIConfig.Resolved
        public let initialRoute: TUIContext.Route
        public let updatedVersion: String?
        public let exitReason: String?

        public init(
            resolvedConfig: TUIConfig.Resolved,
            initialRoute: TUIContext.Route,
            updatedVersion: String? = nil,
            exitReason: String? = nil
        ) {
            self.resolvedConfig = resolvedConfig
            self.initialRoute = initialRoute
            self.updatedVersion = updatedVersion
            self.exitReason = exitReason
        }
    }

    /// Resolves TUI configuration, theme, route, and OpenTUI renderer lifecycle for an OpenCode TUI session.
    // parity: tui/src/app.tsx#run [status=adapted hash=3cc65b82ce3e]
    public static func run(_ input: TuiInput) async throws -> RunResult {
        let log: TUIContext.LogSink = input.log ?? { _, _, _ in }
        let rawConfig = try await input.config.get()
        let terminalSuspend = Platform.current != .windows
        let resolved = TUIConfig.resolve(
            rawConfig,
            options: TUIConfig.ResolveOptions(
                terminalSuspend: terminalSuspend,
                environment: input.environment
            )
        )
        let initialRoute: TUIContext.Route
        if let sid = input.args.sessionID, !sid.isEmpty {
            initialRoute = .session(TUIContext.SessionRoute(sessionID: sid))
        } else {
            initialRoute = .home(TUIContext.HomeRoute())
        }
        let handoff = await input.terminalHandoff?()
        if let handoff {
            handoff.complete()
        }
        log(.info, "TUI initialized", ["channel": .string(input.app.channel), "version": .string(input.app.version)])
        if input.interactive ?? PlatformTerminalBackend().isInteractiveTerminal {
            return try await TUIInteractiveLoop.runInteractive(
                input: input,
                resolved: resolved,
                initialRoute: initialRoute
            )
        }
        return RunResult(
            resolvedConfig: resolved,
            initialRoute: initialRoute,
            updatedVersion: nil,
            exitReason: nil
        )
    }
}

// MARK: - Tree-Sitter Parsers Config (`packages/tui/src/parsers-config.ts`)

/// Built-in tree-sitter parser grammar & highlight query catalog matching `packages/tui/src/parsers-config.ts`.
public enum TUIParsersConfig {
    public struct ParsersConfig: Equatable, Hashable, Sendable, Codable {
        public let parsers: [FiletypeParserOptions]

        public init(parsers: [FiletypeParserOptions]) {
            self.parsers = parsers
        }
    }

    // parity: tui/src/parsers-config.ts#default [status=implemented hash=90e077a22565]
    public static let defaultConfig = ParsersConfig(parsers: [
        FiletypeParserOptions(filetype: "python", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://github.com/tree-sitter/tree-sitter-python/raw/refs/heads/master/queries/highlights.scm"]), wasm: "https://github.com/tree-sitter/tree-sitter-python/releases/download/v0.23.6/tree-sitter-python.wasm"),
        FiletypeParserOptions(filetype: "rust", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/rust/highlights.scm"]), wasm: "https://github.com/tree-sitter/tree-sitter-rust/releases/download/v0.24.0/tree-sitter-rust.wasm"),
        FiletypeParserOptions(filetype: "go", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/go/highlights.scm"]), wasm: "https://github.com/tree-sitter/tree-sitter-go/releases/download/v0.25.0/tree-sitter-go.wasm"),
        FiletypeParserOptions(filetype: "cpp", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/cpp/highlights.scm"]), wasm: "https://github.com/tree-sitter/tree-sitter-cpp/releases/download/v0.23.4/tree-sitter-cpp.wasm"),
        FiletypeParserOptions(filetype: "csharp", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/c_sharp/highlights.scm"]), wasm: "https://github.com/tree-sitter/tree-sitter-c-sharp/releases/download/v0.23.1/tree-sitter-c_sharp.wasm"),
        FiletypeParserOptions(filetype: "bash", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/bash/highlights.scm"]), wasm: "https://github.com/tree-sitter/tree-sitter-bash/releases/download/v0.25.0/tree-sitter-bash.wasm"),
        FiletypeParserOptions(filetype: "c", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/c/highlights.scm"]), wasm: "https://github.com/tree-sitter/tree-sitter-c/releases/download/v0.24.1/tree-sitter-c.wasm"),
        FiletypeParserOptions(filetype: "java", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/java/highlights.scm"]), wasm: "https://github.com/tree-sitter/tree-sitter-java/releases/download/v0.23.5/tree-sitter-java.wasm"),
        FiletypeParserOptions(filetype: "kotlin", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/fwcd/tree-sitter-kotlin/0.3.8/queries/highlights.scm"]), wasm: "https://github.com/fwcd/tree-sitter-kotlin/releases/download/0.3.8/tree-sitter-kotlin.wasm"),
        FiletypeParserOptions(filetype: "ruby", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/ruby/highlights.scm"]), wasm: "https://github.com/tree-sitter/tree-sitter-ruby/releases/download/v0.23.1/tree-sitter-ruby.wasm"),
        FiletypeParserOptions(filetype: "php", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://github.com/tree-sitter/tree-sitter-php/raw/refs/heads/master/queries/highlights.scm"]), wasm: "https://github.com/tree-sitter/tree-sitter-php/releases/download/v0.24.2/tree-sitter-php_only.wasm"),
        FiletypeParserOptions(filetype: "scala", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/scala/highlights.scm"]), wasm: "https://github.com/tree-sitter/tree-sitter-scala/releases/download/v0.24.0/tree-sitter-scala.wasm"),
        FiletypeParserOptions(filetype: "html", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://github.com/tree-sitter/tree-sitter-html/raw/refs/heads/master/queries/highlights.scm"]), wasm: "https://github.com/tree-sitter/tree-sitter-html/releases/download/v0.23.2/tree-sitter-html.wasm"),
        FiletypeParserOptions(filetype: "vue", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/anomalyco/tree-sitter-vue/v0.1.2/queries/html_tags/highlights.scm", "https://raw.githubusercontent.com/anomalyco/tree-sitter-vue/v0.1.2/queries/vue/highlights.scm"]), wasm: "https://github.com/anomalyco/tree-sitter-vue/releases/download/v0.1.2/tree-sitter-vue.wasm"),
        FiletypeParserOptions(filetype: "hcl", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/master/queries/hcl/highlights.scm"]), wasm: "https://github.com/tree-sitter-grammars/tree-sitter-hcl/releases/download/v1.2.0/tree-sitter-hcl.wasm"),
        FiletypeParserOptions(filetype: "json", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/json/highlights.scm"]), wasm: "https://github.com/tree-sitter/tree-sitter-json/releases/download/v0.24.8/tree-sitter-json.wasm"),
        FiletypeParserOptions(filetype: "yaml", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/yaml/highlights.scm"]), wasm: "https://github.com/tree-sitter-grammars/tree-sitter-yaml/releases/download/v0.7.2/tree-sitter-yaml.wasm"),
        FiletypeParserOptions(filetype: "haskell", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/haskell/highlights.scm"]), wasm: "https://github.com/tree-sitter/tree-sitter-haskell/releases/download/v0.23.1/tree-sitter-haskell.wasm"),
        FiletypeParserOptions(filetype: "css", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/css/highlights.scm"]), wasm: "https://github.com/tree-sitter/tree-sitter-css/releases/download/v0.25.0/tree-sitter-css.wasm"),
        FiletypeParserOptions(filetype: "julia", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/julia/highlights.scm"]), wasm: "https://github.com/tree-sitter/tree-sitter-julia/releases/download/v0.23.1/tree-sitter-julia.wasm"),
        FiletypeParserOptions(filetype: "lua", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/tree-sitter-grammars/tree-sitter-lua/v0.5.0/queries/highlights.scm"]), wasm: "https://github.com/tree-sitter-grammars/tree-sitter-lua/releases/download/v0.5.0/tree-sitter-lua.wasm"),
        FiletypeParserOptions(filetype: "ocaml", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/ocaml/highlights.scm"]), wasm: "https://github.com/tree-sitter/tree-sitter-ocaml/releases/download/v0.24.2/tree-sitter-ocaml.wasm"),
        FiletypeParserOptions(filetype: "clojure", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/clojure/highlights.scm"]), wasm: "https://github.com/anomalyco/tree-sitter-clojure/releases/download/v0.0.1/tree-sitter-clojure.wasm"),
        FiletypeParserOptions(filetype: "swift", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/alex-pinkus/tree-sitter-swift/main/queries/highlights.scm"]), wasm: "https://github.com/alex-pinkus/tree-sitter-swift/releases/download/0.7.1/tree-sitter-swift.wasm"),
        FiletypeParserOptions(filetype: "toml", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/master/queries/toml/highlights.scm"]), wasm: "https://github.com/tree-sitter-grammars/tree-sitter-toml/releases/download/v0.7.0/tree-sitter-toml.wasm"),
        FiletypeParserOptions(filetype: "nix", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/nix/highlights.scm"]), wasm: "https://github.com/ast-grep/ast-grep.github.io/raw/40b84530640aa83a0d34a20a2b0623d7b8e5ea97/website/public/parsers/tree-sitter-nix.wasm"),
        FiletypeParserOptions(filetype: "diff", aliases: ["udiff", "patch"], queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/tree-sitter-grammars/tree-sitter-diff/2520c3f934b3179bb540d23e0ef45f75304b5fed/queries/highlights.scm"]), wasm: "https://github.com/tree-sitter-grammars/tree-sitter-diff/releases/download/v0.1.0/tree-sitter-diff.wasm"),
        FiletypeParserOptions(filetype: "elixir", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/elixir/highlights.scm"]), wasm: "https://github.com/elixir-lang/tree-sitter-elixir/releases/download/v0.3.5/tree-sitter-elixir.wasm"),
        FiletypeParserOptions(filetype: "fsharp", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/fsharp/highlights.scm"]), wasm: "https://github.com/ionide/tree-sitter-fsharp/releases/download/0.3.0/tree-sitter-fsharp.wasm"),
        FiletypeParserOptions(filetype: "r", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/r/highlights.scm"]), wasm: "https://github.com/r-lib/tree-sitter-r/releases/download/v1.2.0/tree-sitter-r.wasm"),
        FiletypeParserOptions(filetype: "make", aliases: ["makefile"], queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/make/highlights.scm"]), wasm: "https://github.com/tree-sitter-grammars/tree-sitter-make/releases/download/v1.1.1/tree-sitter-make.wasm"),
        FiletypeParserOptions(filetype: "vim", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/vim/highlights.scm"]), wasm: "https://github.com/tree-sitter-grammars/tree-sitter-vim/releases/download/v0.8.1/tree-sitter-vim.wasm"),
        FiletypeParserOptions(filetype: "xml", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/xml/highlights.scm"]), wasm: "https://github.com/tree-sitter-grammars/tree-sitter-xml/releases/download/v0.7.0/tree-sitter-xml.wasm"),
        FiletypeParserOptions(filetype: "agda", aliases: nil, queries: FiletypeParserQueries(highlights: ["https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/refs/heads/master/queries/agda/highlights.scm"]), wasm: "https://github.com/tree-sitter/tree-sitter-agda/releases/download/v1.3.3/tree-sitter-agda.wasm"),
    ])
}
