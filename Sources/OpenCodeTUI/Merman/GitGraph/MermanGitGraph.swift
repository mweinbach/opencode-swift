import Foundation
import OpenTUICore

extension Merman {
    // MARK: - GitGraph Types (`gitgraph/types.ts`)

    // parity: merman/src/gitgraph/types.ts#GitGraphDirection [status=implemented hash=ee724a894047]
    public enum GitGraphDirection: String, Equatable, Hashable, Sendable, Codable {
        case LR
        case TB
        case BT
    }

    // parity: merman/src/gitgraph/types.ts#GitGraphCommitType [status=implemented hash=5ee70ecad31b]
    public enum GitGraphCommitType: String, Equatable, Hashable, Sendable, Codable {
        case NORMAL
        case REVERSE
        case HIGHLIGHT
    }

    // parity: merman/src/gitgraph/types.ts#GitGraphBranch [status=implemented hash=b96a03635e51]
    public struct GitGraphBranch: Equatable, Hashable, Sendable, Codable {
        public var name: String
        public var order: Int?
        public var head: String?

        public init(name: String, order: Int? = nil, head: String? = nil) {
            self.name = name
            self.order = order
            self.head = head
        }
    }

    // parity: merman/src/gitgraph/types.ts#GitGraphCommit [status=implemented hash=66e986c554a7]
    public struct GitGraphCommit: Equatable, Hashable, Sendable, Codable {
        public var id: String
        public var message: String?
        public var tags: [String]
        public var type: GitGraphCommitType
        public var branch: String
        public var parents: [String]

        public init(
            id: String,
            message: String? = nil,
            tags: [String] = [],
            type: GitGraphCommitType = .NORMAL,
            branch: String,
            parents: [String] = []
        ) {
            self.id = id
            self.message = message
            self.tags = tags
            self.type = type
            self.branch = branch
            self.parents = parents
        }
    }

    // parity: merman/src/gitgraph/types.ts#GitGraphDiagram [status=implemented hash=166c4efb33b2]
    public struct GitGraphDiagram: Equatable, Hashable, Sendable, Codable {
        public var direction: GitGraphDirection
        public var branches: [GitGraphBranch]
        public var commits: [GitGraphCommit]

        public init(direction: GitGraphDirection, branches: [GitGraphBranch], commits: [GitGraphCommit]) {
            self.direction = direction
            self.branches = branches
            self.commits = commits
        }
    }

    // parity: merman/src/gitgraph/types.ts#GitGraphDiagramRenderOptions [status=implemented hash=7b503c15653c]
    public struct GitGraphDiagramRenderOptions: Equatable, Hashable, Sendable {
        public var direction: GitGraphDirection?

        public init(direction: GitGraphDirection? = nil) {
            self.direction = direction
        }
    }

