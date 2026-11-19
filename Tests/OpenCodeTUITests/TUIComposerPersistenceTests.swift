import Testing
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeTUI
import OpenTUICore

@Suite("TUI Persistence, Composer Helpers & Settings Catalog")
struct TUIComposerPersistenceTests {

    // MARK: - 1. TUIPersistenceStore Round-Trip & Resilience

    @Test("TUIPersistenceStore tolerates missing files gracefully with sensible defaults")
    func persistenceStoreMissingFilesReturnDefaults() async {
        let fs = TUIComposerPersistenceHelper.makeInMemoryFileSystem()
        let store = TUIPersistenceStore(stateDirectory: "/state/opencode", fileSystem: fs)

        let prefs = await store.loadPreferences()
        #expect(prefs == TUIPersistedPreferences.default)
        #expect(prefs.themeName == "opencode")
        #expect(prefs.themePreference == .auto)
        #expect(prefs.animations == true)
        #expect(prefs.sidebarMode == "auto")
        #expect(prefs.showScrollbar == false)
        #expect(prefs.scrollOnSend == "bottom")
        #expect(prefs.showThinking == true)
        #expect(prefs.concealMarkdown == true)
        #expect(prefs.diffView == "auto")
        #expect(prefs.diffWrap == "word")
        #expect(prefs.pasteSummary == false)
        #expect(prefs.pinnedSessionIDs.isEmpty)

        let modelState = await store.loadModelState()
        #expect(modelState == TUIPersistedModelState())

        let history = await store.loadHistory()
        #expect(history.isEmpty)

        let stash = await store.loadStash()
        #expect(stash.isEmpty)
    }

    @Test("TUIPersistenceStore round-trips preferences and fills missing keys on partial JSON")
    func preferencesRoundTripAndPartialDecoding() async {
        let fs = TUIComposerPersistenceHelper.makeInMemoryFileSystem()
        let store = TUIPersistenceStore(stateDirectory: "/state/opencode", fileSystem: fs)

        let custom = TUIPersistedPreferences(
            themeName: "catppuccin",
            themePreference: .light,
            animations: false,
            sidebarMode: "hide",
            showScrollbar: true,
            scrollOnSend: "keep",
            showThinking: false,
            concealMarkdown: false,
            diffView: "split",
            diffWrap: "none",
            pasteSummary: true,
            pinnedSessionIDs: ["ses_alpha", "ses_beta"]
        )
        await store.savePreferences(custom)

        let reloaded = await store.loadPreferences()
        #expect(reloaded == custom)
        #expect(store.preferencesPath == "/state/opencode/tui-prefs.json")

        // Partial JSON with unknown extra field falls back cleanly to defaults for missing keys
        let partialJSON = #"{"themeName":"dracula","showScrollbar":true,"unknownFutureKey":42}"#
        let partialFS = TUIComposerPersistenceHelper.makeInMemoryFileSystem(textFiles: [
            "/state/partial/tui-prefs.json": partialJSON,
        ])
        let partialStore = TUIPersistenceStore(stateDirectory: "/state/partial", fileSystem: partialFS)
        let loadedPartial = await partialStore.loadPreferences()
        #expect(loadedPartial.themeName == "dracula")
        #expect(loadedPartial.showScrollbar == true)
        #expect(loadedPartial.themePreference == .auto)
        #expect(loadedPartial.diffWrap == "word")
        #expect(loadedPartial.pinnedSessionIDs.isEmpty)
    }

