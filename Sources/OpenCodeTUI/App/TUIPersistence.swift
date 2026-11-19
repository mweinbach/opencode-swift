#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodePlatform
import OpenCodeSchema

// MARK: - Persisted Preferences (`tui-prefs.json`)

/// User-facing TUI preferences persisted under `<stateDir>/tui-prefs.json`.
public struct TUIPersistedPreferences: Equatable, Hashable, Sendable, Codable {
    public var themeName: String
    public var themePreference: TUIThemePreference
    public var animations: Bool
    public var sidebarMode: String
    public var showScrollbar: Bool
    public var scrollOnSend: String
    public var showThinking: Bool
    public var concealMarkdown: Bool
    public var diffView: String
    public var diffWrap: String
    public var pasteSummary: Bool
    public var pinnedSessionIDs: [String]

    public static let `default` = TUIPersistedPreferences()

    public init(
        themeName: String = "opencode",
        themePreference: TUIThemePreference = .auto,
        animations: Bool = true,
        sidebarMode: String = "auto",
        showScrollbar: Bool = false,
        scrollOnSend: String = "bottom",
        showThinking: Bool = true,
        concealMarkdown: Bool = true,
        diffView: String = "auto",
        diffWrap: String = "word",
        pasteSummary: Bool = false,
        pinnedSessionIDs: [String] = []
    ) {
        self.themeName = themeName
        self.themePreference = themePreference
        self.animations = animations
        self.sidebarMode = sidebarMode
        self.showScrollbar = showScrollbar
        self.scrollOnSend = scrollOnSend
        self.showThinking = showThinking
        self.concealMarkdown = concealMarkdown
        self.diffView = diffView
        self.diffWrap = diffWrap
        self.pasteSummary = pasteSummary
        self.pinnedSessionIDs = pinnedSessionIDs
    }

    private enum CodingKeys: String, CodingKey {
        case themeName
        case themePreference
        case animations
        case sidebarMode
        case showScrollbar
        case scrollOnSend
        case showThinking
        case concealMarkdown
        case diffView
        case diffWrap
        case pasteSummary
        case pinnedSessionIDs
    }

    /// Tolerant decoder that fills missing or mistyped keys with defaults while ignoring unknown fields.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.default
        self.themeName = (try? container.decodeIfPresent(String.self, forKey: .themeName)) ?? defaults.themeName
        self.themePreference = (try? container.decodeIfPresent(TUIThemePreference.self, forKey: .themePreference)) ?? defaults.themePreference
        self.animations = (try? container.decodeIfPresent(Bool.self, forKey: .animations)) ?? defaults.animations
        self.sidebarMode = (try? container.decodeIfPresent(String.self, forKey: .sidebarMode)) ?? defaults.sidebarMode
        self.showScrollbar = (try? container.decodeIfPresent(Bool.self, forKey: .showScrollbar)) ?? defaults.showScrollbar
        self.scrollOnSend = (try? container.decodeIfPresent(String.self, forKey: .scrollOnSend)) ?? defaults.scrollOnSend
        self.showThinking = (try? container.decodeIfPresent(Bool.self, forKey: .showThinking)) ?? defaults.showThinking
        self.concealMarkdown = (try? container.decodeIfPresent(Bool.self, forKey: .concealMarkdown)) ?? defaults.concealMarkdown
        self.diffView = (try? container.decodeIfPresent(String.self, forKey: .diffView)) ?? defaults.diffView
        self.diffWrap = (try? container.decodeIfPresent(String.self, forKey: .diffWrap)) ?? defaults.diffWrap
        self.pasteSummary = (try? container.decodeIfPresent(Bool.self, forKey: .pasteSummary)) ?? defaults.pasteSummary
        self.pinnedSessionIDs = (try? container.decodeIfPresent([String].self, forKey: .pinnedSessionIDs)) ?? defaults.pinnedSessionIDs
    }
}

// MARK: - Persisted Model State (`model.json`)

