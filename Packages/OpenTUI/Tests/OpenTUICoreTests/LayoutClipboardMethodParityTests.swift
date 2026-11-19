import Testing
import OpenTUICore
import OpenTUILayout
import OpenTUITerminal
import Synchronization

// MARK: - 1. Yoga Native Bridge & Config Method Parity

@Suite("YogaNativeBridgeMethodParity")
struct YogaNativeBridgeMethodParityTests {
    @Test("Yoga default namespace and Config native lifecycle (init, setLogger, createNode, hasLiveNodes, deinit)")
    func yogaNamespaceAndConfigLifecycle() throws {
        // Default export facade (`core/src/yoga.ts#default`)
        #expect(Yoga.ALIGN_CENTER == .center)
        #expect(Yoga.FLEX_DIRECTION_ROW == .row)
        #expect(Yoga.UNIT_PERCENT == .percent)

        let host = YogaHost()
        let logs = Mutex<[(LogLevel, String)]>([])
        let config = YogaConfig(host: host, callbacks: YogaBridgeCallbacks(), heapOwned: true)
        #expect(!config.useWebDefaults())
        #expect(config.getPointScaleFactor() == 1.0)
        #expect(!config.hasLiveNodes())

        config.setLogger { level, message in
            logs.withLock { $0.append((level, message)) }
        }
        config.emitLog(level: .warn, message: "test diagnostic")
        let captured = logs.withLock { $0 }
        #expect(captured.count == 1)
        #expect(captured[0].0 == .warn)
        #expect(captured[0].1 == "Yoga: test diagnostic")

        let node = try config.createNode()
        #expect(config.hasLiveNodes())
        #expect(YogaNativeBridge.yogaNodeGetConfig(node) === config)

        // Cannot deinit while a live node is owned
        #expect(throws: YogaError.self) {
            try config.deinitConfig()
        }
        #expect(YogaNativeBridge.yogaConfigFreeChecked(config) == .busy)