    @Test("TUIPersistenceStore decodes upstream model.json with extra unknown keys and preserves them on save")
    func modelStateUpstreamCompatibilityAndExtraKeys() async {
        let upstreamModelJSON = """
        {
          "recent": [
            {"providerID": "anthropic", "modelID": "claude-sonnet-4-5", "extraField": true},
            {"providerID": "", "modelID": "invalid-empty-provider"},
            "not-an-object",
            {"providerID": "openai", "modelID": "gpt-5.3-codex"}
          ],
          "favorite": [
            {"providerID": "google", "modelID": "gemini-2.5-pro"},
            {"providerID": "broken-missing-model"}
          ],
          "variant": {
            "anthropic/claude-sonnet-4-5": "high",
            "openai/gpt-5.3-codex": "default",
            "invalidNumber": 123,
            "emptyString": ""
          },
          "upstreamExtraKey": "keep-me",
          "schemaVersion": 2
        }
        """

        let fs = TUIComposerPersistenceHelper.makeInMemoryFileSystem(textFiles: [
            "/state/opencode/model.json": upstreamModelJSON,
        ])
        let store = TUIPersistenceStore(stateDirectory: "/state/opencode", fileSystem: fs)

        let loaded = await store.loadModelState()
        #expect(loaded.recent == [
            .init(providerID: "anthropic", modelID: "claude-sonnet-4-5"),
            .init(providerID: "openai", modelID: "gpt-5.3-codex"),
        ])
        #expect(loaded.favorite == [
            .init(providerID: "google", modelID: "gemini-2.5-pro"),
        ])
        #expect(loaded.variant == [
            "anthropic/claude-sonnet-4-5": "high",
            "openai/gpt-5.3-codex": "default",
        ])
        #expect(loaded.variant(forProvider: "anthropic", modelID: "claude-sonnet-4-5") == "high")
        #expect(loaded.variant(forProvider: "openai", modelID: "gpt-5.3-codex") == nil)

        // Mutate and save back — verify updated fields round-trip AND unknown top-level keys remain intact
        var updated = loaded
        updated.recordRecent(providerID: "google", modelID: "gemini-2.5-pro")
        let toggledOn = updated.toggleFavorite(providerID: "anthropic", modelID: "claude-sonnet-4-5")
        #expect(toggledOn == true)
        updated.setVariant("xhigh", forProvider: "anthropic", modelID: "claude-sonnet-4-5")

        await store.saveModelState(updated)
        let reloaded = await store.loadModelState()
        #expect(reloaded == updated)
        #expect(reloaded.recent.first == .init(providerID: "google", modelID: "gemini-2.5-pro"))

        let rawSaved = await TUIComposerPersistenceHelper.readTextFile(store.modelStatePath, from: fs)
        #expect(rawSaved != nil)
        let savedObj = rawSaved.flatMap(TUIComposerPersistenceHelper.decodeJSONObject)
        #expect(savedObj?["upstreamExtraKey"] == .string("keep-me"))
        #expect(savedObj?["schemaVersion"] == .int(2))
    }

    @Test("TUIPersistenceStore reads/appends prompt-history.jsonl skipping malformed lines and supporting upstream V2")
    func promptHistoryJSONLRoundTripAndResilience() async {
        let seededJSONL = """
        {"input":"first prompt","mode":"normal"}
        {broken json line
        {"text":"upstream v2 entry","pasted":[],"mode":"normal"}
        {"notPrompt":123}
        {"input":"git status","mode":"shell"}

        """
        let fs = TUIComposerPersistenceHelper.makeInMemoryFileSystem(textFiles: [
            "/state/opencode/prompt-history.jsonl": seededJSONL,
        ])
        let store = TUIPersistenceStore(stateDirectory: "/state/opencode", fileSystem: fs)

        let initial = await store.loadHistory()
        #expect(initial == [
            TUIPromptHistoryEntry(input: "first prompt", mode: "normal"),
            TUIPromptHistoryEntry(input: "upstream v2 entry", mode: "normal"),
            TUIPromptHistoryEntry(input: "git status", mode: "shell"),
        ])

        // Consecutive duplicate is skipped
        await store.appendHistory(TUIPromptHistoryEntry(input: "git status", mode: "shell"))
        #expect(await store.loadHistory() == initial)

        // Same text with different mode is preserved
        await store.appendHistory(TUIPromptHistoryEntry(input: "git status", mode: "normal"))
        let afterModeChange = await store.loadHistory()
        #expect(afterModeChange.count == 4)
        #expect(afterModeChange.last == TUIPromptHistoryEntry(input: "git status", mode: "normal"))

        // Limit parameter returns trailing slice
        let limited = await store.loadHistory(limit: 2)
        #expect(limited == [
            TUIPromptHistoryEntry(input: "git status", mode: "shell"),
            TUIPromptHistoryEntry(input: "git status", mode: "normal"),
        ])
    }

    @Test("TUIPersistenceStore round-trips prompt-stash.jsonl and decodes upstream V2 stash lines")
    func promptStashJSONLRoundTripAndResilience() async {
        let seededStash = """
        {"id":"s1","input":"draft one","timestamp":1700000001000}
        corrupted-line
        {"prompt":{"text":"upstream draft","pasted":[]},"timestamp":1700000002000}
        {"missingInput":true,"timestamp":1700000003000}
        """
        let fs = TUIComposerPersistenceHelper.makeInMemoryFileSystem(textFiles: [
            "/state/opencode/prompt-stash.jsonl": seededStash,
        ])
        let store = TUIPersistenceStore(stateDirectory: "/state/opencode", fileSystem: fs)

        let loaded = await store.loadStash()
        #expect(loaded == [
            TUIPromptStashEntry(id: "s1", input: "draft one", timestamp: 1_700_000_001_000),
            TUIPromptStashEntry(id: "stash-1700000002000", input: "upstream draft", timestamp: 1_700_000_002_000),
        ])

        let updated = [
            TUIPromptStashEntry(id: "a", input: "line 1\nline 2", timestamp: 1_700_000_010_000),
            TUIPromptStashEntry(id: "b", input: "refactor @TUIPersistence.swift 🚀", timestamp: 1_700_000_020_000),
        ]
        await store.saveStash(updated)
        #expect(await store.loadStash() == updated)

        // Saving empty stash clears cleanly
        await store.saveStash([])
        #expect((await store.loadStash()).isEmpty)
    }

    // MARK: - 2. TUIPromptHistoryNavigator

    @Test("TUIPromptHistoryNavigator handles up/down walking, draft restoration, deduplication, and 200 cap")
    func promptHistoryNavigatorBehavior() {
        var nav = TUIPromptHistoryNavigator()
        #expect(nav.navigateUp(currentInput: "draft") == nil)
        #expect(nav.navigateDown() == nil)

        nav.append(TUIPromptHistoryEntry(input: "first", mode: "normal"))
        nav.append(TUIPromptHistoryEntry(input: "first", mode: "normal")) // consecutive duplicate ignored
        nav.append(TUIPromptHistoryEntry(input: "ls -la", mode: "shell"))
        nav.append(TUIPromptHistoryEntry(input: "first", mode: "normal")) // non-consecutive kept
        #expect(nav.entries.count == 3)

        // First Up saves live draft and returns newest
        #expect(nav.navigateUp(currentInput: "wip prompt") == "first")
        #expect(nav.cursor == 2)
        #expect(nav.stashedDraft == "wip prompt")
        #expect(nav.activeEntry?.mode == "normal")

        // Second Up moves to shell entry
        #expect(nav.navigateUp(currentInput: "first") == "ls -la")
        #expect(nav.cursor == 1)
        #expect(nav.activeEntry?.mode == "shell")

        // Third Up moves to oldest
        #expect(nav.navigateUp(currentInput: "ls -la") == "first")
        #expect(nav.cursor == 0)

        // Fourth Up stays at oldest and returns nil
        #expect(nav.navigateUp(currentInput: "first") == nil)
        #expect(nav.cursor == 0)

        // Down walks back forward and restores draft past newest
        #expect(nav.navigateDown() == "ls -la")
        #expect(nav.navigateDown() == "first")
        #expect(nav.navigateDown() == "wip prompt")
        #expect(nav.cursor == nil)
        #expect(nav.stashedDraft == "")
        #expect(nav.navigateDown() == nil)

        // Reset clears active navigation cursor
        _ = nav.navigateUp(currentInput: "another draft")
        #expect(nav.cursor != nil)
        nav.reset()
        #expect(nav.cursor == nil)
        #expect(nav.stashedDraft == "")

        // Cap at 200 entries
        var bigNav = TUIPromptHistoryNavigator()
        for i in 1...215 {
            bigNav.append(TUIPromptHistoryEntry(input: "cmd-\(i)", mode: "normal"))
        }
        #expect(bigNav.entries.count == 200)
        #expect(bigNav.entries.first?.input == "cmd-16")
        #expect(bigNav.entries.last?.input == "cmd-215")
    }

    @Test("TUIShellMode detects ! trigger and extracts shell commands cleanly")
    func shellModeHelpers() {
        #expect(TUIShellMode.isShellTrigger("!") == true)
        #expect(TUIShellMode.isShellTrigger("!ls") == false)
        #expect(TUIShellMode.extractShellCommand(from: "!git status", isShellMode: false) == "git status")
        #expect(TUIShellMode.extractShellCommand(from: "!  ", isShellMode: false) == nil)
        #expect(TUIShellMode.extractShellCommand(from: "echo hello", isShellMode: true) == "echo hello")
        #expect(TUIShellMode.extractShellCommand(from: "echo hello", isShellMode: false) == nil)
    }

    // MARK: - 3. @ Mention Autocomplete

    @Test("detectMentionTrigger detects trailing @ mentions and ignores emails or completed tokens")
    func mentionTriggerDetectionAndUTF8Safety() {
        #expect(detectMentionTrigger(in: "") == nil)
        #expect(detectMentionTrigger(in: "hello world") == nil)
        #expect(detectMentionTrigger(in: "email user@example.com") == nil)
        #expect(detectMentionTrigger(in: "check @done already") == nil)
        #expect(detectMentionTrigger(in: "check @done ") == nil)

        let bare = detectMentionTrigger(in: "@")
        #expect(bare?.startOffset == 0)
        #expect(bare?.query == "")

        let startToken = detectMentionTrigger(in: "@Sources/App")
        #expect(startToken?.startOffset == 0)
        #expect(startToken?.query == "Sources/App")

        let mid = detectMentionTrigger(in: "Please inspect @TUIPer")
        #expect(mid?.startOffset == 15)
        #expect(mid?.query == "TUIPer")

        let afterNewline = detectMentionTrigger(in: "line 1\n@exp")
        #expect(afterNewline?.startOffset == 7)
        #expect(afterNewline?.query == "exp")

        let secondMention = detectMentionTrigger(in: "compare @first.swift and @sec")
        #expect(secondMention?.query == "sec")

        // Emoji & CJK UTF-8 / UTF-16 safety
        let emojiText = "fix 🚀 日本語 @gen"
        let emojiTrigger = detectMentionTrigger(in: emojiText)
        #expect(emojiTrigger != nil)
        if let emojiTrigger {
            #expect(emojiTrigger.query == "gen")
            // "fix " (4) + "🚀" (2 UTF-16) + " " (1) + "日本語" (3 UTF-16) + " " (1) = 11
            #expect(emojiTrigger.startOffset == 11)
            #expect(String(emojiText[emojiTrigger.range]) == "@gen")

            let applied = applyMention(
                TUIMentionSuggestion(kind: .agent, value: "general"),
                to: emojiText,
                trigger: emojiTrigger
            )
            #expect(applied == "fix 🚀 日本語 @general ")
        }
    }

    @Test("applyMention replaces only the active @query span cleanly")
    func applyMentionReplacement() {
        let text = "Check @first.swift and @Pers"
        let trigger = detectMentionTrigger(in: text)
        #expect(trigger != nil)
        if let trigger {
            let suggestion = TUIMentionSuggestion(
                kind: .file,
                value: "Sources/OpenCodeTUI/App/TUIPersistence.swift"
            )
            let updated = applyMention(suggestion, to: text, trigger: trigger)
            #expect(updated == "Check @first.swift and @Sources/OpenCodeTUI/App/TUIPersistence.swift ")
        }

        // Duplicate leading @ on suggestion.value is normalized cleanly
        let bareText = "@ex"
        if let bareTrigger = detectMentionTrigger(in: bareText) {
            let sug = TUIMentionSuggestion(kind: .agent, value: "@explore")
            #expect(applyMention(sug, to: bareText, trigger: bareTrigger) == "@explore ")
        }
    }

    @Test("buildMentionSuggestions ranks exact, prefix, and substring matches across agents and files capped at 12")
    func buildMentionSuggestionsRanking() {
        let agents = [
            TUIAgentItem(id: "general", name: "General", description: "General purpose agent"),
            TUIAgentItem(id: "explore", name: "Explore", description: "Fast codebase explorer"),
            TUIAgentItem(id: "plan", name: "Plan", description: "Planning agent"),
        ]
        let files = [
            "Sources/OpenCodeTUI/App/TUIPersistence.swift",
            "Sources/OpenCodeTUI/App/TUIAutocompleteAndPrompt.swift",
            "Sources/explore_helpers.swift",
            "docs/my-explore-notes.md",
            "README.md",
            "Package.swift",
            "Sources/file1.swift",
            "Sources/file2.swift",
            "Sources/file3.swift",
            "Sources/file4.swift",
            "Sources/file5.swift",
            "Sources/file6.swift",
            "Sources/file7.swift",
            "Sources/file8.swift",
            "Sources/file9.swift",
            "Sources/file10.swift",
        ]

        // Empty query returns agents first, then files, capped at 12
        let emptyResults = buildMentionSuggestions(query: "", files: files, agents: agents)
        #expect(emptyResults.count == 12)
        #expect(emptyResults[0].kind == .agent)
        #expect(emptyResults[0].value == "general")
        #expect(emptyResults[1].kind == .agent)
        #expect(emptyResults[1].value == "explore")
        #expect(emptyResults[2].kind == .agent)
        #expect(emptyResults[2].value == "plan")
        #expect(emptyResults[3].kind == .file)

        // Exact agent match beats file basename prefix beats substring
        let exploreResults = buildMentionSuggestions(query: "explore", files: files, agents: agents)
        #expect(exploreResults.count == 3)
        #expect(exploreResults[0].kind == .agent)
        #expect(exploreResults[0].value == "explore")
        #expect(exploreResults[0].display == "@explore")
        #expect(exploreResults[1].kind == .file)
        #expect(exploreResults[1].value == "Sources/explore_helpers.swift")
        #expect(exploreResults[2].kind == .file)
        #expect(exploreResults[2].value == "docs/my-explore-notes.md")

        // File query with line-range suffix still matches base file path
        let lineRangeResults = buildMentionSuggestions(query: "TUIPersistence.swift#10-20", files: files, agents: agents)
        #expect(lineRangeResults.first?.value == "Sources/OpenCodeTUI/App/TUIPersistence.swift")

        // Unmatched query returns empty
        #expect(buildMentionSuggestions(query: "nonexistent-xyz", files: files, agents: agents).isEmpty)
    }

    // MARK: - 4. TUISettingsCatalog

    @Test("TUISettingsCatalog covers all 11 settings and cycles every setting forward and backward cleanly")
    func settingsCatalogCycleAllForwardAndBackward() {
        #expect(TUISettingID.allCases.count == 11)
        #expect(TUISettingsCatalog.definitions.count == 11)
        #expect(Set(TUISettingsCatalog.definitions.map(\.id)) == Set(TUISettingID.allCases))

        // Verify every setting changes when cycled forward and returns when cycled backward
        for id in TUISettingID.allCases {
            var prefs = TUIPersistedPreferences.default
            let original = prefs
            let originalLabel = TUISettingsCatalog.valueLabel(for: id, preferences: prefs, detectedMode: .dark)

            TUISettingsCatalog.cycle(id, direction: 1, preferences: &prefs)
            #expect(prefs != original, "Setting \(id.rawValue) should change on forward cycle")
            let nextLabel = TUISettingsCatalog.valueLabel(for: id, preferences: prefs, detectedMode: .dark)
            #expect(nextLabel != originalLabel, "Value label for \(id.rawValue) should update after forward cycle")

            TUISettingsCatalog.cycle(id, direction: -1, preferences: &prefs)
            #expect(prefs == original, "Setting \(id.rawValue) should return to original after backward cycle")
        }

        // Verify multi-value wraparound for colorMode (.auto -> .dark -> .light -> .auto)
        var modePrefs = TUIPersistedPreferences.default
        #expect(TUISettingsCatalog.valueLabel(for: .colorMode, preferences: modePrefs, detectedMode: .light) == "auto (light)")
        TUISettingsCatalog.cycle(.colorMode, direction: 1, preferences: &modePrefs)
        #expect(modePrefs.themePreference == .dark)
        #expect(TUISettingsCatalog.valueLabel(for: .colorMode, preferences: modePrefs, detectedMode: .light) == "dark")
        TUISettingsCatalog.cycle(.colorMode, direction: 1, preferences: &modePrefs)
        #expect(modePrefs.themePreference == .light)
        #expect(TUISettingsCatalog.valueLabel(for: .colorMode, preferences: modePrefs, detectedMode: .light) == "light")
        TUISettingsCatalog.cycle(.colorMode, direction: 1, preferences: &modePrefs)
        #expect(modePrefs.themePreference == .auto)

        // Verify backward wraparound from .auto -> .light
        TUISettingsCatalog.cycle(.colorMode, direction: -1, preferences: &modePrefs)
        #expect(modePrefs.themePreference == .light)

        // Verify diffView 3-way wraparound ("auto" -> "split" -> "unified" -> "auto")
        var diffPrefs = TUIPersistedPreferences.default
        TUISettingsCatalog.cycle(.diffView, direction: 1, preferences: &diffPrefs)
        #expect(diffPrefs.diffView == "split")
        TUISettingsCatalog.cycle(.diffView, direction: 1, preferences: &diffPrefs)
        #expect(diffPrefs.diffView == "unified")
        TUISettingsCatalog.cycle(.diffView, direction: 1, preferences: &diffPrefs)
        #expect(diffPrefs.diffView == "auto")
        TUISettingsCatalog.cycle(.diffView, direction: -1, preferences: &diffPrefs)
        #expect(diffPrefs.diffView == "unified")
    }

    @Test("TUISettingsCatalog builds TUIDialogRows and filters by title, category, description, and keywords")
    func settingsCatalogRowsAndFiltering() {
        let prefs = TUIPersistedPreferences(
            themeName: "opencode",
            themePreference: .auto,
            animations: true,
            sidebarMode: "auto",
            showScrollbar: false,
            scrollOnSend: "bottom",
            showThinking: true,
            concealMarkdown: true,
            diffView: "auto",
            diffWrap: "word",
            pasteSummary: false
        )

        let allRows = TUISettingsCatalog.rows(filter: "", preferences: prefs, detectedMode: .dark)
        #expect(allRows.count == 11)
        #expect(allRows.first?.id == TUISettingID.theme.rawValue)
        #expect(allRows.first?.trailing == "opencode")

        let colorRow = allRows.first(where: { $0.id == TUISettingID.colorMode.rawValue })
        #expect(colorRow?.trailing == "auto (dark)")

        let scrollSendRow = allRows.first(where: { $0.id == TUISettingID.scrollOnSend.rawValue })
        #expect(scrollSendRow?.trailing == "jump to latest")

        // Filter by keyword ("chain of thought" -> thinking)
        let thinkingRows = TUISettingsCatalog.rows(filter: "chain of thought", preferences: prefs, detectedMode: .dark)
        #expect(thinkingRows.map(\.id) == [TUISettingID.thinking.rawValue])

        // Filter by category ("Diffs" -> diffView & diffWrap)
        let diffRows = TUISettingsCatalog.rows(filter: "diffs", preferences: prefs, detectedMode: .dark)
        #expect(Set(diffRows.map(\.id)) == [TUISettingID.diffView.rawValue, TUISettingID.diffWrap.rawValue])

        // Filter by keyword ("clipboard" -> pasteSummary)
        let pasteRows = TUISettingsCatalog.rows(filter: "clipboard", preferences: prefs, detectedMode: .dark)
        #expect(pasteRows.map(\.id) == [TUISettingID.pasteSummary.rawValue])
        #expect(pasteRows.first?.trailing == "full")
    }

    // MARK: - 5. TUIExternalEditor & TUITranscriptFormatter

    @Test("TUIExternalEditor.resolveEditorCommand honors VISUAL, EDITOR, fallback vi, and quoted arguments")
    func externalEditorCommandResolution() {
        #expect(TUIExternalEditor.resolveEditorCommand(environment: [:]) == ["vi"])
        #expect(TUIExternalEditor.resolveEditorCommand(environment: ["VISUAL": "   ", "EDITOR": ""]) == ["vi"])

        #expect(
            TUIExternalEditor.resolveEditorCommand(environment: [
                "VISUAL": "code --wait",
                "EDITOR": "nano",
            ]) == ["code", "--wait"]
        )

        #expect(
            TUIExternalEditor.resolveEditorCommand(environment: [
                "VISUAL": "   ",
                "EDITOR": "nvim -u NONE",
            ]) == ["nvim", "-u", "NONE"]
        )

        #expect(
            TUIExternalEditor.resolveEditorCommand(environment: [
                "VISUAL": #""/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" --wait "--title=Prompt Draft""#,
            ]) == [
                "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
                "--wait",
                "--title=Prompt Draft",
            ]
        )

        #expect(
            TUIExternalEditor.resolveEditorCommand(environment: [
                "EDITOR": "'/opt/my editor/bin/edit' -c 'set ft=markdown'",
            ]) == [
                "/opt/my editor/bin/edit",
                "-c",
                "set ft=markdown",
            ]
        )

        #expect(
            TUIExternalEditor.resolveEditorCommand(environment: [
                "EDITOR": #"/usr/local/bin/my\ editor --flag"#,
            ]) == [
                "/usr/local/bin/my editor",
                "--flag",
            ]
        )
    }

    #if os(macOS) || os(Linux)
    @Test("TUIExternalEditor.editInExternalEditor writes temp .md file, reads updated content, and cleans up")
    func externalEditorEndToEndTempFileRoundTrip() throws {
        let tempDir = try TUIComposerPersistenceHelper.makeTemporaryDirectory()
        defer { TUIComposerPersistenceHelper.removePath(tempDir) }

        // Script appends a second line to the passed .md file
        let edited = try TUIExternalEditor.editInExternalEditor(
            initialText: "Initial draft",
            environment: [
                "EDITOR": #"/bin/sh -c 'printf "\nEdited line" >> "$1"' _"#,
            ],
            tempDir: tempDir
        )
        #expect(edited == "Initial draft\nEdited line")
        #expect(TUIComposerPersistenceHelper.listDirectory(tempDir).isEmpty)

        // Emptying the file returns nil and cleans up
        let cleared = try TUIExternalEditor.editInExternalEditor(
            initialText: "Will be cleared",
            environment: [
                "EDITOR": #"/bin/sh -c ': > "$1"' _"#,
            ],
            tempDir: tempDir
        )
        #expect(cleared == nil)
        #expect(TUIComposerPersistenceHelper.listDirectory(tempDir).isEmpty)

        // Non-zero exit throws ExternalEditorError.nonZeroExit and still cleans up temp file
        #expect(throws: TUIExternalEditor.ExternalEditorError.nonZeroExit(42)) {
            _ = try TUIExternalEditor.editInExternalEditor(
                initialText: "Fail test",
                environment: [
                    "EDITOR": "/bin/sh -c 'exit 42' _",
                ],
                tempDir: tempDir
            )
        }
        #expect(TUIComposerPersistenceHelper.listDirectory(tempDir).isEmpty)
    }
    #endif

    @Test("TUITranscriptFormatter formats complete and filtered Markdown transcripts")
    func transcriptMarkdownFormatting() {
        let empty = TUITranscriptFormatter.formatMarkdownTranscript(title: "   ", messages: [])
        #expect(empty == "# OpenCode Session\n")

        let messages: [TUITranscriptItem] = [
            .user(id: "u1", text: "Fix the build warnings.", agentName: "Build", isOptimistic: false),
            .assistant(
                id: "a1",
                agentName: "Build",
                modelLabel: "Claude Sonnet 4.5",
                parts: [
                    .reasoning(id: "r1", text: "Checking Package.swift and compiler diagnostics.", completed: true),
                    .tool(
                        id: "t1",
                        name: "shell",
                        status: .completed,
                        summary: "swift build",
                        outputPreview: "Build complete!",
                        error: nil
                    ),
                    .tool(
                        id: "t2",
                        name: "read",
                        status: .error,
                        summary: "missing.swift",
                        outputPreview: nil,
                        error: "File not found"
                    ),
                    .text(id: "p1", text: "All warnings have been resolved."),
                ],
                completed: true,
                error: nil
            ),
            .system(id: "s1", text: "Session compacted.", isError: false),
            .system(id: "s2", text: "Rate limit exceeded.", isError: true),
        ]

        let full = TUITranscriptFormatter.formatMarkdownTranscript(
            title: "Build Warning Cleanup",
            messages: messages
        )
        #expect(full.hasPrefix("# Build Warning Cleanup\n\n---\n\n"))
        #expect(full.contains("## User\n\nFix the build warnings."))
        #expect(full.contains("## Assistant (Build · Claude Sonnet 4.5)"))
        #expect(full.contains("_Thinking:_\n\nChecking Package.swift and compiler diagnostics."))
        #expect(full.contains("**Tool: shell** `swift build` (completed)"))
        #expect(full.contains("```\nBuild complete!\n```"))
        #expect(full.contains("**Tool: read** `missing.swift` (error)"))
        #expect(full.contains("**Error:** File not found"))
        #expect(full.contains("All warnings have been resolved."))
        #expect(full.contains("## System\n\nSession compacted."))
        #expect(full.contains("## System Error\n\nRate limit exceeded."))

        let stripped = TUITranscriptFormatter.formatMarkdownTranscript(
            title: "Build Warning Cleanup",
            messages: messages,
            includeThinking: false,
            includeTools: false
        )
        #expect(!stripped.contains("_Thinking:_"))
        #expect(!stripped.contains("**Tool:"))
        #expect(stripped.contains("All warnings have been resolved."))
    }
}
