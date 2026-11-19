// Pure-Swift checked and unchecked Yoga native bridge (`native/src/yoga.zig`).
// Zero OS / Foundation imports (Pure Tier).

import OpenTUICore
import Synchronization

/// Pure-Swift checked and unchecked C-ABI Yoga bridge matching `native/src/yoga.zig`.
/// Enforces depth bounds (`depthMax = 256`), active-solve busy guards, poison-on-failure
/// semantics, callback owner exclusivity, and bit-exact value packing.
public enum YogaNativeBridge: Sendable {
    /// Maximum managed tree depth matching `OT_YOGA_DEPTH_MAX`.
    public static let depthMax: UInt32 = 256

    private static let configMutex = Mutex<Void>(())
    private static let defaultOpenTUIConfigBox = Mutex<YogaConfig?>(nil)

    private static func defaultOpenTUIConfig() -> YogaConfig {
        defaultOpenTUIConfigBox.withLock { cached in
            if let existing = cached, !existing.isFreed {
                return existing
            }
            let created = YogaConfig(host: .shared, callbacks: YogaBridgeCallbacks(), heapOwned: false)
            created.setUseWebDefaults(false)
            created.setPointScaleFactor(1.0)
            cached = created
            return created
        }
    }

    // MARK: - Internal Validation Helpers

    private static func nodeStatus(_ node: YogaNode?, mutation: Bool, teardown: Bool) -> YogaStatus {
        guard let node, !node.isFreed() else { return .invalidArgument }
        if mutation && node.treeRoot().activeRoot != nil {
            return .busy
        }
        if !teardown && node.isPoisoned {
            return .poisoned
        }
        return .ok
    }

    private static func configStatus(_ config: YogaConfig?) -> YogaStatus {
        guard let config, !config.isFreed else { return .invalidArgument }
        return configMutex.withLock { _ in
            config.hasActiveLayout() ? .busy : .ok
        }
    }

    private static func placementStatus(
        parent: YogaNode?,
        child: YogaNode?,
        index: UInt32,
        moving: Bool
    ) -> YogaStatus {
        let parentStatus = nodeStatus(parent, mutation: true, teardown: false)
        if parentStatus != .ok { return parentStatus }
        let childStatus = nodeStatus(child, mutation: true, teardown: false)
        if childStatus != .ok { return childStatus }
        guard let parent, let child else { return .invalidArgument }
        if parent === child { return .invalidArgument }

        let previous = child.getParent()
        if !moving && previous != nil { return .invalidArgument }
        if let previous {
            let prevStatus = nodeStatus(previous, mutation: true, teardown: false)
            if prevStatus != .ok { return prevStatus }
        }

        let count = UInt32(max(0, parent.getChildCount()))
        let sameParent = (previous === parent)
        if sameParent && count == 0 { return .invalidArgument }
        let maxIndex = sameParent ? (count - 1) : count
        if index > maxIndex || parent.hasMeasureFunc() { return .invalidArgument }

        // Cycle rejection + ancestor depth bound.
        var cursor: YogaNode? = parent
        var ancestorDepth: UInt32 = 0
        while let current = cursor {
            if current === child { return .invalidArgument }
            ancestorDepth &+= 1
            if ancestorDepth >= depthMax { return .depthLimit }
            cursor = current.getParent()
        }

        let childSubtreeDepth = child.subtreeMaxDepth()
        if ancestorDepth &+ childSubtreeDepth > depthMax {
            return .depthLimit
        }
        return .ok
    }

    private static func validValue(kind: UInt32, edge: UInt32) -> Bool {
        guard let valueKind = YogaValueKind(rawValue: Int32(bitPattern: kind)) else { return false }
        switch valueKind {
        case .width, .height, .minWidth, .minHeight, .maxWidth, .maxHeight, .flexBasis:
            return true
        case .margin, .padding, .position:
            return edge <= UInt32(Edge.all.rawValue)
        case .gap:
            return edge <= UInt32(Gutter.all.rawValue)
        }
    }

    private static func acceptsAuto(kind: YogaValueKind) -> Bool {
        switch kind {
        case .width, .height, .flexBasis, .margin, .position:
            return true
        case .minWidth, .minHeight, .maxWidth, .maxHeight, .padding, .gap:
            return false
        }
    }

    private static func flexValue(unit: Unit, value: Float) -> FlexValue {
        switch unit {
        case .undefined:
            return .undefined
        case .auto:
            return .auto
        case .point:
            return value.isFinite ? .point(value) : .undefined
        case .percent:
            return value.isFinite ? .percent(value) : .undefined
        }
    }

    private static func packYogaValue(_ value: YogaValue) -> UInt64 {
        let valueBits = UInt64(value.value.bitPattern)
        let unitBits = UInt64(UInt32(bitPattern: value.unit.rawValue))
        return (valueBits << 32) | unitBits
    }

    private static func nanLayout() -> YogaLayout {
        YogaLayout(left: .nan, right: .nan, top: .nan, bottom: .nan, width: .nan, height: .nan)
    }

    // MARK: - Config Lifecycle & Settings

    // parity: native/src/yoga.zig#yogaConfigCreate [status=implemented hash=f7e96bf09d4c]
    public static func yogaConfigCreate() -> YogaConfig? {
        var out: YogaConfig? = nil
        _ = yogaConfigCreateChecked(&out)
        return out
    }

    // parity: native/src/yoga.zig#yogaConfigCreateChecked [status=implemented hash=704883df2998]
    public static func yogaConfigCreateChecked(_ out: inout YogaConfig?) -> YogaStatus {
        let config = YogaConfig(host: .shared, callbacks: YogaBridgeCallbacks(), heapOwned: true)
        out = config
        return .ok
    }

    // parity: native/src/yoga.zig#yogaConfigFree [status=implemented hash=636a941490f7]
    @discardableResult
    public static func yogaConfigFree(_ config: YogaConfig?) -> Bool {
        yogaConfigFreeChecked(config) == .ok
    }