/// Upstream-compatible `model.json` state storing recent models, favorites, and per-model variants.
public struct TUIPersistedModelState: Equatable, Hashable, Sendable, Codable {
    public struct ModelEntry: Equatable, Hashable, Sendable, Codable {
        public var providerID: String
        public var modelID: String

        public init(providerID: String, modelID: String) {
            self.providerID = providerID
            self.modelID = modelID
        }

        public var key: String {
            "\(providerID)/\(modelID)"
        }

        public static func parseKey(_ raw: String) -> ModelEntry? {
            guard let slash = raw.firstIndex(of: "/") else { return nil }
            let provider = String(raw[..<slash])
            let model = String(raw[raw.index(after: slash)...])
            guard !provider.isEmpty, !model.isEmpty else { return nil }
            return ModelEntry(providerID: provider, modelID: model)
        }
    }

    public var recent: [ModelEntry]
    public var favorite: [ModelEntry]
    public var variant: [String: String]

    public init(
        recent: [ModelEntry] = [],
        favorite: [ModelEntry] = [],
        variant: [String: String] = [:]
    ) {
        self.recent = recent
        self.favorite = favorite
        self.variant = variant
    }

    private enum CodingKeys: String, CodingKey {
        case recent
        case favorite
        case variant
    }

    /// Tolerant decoding matching upstream `model-preference.ts`: ignores unknown top-level keys
    /// and silently skips malformed model entries or non-string variant values.
    public init(from decoder: any Decoder) throws {
        let root = try JSONValue(from: decoder)
        self = Self.fromJSONValue(root)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recent, forKey: .recent)
        try container.encode(favorite, forKey: .favorite)
        try container.encode(variant, forKey: .variant)
    }

    public static func fromJSONValue(_ value: JSONValue) -> TUIPersistedModelState {
        guard case .object(let dict) = value else {
            return TUIPersistedModelState()
        }
        return TUIPersistedModelState(
            recent: decodeModelEntries(dict["recent"]),
            favorite: decodeModelEntries(dict["favorite"]),
            variant: decodeVariantMap(dict["variant"])
        )
    }

    internal func mergedIntoJSONObject(_ existing: [String: JSONValue]) -> [String: JSONValue] {
        var result = existing
        result["recent"] = .array(recent.map {
            .object(["providerID": .string($0.providerID), "modelID": .string($0.modelID)])
        })
        result["favorite"] = .array(favorite.map {
            .object(["providerID": .string($0.providerID), "modelID": .string($0.modelID)])
        })
        result["variant"] = .object(variant.mapValues { .string($0) })
        return result
    }

    /// Prepends a model to `recent`, deduplicating by `providerID/modelID` and capping at `limit` (default 10).
    public mutating func recordRecent(providerID: String, modelID: String, limit: Int = 10) {
        guard !providerID.isEmpty, !modelID.isEmpty else { return }
        let entry = ModelEntry(providerID: providerID, modelID: modelID)
        var seen: Set<String> = []
        var next: [ModelEntry] = []
        for item in [entry] + recent {
            if seen.insert(item.key).inserted {
                next.append(item)
                if next.count >= max(1, limit) { break }
            }
        }
        recent = next
    }

    /// Toggles whether a model is in `favorite` and returns its new favorite status.
    @discardableResult
    public mutating func toggleFavorite(providerID: String, modelID: String) -> Bool {
        let entry = ModelEntry(providerID: providerID, modelID: modelID)
        let key = entry.key
        if favorite.contains(where: { $0.key == key }) {
            favorite.removeAll { $0.key == key }
            return false
        }
        favorite.insert(entry, at: 0)
        return true
    }

    /// Sets a model's favorite state explicitly.
    public mutating func setFavorite(providerID: String, modelID: String, enabled: Bool) {
        let entry = ModelEntry(providerID: providerID, modelID: modelID)
        let key = entry.key
        favorite.removeAll { $0.key == key }
        if enabled {
            favorite.insert(entry, at: 0)
        }
    }

    /// Saves a reasoning variant for `providerID/modelID` (preserving `"default"` to match upstream).
    public mutating func setVariant(_ value: String?, forProvider providerID: String, modelID: String) {
        let key = "\(providerID)/\(modelID)"
        let normalized = (value == nil || value == "default" || value?.isEmpty == true) ? "default" : value!
        variant[key] = normalized
    }

    /// Resolves the saved reasoning variant for `providerID/modelID`, mapping `"default"` to `nil`.
    public func variant(forProvider providerID: String, modelID: String) -> String? {
        let key = "\(providerID)/\(modelID)"
        guard let raw = variant[key], !raw.isEmpty, raw != "default" else { return nil }
        return raw
    }

    private static func decodeModelEntries(_ value: JSONValue?) -> [ModelEntry] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item in
            guard case .object(let dict) = item,
                  case .string(let providerID) = dict["providerID"], !providerID.isEmpty,
                  case .string(let modelID) = dict["modelID"], !modelID.isEmpty
            else {
                return nil
            }
            return ModelEntry(providerID: providerID, modelID: modelID)
        }
    }

    private static func decodeVariantMap(_ value: JSONValue?) -> [String: String] {
        guard case .object(let dict) = value else { return [:] }
        var out: [String: String] = [:]
        for (key, raw) in dict where !key.isEmpty {
            if case .string(let str) = raw, !str.isEmpty {
                out[key] = str
            }
        }
        return out
    }
}