        #expect(YogaNativeBridge.yogaNodeFreeChecked(node) == .ok)
        #expect(!config.hasLiveNodes())
        try config.deinitConfig()
        #expect(config.isFreed)
    }

    @Test("YogaNativeBridge config checked APIs enforce bounds and ownership")
    func configCheckedAPIs() {
        var config: YogaConfig? = nil
        #expect(YogaNativeBridge.yogaConfigCreateChecked(&config) == .ok)
        #expect(config != nil)

        #expect(YogaNativeBridge.yogaConfigSetUseWebDefaultsChecked(config, 1) == .ok)
        #expect(YogaNativeBridge.yogaConfigGetUseWebDefaults(config) == true)
        #expect(YogaNativeBridge.yogaConfigSetUseWebDefaultsChecked(config, 2) == .invalidArgument)

        #expect(YogaNativeBridge.yogaConfigSetPointScaleFactorChecked(config, 2.5) == .ok)
        #expect(YogaNativeBridge.yogaConfigGetPointScaleFactor(config) == 2.5)
        #expect(YogaNativeBridge.yogaConfigSetPointScaleFactorChecked(config, -1.0) == .invalidArgument)
        #expect(YogaNativeBridge.yogaConfigSetPointScaleFactorChecked(config, .nan) == .invalidArgument)
        #expect(YogaNativeBridge.yogaConfigSetPointScaleFactorChecked(config, .infinity) == .invalidArgument)

        #expect(YogaNativeBridge.yogaConfigSetErrataChecked(config, UInt32(Errata.stretchFlexBasis.rawValue)) == .ok)
        #expect(YogaNativeBridge.yogaConfigSetErrataChecked(config, UInt32(bitPattern: Errata.classic.rawValue)) == .ok)
        #expect(YogaNativeBridge.yogaConfigSetErrataChecked(config, 99) == .invalidArgument)

        var expEnabled: UInt32 = 0
        #expect(YogaNativeBridge.yogaConfigSetExperimentalFeatureEnabledChecked(config, 0, 1) == .ok)
        #expect(YogaNativeBridge.yogaConfigIsExperimentalFeatureEnabledChecked(config, 0, &expEnabled) == .ok)
        #expect(expEnabled == 1)
        #expect(YogaNativeBridge.yogaConfigSetExperimentalFeatureEnabledChecked(config, 7, 1) == .invalidArgument)
        #expect(YogaNativeBridge.yogaConfigIsExperimentalFeatureEnabledChecked(config, 7, &expEnabled) == .invalidArgument)

        #expect(YogaNativeBridge.yogaConfigFree(config) == true)
        #expect(YogaNativeBridge.yogaConfigFreeChecked(config) == .invalidArgument)

        // Default OpenTUI config is process-owned and cannot be freed via yogaConfigFreeChecked
        let openTUINode = YogaNativeBridge.yogaNodeCreateForOpenTUI()
        #expect(openTUINode != nil)
        let defaultCfg = YogaNativeBridge.yogaNodeGetConfig(openTUINode)
        #expect(defaultCfg != nil)
        YogaNativeBridge.yogaNodeFree(openTUINode)
        #expect(YogaNativeBridge.yogaConfigFreeChecked(defaultCfg) == .invalidArgument)
    }

    @Test("YogaNativeBridge tree operations, moveChild, reset, copyStyle, depth limit, and cycle guards")
    func treeOperationsAndGuards() {
        let cfg = YogaNativeBridge.yogaConfigCreate()
        #expect(cfg != nil)
        defer { _ = YogaNativeBridge.yogaConfigFree(cfg) }

        var root: YogaNode? = nil
        var childA: YogaNode? = nil
        var childB: YogaNode? = nil
        var otherParent: YogaNode? = nil
        #expect(YogaNativeBridge.yogaNodeCreateWithConfigChecked(cfg, &root) == .ok)
        #expect(YogaNativeBridge.yogaNodeCreateWithConfigChecked(cfg, &childA) == .ok)
        #expect(YogaNativeBridge.yogaNodeCreateWithConfigChecked(cfg, &childB) == .ok)
        #expect(YogaNativeBridge.yogaNodeCreateWithConfigChecked(cfg, &otherParent) == .ok)

        // Insert & parent/child checks
        #expect(YogaNativeBridge.yogaNodeInsertChildChecked(root, childA, 0) == .ok)
        #expect(YogaNativeBridge.yogaNodeInsertChildChecked(root, childB, 1) == .ok)
        #expect(YogaNativeBridge.yogaNodeGetParent(childA) === root)

        // Reject inserting already-owned child, self-insertion, ancestor cycles, and out-of-range index
        #expect(YogaNativeBridge.yogaNodeInsertChildChecked(otherParent, childA, 0) == .invalidArgument)
        #expect(YogaNativeBridge.yogaNodeInsertChildChecked(root, root, 0) == .invalidArgument)
        #expect(YogaNativeBridge.yogaNodeInsertChildChecked(childA, root, 0) == .invalidArgument)
        #expect(YogaNativeBridge.yogaNodeInsertChildChecked(root, otherParent, 99) == .invalidArgument)

        // Move within same parent & across parents
        #expect(YogaNativeBridge.yogaNodeMoveChildChecked(root, childB, 0) == .ok)
        var firstChild: YogaNode? = nil
        #expect(YogaNativeBridge.yogaNodeGetChildChecked(root, 0, &firstChild) == .ok)
        #expect(firstChild === childB)
        #expect(YogaNativeBridge.yogaNodeMoveChildChecked(otherParent, childB, 0) == .ok)
        #expect(YogaNativeBridge.yogaNodeGetParent(childB) === otherParent)

        // Out-of-bounds getChildChecked succeeds with nil output
        var missingChild: YogaNode? = childA
        #expect(YogaNativeBridge.yogaNodeGetChildChecked(root, 42, &missingChild) == .ok)
        #expect(missingChild == nil)

        // Reset rejects attached or parent nodes; succeeds once detached
        #expect(YogaNativeBridge.yogaNodeResetChecked(root) == .invalidArgument)
        #expect(YogaNativeBridge.yogaNodeResetChecked(childA) == .invalidArgument)
        #expect(YogaNativeBridge.yogaNodeRemoveAllChildrenChecked(root) == .ok)
        #expect(YogaNativeBridge.yogaNodeResetChecked(root) == .ok)
        #expect(YogaNativeBridge.yogaNodeResetChecked(childA) == .ok)

        // Copy style checked
        YogaNativeBridge.yogaNodeStyleSetValue(childA, UInt32(YogaValueKind.width.rawValue), 0, UInt32(Unit.point.rawValue), 33)
        #expect(YogaNativeBridge.yogaNodeCopyStyleChecked(root, childA) == .ok)
        var packedWidth: UInt64 = 0
        #expect(YogaNativeBridge.yogaNodeStyleGetValueChecked(root, UInt32(YogaValueKind.width.rawValue), 0, &packedWidth) == .ok)
        #expect(UInt32(packedWidth & 0xFFFF_FFFF) == UInt32(Unit.point.rawValue))
        #expect(Float(bitPattern: UInt32(packedWidth >> 32)) == 33)

        // Free recursive tears down entire subtree
        YogaNativeBridge.yogaNodeInsertChild(otherParent, childA, 1)
        #expect(YogaNativeBridge.yogaNodeFreeRecursiveChecked(otherParent) == .ok)
        #expect(otherParent?.isFreed() == true)
        #expect(childA?.isFreed() == true)
        #expect(childB?.isFreed() == true)
        #expect(YogaNativeBridge.yogaNodeFreeChecked(root) == .ok)

        // Depth limit guard (`depthMax == 256`)
        var chain: [YogaNode] = []
        for _ in 0..<Int(YogaNativeBridge.depthMax) {
            if let n = YogaNativeBridge.yogaNodeCreateWithConfig(cfg) {
                if let prev = chain.last {
                    #expect(YogaNativeBridge.yogaNodeInsertChildChecked(prev, n, 0) == .ok)
                }
                chain.append(n)
            }
        }
        let overflowLeaf = YogaNativeBridge.yogaNodeCreateWithConfig(cfg)
        #expect(YogaNativeBridge.yogaNodeInsertChildChecked(chain.last, overflowLeaf, 0) == .depthLimit)
        YogaNativeBridge.yogaNodeFree(overflowLeaf)
        YogaNativeBridge.yogaNodeFreeRecursive(chain.first)
    }

    @Test("YogaNativeBridge style enums, floats, borders, values, dimensions, positions, flags, and callbacks")
    func stylesLayoutAndCallbacks() {
        let cfg = YogaNativeBridge.yogaConfigCreate()!
        defer { _ = YogaNativeBridge.yogaConfigFree(cfg) }

        let root = YogaNativeBridge.yogaNodeCreateWithConfig(cfg)!
        let leaf = YogaNativeBridge.yogaNodeCreateWithConfig(cfg)!
        YogaNativeBridge.yogaNodeInsertChild(root, leaf, 0)

        // Enum get/set + layoutMode scene-config gating
        #expect(YogaNativeBridge.yogaNodeStyleSetEnumChecked(root, UInt32(YogaEnumKind.flexDirection.rawValue), 2) == .ok)
        #expect(YogaNativeBridge.yogaNodeStyleGetEnum(root, UInt32(YogaEnumKind.flexDirection.rawValue)) == 2)
        #expect(YogaNativeBridge.yogaNodeStyleSetEnumChecked(root, UInt32(YogaEnumKind.alignItems.rawValue), UInt32(Align.flexStart.rawValue)) == .ok)
        #expect(YogaNativeBridge.yogaNodeStyleSetEnumChecked(root, UInt32(YogaEnumKind.layoutMode.rawValue), 1) == .invalidArgument)
        cfg.setRoundsPositionsFromAbsoluteEdges(true)
        #expect(YogaNativeBridge.yogaNodeStyleSetEnumChecked(root, UInt32(YogaEnumKind.layoutMode.rawValue), 1) == .ok)
        var outMode: UInt32 = 0
        #expect(YogaNativeBridge.yogaNodeStyleGetEnumChecked(root, UInt32(YogaEnumKind.layoutMode.rawValue), &outMode) == .ok)
        #expect(outMode == 1)

        // Float & border checked
        #expect(YogaNativeBridge.yogaNodeStyleSetFloatChecked(leaf, UInt32(YogaFloatKind.flexGrow.rawValue), 2.0) == .ok)
        #expect(YogaNativeBridge.yogaNodeStyleSetFloatChecked(leaf, UInt32(YogaFloatKind.flexGrow.rawValue), .infinity) == .invalidArgument)
        var growVal: Float = 0
        #expect(YogaNativeBridge.yogaNodeStyleGetFloatChecked(leaf, UInt32(YogaFloatKind.flexGrow.rawValue), &growVal) == .ok)
        #expect(growVal == 2.0)

        #expect(YogaNativeBridge.yogaNodeStyleSetBorderChecked(root, UInt32(Edge.left.rawValue), 2) == .ok)
        var borderVal: Float = 0
        #expect(YogaNativeBridge.yogaNodeStyleGetBorderChecked(root, UInt32(Edge.left.rawValue), &borderVal) == .ok)
        #expect(borderVal == 2)

        // Value auto rejection on padding/gap, acceptance on width/margin
        #expect(YogaNativeBridge.yogaNodeStyleSetValueChecked(root, UInt32(YogaValueKind.padding.rawValue), UInt32(Edge.top.rawValue), UInt32(Unit.auto.rawValue), .nan) == .invalidArgument)
        #expect(YogaNativeBridge.yogaNodeStyleSetValueChecked(root, UInt32(YogaValueKind.padding.rawValue), UInt32(Edge.top.rawValue), UInt32(Unit.point.rawValue), 4) == .ok)

        // Dimension with disableFlexShrink
        YogaNativeBridge.yogaNodeStyleSetFloat(leaf, UInt32(YogaFloatKind.flexShrink.rawValue), 3)
        #expect(YogaNativeBridge.yogaNodeStyleSetDimensionChecked(leaf, UInt32(Dimension.width.rawValue), UInt32(Unit.point.rawValue), 20, 1) == .ok)
        var shrinkVal: Float = -1
        #expect(YogaNativeBridge.yogaNodeStyleGetFloatChecked(leaf, UInt32(YogaFloatKind.flexShrink.rawValue), &shrinkVal) == .ok)
        #expect(shrinkVal == 0)

        // Positions batch setter
        #expect(YogaNativeBridge.yogaNodeStyleSetPositionsChecked(
            leaf,
            0b0101,
            [UInt32(Unit.point.rawValue), 0, UInt32(Unit.percent.rawValue), 0],
            [5, 0, 25, 0]
        ) == .ok)
        #expect(YogaNativeBridge.yogaNodeStyleSetPositionsChecked(leaf, 0b10000, [0, 0, 0, 0], [0, 0, 0, 0]) == .invalidArgument)
        let packedRight = YogaNativeBridge.yogaNodeStyleGetValue(leaf, UInt32(YogaValueKind.position.rawValue), UInt32(Edge.right.rawValue))
        #expect(UInt32(packedRight & 0xFFFF_FFFF) == UInt32(Unit.percent.rawValue))
        #expect(Float(bitPattern: UInt32(packedRight >> 32)) == 25)

        // Callback owner exclusivity, measure trampoline + yogaStoreMeasureResult, dirtied trampoline
        let dirtiedCount = Mutex<Int>(0)
        #expect(YogaNativeBridge.yogaConfigSetCallbacks(
            cfg,
            ownerID: 10,
            measure: { node, _, _, _, _ in
                YogaNativeBridge.yogaStoreMeasureResult(YogaNativeBridge.yogaNodeGetConfig(node), 14, 6)
            },
            dirtied: { _ in
                dirtiedCount.withLock { $0 += 1 }
            }
        ) == true)
        #expect(YogaNativeBridge.yogaConfigSetCallbacks(cfg, ownerID: 99, measure: { _, _, _, _, _ in }, dirtied: { _ in }) == false)
        #expect(YogaNativeBridge.yogaConfigClearCallbacks(cfg, ownerID: 99) == false)

        // Measure func rejected on parent with children, accepted on leaf
        #expect(YogaNativeBridge.yogaNodeSetMeasureFuncChecked(root, 1) == .invalidArgument)
        #expect(YogaNativeBridge.yogaNodeSetMeasureFuncChecked(leaf, 1) == .ok)
        #expect(YogaNativeBridge.yogaNodeHasMeasureFunc(leaf) == true)
        #expect(YogaNativeBridge.yogaNodeSetDirtiedFuncChecked(leaf, 1) == .ok)

        // Layout calculation, flags, and edge getters
        #expect(YogaNativeBridge.yogaNodeCalculateLayoutChecked(root, 80, 24, UInt32(Direction.ltr.rawValue)) == .ok)
        #expect(YogaNativeBridge.yogaNodeCalculateLayoutChecked(root, -5, 24, UInt32(Direction.ltr.rawValue)) == .invalidArgument)
        #expect(YogaNativeBridge.yogaNodeCalculateLayoutChecked(root, 80, 24, 9) == .invalidArgument)

        var layout = YogaLayout.zero
        #expect(YogaNativeBridge.yogaNodeGetComputedLayoutChecked(leaf, &layout) == .ok)
        #expect(layout.height == 6)

        var padTop: Float = 0
        #expect(YogaNativeBridge.yogaNodeLayoutGetEdgeChecked(root, 1, UInt32(Edge.top.rawValue), &padTop) == .ok)
        #expect(padTop == 4)
        #expect(YogaNativeBridge.yogaNodeLayoutGetEdgeChecked(root, 3, 0, &padTop) == .invalidArgument)

        var hasNewLayout: UInt32 = 0
        #expect(YogaNativeBridge.yogaNodeGetHasNewLayoutChecked(leaf, &hasNewLayout) == .ok)
        #expect(hasNewLayout == 1)
        #expect(YogaNativeBridge.yogaNodeSetHasNewLayoutChecked(leaf, 0) == .ok)
        #expect(YogaNativeBridge.yogaNodeGetHasNewLayoutChecked(leaf, &hasNewLayout) == .ok)
        #expect(hasNewLayout == 0)

        #expect(YogaNativeBridge.yogaNodeSetIsReferenceBaselineChecked(leaf, 1) == .ok)
        var refBaseline: UInt32 = 0
        #expect(YogaNativeBridge.yogaNodeIsReferenceBaselineChecked(leaf, &refBaseline) == .ok)
        #expect(refBaseline == 1)

        #expect(YogaNativeBridge.yogaNodeSetAlwaysFormsContainingBlockChecked(root, 1) == .ok)
        var containing: UInt32 = 0
        #expect(YogaNativeBridge.yogaNodeGetAlwaysFormsContainingBlockChecked(root, &containing) == .ok)
        #expect(containing == 1)

        // Mark dirty requires measureFunc
        #expect(YogaNativeBridge.yogaNodeMarkDirtyChecked(root) == .invalidArgument)
        #expect(YogaNativeBridge.yogaNodeMarkDirtyChecked(leaf) == .ok)
        var isDirtyFlag: UInt32 = 0
        #expect(YogaNativeBridge.yogaNodeIsDirtyChecked(leaf, &isDirtyFlag) == .ok)
        #expect(isDirtyFlag == 1)
        #expect(dirtiedCount.withLock { $0 } >= 1)

        #expect(YogaNativeBridge.yogaNodeUnsetDirtiedFuncChecked(leaf) == .ok)
        #expect(YogaNativeBridge.yogaNodeUnsetMeasureFuncChecked(leaf) == .ok)
        #expect(YogaNativeBridge.yogaNodeHasMeasureFunc(leaf) == false)
        #expect(YogaNativeBridge.yogaConfigClearCallbacks(cfg, ownerID: 10) == true)

        YogaNativeBridge.yogaNodeFreeRecursive(root)

        // Freed node fills NaN layout in unchecked yogaNodeGetComputedLayout
        var freedLayout = YogaLayout.zero
        YogaNativeBridge.yogaNodeGetComputedLayout(leaf, &freedLayout)
        #expect(freedLayout.width.isNaN)
        #expect(freedLayout.height.isNaN)
    }
}