    // parity: merman/src/gitgraph/types.ts#GitGraphCellStyle [status=implemented hash=ce11c2655ea8]
    public enum GitGraphCellStyle: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case branch0
        case branch1
        case branch2
        case branch3
        case branch4
        case branch5
        case branch6
        case branch7
        case commit
        case merge
        case highlight
        case reverse
        case label
    }

    // MARK: - GitGraph Style (`gitgraph/style.ts`)

    private static let gitGraphBranchRgb: [DiagramRgb] = [
        (134, 225, 200),
        (230, 177, 126),
        (154, 184, 169),
        (198, 160, 246),
        (126, 189, 230),
        (225, 134, 166),
        (190, 210, 120),
        (180, 180, 210),
    ]

    public enum GitGraphThemeKey: String, Equatable, Hashable, Sendable {
        case primary
        case secondary
        case muted
        case warning
        case text
    }

    // parity: merman/src/gitgraph/style.ts#GitGraphStyleColors [status=implemented hash=8ff623a2a621]
    public typealias GitGraphStyleColors = [GitGraphCellStyle: RGBA]

    // parity: merman/src/gitgraph/style.ts#resolveGitGraphStyleColors [status=implemented hash=1468f294ffa7]
    public static func resolveGitGraphStyleColors(
        _ colors: [GitGraphThemeKey: RGBA?] = [:]
    ) -> GitGraphStyleColors {
        let rail = (colors[.muted] ?? nil) ?? rgba((111, 138, 126))
        return [
            .branch0: rail,
            .branch1: rail,
            .branch2: rail,
            .branch3: rail,
            .branch4: rail,
            .branch5: rail,
            .branch6: rail,
            .branch7: rail,
            .commit: (colors[.primary] ?? nil) ?? rgba(gitGraphBranchRgb[0]),
            .merge: (colors[.secondary] ?? nil) ?? rgba(gitGraphBranchRgb[2]),
            .highlight: (colors[.warning] ?? nil) ?? rgba(gitGraphBranchRgb[1]),
            .reverse: (colors[.warning] ?? nil) ?? rgba(gitGraphBranchRgb[5]),
            .label: (colors[.text] ?? nil) ?? rgba((228, 239, 232)),
        ]
    }

    // MARK: - GitGraph Parser (`gitgraph/parser.ts`)

    private static let gitGraphHeaderPattern = #"^gitGraph(?:\s+(LR|TB|BT))?\s*:?$"#
    private static let gitGraphAccessibilityPattern = #"^acc(?:Title|Descr)(?::|\s|$)"#

    // parity: merman/src/gitgraph/parser.ts#isMermaidGitGraphDiagram [status=implemented hash=b10d35397ab1]
    public static func isMermaidGitGraphDiagram(_ content: String) -> Bool {
        regexTest(gitGraphHeaderPattern, in: firstMeaningfulMermaidLine(content) ?? "", options: [.caseInsensitive])
    }

    // parity: merman/src/gitgraph/parser.ts#parseMermaidGitGraphDiagram [status=implemented hash=aaa01d19e77d]
    public static func parseMermaidGitGraphDiagram(_ content: String) throws -> GitGraphDiagram {
        let firstLine = firstMeaningfulMermaidLine(content) ?? ""
        if !regexTest(gitGraphHeaderPattern, in: firstLine, options: [.caseInsensitive]) {
            throw gitGraphSyntaxError(1, firstLine, "GitGraph header is required")
        }

        var branches: [GitGraphBranch] = [GitGraphBranch(name: "main", order: 0)]
        var commits: [GitGraphCommit] = []
        var heads: [String: String?] = ["main": nil]
        var ids = Set<String>()
        var direction: GitGraphDirection = .LR
        var currentBranch = "main"
        var generatedId = 1
        var inAccessibilityDescription = false
        var headerSeen = false

        for source in meaningfulNumberedMermaidLines(content) {
            let line = stripGitGraphComment(source.text)
            if inAccessibilityDescription {
                if line == "}" { inAccessibilityDescription = false }
                continue
            }
            if regexTest(#"^accDescr\s*\{$"#, in: line, options: [.caseInsensitive]) {
                inAccessibilityDescription = true
                continue
            }
            if line.isEmpty
                || regexTest(gitGraphAccessibilityPattern, in: line, options: [.caseInsensitive])
                || regexTest(#"^title(?:\s|$)"#, in: line, options: [.caseInsensitive])
            {
                continue
            }

            if let header = regexFirstMatch(gitGraphHeaderPattern, in: line, options: [.caseInsensitive]) {
                if headerSeen {
                    throw gitGraphSyntaxError(source.lineNumber, line, "GitGraph header can only appear once")
                }
                headerSeen = true
                if let dirRaw = header[1]?.uppercased(), let dir = GitGraphDirection(rawValue: dirRaw) {
                    direction = dir
                } else {
                    direction = .LR
                }
                continue
            }

            let tokens = tokenizeGitGraph(line)
            let command = tokens.first ?? ""
            var rest = Array(tokens.dropFirst())
            let operation = command.lowercased()

            if operation == "commit" {
                var shorthandMessage: String?
                if let first = rest.first,
                   first.count >= 2,
                   ((first.hasPrefix("\"") && first.hasSuffix("\"")) || (first.hasPrefix("'") && first.hasSuffix("'")))
                {
                    shorthandMessage = stripMermaidQuotes(rest.removeFirst())
                }
                let attributes = try parseGitGraphAttributes(rest, lineNumber: source.lineNumber, line: line, allowed: ["id", "msg", "tag", "type"])
                let explicitId = try singleGitGraphAttribute(attributes, key: "id", lineNumber: source.lineNumber, line: line)
                let id: String
                if let explicitId {
                    id = explicitId
                } else {
                    id = "commit-\(generatedId)"
                    generatedId += 1
                }
                if id.isEmpty {
                    throw gitGraphSyntaxError(source.lineNumber, line, "GitGraph commit id cannot be empty")
                }
                if ids.contains(id) {
                    throw gitGraphSyntaxError(source.lineNumber, line, "Duplicate commit id \"\(id)\"")
                }
                let typeVal = try parseGitGraphCommitType(
                    try singleGitGraphAttribute(attributes, key: "type", lineNumber: source.lineNumber, line: line),
                    lineNumber: source.lineNumber,
                    line: line
                )
                let parent = heads[currentBranch] ?? nil
                let message = try singleGitGraphAttribute(attributes, key: "msg", lineNumber: source.lineNumber, line: line) ?? shorthandMessage
                let commit = GitGraphCommit(
                    id: id,
                    message: message,
                    tags: attributes["tag"] ?? [],
                    type: typeVal,
                    branch: currentBranch,
                    parents: parent.map { [$0] } ?? []
                )
                commits.append(commit)
                ids.insert(id)
                heads[currentBranch] = id
                continue
            }

            if operation == "branch" {
                if rest.isEmpty {
                    throw gitGraphSyntaxError(source.lineNumber, line, "GitGraph branch name cannot be empty")
                }
                let name = stripMermaidQuotes(rest[0])
                if name.isEmpty {
                    throw gitGraphSyntaxError(source.lineNumber, line, "GitGraph branch name cannot be empty")
                }
                if heads.keys.contains(name) {
                    throw gitGraphSyntaxError(source.lineNumber, line, "Duplicate branch \"\(name)\"")
                }
                let attributes = try parseGitGraphAttributes(Array(rest.dropFirst()), lineNumber: source.lineNumber, line: line, allowed: ["order"])
                let orderValue = try singleGitGraphAttribute(attributes, key: "order", lineNumber: source.lineNumber, line: line)
                var order: Int?
                if let orderValue {
                    guard let parsed = Int(orderValue), parsed >= 0 else {
                        throw gitGraphSyntaxError(source.lineNumber, line, "GitGraph branch order must be a non-negative integer")
                    }
                    order = parsed
                }
                branches.append(GitGraphBranch(name: name, order: order))
                heads[name] = heads[currentBranch] ?? nil
                currentBranch = name
                continue
            }

            if operation == "checkout" || operation == "switch" {
                if rest.count != 1 {
                    throw gitGraphSyntaxError(source.lineNumber, line, "GitGraph \(operation) requires one branch")
                }
                let name = stripMermaidQuotes(rest[0])
                if !heads.keys.contains(name) {
                    throw gitGraphSyntaxError(source.lineNumber, line, "Unknown branch \"\(name)\"")
                }
                currentBranch = name
                continue
            }

            if operation == "merge" {
                if rest.isEmpty {
                    throw gitGraphSyntaxError(source.lineNumber, line, "GitGraph merge requires a branch")
                }
                let branch = stripMermaidQuotes(rest[0])
                if !heads.keys.contains(branch) {
                    throw gitGraphSyntaxError(source.lineNumber, line, "Unknown branch \"\(branch)\"")
                }
                if branch == currentBranch {
                    throw gitGraphSyntaxError(source.lineNumber, line, "GitGraph cannot merge a branch into itself")
                }
                guard let currentHead = heads[currentBranch] ?? nil else {
                    throw gitGraphSyntaxError(source.lineNumber, line, "Branch \"\(currentBranch)\" has no commits")
                }
                guard let mergedHead = heads[branch] ?? nil else {
                    throw gitGraphSyntaxError(source.lineNumber, line, "Branch \"\(branch)\" has no commits")
                }
                if currentHead == mergedHead {
                    throw gitGraphSyntaxError(source.lineNumber, line, "Branches already share head \"\(mergedHead)\"")
                }
                let attributes = try parseGitGraphAttributes(Array(rest.dropFirst()), lineNumber: source.lineNumber, line: line, allowed: ["id", "tag", "type"])
                let explicitId = try singleGitGraphAttribute(attributes, key: "id", lineNumber: source.lineNumber, line: line)
                let id: String
                if let explicitId {
                    id = explicitId
                } else {
                    id = "commit-\(generatedId)"
                    generatedId += 1
                }
                if ids.contains(id) {
                    throw gitGraphSyntaxError(source.lineNumber, line, "Duplicate commit id \"\(id)\"")
                }
                let commit = GitGraphCommit(
                    id: id,
                    message: nil,
                    tags: attributes["tag"] ?? [],
                    type: try parseGitGraphCommitType(
                        try singleGitGraphAttribute(attributes, key: "type", lineNumber: source.lineNumber, line: line),
                        lineNumber: source.lineNumber,
                        line: line
                    ),
                    branch: currentBranch,
                    parents: [currentHead, mergedHead]
                )
                commits.append(commit)
                ids.insert(id)
                heads[currentBranch] = id
                continue
            }

            if operation == "cherry-pick" {
                throw gitGraphSyntaxError(source.lineNumber, line, "Cherry-pick is not supported")
            }
            throw gitGraphSyntaxError(source.lineNumber, line)
        }

        let resolvedBranches = branches.map { branch in
            GitGraphBranch(name: branch.name, order: branch.order, head: heads[branch.name] ?? nil)
        }
        return GitGraphDiagram(direction: direction, branches: orderGitGraphBranches(resolvedBranches), commits: commits)
    }

    private static func tokenizeGitGraph(_ line: String) -> [String] {
        var tokens: [String] = []
        var token = ""
        var quote: Character?
        for char in line {
            if (char == "\"" || char == "'") && (quote == nil || quote == char) {
                quote = (quote == char) ? nil : char
                token.append(char)
                continue
            }
            if char.isWhitespace && quote == nil {
                if !token.isEmpty { tokens.append(token) }
                token = ""
                continue
            }
            token.append(char)
        }
        if quote != nil { return [line] }
        if !token.isEmpty { tokens.append(token) }
        return tokens
    }

    private static func parseGitGraphAttributes(
        _ tokens: [String],
        lineNumber: Int,
        line: String,
        allowed: [String]
    ) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        var index = 0
        while index < tokens.count {
            let keyToken = tokens[index]
            let key: String
            let inline: String
            if let colon = keyToken.firstIndex(of: ":") {
                key = String(keyToken[..<colon]).lowercased()
                inline = String(keyToken[keyToken.index(after: colon)...])
            } else {
                key = keyToken.lowercased()
                inline = ""
            }
            if !allowed.contains(key) {
                throw gitGraphSyntaxError(lineNumber, line, "Unsupported GitGraph attribute \"\(key)\"")
            }
            let valueToken: String
            if !inline.isEmpty {
                valueToken = inline
            } else {
                index += 1
                guard index < tokens.count else {
                    throw gitGraphSyntaxError(lineNumber, line, "GitGraph attribute \"\(key)\" requires a value")
                }
                valueToken = tokens[index]
            }
            result[key, default: []].append(stripMermaidQuotes(valueToken))
            index += 1
        }
        return result
    }

    private static func singleGitGraphAttribute(
        _ attributes: [String: [String]],
        key: String,
        lineNumber: Int,
        line: String
    ) throws -> String? {
        guard let values = attributes[key] else { return nil }
        if values.count > 1 {
            throw gitGraphSyntaxError(lineNumber, line, "GitGraph attribute \"\(key)\" cannot repeat")
        }
        return values.first
    }

    private static func parseGitGraphCommitType(
        _ value: String?,
        lineNumber: Int,
        line: String
    ) throws -> GitGraphCommitType {
        guard let value else { return .NORMAL }
        if let parsed = GitGraphCommitType(rawValue: value.uppercased()) {
            return parsed
        }
        throw gitGraphSyntaxError(lineNumber, line, "Unknown GitGraph commit type \"\(value)\"")
    }

    private static func orderGitGraphBranches(_ branches: [GitGraphBranch]) -> [GitGraphBranch] {
        guard let main = branches.first else { return [] }
        let rest = Array(branches.dropFirst().enumerated())
        let unordered = rest.filter { $0.element.order == nil }.map(\.element)
        let ordered = rest
            .filter { $0.element.order != nil }
            .sorted { lhs, rhs in
                if lhs.element.order! != rhs.element.order! {
                    return lhs.element.order! < rhs.element.order!
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        return [main] + unordered + ordered
    }

    private static func stripGitGraphComment(_ value: String) -> String {
        let chars = Array(value)
        var quote: Character?
        if chars.count >= 2 {
            for index in 0..<(chars.count - 1) {
                let char = chars[index]
                if (char == "\"" || char == "'") && (quote == nil || quote == char) {
                    quote = (quote == char) ? nil : char
                    continue
                }
                if quote == nil && char == "%" && chars[index + 1] == "%" {
                    return jsTrim(String(chars[..<index]))
                }
            }
        }
        return jsTrim(value)
    }

    private static func gitGraphSyntaxError(_ lineNumber: Int, _ sourceLine: String, _ reason: String = "Unsupported syntax") -> MermaidSyntaxError {
        MermaidSyntaxError(kind: .gitGraph, lineNumber: lineNumber, sourceLine: sourceLine, reason: reason)
    }

    // MARK: - GitGraph Render Grid (`gitgraph/render-grid.ts`)

    // parity: merman/src/gitgraph/render-grid.ts#GitGraphGrid [status=implemented hash=96d70ed03846]
    public typealias GitGraphGrid = DiagramCanvas<GitGraphCellStyle, EmptyCanvasMetadata>

    // parity: merman/src/gitgraph/render-grid.ts#renderGitGraphGridText [status=implemented hash=d654da4a2515]
    public static func renderGitGraphGridText(_ grid: GitGraphGrid) -> String {
        grid.toString(DiagramCanvasTextOptions(trimBottom: true))
    }

    // parity: merman/src/gitgraph/render-grid.ts#renderGitGraphGridStyledText [status=implemented hash=5b939b9740a9]
    public static func renderGitGraphGridStyledText(_ grid: GitGraphGrid, colors: GitGraphStyleColors) -> StyledText {
        renderDiagramGridStyledText(
            grid,
            fg: { run in run.style.flatMap { colors[$0] } },
            bg: nil,
            options: DiagramCanvasRunOptions(trimBottom: true)
        )
    }

    // MARK: - GitGraph Drawing (`gitgraph/drawing.ts`)

    private struct GitBranchSpan {
        var first: Int
        var last: Int
    }

    private struct GitConnections {
        var up: Bool = false
        var down: Bool = false
        var left: Bool = false
        var right: Bool = false
        var style: GitGraphCellStyle
    }

    // parity: merman/src/gitgraph/drawing.ts#drawGitGraphDiagramGrid [status=implemented hash=19d7305a6f5a]
    public static func drawGitGraphDiagramGrid(
        _ diagram: GitGraphDiagram,
        options: GitGraphDiagramRenderOptions = GitGraphDiagramRenderOptions()
    ) throws -> GitGraphGrid {
        _ = options
        if diagram.commits.isEmpty {
            return try GitGraphGrid(width: 0, height: 0)
        }
        let laneWidth = 2
        let labelGap = 2
        let laneByBranch = Dictionary(uniqueKeysWithValues: diagram.branches.enumerated().map { ($0.element.name, $0.offset) })
        let commitById = Dictionary(uniqueKeysWithValues: diagram.commits.map { ($0.id, $0) })
        let spans = gitBranchSpans(diagram, commitById: commitById)
        let heads = gitBranchHeads(diagram)
        let graphWidth = (diagram.branches.count - 1) * laneWidth + 1
        let labelWidth = diagram.commits.map { diagramTextWidth(gitCommitLabel($0, heads: heads)) }.max() ?? 0
        let forks = diagram.commits.map { gitIsFork($0, laneByBranch: laneByBranch, commitById: commitById) }
        let height = diagram.commits.count + forks.filter { $0 }.count
        let grid = try GitGraphGrid(width: graphWidth + labelGap + labelWidth, height: height)

        var row = 0
        for (index, commit) in diagram.commits.enumerated() {
            if forks[index] {
                drawGitTransitionRow(
                    grid,
                    spans: spans,
                    laneByBranch: laneByBranch,
                    commitById: commitById,
                    commit: commit,
                    index: index,
                    y: row,
                    laneWidth: laneWidth
                )
                row += 1
            }
            drawGitCommitRow(
                grid,
                diagram: diagram,
                spans: spans,
                laneByBranch: laneByBranch,
                commitById: commitById,
                commit: commit,
                index: index,
                y: row,
                laneWidth: laneWidth
            )
            grid.setText(graphWidth + labelGap, row, gitCommitLabel(commit, heads: heads), style: .label)
            row += 1
        }
        return grid
    }

    private static func drawGitTransitionRow(
        _ grid: GitGraphGrid,
        spans: [String: GitBranchSpan],
        laneByBranch: [String: Int],
        commitById: [String: GitGraphCommit],
        commit: GitGraphCommit,
        index: Int,
        y: Int,
        laneWidth: Int
    ) {
        var cells: [Int: GitConnections] = [:]
        for (branch, span) in spans {
            if span.first >= index || span.last < index { continue }
            guard let lane = laneByBranch[branch] else { continue }
            gitConnect(&cells, x: lane * laneWidth, up: true, down: true, style: gitBranchStyle(lane))
        }
        if let lane = laneByBranch[commit.branch],
           let firstParentId = commit.parents.first,
           let firstParent = commitById[firstParentId],
           firstParent.branch != commit.branch,
           let parentLane = laneByBranch[firstParent.branch]
        {
            gitConnectHorizontal(
                &cells,
                sourceLane: parentLane,
                targetLane: lane,
                sourceUp: true,
                sourceDown: true,
                targetUp: false,
                targetDown: true,
                style: gitBranchStyle(lane),
                laneWidth: laneWidth
            )
        }
        gitPaintConnections(grid, cells: cells, y: y)
    }

    private static func drawGitCommitRow(
        _ grid: GitGraphGrid,
        diagram: GitGraphDiagram,
        spans: [String: GitBranchSpan],
        laneByBranch: [String: Int],
        commitById: [String: GitGraphCommit],
        commit: GitGraphCommit,
        index: Int,
        y: Int,
        laneWidth: Int
    ) {
        var cells: [Int: GitConnections] = [:]
        for branch in diagram.branches {
            guard let span = spans[branch.name] else { continue }
            if span.first > index || (span.last <= index && branch.name != commit.branch) { continue }
            guard let lane = laneByBranch[branch.name] else { continue }
            gitConnect(&cells, x: lane * laneWidth, up: index > 0, down: span.last > index, style: gitBranchStyle(lane))
        }
        if let lane = laneByBranch[commit.branch] {
            if commit.parents.count > 1,
               let secondParent = commitById[commit.parents[1]],
               let parentLane = laneByBranch[secondParent.branch]
            {
                gitConnectHorizontal(
                    &cells,
                    sourceLane: lane,
                    targetLane: parentLane,
                    sourceUp: true,
                    sourceDown: false,
                    targetUp: true,
                    targetDown: false,
                    style: gitBranchStyle(parentLane),
                    laneWidth: laneWidth
                )
            }
            gitPaintConnections(grid, cells: cells, y: y)
            grid.setCell(lane * laneWidth, y, gitCommitGlyph(commit), style: gitCommitStyle(commit))
        } else {
            gitPaintConnections(grid, cells: cells, y: y)
        }
    }

    private static func gitConnectHorizontal(
        _ cells: inout [Int: GitConnections],
        sourceLane: Int,
        targetLane: Int,
        sourceUp: Bool,
        sourceDown: Bool,
        targetUp: Bool,
        targetDown: Bool,
        style: GitGraphCellStyle,
        laneWidth: Int
    ) {
        guard sourceLane != targetLane else { return }
        let source = sourceLane * laneWidth
        let target = targetLane * laneWidth
        let direction = target > source ? 1 : -1
        gitConnect(
            &cells,
            x: source,
            up: sourceUp,
            down: sourceDown,
            left: direction < 0,
            right: direction > 0,
            style: style
        )
        var x = source + direction
        while x != target {
            gitConnect(&cells, x: x, left: true, right: true, style: style)
            x += direction
        }
        gitConnect(
            &cells,
            x: target,
            up: targetUp,
            down: targetDown,
            left: direction > 0,
            right: direction < 0,
            style: style
        )
    }

    private static func gitConnect(
        _ cells: inout [Int: GitConnections],
        x: Int,
        up: Bool = false,
        down: Bool = false,
        left: Bool = false,
        right: Bool = false,
        style: GitGraphCellStyle
    ) {
        if var existing = cells[x] {
            if up { existing.up = true }
            if down { existing.down = true }
            if left { existing.left = true }
            if right { existing.right = true }
            cells[x] = existing
        } else {
            cells[x] = GitConnections(up: up, down: down, left: left, right: right, style: style)
        }
    }

    private static func gitPaintConnections(_ grid: GitGraphGrid, cells: [Int: GitConnections], y: Int) {
        for (x, conn) in cells {
            grid.setCell(x, y, gitConnectionGlyph(conn), style: conn.style)
        }
    }

    private static func gitConnectionGlyph(_ c: GitConnections) -> String {
        switch (c.up, c.down, c.left, c.right) {
        case (true, true, false, false): return "│"
        case (false, false, true, true): return "─"
        case (false, true, false, true): return "╭"
        case (false, true, true, false): return "╮"
        case (true, false, false, true): return "╰"
        case (true, false, true, false): return "╯"
        case (true, true, false, true): return "├"
        case (true, true, true, false): return "┤"
        case (false, true, true, true): return "┬"
        case (true, false, true, true): return "┴"
        case (true, true, true, true): return "┼"
        case (true, false, false, false): return "│"
        case (false, true, false, false): return "│"
        case (false, false, true, false): return "─"
        case (false, false, false, true): return "─"
        default: return " "
        }
    }

    private static func gitBranchSpans(_ diagram: GitGraphDiagram, commitById: [String: GitGraphCommit]) -> [String: GitBranchSpan] {
        var spans: [String: GitBranchSpan] = [:]
        for (index, commit) in diagram.commits.enumerated() {
            if var span = spans[commit.branch] {
                span.last = index
                spans[commit.branch] = span
            } else {
                spans[commit.branch] = GitBranchSpan(first: index, last: index)
            }
            for parentId in commit.parents {
                guard let parent = commitById[parentId], parent.branch != commit.branch else { continue }
                if var parentSpan = spans[parent.branch] {
                    parentSpan.last = max(parentSpan.last, index)
                    spans[parent.branch] = parentSpan
                }
            }
        }
        return spans
    }

    private static func gitBranchHeads(_ diagram: GitGraphDiagram) -> [String: [String]] {
        var heads: [String: [String]] = [:]
        for branch in diagram.branches {
            guard let head = branch.head else { continue }
            heads[head, default: []].append(branch.name)
        }
        return heads
    }

    private static func gitIsFork(
        _ commit: GitGraphCommit,
        laneByBranch: [String: Int],
        commitById: [String: GitGraphCommit]
    ) -> Bool {
        guard let parentId = commit.parents.first, let parent = commitById[parentId] else { return false }
        return laneByBranch[parent.branch] != laneByBranch[commit.branch]
    }

    private static func gitCommitGlyph(_ commit: GitGraphCommit) -> String {
        switch commit.type {
        case .REVERSE: return "⊗"
        case .HIGHLIGHT: return "◆"
        case .NORMAL: return commit.parents.count > 1 ? "◎" : "●"
        }
    }

    private static func gitCommitStyle(_ commit: GitGraphCommit) -> GitGraphCellStyle {
        switch commit.type {
        case .REVERSE: return .reverse
        case .HIGHLIGHT: return .highlight
        case .NORMAL: return commit.parents.count > 1 ? .merge : .commit
        }
    }

    private static func gitCommitLabel(_ commit: GitGraphCommit, heads: [String: [String]]) -> String {
        let subject = commit.message ?? commit.id
        let decorations = ((heads[commit.id] ?? []) + commit.tags).map { "[\($0)]" }
        return decorations.isEmpty ? subject : "\(subject)  \(decorations.joined(separator: " "))"
    }

    private static func gitBranchStyle(_ lane: Int) -> GitGraphCellStyle {
        let styles: [GitGraphCellStyle] = [.branch0, .branch1, .branch2, .branch3, .branch4, .branch5, .branch6, .branch7]
        return styles[lane % 8]
    }

    // MARK: - GitGraph Diagram (`gitgraph/diagram.ts`)

    // parity: merman/src/gitgraph/diagram.ts#renderGitGraphDiagram [status=implemented hash=29f2f69eb79b]
    public static func renderGitGraphDiagram(
        _ content: String,
        options: GitGraphDiagramRenderOptions = GitGraphDiagramRenderOptions()
    ) throws -> String {
        renderGitGraphGridText(try drawGitGraphDiagramGrid(try parseMermaidGitGraphDiagram(content), options: options))
    }
}