// MARK: - Prompt History Entry (`prompt-history.jsonl`)

/// Single prompt history record persisted as one JSONL line in `<stateDir>/prompt-history.jsonl`.
public struct TUIPromptHistoryEntry: Equatable, Hashable, Sendable, Codable {
    public var input: String
    public var mode: String

    public init(input: String, mode: String = "normal") {
        self.input = input
        self.mode = mode == "shell" ? "shell" : "normal"
    }

    private enum CodingKeys: String, CodingKey {
        case input
        case text
        case mode
    }

    /// Decodes both `{"input": "...", "mode": "..."}` and upstream V2 `{"text": "...", "pasted": [], "mode": "..."}`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let input = try container.decodeIfPresent(String.self, forKey: .input) {
            self.input = input
        } else if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self.input = text
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.input,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected 'input' or 'text' string field in prompt history entry"
                )
            )
        }
        let rawMode = (try? container.decodeIfPresent(String.self, forKey: .mode)) ?? "normal"
        self.mode = rawMode == "shell" ? "shell" : "normal"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(input, forKey: .input)
        try container.encode(mode, forKey: .mode)
    }
}

// MARK: - Prompt Stash Entry (`prompt-stash.jsonl`)

/// Single stashed draft persisted as one JSONL line in `<stateDir>/prompt-stash.jsonl`.
public struct TUIPromptStashEntry: Equatable, Hashable, Sendable, Codable {
    public var id: String
    public var input: String
    public var timestamp: Int64

    public init(
        id: String = UUID().uuidString,
        input: String,
        timestamp: Int64 = Flock.currentEpochMs()
    ) {
        self.id = id
        self.input = input
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case input
        case prompt
        case timestamp
    }

    private struct UpstreamPromptBox: Decodable {
        let text: String
    }

    /// Decodes both `{"id": "...", "input": "...", "timestamp": 123}` and upstream V2
    /// `{"prompt": {"text": "...", "pasted": []}, "timestamp": 123}`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let decodedInput: String
        if let direct = try container.decodeIfPresent(String.self, forKey: .input) {
            decodedInput = direct
        } else if let nested = try container.decodeIfPresent(UpstreamPromptBox.self, forKey: .prompt) {
            decodedInput = nested.text
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.input,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected 'input' or 'prompt.text' in prompt stash entry"
                )
            )
        }

        let decodedTimestamp: Int64
        if let ts = try? container.decode(Int64.self, forKey: .timestamp) {
            decodedTimestamp = ts
        } else if let dbl = try? container.decode(Double.self, forKey: .timestamp), dbl.isFinite {
            decodedTimestamp = Int64(dbl)
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.timestamp,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected numeric 'timestamp' in prompt stash entry"
                )
            )
        }

        let decodedID = (try? container.decodeIfPresent(String.self, forKey: .id))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "stash-\(decodedTimestamp)"

        self.id = decodedID
        self.input = decodedInput
        self.timestamp = decodedTimestamp
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(input, forKey: .input)
        try container.encode(timestamp, forKey: .timestamp)
    }
}

