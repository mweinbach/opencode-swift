import Testing
import OpenCodeGUIPlugins
import OpenCodeUtil

@Suite("File Plugin Domain & State Machines")
struct FilePluginTests {
    @Test("path helpers, open-in-app resolution, and drag payloads match upstream")
    func pathAndDragHelpers() {
        #expect(FilePathHelper.pathToFileUrl("/repo/my file.swift") == "file:///repo/my%20file.swift")
        #expect(FilePathHelper.isFileTab("//src/app.swift"))
        #expect(FilePathHelper.resolveOpenInAppPath(root: "/repo/", path: "src/main.swift") == "/repo/src/main.swift")
        #expect(FilePathHelper.resolveOpenInAppPath(root: #"C:\repo\"#, path: "src/main.swift") == #"C:\repo\src\main.swift"#)
        #expect(FilePathHelper.resolveOpenInAppPath(root: "/repo", path: "skill://demo") == "skill://demo")
        #expect(FilePathHelper.openInAppParentPath("/repo/src/main.swift") == "/repo/src")
        #expect(FilePathHelper.openInAppParentPath("/README.md") == "/")
        #expect(FilePathHelper.openInAppParentPath(#"C:\README.md"#) == #"C:\"#)

        let drag = FileDragPayload(path: "src/app.swift")
        #expect(drag.plainText == "file:src/app.swift")
        #expect(drag.uriList == "file://src/app.swift")
        #expect(OpenApp.allCases.count == 14)
    }