    // parity: native/src/yoga.zig#yogaConfigFreeChecked [status=implemented hash=5a01e317fcc7]
    public static func yogaConfigFreeChecked(_ config: YogaConfig?) -> YogaStatus {
        guard let config, !config.isFreed else { return .invalidArgument }
        guard config.ownsConfig else { return .invalidArgument }
        if config.hasLiveNodes() { return .busy }
        do {
            try config.deinitConfig()
            return .ok
        } catch {
            return error.status
        }
    }

    // parity: native/src/yoga.zig#yogaConfigSetUseWebDefaultsChecked [status=implemented hash=a4142152e2cc]
    public static func yogaConfigSetUseWebDefaultsChecked(_ config: YogaConfig?, _ enabled: UInt32) -> YogaStatus {
        let status = configStatus(config)
        if status != .ok { return status }
        guard enabled <= 1, let config else { return .invalidArgument }
        config.setUseWebDefaults(enabled != 0)
        return .ok
    }

    // parity: native/src/yoga.zig#yogaConfigGetUseWebDefaults [status=implemented hash=43e9de97a806]
    public static func yogaConfigGetUseWebDefaults(_ config: YogaConfig?) -> Bool {
        guard let config, !config.isFreed else { return false }
        return config.useWebDefaults()
    }

    // parity: native/src/yoga.zig#yogaConfigSetPointScaleFactorChecked [status=implemented hash=8199c75a009e]
    public static func yogaConfigSetPointScaleFactorChecked(
        _ config: YogaConfig?,
        _ pointScaleFactor: Float
    ) -> YogaStatus {
        let status = configStatus(config)
        if status != .ok { return status }
        guard pointScaleFactor.isFinite, pointScaleFactor >= 0, let config else { return .invalidArgument }
        config.setPointScaleFactor(pointScaleFactor)
        return .ok
    }

    // parity: native/src/yoga.zig#yogaConfigGetPointScaleFactor [status=implemented hash=86d027e3f9fd]
    public static func yogaConfigGetPointScaleFactor(_ config: YogaConfig?) -> Float {
        guard let config, !config.isFreed else { return 0 }
        return config.getPointScaleFactor()
    }

    // parity: native/src/yoga.zig#yogaConfigSetErrataChecked [status=implemented hash=1b256ec476c5]
    public static func yogaConfigSetErrataChecked(_ config: YogaConfig?, _ errata: UInt32) -> YogaStatus {
        let status = configStatus(config)
        if status != .ok { return status }
        let allRaw = UInt32(bitPattern: Errata.all.rawValue)
        let classicRaw = UInt32(bitPattern: Errata.classic.rawValue)
        guard errata <= 7 || errata == allRaw || errata == classicRaw else {
            return .invalidArgument
        }
        guard let config else { return .invalidArgument }
        if let exact = Errata(rawValue: Int32(bitPattern: errata)) {
            config.setErrata(exact)
        } else if (errata & UInt32(Errata.stretchFlexBasis.rawValue)) != 0 {
            config.setErrata(.stretchFlexBasis)
        } else if (errata & UInt32(Errata.absolutePositionWithoutInsetsExcludesPadding.rawValue)) != 0 {
            config.setErrata(.absolutePositionWithoutInsetsExcludesPadding)
        } else if (errata & UInt32(Errata.absolutePercentAgainstInnerSize.rawValue)) != 0 {
            config.setErrata(.absolutePercentAgainstInnerSize)
        } else {
            config.setErrata(.none)
        }
        return .ok
    }

    // parity: native/src/yoga.zig#yogaConfigSetExperimentalFeatureEnabledChecked [status=implemented hash=d7be6bdb3179]
    public static func yogaConfigSetExperimentalFeatureEnabledChecked(
        _ config: YogaConfig?,
        _ feature: UInt32,
        _ enabled: UInt32
    ) -> YogaStatus {
        let status = configStatus(config)
        if status != .ok { return status }
        guard enabled <= 1,
              let expFeature = ExperimentalFeature(rawValue: Int32(bitPattern: feature)),
              let config
        else {
            return .invalidArgument
        }
        config.setExperimentalFeatureEnabled(expFeature, enabled != 0)
        return .ok
    }

    // parity: native/src/yoga.zig#yogaConfigIsExperimentalFeatureEnabledChecked [status=implemented hash=1e7dc18f2b35]
    public static func yogaConfigIsExperimentalFeatureEnabledChecked(
        _ config: YogaConfig?,
        _ feature: UInt32,
        _ out: inout UInt32
    ) -> YogaStatus {
        guard let config,
              !config.isFreed,
              let expFeature = ExperimentalFeature(rawValue: Int32(bitPattern: feature))
        else {
            return .invalidArgument
        }
        out = config.isExperimentalFeatureEnabled(expFeature) ? 1 : 0
        return .ok
    }

    // parity: native/src/yoga.zig#yogaConfigSetCallbacks [status=implemented hash=7ca339601038]
    @discardableResult
    public static func yogaConfigSetCallbacks(
        _ config: YogaConfig?,
        ownerID: UInt64 = 1,
        measure: @escaping YogaJSMeasureTrampoline,
        dirtied: @escaping YogaJSDirtiedTrampoline
    ) -> Bool {
        guard let config, !config.isFreed else { return false }
        return configMutex.withLock { _ in
            if config.hasActiveLayout() { return false }
            if let existingOwner = config.callbackOwnerID, existingOwner != ownerID {
                return false
            }
            config.callbackOwnerID = ownerID
            config.jsMeasureCallback = measure
            config.jsDirtiedCallback = dirtied
            return true
        }
    }

    // parity: native/src/yoga.zig#yogaConfigClearCallbacks [status=implemented hash=49ff47fba66a]
    @discardableResult
    public static func yogaConfigClearCallbacks(
        _ config: YogaConfig?,
        ownerID: UInt64 = 1
    ) -> Bool {
        guard let config, !config.isFreed else { return false }
        return configMutex.withLock { _ in
            if config.hasActiveLayout() { return false }
            guard config.callbackOwnerID == ownerID else { return false }
            config.callbackOwnerID = nil
            config.jsMeasureCallback = nil
            config.jsDirtiedCallback = nil
            return true
        }
    }