// MARK: - Persistence Store

/// Actor-serialized, cross-platform persistence store for TUI preferences, model state, prompt history, and stash.
public final class TUIPersistenceStore: Sendable {
    public static let maxHistoryEntries = 200
    public static let maxStashEntries = 50

    public let stateDirectory: String
    private let fileSystem: any OpenCodeFileSystem
    private let coordinator: StorageCoordinator

    public init(
        stateDirectory: String = Global.make().state,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
    ) {
        let normalizedDir: String
        if stateDirectory.count > 1 && (stateDirectory.hasSuffix("/") || stateDirectory.hasSuffix("\\")) {
            normalizedDir = String(stateDirectory.dropLast())
        } else {
            normalizedDir = stateDirectory
        }
        self.stateDirectory = normalizedDir
        self.fileSystem = fileSystem
        self.coordinator = StorageCoordinator(stateDirectory: normalizedDir, fileSystem: fileSystem)
    }

    public var preferencesPath: String {
        joinPath("tui-prefs.json")
    }

    public var modelStatePath: String {
        joinPath("model.json")
    }

    public var historyPath: String {
        joinPath("prompt-history.jsonl")
    }

    public var stashPath: String {
        joinPath("prompt-stash.jsonl")
    }

    private func joinPath(_ filename: String) -> String {
        if stateDirectory.isEmpty { return filename }
        if stateDirectory == "/" { return "/\(filename)" }
        return "\(stateDirectory)/\(filename)"
    }

    // MARK: - Preferences

    public func loadPreferences() async -> TUIPersistedPreferences {
        await coordinator.loadPreferences(path: preferencesPath)
    }

    public func savePreferences(_ preferences: TUIPersistedPreferences) async {
        await coordinator.savePreferences(preferences, path: preferencesPath)
    }

    // MARK: - Model State (`model.json`)

    public func loadModelState() async -> TUIPersistedModelState {
        await coordinator.loadModelState(path: modelStatePath)
    }

    public func saveModelState(_ state: TUIPersistedModelState) async {
        await coordinator.saveModelState(state, path: modelStatePath)
    }

    // MARK: - Prompt History (`prompt-history.jsonl`)

    public func loadHistory(limit: Int = 200) async -> [TUIPromptHistoryEntry] {
        await coordinator.loadHistory(path: historyPath, limit: limit)
    }

    public func appendHistory(_ entry: TUIPromptHistoryEntry) async {
        await coordinator.appendHistory(entry, path: historyPath, maxEntries: Self.maxHistoryEntries)
    }

    // MARK: - Prompt Stash (`prompt-stash.jsonl`)

    public func loadStash() async -> [TUIPromptStashEntry] {
        await coordinator.loadStash(path: stashPath, maxEntries: Self.maxStashEntries)
    }

    public func saveStash(_ entries: [TUIPromptStashEntry]) async {
        await coordinator.saveStash(entries, path: stashPath, maxEntries: Self.maxStashEntries)
    }
}

// MARK: - Serialized Storage Actor