    @Test("artifact helpers parse RFC 4180 CSV, relative links, bytes, and YAML frontmatter")
    func artifactHelpers() throws {
        let csv = #"""
        name,note
        "Alice","Hello, ""World"""
        Bob,Line1
        """#
        let table = ArtifactHelper.parseDelimited(csv, delimiter: ",")
        #expect(table.total == 3)
        #expect(table.columns == 2)
        #expect(table.rows[1] == ["Alice", #"Hello, "World""#])

        let limited = ArtifactHelper.parseDelimited("a\nb\nc\nd", delimiter: ",", limit: 2)
        #expect(limited.rows.count == 2)
        #expect(limited.total == 4)

        #expect(ArtifactHelper.resolveArtifactPath(base: "docs/guides", href: "../img/a.png") == "docs/img/a.png")
        #expect(ArtifactHelper.resolveArtifactPath(base: "docs", href: "../../escape.txt") == nil)
        #expect(ArtifactHelper.resolveArtifactPath(base: "docs", href: "/abs.txt") == nil)

        let b64 = GUIFileContent(type: .binary, content: "SGVsbG8=", encoding: .base64, mimeType: "text/plain")
        #expect(ArtifactHelper.contentBytes(b64) == 5)
        #expect(try ArtifactHelper.bytesFromContent(b64) == Array("Hello".utf8))

        let md = """
        ---
        title: "Release Notes"
        summary: >
          First line
          second line
        ---
        # Heading
        """
        let split = ArtifactHelper.splitFrontmatter(md)
        #expect(split.properties == [
            FrontmatterProperty(key: "title", value: "Release Notes", code: false),
            FrontmatterProperty(key: "summary", value: "First line second line", code: false),
        ])
        #expect(split.body == "# Heading")

        // Unparseable frontmatter with inline comment falls back to fenced yaml block
        let fallbackMD = "---\nkey: val # comment\n---\nBody"
        let fallback = ArtifactHelper.splitFrontmatter(fallbackMD)
        #expect(fallback.properties == nil)
        #expect(fallback.body.hasPrefix("```yaml\nkey: val # comment\n```"))
    }

    @Test("artifact viewer, image stage gesture, and video overlay state machines transition accurately")
    func artifactViewerAndMediaMachines() {
        let svgContent = GUIFileContent(type: .text, content: "<svg/>")
        var viewer = ArtifactViewerMachine.createState(content: svgContent)
        #expect(ArtifactViewerMachine.fixedMode(path: "icon.svg", content: svgContent) == nil)
        #expect(ArtifactViewerMachine.fixedMode(path: "main.swift", content: svgContent) == .source)

        viewer = ArtifactViewerMachine.reduce(state: viewer, content: svgContent, event: .infoReported(content: svgContent, info: ArtifactInfo(width: 64, height: 64)))
        #expect(ArtifactViewerMachine.selectInfo(state: viewer, content: svgContent).width == 64)

        viewer = ArtifactViewerMachine.reduce(state: viewer, content: svgContent, event: .decodeFailed(content: svgContent, reason: "Invalid XML"))
        #expect(ArtifactViewerMachine.selectStageKind(state: viewer, path: "icon.svg", content: svgContent) == .binary)
        #expect(ArtifactViewerMachine.selectReason(state: viewer, content: svgContent) == "Invalid XML")
        viewer = ArtifactViewerMachine.reduce(state: viewer, content: svgContent, event: .modeChanged(.source))
        #expect(ArtifactViewerMachine.selectMode(state: viewer, content: svgContent) == .source)

        // Image stage gesture machine suppresses click after drag pan
        var gesture = ImageStageGestureMachine.initialState
        let g1 = ImageStageGestureMachine.reduce(state: gesture, event: .pointerDown(pointerID: 1, button: 0, primary: true, zoomed: true))
        gesture = g1.state
        #expect(g1.effects == [.pointerCapture(pointerID: 1)])
        #expect(ImageStageGestureMachine.cursor(gesture, zoomed: true) == .grabbing)
        gesture = ImageStageGestureMachine.reduce(state: gesture, event: .pointerMoved(pointerID: 1)).state
        gesture = ImageStageGestureMachine.reduce(state: gesture, event: .pointerUp(pointerID: 1)).state
        #expect(ImageStageGestureMachine.clickSuppressed(gesture))
        gesture = ImageStageGestureMachine.reduce(state: gesture, event: .click).state
        #expect(!ImageStageGestureMachine.clickSuppressed(gesture))

        // Video overlay controls hide after idle timeout
        var video = VideoOverlayMachine.createState()
        #expect(VideoOverlayMachine.isLoading(video))
        let v1 = VideoOverlayMachine.reduce(state: video, event: .mediaLoaded(paused: false))
        video = v1.state
        #expect(VideoOverlayMachine.controlsVisible(video))
        #expect(v1.effects == [.idleSchedule(attempt: 1, delayMs: VideoOverlayMachine.idleMs)])
        video = VideoOverlayMachine.reduce(state: video, event: .idleElapsed(attempt: 1)).state
        #expect(!VideoOverlayMachine.controlsVisible(video))
    }

    @Test("file tree model, picker LRU, search, open-in-app, link-exists TTL, and link-open machines work cleanly")
    func treePickerSearchAndLinkMachines() async {
        // Tree model
        let allowed = FileTreeModel.buildAllowedTreeInput(paths: ["src/a.swift", "untracked/"])
        #expect(allowed.directories == ["src", "untracked"])
        #expect(allowed.untrackedDirs == ["untracked"])
        let collapsed = FileTreeModel.collectAllowedCollapsedDirs(model: allowed) { _ in nil }
        #expect(collapsed == ["untracked"])

        // Picker LRU eviction at 40 sessions
        var picker = FilePickerMachine.createState()
        for i in 0..<45 {
            picker = FilePickerMachine.reduce(state: picker, event: .filterChanged(sessionKey: "ses_\(i)", text: "q\(i)")).state
        }
        #expect(FilePickerMachine.filterText(picker, sessionKey: "ses_0") == "")
        #expect(FilePickerMachine.filterText(picker, sessionKey: "ses_44") == "q44")

        // File link resolver
        let parsed = FileLinkResolver.parseFileLink("file:///repo/src/app.swift#L12-L20")
        #expect(parsed.path == "/repo/src/app.swift")
        #expect(parsed.selection == LineRangeSelection(start: 12, end: 20))
        #expect(FileLinkResolver.matchRelativeLink(path: "app.swift", searchResults: ["a/app.swift", "b/app.swift"]) == .picker(query: "app.swift"))
        #expect(FileLinkResolver.matchRelativeLink(path: "a/app.swift", searchResults: ["a/app.swift", "b/a/app.swift"]) == .file(path: "a/app.swift"))

        // LinkExistsMachine TTL and stale-while-revalidate
        var linkCache = LinkExistsMachine.createState()
        let c1 = LinkExistsMachine.reduce(state: linkCache, event: .checkRequested(key: "src/a.swift", now: 1_000))
        linkCache = c1.state
        #expect(LinkExistsMachine.answer(linkCache, key: "src/a.swift") == .pending(attempt: 1))
        linkCache = LinkExistsMachine.reduce(state: linkCache, event: .checkSettled(key: "src/a.swift", attempt: 1, exists: true, now: 1_000)).state
        #expect(LinkExistsMachine.answer(linkCache, key: "src/a.swift") == .value(true))
        // After 60s positive TTL expires, revalidation still answers true (no flash!)
        let c2 = LinkExistsMachine.reduce(state: linkCache, event: .checkRequested(key: "src/a.swift", now: 62_000))
        linkCache = c2.state
        #expect(LinkExistsMachine.answer(linkCache, key: "src/a.swift") == .value(true))
        #expect(c2.effects == [.runCheck(key: "src/a.swift", attempt: 2, timeoutMs: LinkExistsMachine.timeoutMs)])

        // OpenInAppMachine checks and single-flight launch
        let browser = FileBrowserController(preferredApp: .zed)
        #expect(await browser.toggleDirectory("src/"))
        #expect(await browser.isExpanded("src"))
        let checkEffects = await browser.dispatchOpenInApp(.appsRequested(openWith: ["Zed", "Xcode"]))
        #expect(checkEffects.count == 2)
        _ = await browser.dispatchOpenInApp(.appChecked(attempt: 1, openWith: "Zed", installed: true))
        #expect(OpenInAppMachine.isAppInstalled(await browser.currentOpenInAppState(), openWith: "Zed"))
        let launchEffects = await browser.dispatchOpenInApp(.launchRequested(app: .finder, target: "/repo/a.swift", openWith: "Finder", reveal: true))
        #expect(launchEffects == [.runLaunch(attempt: 3, target: "/repo/a.swift", openWith: "Finder", reveal: true, timeoutMs: OpenInAppMachine.launchTimeoutMs)])
    }

    @Test("file search & link-open machines preserve stale results during typing and fence route changes")
    func searchAndLinkOpenMachines() {
        let scope = FileSearchMachine.Scope(serverID: "srv", root: "/repo")
        var search = FileSearchMachine.initialState
        let s1 = FileSearchMachine.reduce(state: search, event: .contextChanged(FileSearchMachine.Context(scope: scope, connected: true, query: "app")))
        search = s1.state
        #expect(s1.effects == [.search(scope: scope, query: "app", attempt: 1, timeoutMs: FileSearchMachine.timeoutMs)])
        search = FileSearchMachine.reduce(state: search, event: .searchSucceeded(attempt: 1, files: ["src/app.swift", "src/app.swift"])).state
        #expect(FileSearchMachine.view(search) == .results(files: ["src/app.swift"], stale: false))

        // Typing next query keeps previous results visible as stale while searching
        let s2 = FileSearchMachine.reduce(state: search, event: .contextChanged(FileSearchMachine.Context(scope: scope, connected: true, query: "app2")))
        #expect(FileSearchMachine.view(s2.state) == .results(files: ["src/app.swift"], stale: true))

        // LinkOpenMachine resolves -> syncs -> opens file with selection, ignoring results if route changed
        var link = LinkOpenMachine.createState()
        let route = LinkOpenMachine.Route(sessionKey: "s1", root: "/repo", sameScreen: true)
        let l1 = LinkOpenMachine.reduce(
            state: link,
            event: .linkClicked(sessionKey: "s1", root: "/repo", href: "src/app.swift:10", base: nil, background: false)
        )
        link = l1.state
        let l2 = LinkOpenMachine.reduce(
            state: link,
            event: .linkResolved(attempt: 1, route: route, resolution: .file(path: "src/app.swift", selection: LineRangeSelection(start: 10, end: 10)))
        )
        link = l2.state
        #expect(l2.effects == [.sync(attempt: 1, path: "src/app.swift")])
        let l3 = LinkOpenMachine.reduce(
            state: link,
            event: .fileSynced(attempt: 1, route: route, loaded: true, notFound: false, opened: false, error: nil)
        )
        #expect(l3.effects == [
            .abort(attempt: 1),
            .openFile(path: "src/app.swift", selection: LineRangeSelection(start: 10, end: 10), background: false),
        ])
    }
}