    // MARK: - Node Creation, Teardown, Reset & Style Copy

    // parity: native/src/yoga.zig#yogaNodeCreate [status=implemented hash=73993a60eb8b]
    public static func yogaNodeCreate() -> YogaNode? {
        yogaNodeCreateForOpenTUI()
    }

    // parity: native/src/yoga.zig#yogaNodeCreateForOpenTUI [status=implemented hash=fba6ecbd988e]
    public static func yogaNodeCreateForOpenTUI() -> YogaNode? {
        var out: YogaNode? = nil
        _ = yogaNodeCreateForOpenTUIChecked(&out)
        return out
    }

    // parity: native/src/yoga.zig#yogaNodeCreateForOpenTUIChecked [status=implemented hash=5d5bf196f630]
    public static func yogaNodeCreateForOpenTUIChecked(_ out: inout YogaNode?) -> YogaStatus {
        let config = defaultOpenTUIConfig()
        do {
            out = try config.createNode()
            return .ok
        } catch {
            return error.status
        }
    }

    // parity: native/src/yoga.zig#yogaNodeCreateWithConfig [status=implemented hash=f2f08578a6c7]
    public static func yogaNodeCreateWithConfig(_ config: YogaConfig?) -> YogaNode? {
        var out: YogaNode? = nil
        _ = yogaNodeCreateWithConfigChecked(config, &out)
        return out
    }

    // parity: native/src/yoga.zig#yogaNodeCreateWithConfigChecked [status=implemented hash=352f647208ea]
    public static func yogaNodeCreateWithConfigChecked(
        _ config: YogaConfig?,
        _ out: inout YogaNode?
    ) -> YogaStatus {
        guard let config, !config.isFreed else { return .invalidArgument }
        do {
            out = try config.createNode()
            return .ok
        } catch {
            return error.status
        }
    }

    // parity: native/src/yoga.zig#yogaNodeFree [status=implemented hash=92ed04fc2f03]
    public static func yogaNodeFree(_ node: YogaNode?) {
        _ = yogaNodeFreeChecked(node)
    }

    // parity: native/src/yoga.zig#yogaNodeFreeChecked [status=implemented hash=9cef092842a5]
    public static func yogaNodeFreeChecked(_ node: YogaNode?) -> YogaStatus {
        let status = nodeStatus(node, mutation: true, teardown: true)
        if status != .ok { return status }
        guard let node else { return .invalidArgument }
        return configMutex.withLock { _ in
            node.free()
            return .ok
        }
    }

    // parity: native/src/yoga.zig#yogaNodeFreeRecursive [status=implemented hash=c2a4b642770c]
    public static func yogaNodeFreeRecursive(_ node: YogaNode?) {
        _ = yogaNodeFreeRecursiveChecked(node)
    }