// MARK: - 2. Clipboard Sync, Linux, macOS, Windows, Wayland, X11 & Host Parity

@Suite("ClipboardMethodParity", .serialized)
struct ClipboardMethodParityTests {
    @Test("ClipboardSyncMutex lock/tryLock/unlock and ClipboardSyncLatch wait/timedWait/signal")
    func syncMutexAndConditionMethods() async {
        let mutex = ClipboardSyncMutex()
        #expect(mutex.tryLock() == true)
        mutex.unlock()

        mutex.lock()
        let latch = ClipboardSyncLatch()
        // timedWait releases mutex, waits briefly, and re-acquires mutex before returning
        latch.timedWait(mutex, timeoutNanoseconds: 1_000_000)
        mutex.unlock()

        // Paired wait(_:) wakes cleanly when another task calls signal()
        let woke = Mutex<Bool>(false)
        let waitTask = Task.detached {
            mutex.lock()
            defer { mutex.unlock() }
            while !latch.isSignaled {
                latch.wait(mutex)
            }
            woke.withLock { $0 = true }
        }
        try? await Task.sleep(for: .milliseconds(5))
        mutex.lock()
        latch.signal()
        mutex.unlock()
        await waitTask.value
        #expect(woke.withLock { $0 } == true)
    }

    @Test("LinuxClipboardEnvironment fromMap/detect/detectProcess and LinuxClipboardRuntime.TestLog")
    func linuxEnvironmentAndTestLog() {
        let mapEnv = LinuxClipboardEnvironment.fromMap([
            "WAYLAND_DISPLAY": "",
            "DISPLAY": ":0",
            "WSL_INTEROP": "",
        ])
        #expect(mapEnv.isWSL == true)
        #expect(mapEnv.hasWaylandDisplay == false)
        #expect(mapEnv.hasX11Display == true)
        #expect(mapEnv.preferredMechanism == .x11)

        let socketEnv = LinuxClipboardEnvironment.fromMap([
            "WAYLAND_SOCKET": "7",
        ])
        #expect(socketEnv.hasWaylandDisplay == true)
        #expect(socketEnv.preferredMechanism == .wayland)

        let wslKernelEnv = LinuxClipboardEnvironment.detect([:], kernelRelease: "5.15.153.1-microsoft-standard-WSL2")
        #expect(wslKernelEnv.isWSL == true)

        let regularKernelEnv = LinuxClipboardEnvironment.detect([:], kernelRelease: "6.12.31-1-lts")
        #expect(regularKernelEnv.isWSL == false)

        _ = LinuxClipboardEnvironment.detectProcess()

        LinuxClipboardRuntime.TestLog.begin()
        LinuxClipboardRuntime.TestLog.callback(level: 1, message: "Clipboard: warn entry")
        LinuxClipboardRuntime.TestLog.callback(level: 0, message: "Clipboard: err entry")
        let captured = LinuxClipboardRuntime.TestLog.end()
        #expect(captured == "Clipboard: warn entry\nlevel 0: Clipboard: err entry\n")
    }