private actor StorageCoordinator {
    let stateDirectory: String
    let fileSystem: any OpenCodeFileSystem

    init(stateDirectory: String, fileSystem: any OpenCodeFileSystem) {
        self.stateDirectory = stateDirectory
        self.fileSystem = fileSystem
    }

    func loadPreferences(path: String) async -> TUIPersistedPreferences {
        guard let bytes = try? await fileSystem.readFile(at: path), !bytes.isEmpty else {
            return TUIPersistedPreferences.default
        }
        guard let decoded = try? JSONDecoder().decode(TUIPersistedPreferences.self, from: Data(bytes)) else {
            return TUIPersistedPreferences.default
        }
        return decoded
    }

    func savePreferences(_ preferences: TUIPersistedPreferences, path: String) async {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(preferences) else { return }
        await writeAtomic(Array(data) + [0x0A], to: path)
    }

    func loadModelState(path: String) async -> TUIPersistedModelState {
        guard let bytes = try? await fileSystem.readFile(at: path), !bytes.isEmpty else {
            return TUIPersistedModelState()
        }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(bytes)) else {
            return TUIPersistedModelState()
        }
        return TUIPersistedModelState.fromJSONValue(json)
    }

    func saveModelState(_ state: TUIPersistedModelState, path: String) async {
        var existingRoot: [String: JSONValue] = [:]
        if let bytes = try? await fileSystem.readFile(at: path),
           !bytes.isEmpty,
           let json = try? JSONDecoder().decode(JSONValue.self, from: Data(bytes)),
           case .object(let dict) = json
        {
            existingRoot = dict
        }
        let merged = state.mergedIntoJSONObject(existingRoot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(JSONValue.object(merged)) else { return }
        await writeAtomic(Array(data) + [0x0A], to: path)
    }

    func loadHistory(path: String, limit: Int) async -> [TUIPromptHistoryEntry] {
        guard limit > 0 else { return [] }
        guard let bytes = try? await fileSystem.readFile(at: path), !bytes.isEmpty else {
            return []
        }
        let text = String(decoding: bytes, as: UTF8.self)
        let decoder = JSONDecoder()
        var entries: [TUIPromptHistoryEntry] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let entry = try? decoder.decode(TUIPromptHistoryEntry.self, from: Data(trimmed.utf8)) {
                entries.append(entry)
            }
        }
        if entries.count > limit {
            return Array(entries.suffix(limit))
        }
        return entries
    }

    func appendHistory(_ entry: TUIPromptHistoryEntry, path: String, maxEntries: Int) async {
        guard !entry.input.isEmpty else { return }
        var existing = await loadHistory(path: path, limit: maxEntries)
        if existing.last == entry {
            return
        }
        existing.append(entry)
        if existing.count > maxEntries {
            existing = Array(existing.suffix(maxEntries))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines: [String] = existing.compactMap { item in
            guard let data = try? encoder.encode(item) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        let payload = lines.isEmpty ? "" : (lines.joined(separator: "\n") + "\n")
        await writeAtomic(Array(payload.utf8), to: path)
    }

    func loadStash(path: String, maxEntries: Int) async -> [TUIPromptStashEntry] {
        guard maxEntries > 0 else { return [] }
        guard let bytes = try? await fileSystem.readFile(at: path), !bytes.isEmpty else {
            return []
        }
        let text = String(decoding: bytes, as: UTF8.self)
        let decoder = JSONDecoder()
        var entries: [TUIPromptStashEntry] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let entry = try? decoder.decode(TUIPromptStashEntry.self, from: Data(trimmed.utf8)) {
                entries.append(entry)
            }
        }
        if entries.count > maxEntries {
            return Array(entries.suffix(maxEntries))
        }
        return entries
    }

    func saveStash(_ entries: [TUIPromptStashEntry], path: String, maxEntries: Int) async {
        let retained = entries.count > maxEntries ? Array(entries.suffix(maxEntries)) : entries
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines: [String] = retained.compactMap { item in
            guard let data = try? encoder.encode(item) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        let payload = lines.isEmpty ? "" : (lines.joined(separator: "\n") + "\n")
        await writeAtomic(Array(payload.utf8), to: path)
    }

    private func writeAtomic(_ bytes: [UInt8], to path: String) async {
        let tempPath = "\(path).\(UUID().uuidString).tmp"
        do {
            try await fileSystem.writeFile(bytes, to: tempPath, createDirectories: true)
            try await fileSystem.rename(from: tempPath, to: path)
        } catch {
            try? await fileSystem.remove(at: tempPath)
            // Best-effort direct write fallback in case a custom filesystem does not support atomic rename.
            try? await fileSystem.writeFile(bytes, to: path, createDirectories: true)
        }
    }
}