    // parity: native/src/yoga.zig#yogaNodeFreeRecursiveChecked [status=implemented hash=72bf99ab8852]
    public static func yogaNodeFreeRecursiveChecked(_ node: YogaNode?) -> YogaStatus {
        let status = nodeStatus(node, mutation: true, teardown: true)
        if status != .ok { return status }
        guard let root = node else { return .invalidArgument }

        // Iterative post-order teardown matching yoga.zig's two-phase detach-then-free.
        var stack: [YogaNode] = [root]
        var retired: [YogaNode] = []
        while let current = stack.last {
            if current.getChildCount() > 0, let child = current.getChild(0) {
                let removeStatus = yogaNodeRemoveChildChecked(current, child)
                if removeStatus != .ok { return removeStatus }
                stack.append(child)
            } else {
                stack.removeLast()
                retired.append(current)
            }
        }
        for target in retired {
            let freeStatus = yogaNodeFreeChecked(target)
            if freeStatus != .ok { return freeStatus }
        }
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeResetChecked [status=implemented hash=81d0ea817117]
    public static func yogaNodeResetChecked(_ node: YogaNode?) -> YogaStatus {
        let status = nodeStatus(node, mutation: true, teardown: false)
        if status != .ok { return status }
        guard let node else { return .invalidArgument }
        if node.getParent() != nil || node.getChildCount() > 0 {
            return .invalidArgument
        }
        return configMutex.withLock { _ in
            node.resetNativeState()
            return .ok
        }
    }

    // parity: native/src/yoga.zig#yogaNodeCopyStyleChecked [status=implemented hash=511571c41a71]
    public static func yogaNodeCopyStyleChecked(_ dstNode: YogaNode?, _ srcNode: YogaNode?) -> YogaStatus {
        let dstStatus = nodeStatus(dstNode, mutation: true, teardown: false)
        if dstStatus != .ok { return dstStatus }
        let srcStatus = nodeStatus(srcNode, mutation: false, teardown: false)
        if srcStatus != .ok { return srcStatus }
        guard let dstNode, let srcNode else { return .invalidArgument }
        dstNode.copyStyle(srcNode)
        return .ok
    }

    // MARK: - Child Tree Management

    // parity: native/src/yoga.zig#yogaNodeInsertChild [status=implemented hash=8e245b1fe403]
    public static func yogaNodeInsertChild(_ node: YogaNode?, _ child: YogaNode?, _ index: UInt32) {
        _ = yogaNodeInsertChildChecked(node, child, index)
    }

    // parity: native/src/yoga.zig#yogaNodeInsertChildChecked [status=implemented hash=414df22ed31a]
    public static func yogaNodeInsertChildChecked(
        _ node: YogaNode?,
        _ child: YogaNode?,
        _ index: UInt32
    ) -> YogaStatus {
        let status = placementStatus(parent: node, child: child, index: index, moving: false)
        if status != .ok { return status }
        guard let node, let child else { return .invalidArgument }
        node.insertChild(child, Int(index))
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeMoveChildChecked [status=implemented hash=89045f30bdd6]
    public static func yogaNodeMoveChildChecked(
        _ parent: YogaNode?,
        _ child: YogaNode?,
        _ finalIndex: UInt32
    ) -> YogaStatus {
        let status = placementStatus(parent: parent, child: child, index: finalIndex, moving: true)
        if status != .ok { return status }
        guard let parent, let child else { return .invalidArgument }
        let sourceRoot = child.treeRoot()
        let destRoot = parent.treeRoot()
        sourceRoot.activeRoot = sourceRoot
        destRoot.activeRoot = destRoot
        defer {
            sourceRoot.activeRoot = nil
            destRoot.activeRoot = nil
        }
        return parent.moveChildInternal(child, to: Int(finalIndex))
    }

    // parity: native/src/yoga.zig#yogaNodeRemoveChild [status=implemented hash=3c0ab0550bc9]
    public static func yogaNodeRemoveChild(_ node: YogaNode?, _ child: YogaNode?) {
        _ = yogaNodeRemoveChildChecked(node, child)
    }

    // parity: native/src/yoga.zig#yogaNodeRemoveChildChecked [status=implemented hash=655a328f50a9]
    public static func yogaNodeRemoveChildChecked(_ node: YogaNode?, _ child: YogaNode?) -> YogaStatus {
        let status = nodeStatus(node, mutation: true, teardown: true)
        if status != .ok { return status }
        let childStatus = nodeStatus(child, mutation: true, teardown: true)
        if childStatus != .ok { return childStatus }
        guard let node, let child else { return .invalidArgument }
        node.removeChild(child)
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeRemoveAllChildrenChecked [status=implemented hash=0571e252457a]
    public static func yogaNodeRemoveAllChildrenChecked(_ node: YogaNode?) -> YogaStatus {
        let status = nodeStatus(node, mutation: true, teardown: true)
        if status != .ok { return status }
        guard let node else { return .invalidArgument }
        node.removeAllChildren()
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeGetChildChecked [status=implemented hash=38f9cb1c78fb]
    public static func yogaNodeGetChildChecked(
        _ node: YogaNode?,
        _ index: UInt32,
        _ out: inout YogaNode?
    ) -> YogaStatus {
        guard let node, !node.isFreed() else { return .invalidArgument }
        if Int(index) < node.getChildCount() {
            out = node.getChild(Int(index))
        } else {
            out = nil
        }
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeGetParent [status=implemented hash=d5e0af1bb4b3]
    public static func yogaNodeGetParent(_ node: YogaNode?) -> YogaNode? {
        guard let node, !node.isFreed() else { return nil }
        return node.getParent()
    }

    // MARK: - Layout Calculation, Dirty & Flag State

    // parity: native/src/yoga.zig#yogaNodeCalculateLayout [status=implemented hash=93e51748b561]
    public static func yogaNodeCalculateLayout(
        _ node: YogaNode?,
        _ width: Float,
        _ height: Float,
        _ direction: UInt32
    ) {
        _ = yogaNodeCalculateLayoutChecked(node, width, height, direction)
    }

    // parity: native/src/yoga.zig#yogaNodeCalculateLayoutChecked [status=implemented hash=8e989acd10b9]
    public static func yogaNodeCalculateLayoutChecked(
        _ node: YogaNode?,
        _ width: Float,
        _ height: Float,
        _ direction: UInt32
    ) -> YogaStatus {
        guard let root = node, !root.isFreed() else { return .invalidArgument }
        let top = root.treeRoot()
        if top.activeRoot != nil { return .busy }
        if root.isPoisoned || top.isPoisoned { return .poisoned }
        guard let resolvedDirection = Direction(rawValue: Int32(bitPattern: direction)) else {
            return .invalidArgument
        }
        for dim in [width, height] {
            if !dim.isNaN && (!dim.isFinite || dim < 0) {
                return .invalidArgument
            }
        }
        root.measureError = .ok
        top.activeRoot = root
        let availableW: Float? = width.isNaN ? nil : width
        let availableH: Float? = height.isNaN ? nil : height
        root.calculateLayout(availableW, availableH, resolvedDirection)
        let result = root.measureError
        if result != .ok {
            top.poisonTree()
        }
        top.activeRoot = nil
        root.measureError = .ok
        return result
    }

    // parity: native/src/yoga.zig#yogaNodeIsDirtyChecked [status=implemented hash=cae3cdd9864e]
    public static func yogaNodeIsDirtyChecked(_ node: YogaNode?, _ out: inout UInt32) -> YogaStatus {
        let status = nodeStatus(node, mutation: false, teardown: false)
        if status != .ok { return status }
        guard let node else { return .invalidArgument }
        out = node.isDirty() ? 1 : 0
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeMarkDirty [status=implemented hash=4e3e65b063f9]
    public static func yogaNodeMarkDirty(_ node: YogaNode?) {
        _ = yogaNodeMarkDirtyChecked(node)
    }

    // parity: native/src/yoga.zig#yogaNodeMarkDirtyChecked [status=implemented hash=744877448c13]
    public static func yogaNodeMarkDirtyChecked(_ node: YogaNode?) -> YogaStatus {
        let status = nodeStatus(node, mutation: true, teardown: false)
        if status != .ok { return status }
        guard let node, node.hasMeasureFunc() else { return .invalidArgument }
        node.markDirty()
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeGetHasNewLayoutChecked [status=implemented hash=fd21066edcf7]
    public static func yogaNodeGetHasNewLayoutChecked(_ node: YogaNode?, _ out: inout UInt32) -> YogaStatus {
        let status = nodeStatus(node, mutation: false, teardown: false)
        if status != .ok { return status }
        guard let node else { return .invalidArgument }
        out = node.hasNewLayout() ? 1 : 0
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeSetHasNewLayoutChecked [status=implemented hash=d24792bd9cbd]
    public static func yogaNodeSetHasNewLayoutChecked(_ node: YogaNode?, _ value: UInt32) -> YogaStatus {
        let status = nodeStatus(node, mutation: true, teardown: false)
        if status != .ok { return status }
        guard value <= 1, let node else { return .invalidArgument }
        node.setHasNewLayoutFlag(value != 0)
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeSetIsReferenceBaselineChecked [status=implemented hash=bcc888293c98]
    public static func yogaNodeSetIsReferenceBaselineChecked(_ node: YogaNode?, _ value: UInt32) -> YogaStatus {
        let status = nodeStatus(node, mutation: true, teardown: false)
        if status != .ok { return status }
        guard value <= 1, let node else { return .invalidArgument }
        node.setIsReferenceBaseline(value != 0)
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeIsReferenceBaselineChecked [status=implemented hash=13943c9902c8]
    public static func yogaNodeIsReferenceBaselineChecked(_ node: YogaNode?, _ out: inout UInt32) -> YogaStatus {
        let status = nodeStatus(node, mutation: false, teardown: false)
        if status != .ok { return status }
        guard let node else { return .invalidArgument }
        out = node.isReferenceBaseline() ? 1 : 0
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeSetAlwaysFormsContainingBlockChecked [status=implemented hash=83c889038ec2]
    public static func yogaNodeSetAlwaysFormsContainingBlockChecked(
        _ node: YogaNode?,
        _ value: UInt32
    ) -> YogaStatus {
        let status = nodeStatus(node, mutation: true, teardown: false)
        if status != .ok { return status }
        guard value <= 1, let node else { return .invalidArgument }
        node.setAlwaysFormsContainingBlock(value != 0)
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeGetAlwaysFormsContainingBlockChecked [status=implemented hash=2ca01efedc1c]
    public static func yogaNodeGetAlwaysFormsContainingBlockChecked(
        _ node: YogaNode?,
        _ out: inout UInt32
    ) -> YogaStatus {
        let status = nodeStatus(node, mutation: false, teardown: false)
        if status != .ok { return status }
        guard let node else { return .invalidArgument }
        out = node.getAlwaysFormsContainingBlock() ? 1 : 0
        return .ok
    }

    // MARK: - Computed Layout & Edges

    // parity: native/src/yoga.zig#yogaNodeGetComputedLayout [status=implemented hash=a25ffbcb8d7b]
    public static func yogaNodeGetComputedLayout(_ node: YogaNode?, _ out: inout YogaLayout) {
        if yogaNodeGetComputedLayoutChecked(node, &out) != .ok {
            out = nanLayout()
        }
    }

    // parity: native/src/yoga.zig#yogaNodeGetComputedLayoutChecked [status=implemented hash=d11efcb219d8]
    public static func yogaNodeGetComputedLayoutChecked(_ node: YogaNode?, _ out: inout YogaLayout) -> YogaStatus {
        let status = nodeStatus(node, mutation: false, teardown: false)
        if status != .ok { return status }
        guard let node else { return .invalidArgument }
        out = node.getComputedLayout()
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeLayoutGetEdgeChecked [status=implemented hash=669b1447aac0]
    public static func yogaNodeLayoutGetEdgeChecked(
        _ node: YogaNode?,
        _ kind: UInt32,
        _ edge: UInt32,
        _ out: inout Float
    ) -> YogaStatus {
        let status = nodeStatus(node, mutation: false, teardown: false)
        if status != .ok { return status }
        guard kind <= 2,
              edge <= UInt32(Edge.end.rawValue),
              let resolvedEdge = Edge(rawValue: Int32(bitPattern: edge)),
              let node
        else {
            return .invalidArgument
        }
        switch kind {
        case 0: out = node.getComputedMargin(resolvedEdge)
        case 1: out = node.getComputedPadding(resolvedEdge)
        case 2: out = node.getComputedBorder(resolvedEdge)
        default: return .invalidArgument
        }
        return .ok
    }

    // MARK: - Style Enum Get/Set

    // parity: native/src/yoga.zig#yogaNodeStyleSetEnum [status=implemented hash=6e2cd14f7ee0]
    public static func yogaNodeStyleSetEnum(_ node: YogaNode?, _ kind: UInt32, _ value: UInt32) {
        _ = yogaNodeStyleSetEnumChecked(node, kind, value)
    }

    // parity: native/src/yoga.zig#yogaNodeStyleSetEnumChecked [status=implemented hash=29f43cbb4b68]
    public static func yogaNodeStyleSetEnumChecked(
        _ node: YogaNode?,
        _ kind: UInt32,
        _ value: UInt32
    ) -> YogaStatus {
        let status = nodeStatus(node, mutation: true, teardown: false)
        if status != .ok { return status }
        guard let node,
              let enumKind = YogaEnumKind(rawValue: Int32(bitPattern: kind))
        else {
            return .invalidArgument
        }
        let raw = Int32(bitPattern: value)
        switch enumKind {
        case .direction:
            guard let v = Direction(rawValue: raw) else { return .invalidArgument }
            node.setDirection(v)
        case .flexDirection:
            guard value <= 3 else { return .invalidArgument }
            node.setFlexDirection(FlexDirection.fromYogaRawValue(raw))
        case .justifyContent:
            guard let v = Justify(rawValue: raw) else { return .invalidArgument }
            node.setJustifyContent(v)
        case .alignContent:
            guard let v = Align(rawValue: raw) else { return .invalidArgument }
            node.setAlignContent(v)
        case .alignItems:
            guard let v = Align(rawValue: raw) else { return .invalidArgument }
            node.setAlignItems(v)
        case .alignSelf:
            guard let v = Align(rawValue: raw) else { return .invalidArgument }
            node.setAlignSelf(v)
        case .positionType:
            guard let v = PositionType(rawValue: raw) else { return .invalidArgument }
            node.setPositionType(v)
        case .flexWrap:
            guard let v = Wrap(rawValue: raw) else { return .invalidArgument }
            node.setFlexWrap(v)
        case .overflow:
            guard let v = Overflow(rawValue: raw) else { return .invalidArgument }
            node.setOverflow(v)
        case .display:
            guard let v = Display(rawValue: raw) else { return .invalidArgument }
            node.setDisplay(v)
        case .boxSizing:
            guard let v = BoxSizing(rawValue: raw) else { return .invalidArgument }
            node.setBoxSizing(v)
        case .layoutMode:
            guard let v = LayoutMode(rawValue: raw), node.config.roundsPositionsFromAbsoluteEdges else {
                return .invalidArgument
            }
            node.layoutMode = v
            node.flexNode.markDirty()
        }
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeStyleGetEnum [status=implemented hash=ec68faf13795]
    public static func yogaNodeStyleGetEnum(_ node: YogaNode?, _ kind: UInt32) -> UInt32 {
        var out: UInt32 = 0
        _ = yogaNodeStyleGetEnumChecked(node, kind, &out)
        return out
    }

    // parity: native/src/yoga.zig#yogaNodeStyleGetEnumChecked [status=implemented hash=514a6566f99d]
    public static func yogaNodeStyleGetEnumChecked(
        _ node: YogaNode?,
        _ kind: UInt32,
        _ out: inout UInt32
    ) -> YogaStatus {
        let status = nodeStatus(node, mutation: false, teardown: false)
        if status != .ok { return status }
        guard let node,
              let enumKind = YogaEnumKind(rawValue: Int32(bitPattern: kind))
        else {
            return .invalidArgument
        }
        let raw: Int32
        switch enumKind {
        case .direction: raw = node.getDirection().rawValue
        case .flexDirection: raw = node.getFlexDirection().yogaRawValue
        case .justifyContent: raw = node.getJustifyContent().rawValue
        case .alignContent: raw = node.getAlignContent().rawValue
        case .alignItems: raw = node.getAlignItems().rawValue
        case .alignSelf: raw = node.getAlignSelf().rawValue
        case .positionType: raw = node.getPositionType().rawValue
        case .flexWrap: raw = node.getFlexWrap().rawValue
        case .overflow: raw = node.getOverflow().rawValue
        case .display: raw = node.getDisplay().rawValue
        case .boxSizing: raw = node.getBoxSizing().rawValue
        case .layoutMode: raw = node.layoutMode.rawValue
        }
        out = UInt32(bitPattern: raw)
        return .ok
    }

    // MARK: - Style Float & Border Get/Set

    // parity: native/src/yoga.zig#yogaNodeStyleSetFloat [status=implemented hash=9496847317b8]
    public static func yogaNodeStyleSetFloat(_ node: YogaNode?, _ kind: UInt32, _ value: Float) {
        _ = yogaNodeStyleSetFloatChecked(node, kind, value)
    }

    // parity: native/src/yoga.zig#yogaNodeStyleSetFloatChecked [status=implemented hash=861668536b0e]
    public static func yogaNodeStyleSetFloatChecked(
        _ node: YogaNode?,
        _ kind: UInt32,
        _ value: Float
    ) -> YogaStatus {
        let status = nodeStatus(node, mutation: true, teardown: false)
        if status != .ok { return status }
        guard !value.isInfinite,
              let node,
              let floatKind = YogaFloatKind(rawValue: Int32(bitPattern: kind))
        else {
            return .invalidArgument
        }
        let optionalVal: Float? = value.isNaN ? nil : value
        switch floatKind {
        case .flex: node.setFlex(optionalVal)
        case .flexGrow: node.setFlexGrow(optionalVal)
        case .flexShrink: node.setFlexShrink(optionalVal)
        case .aspectRatio: node.setAspectRatio(optionalVal)
        }
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeStyleGetFloatChecked [status=implemented hash=2d359e3bdb32]
    public static func yogaNodeStyleGetFloatChecked(
        _ node: YogaNode?,
        _ kind: UInt32,
        _ out: inout Float
    ) -> YogaStatus {
        let status = nodeStatus(node, mutation: false, teardown: false)
        if status != .ok { return status }
        guard let node,
              let floatKind = YogaFloatKind(rawValue: Int32(bitPattern: kind))
        else {
            return .invalidArgument
        }
        switch floatKind {
        case .flex: out = node.getFlex()
        case .flexGrow: out = node.getFlexGrow()
        case .flexShrink: out = node.getFlexShrink()
        case .aspectRatio: out = node.getAspectRatio()
        }
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeStyleSetBorderChecked [status=implemented hash=e3e8da3c6501]
    public static func yogaNodeStyleSetBorderChecked(
        _ node: YogaNode?,
        _ edge: UInt32,
        _ border: Float
    ) -> YogaStatus {
        let status = nodeStatus(node, mutation: true, teardown: false)
        if status != .ok { return status }
        guard !border.isInfinite,
              let resolvedEdge = Edge(rawValue: Int32(bitPattern: edge)),
              let node
        else {
            return .invalidArgument
        }
        node.setBorder(resolvedEdge, border.isNaN ? nil : border)
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeStyleGetBorderChecked [status=implemented hash=ced00410936a]
    public static func yogaNodeStyleGetBorderChecked(
        _ node: YogaNode?,
        _ edge: UInt32,
        _ out: inout Float
    ) -> YogaStatus {
        let status = nodeStatus(node, mutation: false, teardown: false)
        if status != .ok { return status }
        guard let resolvedEdge = Edge(rawValue: Int32(bitPattern: edge)), let node else {
            return .invalidArgument
        }
        out = node.getBorder(resolvedEdge)
        return .ok
    }

    // MARK: - Style Value, Dimension & Position Get/Set

    // parity: native/src/yoga.zig#yogaNodeStyleSetValue [status=implemented hash=3a24060855a0]
    public static func yogaNodeStyleSetValue(
        _ node: YogaNode?,
        _ kind: UInt32,
        _ edgeOrGutter: UInt32,
        _ unit: UInt32,
        _ value: Float
    ) {
        _ = yogaNodeStyleSetValueChecked(node, kind, edgeOrGutter, unit, value)
    }

    // parity: native/src/yoga.zig#yogaNodeStyleSetValueChecked [status=implemented hash=05f5f3b52c0d]
    public static func yogaNodeStyleSetValueChecked(
        _ node: YogaNode?,
        _ kind: UInt32,
        _ edgeOrGutter: UInt32,
        _ unit: UInt32,
        _ value: Float
    ) -> YogaStatus {
        let status = nodeStatus(node, mutation: true, teardown: false)
        if status != .ok { return status }
        guard let node,
              validValue(kind: kind, edge: edgeOrGutter),
              let valueKind = YogaValueKind(rawValue: Int32(bitPattern: kind)),
              let resolvedUnit = Unit(rawValue: Int32(bitPattern: unit)),
              !value.isInfinite
        else {
            return .invalidArgument
        }
        if resolvedUnit == .auto && !acceptsAuto(kind: valueKind) {
            return .invalidArgument
        }

        let resolvedValue: FlexValue = flexValue(unit: resolvedUnit, value: resolvedUnit == .undefined ? .nan : value)
        switch valueKind {
        case .width:
            node.flexNode.style.width = resolvedValue
        case .height:
            node.flexNode.style.height = resolvedValue
        case .minWidth:
            node.flexNode.style.minWidth = resolvedValue
        case .minHeight:
            node.flexNode.style.minHeight = resolvedValue
        case .maxWidth:
            node.flexNode.style.maxWidth = resolvedValue
        case .maxHeight:
            node.flexNode.style.maxHeight = resolvedValue
        case .flexBasis:
            node.flexNode.style.flexBasis = resolvedValue
        case .margin:
            guard let edge = Edge(rawValue: Int32(bitPattern: edgeOrGutter)) else { return .invalidArgument }
            node.flexNode.style.margin.set(edge, resolvedValue)
        case .padding:
            guard let edge = Edge(rawValue: Int32(bitPattern: edgeOrGutter)) else { return .invalidArgument }
            node.flexNode.style.padding.set(edge, resolvedValue)
        case .position:
            guard let edge = Edge(rawValue: Int32(bitPattern: edgeOrGutter)) else { return .invalidArgument }
            node.flexNode.style.position.set(edge, resolvedValue)
        case .gap:
            guard let gutter = Gutter(rawValue: Int32(bitPattern: edgeOrGutter)) else { return .invalidArgument }
            node.flexNode.style.gap.set(gutter, resolvedValue)
        }
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeStyleSetDimensionChecked [status=implemented hash=314917cbb1aa]
    public static func yogaNodeStyleSetDimensionChecked(
        _ node: YogaNode?,
        _ kind: UInt32,
        _ unit: UInt32,
        _ value: Float,
        _ disableFlexShrink: UInt32
    ) -> YogaStatus {
        let status = nodeStatus(node, mutation: true, teardown: false)
        if status != .ok { return status }
        guard let node,
              let dimension = Dimension(rawValue: Int32(bitPattern: kind)),
              let resolvedUnit = Unit(rawValue: Int32(bitPattern: unit)),
              !value.isInfinite,
              disableFlexShrink <= 1
        else {
            return .invalidArgument
        }
        let nextLength = flexValue(unit: resolvedUnit, value: resolvedUnit == .undefined ? .nan : value)
        switch dimension {
        case .width:
            if node.flexNode.style.width != nextLength {
                node.flexNode.style.width = nextLength
            }
        case .height:
            if node.flexNode.style.height != nextLength {
                node.flexNode.style.height = nextLength
            }
        }
        if disableFlexShrink != 0 {
            node.setFlexShrink(0)
        }
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeStyleSetPositionsChecked [status=implemented hash=5a4ef463760b]
    public static func yogaNodeStyleSetPositionsChecked(
        _ node: YogaNode?,
        _ edgeMask: UInt32,
        _ units: [UInt32]?,
        _ values: [Float]?
    ) -> YogaStatus {
        let status = nodeStatus(node, mutation: true, teardown: false)
        if status != .ok { return status }
        guard let node,
              let units,
              let values,
              units.count >= 4,
              values.count >= 4,
              (edgeMask & ~UInt32(15)) == 0
        else {
            return .invalidArgument
        }
        let edges: [Edge] = [.left, .top, .right, .bottom]
        var resolved: [FlexValue?] = [nil, nil, nil, nil]
        for idx in 0..<4 {
            if (edgeMask & (UInt32(1) << UInt32(idx))) == 0 { continue }
            guard let u = Unit(rawValue: Int32(bitPattern: units[idx])), !values[idx].isInfinite else {
                return .invalidArgument
            }
            resolved[idx] = flexValue(unit: u, value: u == .undefined ? .nan : values[idx])
        }
        var updatedPosition = node.flexNode.style.position
        var changed = false
        for idx in 0..<4 {
            if let nextVal = resolved[idx] {
                if updatedPosition.value(for: edges[idx]) != nextVal {
                    updatedPosition.set(edges[idx], nextVal)
                    changed = true
                }
            }
        }
        if changed {
            node.flexNode.style.position = updatedPosition
        }
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeStyleGetValue [status=implemented hash=7393c6eb975a]
    public static func yogaNodeStyleGetValue(
        _ node: YogaNode?,
        _ kind: UInt32,
        _ edgeOrGutter: UInt32
    ) -> UInt64 {
        var out: UInt64 = UInt64(Float.nan.bitPattern) << 32
        _ = yogaNodeStyleGetValueChecked(node, kind, edgeOrGutter, &out)
        return out
    }

    // parity: native/src/yoga.zig#yogaNodeStyleGetValueChecked [status=implemented hash=2049ad07fc90]
    public static func yogaNodeStyleGetValueChecked(
        _ node: YogaNode?,
        _ kind: UInt32,
        _ edgeOrGutter: UInt32,
        _ out: inout UInt64
    ) -> YogaStatus {
        let status = nodeStatus(node, mutation: false, teardown: false)
        if status != .ok { return status }
        guard let node,
              validValue(kind: kind, edge: edgeOrGutter),
              let valueKind = YogaValueKind(rawValue: Int32(bitPattern: kind))
        else {
            return .invalidArgument
        }
        let result: YogaValue
        switch valueKind {
        case .width: result = node.getWidth()
        case .height: result = node.getHeight()
        case .minWidth: result = node.getMinWidth()
        case .minHeight: result = node.getMinHeight()
        case .maxWidth: result = node.getMaxWidth()
        case .maxHeight: result = node.getMaxHeight()
        case .flexBasis: result = node.getFlexBasis()
        case .margin:
            guard let edge = Edge(rawValue: Int32(bitPattern: edgeOrGutter)) else { return .invalidArgument }
            result = node.getMargin(edge)
        case .padding:
            guard let edge = Edge(rawValue: Int32(bitPattern: edgeOrGutter)) else { return .invalidArgument }
            result = node.getPadding(edge)
        case .position:
            guard let edge = Edge(rawValue: Int32(bitPattern: edgeOrGutter)) else { return .invalidArgument }
            result = node.getPosition(edge)
        case .gap:
            guard let gutter = Gutter(rawValue: Int32(bitPattern: edgeOrGutter)) else { return .invalidArgument }
            result = node.getGap(gutter)
        }
        out = packYogaValue(result)
        return .ok
    }

    // MARK: - Measure & Dirtied Callbacks + Config Lookup

    // parity: native/src/yoga.zig#yogaNodeSetMeasureFunc [status=implemented hash=d3fef39f4ebf]
    public static func yogaNodeSetMeasureFunc(_ node: YogaNode?, _ enabled: Bool) {
        _ = yogaNodeSetMeasureFuncChecked(node, enabled ? 1 : 0)
    }

    // parity: native/src/yoga.zig#yogaNodeSetMeasureFuncChecked [status=implemented hash=c34a85fc0a7c]
    public static func yogaNodeSetMeasureFuncChecked(_ node: YogaNode?, _ enabled: UInt32) -> YogaStatus {
        guard enabled <= 1 else { return .invalidArgument }
        let status = nodeStatus(node, mutation: true, teardown: enabled == 0)
        if status != .ok { return status }
        guard let node else { return .invalidArgument }
        if enabled != 0 && node.getChildCount() > 0 {
            return .invalidArgument
        }
        if enabled == 0 {
            node.unsetMeasureFunc()
            return .ok
        }
        let cfg = node.config
        node.setMeasureFunc { [weak node] width, widthMode, height, heightMode in
            guard let node else { return FlexSize(width: .nan, height: .nan) }
            if let jsMeasure = cfg.jsMeasureCallback {
                cfg.measureResult = FlexSize(width: .nan, height: .nan)
                jsMeasure(
                    node,
                    width,
                    UInt32(bitPattern: widthMode.rawValue),
                    height,
                    UInt32(bitPattern: heightMode.rawValue)
                )
                return cfg.measureResult
            }
            if let nativeMeasure = cfg.nativeCallbacks.measure {
                return nativeMeasure(
                    node,
                    width,
                    UInt32(bitPattern: widthMode.rawValue),
                    height,
                    UInt32(bitPattern: heightMode.rawValue)
                )
            }
            return FlexSize(width: .nan, height: .nan)
        }
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeUnsetMeasureFuncChecked [status=implemented hash=46d1608b34aa]
    public static func yogaNodeUnsetMeasureFuncChecked(_ node: YogaNode?) -> YogaStatus {
        yogaNodeSetMeasureFuncChecked(node, 0)
    }

    // parity: native/src/yoga.zig#yogaNodeHasMeasureFunc [status=implemented hash=e00b3fbf24bf]
    public static func yogaNodeHasMeasureFunc(_ node: YogaNode?) -> Bool {
        guard let node, !node.isFreed() else { return false }
        return node.hasMeasureFunc()
    }

    // parity: native/src/yoga.zig#yogaNodeSetDirtiedFunc [status=implemented hash=9f590daed4ba]
    public static func yogaNodeSetDirtiedFunc(_ node: YogaNode?, _ enabled: Bool) {
        _ = yogaNodeSetDirtiedFuncChecked(node, enabled ? 1 : 0)
    }

    // parity: native/src/yoga.zig#yogaNodeSetDirtiedFuncChecked [status=implemented hash=b8437bbc1eb1]
    public static func yogaNodeSetDirtiedFuncChecked(_ node: YogaNode?, _ enabled: UInt32) -> YogaStatus {
        guard enabled <= 1 else { return .invalidArgument }
        let status = nodeStatus(node, mutation: true, teardown: enabled == 0)
        if status != .ok { return status }
        guard let node else { return .invalidArgument }
        if enabled == 0 {
            node.unsetDirtiedFunc()
            return .ok
        }
        let cfg = node.config
        node.setDirtiedFunc { dirtiedNode in
            if let jsDirtied = cfg.jsDirtiedCallback {
                jsDirtied(dirtiedNode)
                return
            }
            cfg.nativeCallbacks.dirtied?(dirtiedNode)
        }
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeUnsetDirtiedFuncChecked [status=implemented hash=d17e3a2cd257]
    public static func yogaNodeUnsetDirtiedFuncChecked(_ node: YogaNode?) -> YogaStatus {
        yogaNodeSetDirtiedFuncChecked(node, 0)
    }

    // parity: native/src/yoga.zig#yogaStoreMeasureResult [status=implemented hash=4aa145b5e58a]
    public static func yogaStoreMeasureResult(_ config: YogaConfig?, _ width: Float, _ height: Float) {
        guard let config, !config.isFreed else { return }
        config.measureResult = FlexSize(width: width, height: height)
    }

    // parity: native/src/yoga.zig#yogaNodeGetConfig [status=implemented hash=928957494f9e]
    public static func yogaNodeGetConfig(_ node: YogaNode?) -> YogaConfig? {
        guard let node, !node.isFreed() else { return nil }
        return node.config
    }
}