    @Test("MacOS and Windows clipboard mime/result/worker lifecycle methods")
    func macosAndWindowsMethods() {
        #expect(MacOSClipboardMimeType.textPlain.name() == "text/plain")
        #expect(MacOSClipboardMimeType.imagePng.name() == "image/png")

        var macResult = MacOSClipboardResult(
            status: .read,
            readResult: MacOSClipboardReadResult(mimeType: "text/plain", bytes: Array("hi".utf8))
        )
        macResult.deinitResult()
        #expect(macResult.readResult == nil)
        #expect(macResult.status == .empty)

        var winResult = WindowsClipboardResult(
            status: .read,
            mimeType: "text/plain",
            bytes: Array("win".utf8),
            errorCode: 0
        )
        winResult.deinitResult()
        #expect(winResult.mimeType == nil)
        #expect(winResult.bytes.isEmpty)
        #expect(winResult.status == .failed)

        let worker = WindowsClipboardWorker()
        #expect(worker.isInitialized == true)
        #expect(worker.pumpMessages() == false)
        let aborted = ClipboardAbortController()
        aborted.abort(reason: "stop")
        let cancelledRes = worker.execute(.clear, options: WindowsClipboardExecuteOptions(signal: aborted.signal))
        #expect(cancelledRes.status == .cancelled)
        worker.dispose()
        #expect(worker.isInitialized == false)
        let disposedRes = worker.execute(.clear)
        #expect(disposedRes.status == .failed)
    }

    @Test("WaylandClipboardConnection state machine, selection barriers, core focus retries, and providers")
    func waylandConnectionParity() throws {
        #expect(WAYLAND_CLIPBOARD_READ_RETRY_MAX == 2)

        // Protocol metadata init
        let extMeta = WaylandDataControlMetadata(kind: .ext)
        #expect(extMeta.manager.name == "ext_data_control_manager_v1")
        #expect(extMeta.manager.version == 1)
        #expect(extMeta.device.requests[2].signature == "?o")
        let wlrMeta = WaylandDataControlMetadata(kind: .wlr)
        #expect(wlrMeta.manager.name == "zwlr_data_control_manager_v1")
        #expect(wlrMeta.manager.version == 2)
        #expect(wlrMeta.device.requests[2].signature == "2?o")

        // Drive idle -> registry -> seats -> device -> ready
        let conn = WaylandClipboardConnection(protocolKind: .ext, seatName: "seat0", ready: false)
        #expect(conn.drive() == .pending)
        #expect(conn.drive() == .pending)
        #expect(conn.drive() == .pending)
        #expect(conn.drive() == .ready)
        #expect(conn.isReady)
        #expect(!conn.isFailed())
        #expect(conn.closableWhenIdle())

        // Selection barrier serialization
        let s1 = try #require(conn.requestSelectionBarrier())
        let s2 = try #require(conn.requestSelectionBarrier())
        #expect(s2 == s1 + 1)
        #expect(!conn.selectionBarrierReached(s1))
        #expect(conn.hasWork())
        #expect(!conn.closableWhenIdle())

        conn.completeSelectionBarrier()
        #expect(conn.selectionBarrierReached(s1))
        #expect(!conn.selectionBarrierReached(s2))
        conn.completeSelectionBarrier()
        #expect(conn.selectionBarrierReached(s2))
        #expect(!conn.hasWork())

        // Offers, MIME matching, and wire receive
        let offer = WaylandClipboardOffer(objectId: 9, mimeTypes: ["text/plain;charset=utf-8", "image/bmp"])
        conn.setOffer(offer, selection: .clipboard)
        #expect(conn.currentOffer(primary: false) == offer)
        #expect(conn.offeredMime(offer: offer, preferred: "text/plain")?.offeredMime == "text/plain;charset=utf-8")
        // BMP fallback only applies to core data device
        #expect(conn.offeredMime(offer: offer, preferred: "image/png") == nil)
        #expect(conn.receive(offer: offer, mime: "text/plain;charset=utf-8", fd: 5) == true)
        #expect(conn.lastReceiveMessage != nil)
        #expect(conn.receive(offer: offer, mime: String(repeating: "a", count: 300), fd: 5) == false)

        // Publish, driveProviderUnit over a real pipe, retire, clear, and release
        #expect(conn.publishText(primary: false, data: Array("hello wayland".utf8)) == .ready)
        #expect(conn.hasProviders())
        #expect(conn.hasWork())
        conn.dispatchQueued()

        #if os(macOS) || os(Linux) || os(FreeBSD) || os(Android)
        let pipeFDs = try PosixClipboardIO.pipe()
        #expect(conn.enqueueProviderTransfer(primary: false, fd: pipeFDs.writeFD))
        _ = conn.driveProviderUnit()
        let readBack = try PosixClipboardIO.readAll(fd: pipeFDs.readFD, maxBytes: 1024)
        PosixClipboardIO.close(pipeFDs.readFD)
        #expect(String(decoding: readBack.bytes, as: UTF8.self) == "hello wayland")
        #endif

        conn.retireProviders()
        #expect(!conn.hasProviders())
        #expect(conn.clearSelection(primary: false) == .ready)
        #expect(conn.takeFailure() == nil)
        conn.releaseProviders()
        conn.deinitConnection()
        #expect(!conn.isReady)

        // Core data-device focus acquisition, focus-loss retry cap, and BMP->PNG fallback
        let coreConn = WaylandClipboardConnection(protocolKind: .ext, seatName: "seat0", ready: true, coreDataDevice: true)
        #expect(coreConn.usesCoreDataDevice())
        #expect(coreConn.offeredMime(offer: offer, preferred: "image/png")?.needsBmpToPng == true)
        #expect(coreConn.publishText(primary: false, data: [65]) == .unsupported)
        #expect(coreConn.acquireCoreSelection() == .pending)
        coreConn.updateCoreFocusState(entered: false, selectionSeen: false, lost: true)
        #expect(coreConn.coreSelectionProgress() == .pending) // retry 1
        coreConn.updateCoreFocusState(entered: true, selectionSeen: true, lost: false)
        #expect(coreConn.coreSelectionProgress() == .ready)
        coreConn.releaseCoreSelection()
    }

    @Test("X11ClipboardConnection state machine, read/INCR/Latin-1, write/retired timestamps, and providers")
    func x11ConnectionParity() throws {
        #expect(X11_ATOM_PRIMARY == 1)
        #expect(X11_ATOM_ATOM == 4)
        #expect(X11_ATOM_STRING == 31)

        let conn = X11ClipboardConnection(displayName: ":0", connected: false)
        #expect(conn.resolvedAtoms() == nil)
        // Drive idle -> atoms -> flush -> replies -> window -> windowFlush -> ready
        for _ in 0..<5 {
            #expect(conn.drive() == .pending)
        }
        #expect(conn.drive() == .ready)
        let atoms = try #require(conn.resolvedAtoms())
        #expect(conn.selectionAtom(primary: true) == X11_ATOM_PRIMARY)
        #expect(conn.selectionAtom(primary: false) == atoms.clipboard)

        let textTargets = conn.targetAtoms(for: "text/plain")
        #expect(textTargets == [atoms.textPlainUtf8Upper, atoms.textPlainUtf8, atoms.utf8String, atoms.textPlain, atoms.text, X11_ATOM_STRING])
        #expect(conn.targetAtoms(for: "image/png") == [atoms.png])

        // 1. Direct Latin-1 read (ATOM_STRING -> UTF-8 transcoding)
        var readState = X11ClipboardReadState()
        #expect(conn.beginRead(&readState, primary: false, target: X11_ATOM_STRING, maxBytes: 64))
        let notify = XcbSelectionNotifyEventRecord(
            requestor: readState.window,
            selection: atoms.clipboard,
            target: X11_ATOM_STRING,
            property: atoms.property
        )
        #expect(conn.routeReadEvent(&readState, event: .selectionNotify(notify)))
        let cookie1 = try #require(readState.propertyCookie)
        conn.enqueuePropertyReply(
            for: cookie1,
            reply: X11ClipboardPropertyReply(format: 8, atomType: X11_ATOM_STRING, bytes: [0x63, 0x61, 0x66, 0xE9]) // "café" in Latin-1
        )
        var readData: [UInt8] = []
        let readRes = conn.driveRead(&readState, data: &readData, maxBytes: 64)
        #expect(readRes == .read(mimeType: "text/plain", bytes: Array("café".utf8)))
        conn.cleanupRead(&readState)

        // 2. INCR multi-chunk read
        var incrState = X11ClipboardReadState()
        #expect(conn.beginRead(&incrState, primary: false, target: atoms.utf8String, maxBytes: 64))
        #expect(conn.routeReadEvent(&incrState, event: .selectionNotify(XcbSelectionNotifyEventRecord(
            requestor: incrState.window,
            selection: atoms.clipboard,
            target: atoms.utf8String,
            property: atoms.property
        ))))
        let incrCookie = try #require(incrState.propertyCookie)
        conn.enqueuePropertyReply(for: incrCookie, reply: X11ClipboardPropertyReply(format: 32, atomType: atoms.incr, bytes: [5, 0, 0, 0]))
        var incrData: [UInt8] = []
        #expect(conn.driveRead(&incrState, data: &incrData, maxBytes: 64) == .pending)
        #expect(incrState.incremental == true)

        // First chunk
        #expect(conn.routeReadEvent(&incrState, event: .propertyNotify(XcbPropertyNotifyEventRecord(window: incrState.window, atom: atoms.property, state: 0))))
        let chunkCookie1 = try #require(incrState.propertyCookie)
        conn.enqueuePropertyReply(for: chunkCookie1, reply: X11ClipboardPropertyReply(format: 8, atomType: atoms.utf8String, bytes: Array("he".utf8)))
        #expect(conn.driveRead(&incrState, data: &incrData, maxBytes: 64) == .pending)

        // Second chunk + zero-length terminator
        #expect(conn.routeReadEvent(&incrState, event: .propertyNotify(XcbPropertyNotifyEventRecord(window: incrState.window, atom: atoms.property, state: 0))))
        let chunkCookie2 = try #require(incrState.propertyCookie)
        conn.enqueuePropertyReply(for: chunkCookie2, reply: X11ClipboardPropertyReply(format: 8, atomType: atoms.utf8String, bytes: Array("llo".utf8)))
        #expect(conn.driveRead(&incrState, data: &incrData, maxBytes: 64) == .pending)

        #expect(conn.routeReadEvent(&incrState, event: .propertyNotify(XcbPropertyNotifyEventRecord(window: incrState.window, atom: atoms.property, state: 0))))
        let endCookie = try #require(incrState.propertyCookie)
        conn.enqueuePropertyReply(for: endCookie, reply: X11ClipboardPropertyReply(format: 8, atomType: atoms.utf8String, bytes: []))
        #expect(conn.driveRead(&incrState, data: &incrData, maxBytes: 64) == .read(mimeType: "text/plain", bytes: Array("hello".utf8)))
        conn.cleanupRead(&incrState)

        // 3. Write pipeline + timestamp routing + ownership verification + provider event handling
        var writeState = X11ClipboardWriteState()
        #expect(conn.beginWrite(&writeState, primary: false, data: Array("x11 payload".utf8)) == .pending)
        let tsEvent = X11ClipboardEvent.propertyNotify(XcbPropertyNotifyEventRecord(
            window: writeState.timestampWindow,
            atom: atoms.timestamp,
            state: 0,
            time: 12345
        ))
        #expect(conn.isMutationTimestampEvent(state: writeState, event: tsEvent))
        #expect(conn.routeWriteEvent(&writeState, event: tsEvent))
        let ownerCookie = try #require(writeState.ownerCookie)
        conn.enqueueSelectionOwnerReply(for: ownerCookie, owner: conn.ownerWindow)
        #expect(conn.driveWrite(&writeState) == .committed)
        #expect(conn.hasWork())

        // Provider handles SelectionRequest & driveProviderUnit emits SelectionNotify
        let reqEvent = X11ClipboardEvent.selectionRequest(XcbSelectionRequestEventRecord(
            requestor: 0x999,
            selection: atoms.clipboard,
            target: atoms.utf8String,
            property: atoms.property
        ))
        conn.enqueueEvent(reqEvent)
        let polled = try #require(conn.pollEvent())
        conn.handleProviderEvent(polled)
        _ = conn.driveProviderUnit()
        #expect(conn.sentSelectionNotifications.last?.property == atoms.property)

        // Retired timestamp cleanup on abandoned beginClear
        var clearState = X11ClipboardWriteState()
        #expect(conn.beginClear(&clearState, primary: true) == .pending)
        let retiredWin = clearState.timestampWindow
        conn.cleanupWrite(&clearState)
        #expect(conn.consumeRetiredTimestampEvent(.propertyNotify(XcbPropertyNotifyEventRecord(
            window: retiredWin,
            atom: atoms.timestamp,
            state: 0
        ))) == true)

        // abandonMutationConfirmation
        var abandonState = X11ClipboardWriteState(mutationDispatched: true)
        conn.abandonMutationConfirmation(&abandonState)
        #expect(!abandonState.mutationDispatched)

        #expect(conn.takeFailure() == nil)
        conn.requestShutdown()
        #expect(conn.shutdownReady())
        conn.releaseProviders()
        #expect(!conn.hasWork())
        conn.deinitConnection()
        #expect(!conn.isConnected)
    }

    @Test("HostClipboardOperation and HostClipboardNativeService shutdown and teardown lifecycle")
    func hostOperationAndServiceLifecycle() {
        let wayland = WaylandClipboardConnection.testReadyConnection()
        _ = wayland.publishText(primary: false, data: Array("wl".utf8))
        let x11 = X11ClipboardConnection(displayName: ":0", connected: true)

        let service = HostClipboardNativeService(
            contextId: 42,
            wayland: wayland,
            x11: x11
        )
        #expect(service.pollShutdown() == .pending) // not shutting down yet

        let op = HostClipboardOperation(handle: HostClipboardHandle(contextId: 42, slot: 1, generation: 1))
        #expect(!op.isReadyToDestroy()) // still pending
        op.setWorkerRunning(true)
        op.complete(status: .read, mime: "text/plain", data: Array("payload".utf8))
        #expect(!op.isReadyToDestroy()) // worker still running
        op.setWorkerRunning(false)
        #expect(op.isReadyToDestroy())
        op.destroyStorage(in: service)
        #expect(op.isStorageDestroyed)
        #expect(op.dataBytes.isEmpty)

        #expect(service.beginShutdown() == .ready)
        #expect(service.pollShutdown() == .ready)
        #expect(!wayland.hasProviders())

        service.deinitService()
        #expect(service.isDestroyed)
        #expect(!wayland.isReady)
        #expect(!x11.isConnected)
    }
}
