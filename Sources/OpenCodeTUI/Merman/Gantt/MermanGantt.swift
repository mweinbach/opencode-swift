import Foundation
import OpenTUICore

extension Merman {
    // MARK: - Gantt Types (`gantt/types.ts`)

    // parity: merman/src/gantt/types.ts#GanttTaskState [status=implemented hash=15d4da597164]
    public enum GanttTaskState: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case task
        case active
        case critical
        case done
        case milestone
    }

    // parity: merman/src/gantt/types.ts#GanttSection [status=implemented hash=9cae8c1d8b33]
    public struct GanttSection: Equatable, Hashable, Sendable, Codable {
        public var label: String

        public init(label: String) {
            self.label = label
        }
    }

    // parity: merman/src/gantt/types.ts#GanttTask [status=implemented hash=4eb0334cf6ae]
    public struct GanttTask: Equatable, Hashable, Sendable, Codable {
        public var label: String
        public var id: String?
        public var section: GanttSection?
        public var start: Double
        public var end: Double
        public var state: GanttTaskState

        public init(
            label: String,
            id: String? = nil,
            section: GanttSection? = nil,
            start: Double,
            end: Double,
            state: GanttTaskState
        ) {
            self.label = label
            self.id = id
            self.section = section
            self.start = start
            self.end = end
            self.state = state
        }
    }

    // parity: merman/src/gantt/types.ts#GanttEntry [status=implemented hash=4b6bd62a2355]
    public enum GanttEntry: Equatable, Hashable, Sendable, Codable {
        case section(GanttSection)
        case task(GanttTask)
    }

    // parity: merman/src/gantt/types.ts#GanttDiagram [status=implemented hash=2610716beff7]
    public struct GanttDiagram: Equatable, Hashable, Sendable, Codable {
        public var title: String?
        public var dateFormat: String
        public var axisFormat: String
        public var tasks: [GanttTask]
        public var entries: [GanttEntry]

        public init(
            title: String? = nil,
            dateFormat: String,
            axisFormat: String,
            tasks: [GanttTask],
            entries: [GanttEntry]
        ) {
            self.title = title
            self.dateFormat = dateFormat
            self.axisFormat = axisFormat
            self.tasks = tasks
            self.entries = entries
        }
    }

    public enum GanttTrackMode: String, Equatable, Hashable, Sendable, Codable {
        case dots
        case line
    }

    public enum GanttEndpointsMode: String, Equatable, Hashable, Sendable, Codable {
        case plain
        case points
    }

    public enum GanttSectionsSpacing: String, Equatable, Hashable, Sendable, Codable {
        case compact
        case spaced
    }

    // parity: merman/src/gantt/types.ts#GanttRenderStyle [status=implemented hash=9cf19d608e16]
    public enum GanttRenderStyle: String, Equatable, Hashable, Sendable, Codable {
        case rail
        case block
        case capsule
        case points
        case track
    }

    // parity: merman/src/gantt/types.ts#GanttLineStyle [status=implemented hash=0daf15d9bfb7]
    public enum GanttLineStyle: String, Equatable, Hashable, Sendable, Codable {
        case heavy
        case thin
        case double
        case dashed
    }

    // parity: merman/src/gantt/types.ts#GanttLabelLayout [status=implemented hash=4db385db0a8a]
    public enum GanttLabelLayout: String, Equatable, Hashable, Sendable, Codable {
        case right
        case left
        case tree
    }

    // parity: merman/src/gantt/types.ts#GanttTrackTone [status=implemented hash=d433097af1ec]
    public enum GanttTrackTone: String, Equatable, Hashable, Sendable, Codable {
        case medium
        case dim
        case faint
    }

    // parity: merman/src/gantt/types.ts#GanttDiagramRenderOptions [status=implemented hash=3d32db33563f]
    public struct GanttDiagramRenderOptions: Equatable, Hashable, Sendable {
        public var layoutMaxWidth: Int?
        public var style: GanttRenderStyle?
        public var track: GanttTrackMode?
        public var endpoints: GanttEndpointsMode?
        public var line: GanttLineStyle?
        public var labels: GanttLabelLayout?
        public var sections: GanttSectionsSpacing?
        public var trackTone: GanttTrackTone?

        public init(
            layoutMaxWidth: Int? = nil,
            style: GanttRenderStyle? = nil,
            track: GanttTrackMode? = nil,
            endpoints: GanttEndpointsMode? = nil,
            line: GanttLineStyle? = nil,
            labels: GanttLabelLayout? = nil,
            sections: GanttSectionsSpacing? = nil,
            trackTone: GanttTrackTone? = nil
        ) {
            self.layoutMaxWidth = layoutMaxWidth
            self.style = style
            self.track = track
            self.endpoints = endpoints
            self.line = line
            self.labels = labels
            self.sections = sections
            self.trackTone = trackTone
        }
    }

    // parity: merman/src/gantt/types.ts#GanttBaseCellStyle [status=implemented hash=f9ed2daa32f4]
    public enum GanttBaseCellStyle: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case title
        case axis
        case section
        case task
        case active
        case critical
        case done
        case milestone
    }

    // parity: merman/src/gantt/types.ts#GanttTrackCellStyle [status=implemented hash=93f125c38790]
    public enum GanttTrackCellStyle: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case trackMedium
        case trackDim
        case trackFaint
    }

    // parity: merman/src/gantt/types.ts#GanttCellStyle [status=implemented hash=7aeb20d0d23d]
    public enum GanttCellStyle: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case title
        case axis
        case section
        case task
        case active
        case critical
        case done
        case milestone
        case trackMedium
        case trackDim
        case trackFaint

        static func fromTaskState(_ state: GanttTaskState) -> GanttCellStyle {
            switch state {
            case .task: return .task
            case .active: return .active
            case .critical: return .critical
            case .done: return .done
            case .milestone: return .milestone
            }
        }
    }

    // MARK: - Gantt Style (`gantt/style.ts`)

    private static let ganttDefaultThemeRgb: [GanttBaseCellStyle: DiagramRgb] = [
        .title: (228, 239, 232),
        .axis: (111, 138, 126),
        .section: (154, 184, 169),
        .task: (134, 225, 200),
        .active: (134, 225, 200),
        .critical: (230, 177, 126),
        .done: (111, 138, 126),
        .milestone: (198, 160, 246),
    ]

    public enum GanttStyleInputKey: String, Equatable, Hashable, Sendable {
        case title
        case axis
        case background
        case section
        case task
        case active
        case critical
        case done
        case milestone
    }

    // parity: merman/src/gantt/style.ts#GanttStyleColors [status=implemented hash=7400e90ebda1]
    public typealias GanttStyleColors = [GanttCellStyle: RGBA]

    // parity: merman/src/gantt/style.ts#resolveGanttStyleColors [status=implemented hash=611de78c2378]
    public static func resolveGanttStyleColors(
        _ colors: [GanttStyleInputKey: RGBA?] = [:]
    ) -> GanttStyleColors {
        let axis = (colors[.axis] ?? nil) ?? rgba(ganttDefaultThemeRgb[.axis]!)
        let background = (colors[.background] ?? nil) ?? rgba((13, 17, 23))
        return [
            .title: (colors[.title] ?? nil) ?? rgba(ganttDefaultThemeRgb[.title]!),
            .axis: axis,
            .section: (colors[.section] ?? nil) ?? rgba(ganttDefaultThemeRgb[.section]!),
            .task: (colors[.task] ?? nil) ?? rgba(ganttDefaultThemeRgb[.task]!),
            .active: (colors[.active] ?? nil) ?? rgba(ganttDefaultThemeRgb[.active]!),
            .critical: (colors[.critical] ?? nil) ?? rgba(ganttDefaultThemeRgb[.critical]!),
            .done: (colors[.done] ?? nil) ?? rgba(ganttDefaultThemeRgb[.done]!),
            .milestone: (colors[.milestone] ?? nil) ?? rgba(ganttDefaultThemeRgb[.milestone]!),
            .trackMedium: blendColor(axis, background, 0.35),
            .trackDim: blendColor(axis, background, 0.55),
            .trackFaint: blendColor(axis, background, 0.72),
        ]
    }

    // MARK: - Gantt Parser (`gantt/parser.ts`)

    private static let ganttHeaderPattern = #"^gantt$"#
    private static let ganttDirectivePattern = #"^(title|dateFormat|axisFormat|tickInterval|excludes|todayMarker)\s+(.+)$"#
    private static let ganttSectionPattern = #"^section(?:\s+(.+))?$"#
    private static let ganttAccessibilityPattern = #"^acc(?:Title|Descr)(?::|\s|$)"#
    private static let ganttTaskStates: Set<String> = ["active", "done", "crit", "milestone", "vert"]

    // parity: merman/src/gantt/parser.ts#isMermaidGanttDiagram [status=implemented hash=203f7f935f90]
    public static func isMermaidGanttDiagram(_ content: String) -> Bool {
        regexTest(ganttHeaderPattern, in: firstMeaningfulMermaidLine(content) ?? "", options: [.caseInsensitive])
    }

    // parity: merman/src/gantt/parser.ts#parseMermaidGanttDiagram [status=implemented hash=dfb251de4f9e]
    public static func parseMermaidGanttDiagram(_ content: String) throws -> GanttDiagram {
        var tasks: [GanttTask] = []
        var entries: [GanttEntry] = []
        var tasksById: [String: GanttTask] = [:]
        var title: String?
        var dateFormat = "YYYY-MM-DD"
        var axisFormat = "%Y-%m-%d"
        var section: GanttSection?
        var headerSeen = false
        var inAccessibilityDescription = false

        for source in meaningfulNumberedMermaidLines(content) {
            let line = stripGanttComment(source.text)
            if inAccessibilityDescription {
                if line == "}" { inAccessibilityDescription = false }
                continue
            }
            if regexTest(#"^accDescr\s*\{$"#, in: line, options: [.caseInsensitive]) {
                inAccessibilityDescription = true
                continue
            }
            if regexTest(ganttAccessibilityPattern, in: line, options: [.caseInsensitive]) || line.isEmpty {
                continue
            }
            if regexTest(ganttHeaderPattern, in: line, options: [.caseInsensitive]) {
                if headerSeen {
                    throw ganttSyntaxError(source.lineNumber, line, "Gantt header can only appear once")
                }
                headerSeen = true
                continue
            }
            if !headerSeen {
                throw ganttSyntaxError(source.lineNumber, line, "Gantt header is required")
            }

            if let sectionMatch = regexFirstMatch(ganttSectionPattern, in: line, options: [.caseInsensitive]) {
                guard let raw = sectionMatch[1], !raw.isEmpty else {
                    throw ganttSyntaxError(source.lineNumber, line, "Gantt section cannot be empty")
                }
                let nextSection = GanttSection(label: stripMermaidQuotes(raw))
                section = nextSection
                entries.append(.section(nextSection))
                continue
            }

            if let directive = regexFirstMatch(ganttDirectivePattern, in: line, options: [.caseInsensitive]) {
                let rawName = directive[1] ?? ""
                let name = rawName.lowercased()
                let value = jsTrim(directive[2] ?? "")
                if name == "title" {
                    title = stripMermaidQuotes(value)
                } else if name == "dateformat" {
                    dateFormat = value
                } else if name == "axisformat" {
                    axisFormat = value
                } else {
                    throw ganttSyntaxError(source.lineNumber, line, "\(rawName) is not supported")
                }
                continue
            }

            guard let sepIdx = line.firstIndex(of: ":"), sepIdx > line.startIndex else {
                throw ganttSyntaxError(source.lineNumber, line)
            }
            let label = stripMermaidQuotes(String(line[..<sepIdx]))
            var fields = String(line[line.index(after: sepIdx)...])
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { jsTrim(String($0)) }
                .filter { !$0.isEmpty }
            var flags = Set<String>()
            while let first = fields.first, ganttTaskStates.contains(first.lowercased()) {
                flags.insert(fields.removeFirst().lowercased())
            }
            if fields.count < 2 || fields.count > 3 {
                throw ganttSyntaxError(source.lineNumber, line, "Gantt tasks require a start and end or duration")
            }
            let id = fields.count == 3 ? fields.removeFirst() : nil
            if let id, tasksById[id] != nil {
                throw ganttSyntaxError(source.lineNumber, line, "Duplicate task id \"\(id)\"")
            }
            let start = try parseGanttStart(fields[0], format: dateFormat, tasksById: tasksById, lineNumber: source.lineNumber, sourceLine: line)
            let end = try parseGanttEnd(fields[1], start: start, format: dateFormat, lineNumber: source.lineNumber, sourceLine: line)
            if end < start {
                throw ganttSyntaxError(source.lineNumber, line, "Gantt task cannot end before it starts")
            }
            let task = GanttTask(
                label: label,
                id: id,
                section: section,
                start: start,
                end: end,
                state: ganttTaskState(flags)
            )
            tasks.append(task)
            entries.append(.task(task))
            if let id { tasksById[id] = task }
        }

        if !headerSeen {
            throw MermaidSyntaxError(kind: .gantt, lineNumber: 1, sourceLine: "", reason: "Gantt header is required")
        }
        return GanttDiagram(title: title, dateFormat: dateFormat, axisFormat: axisFormat, tasks: tasks, entries: entries)
    }

    private static func parseGanttStart(
        _ value: String,
        format: String,
        tasksById: [String: GanttTask],
        lineNumber: Int,
        sourceLine: String
    ) throws -> Double {
        if !regexTest(#"^after\s+"#, in: value, options: [.caseInsensitive]) {
            return try parseGanttDate(value, format: format, lineNumber: lineNumber, sourceLine: sourceLine)
        }
        let stripped = jsTrim(regexReplace(#"^after\s+"#, in: value, with: "", options: [.caseInsensitive]))
        let deps = stripped.split(whereSeparator: \.isWhitespace).map(String.init)
        var maxEnd = -Double.infinity
        for dep in deps {
            guard let task = tasksById[dep] else {
                throw ganttSyntaxError(lineNumber, sourceLine, "Unknown Gantt task id \"\(dep)\"")
            }
            maxEnd = max(maxEnd, task.end)
        }
        return maxEnd
    }

    private static func parseGanttEnd(
        _ value: String,
        start: Double,
        format: String,
        lineNumber: Int,
        sourceLine: String
    ) throws -> Double {
        if let duration = regexFirstMatch(#"^(\d+(?:\.\d+)?)\s*(ms|s|m|h|d|w)$"#, in: value, options: [.caseInsensitive]),
           let amount = Double(duration[1] ?? ""),
           let unit = duration[2]?.lowercased()
        {
            let mult: Double
            switch unit {
            case "ms": mult = 1
            case "s": mult = 1_000
            case "m": mult = 60_000
            case "h": mult = 3_600_000
            case "d": mult = 86_400_000
            case "w": mult = 604_800_000
            default: mult = 1
            }
            return start + amount * mult
        }
        return try parseGanttDate(value, format: format, lineNumber: lineNumber, sourceLine: sourceLine)
    }

    /// Exact proleptic Gregorian UTC epoch milliseconds matching JavaScript `Date.UTC(...)`.
    private static func utcMillis(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Double {
        // Howard Hinnant days_from_civil (handles normalized year/month/day)
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = Int64(era) * 146_097 + Int64(doe) - 719_468
        let secs = days * 86_400 + Int64(hour) * 3_600 + Int64(minute) * 60 + Int64(second)
        return Double(secs * 1_000)
    }

    private static func civilFromUTCMillis(_ ms: Double) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        let totalSecs = Int64(floor(ms / 1_000.0))
        let days = totalSecs >= 0 ? totalSecs / 86_400 : -((-totalSecs + 86_399) / 86_400)
        let rem = Int(totalSecs - days * 86_400)
        let hour = rem / 3_600
        let minute = (rem % 3_600) / 60
        let second = rem % 60
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = Int(z - era * 146_097)
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + Int(era) * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp + (mp < 10 ? 3 : -9)
        let year = y + (month <= 2 ? 1 : 0)
        return (year, month, day, hour, minute, second)
    }

    private static func parseGanttDate(
        _ value: String,
        format: String,
        lineNumber: Int,
        sourceLine: String
    ) throws -> Double {
        if let numeric = Double(value), numeric.isFinite {
            if format == "s" || format == "X" { return numeric * 1_000 }
            if format == "x" { return numeric }
        }
        if ["YYYY-MM-DD", "YYYY-MM-DD HH:mm", "YYYY-MM-DD HH:mm:ss"].contains(format),
           let cal = regexFirstMatch(#"^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?)?$"#, in: value),
           let y = Int(cal[1] ?? ""),
           let m = Int(cal[2] ?? ""),
           let d = Int(cal[3] ?? "")
        {
            let hh = Int(cal[4] ?? "0") ?? 0
            let mm = Int(cal[5] ?? "0") ?? 0
            let ss = Int(cal[6] ?? "0") ?? 0
            return utcMillis(year: y, month: m, day: d, hour: hh, minute: mm, second: ss)
        }
        throw ganttSyntaxError(lineNumber, sourceLine, "Unsupported date \"\(value)\" for dateFormat \(format)")
    }

    private static func ganttTaskState(_ flags: Set<String>) -> GanttTaskState {
        if flags.contains("milestone") { return .milestone }
        if flags.contains("crit") { return .critical }
        if flags.contains("done") { return .done }
        if flags.contains("active") { return .active }
        return .task
    }

    private static func stripGanttComment(_ value: String) -> String {
        if let range = value.range(of: "%%") {
            return jsTrim(String(value[..<range.lowerBound]))
        }
        return jsTrim(value)
    }

    private static func ganttSyntaxError(_ lineNumber: Int, _ sourceLine: String, _ reason: String = "Unsupported syntax") -> MermaidSyntaxError {
        MermaidSyntaxError(kind: .gantt, lineNumber: lineNumber, sourceLine: sourceLine, reason: reason)
    }

    // MARK: - Gantt Render Grid (`gantt/render-grid.ts`)

    // parity: merman/src/gantt/render-grid.ts#GanttGrid [status=implemented hash=44c54b4657a4]
    public typealias GanttGrid = DiagramCanvas<GanttCellStyle, EmptyCanvasMetadata>

    // parity: merman/src/gantt/render-grid.ts#renderGanttGridText [status=implemented hash=0ef651111f31]
    public static func renderGanttGridText(_ grid: GanttGrid) -> String {
        grid.toString(DiagramCanvasTextOptions(trimBottom: true))
    }

    // parity: merman/src/gantt/render-grid.ts#renderGanttGridStyledText [status=implemented hash=6b8cae75c245]
    public static func renderGanttGridStyledText(_ grid: GanttGrid, colors: GanttStyleColors) -> StyledText {
        renderDiagramGridStyledText(
            grid,
            fg: { run in run.style.flatMap { colors[$0] } },
            bg: nil,
            options: DiagramCanvasRunOptions(trimBottom: true)
        )
    }

    // MARK: - Gantt Drawing (`gantt/drawing.ts`)

    // parity: merman/src/gantt/drawing.ts#drawGanttDiagramGrid [status=implemented hash=717b2e5cbdf1]
    public static func drawGanttDiagramGrid(
        _ diagram: GanttDiagram,
        options: GanttDiagramRenderOptions = GanttDiagramRenderOptions()
    ) throws -> GanttGrid {
        let labelGap = 2
        let minChartWidth = 24
        let maxChartWidth = 64

        if diagram.entries.isEmpty {
            return try GanttGrid(width: 0, height: 0)
        }
        let labelLayout = options.labels ?? .left
        let labels = diagram.entries.indices.map { ganttEntryLabel(diagram, index: $0, layout: labelLayout) }
        let labelWidth = labels.map(diagramTextWidth).max() ?? 0
        var entryRows: [Int] = []
        var bodyHeight = 0
        for (index, entry) in diagram.entries.enumerated() {
            if (options.sections ?? .spaced) == .spaced, case .section = entry, index > 0 {
                bodyHeight += 1
            }
            entryRows.append(bodyHeight)
            bodyHeight += 1
        }
        if diagram.tasks.isEmpty {
            let grid = try GanttGrid(width: labelWidth, height: bodyHeight)
            for (index, entry) in diagram.entries.enumerated() {
                if case .section(let sec) = entry {
                    grid.setText(0, entryRows[index], sec.label, style: .section)
                }
            }
            return grid
        }

        let available = (options.layoutMaxWidth ?? 120) - labelWidth - labelGap
        let chartWidth = max(minChartWidth, min(maxChartWidth, available))
        let minimum = diagram.tasks.map(\.start).min() ?? 0
        let maximum = diagram.tasks.map(\.end).max() ?? minimum
        let span = max(1.0, maximum - minimum)
        let titleHeight = diagram.title != nil ? 2 : 0
        let axisHeight = 2
        let grid = try GanttGrid(width: labelWidth + labelGap + chartWidth, height: titleHeight + axisHeight + bodyHeight)
        let chartX = labelWidth + labelGap

        if let title = diagram.title {
            grid.setText(
                max(0, chartX + floorDiv(chartWidth - diagramTextWidth(title), 2)),
                0,
                title,
                style: .title
            )
        }
        drawGanttAxis(grid, x: chartX, y: titleHeight, width: chartWidth, minimum: minimum, span: span, format: diagram.axisFormat)

        for (index, entry) in diagram.entries.enumerated() {
            let y = titleHeight + axisHeight + entryRows[index]
            switch entry {
            case .section:
                grid.setText(0, y, labels[index], style: .section)
            case .task(let task):
                let label = labels[index]
                let labelX = options.labels == .right ? labelWidth - diagramTextWidth(label) : 0
                grid.setText(labelX, y, label, style: GanttCellStyle.fromTaskState(task.state))
                drawGanttTask(grid, task: task, x: chartX, y: y, width: chartWidth, minimum: minimum, span: span, options: options)
            }
        }
        return grid
    }

    private static func drawGanttAxis(
        _ grid: GanttGrid,
        x: Int,
        y: Int,
        width: Int,
        minimum: Double,
        span: Double,
        format: String
    ) {
        for offset in 0..<width {
            grid.setCell(x + offset, y + 1, "─", style: .axis)
        }
        let step = ganttTickStep(span)
        var ticks: [Double] = []
        var value = ceil(minimum / step) * step
        while value <= minimum + span {
            ticks.append(value)
            value += step
        }
        if ticks.isEmpty {
            ticks = [minimum, minimum + span]
        }
        for tick in ticks {
            let offset = jsRound(((tick - minimum) / span) * Double(width - 1))
            let label = formatGanttTime(tick, format: format)
            let labelW = diagramTextWidth(label)
            let labelX = max(x, min(x + width - labelW, x + offset - floorDiv(labelW, 2)))
            grid.setText(labelX, y, label, style: .axis)
            grid.setCell(x + offset, y + 1, "┬", style: .axis)
        }
    }

    private static func ganttTickStep(_ span: Double) -> Double {
        let steps: [Double] = [
            1_000, 5_000, 10_000, 30_000, 60_000, 300_000, 900_000, 3_600_000,
            21_600_000, 43_200_000, 86_400_000, 172_800_000, 604_800_000,
            2_592_000_000, 31_536_000_000,
        ]
        return steps.first { $0 >= span / 4.0 } ?? steps.last!
    }

    private static func drawGanttTask(
        _ grid: GanttGrid,
        task: GanttTask,
        x: Int,
        y: Int,
        width: Int,
        minimum: Double,
        span: Double,
        options: GanttDiagramRenderOptions
    ) {
        let style = options.style ?? .track
        let line = ganttLineGlyph(options.line ?? .thin)
        let start = jsRound(((task.start - minimum) / span) * Double(width - 1))
        let end = jsRound(((task.end - minimum) / span) * Double(width - 1))
        let taskStyle = GanttCellStyle.fromTaskState(task.state)
        if task.state == .milestone || start == end {
            grid.setCell(x + start, y, "◆", style: taskStyle)
            return
        }
        if style == .track {
            let trackGlyph = (options.track ?? .line) == .line ? line : "·"
            let tStyle = ganttTrackCellStyle(options)
            for offset in 0..<width {
                grid.setCell(x + offset, y, trackGlyph, style: tStyle)
            }
        }
        let glyph = style == .block ? "█" : line
        for offset in start...end {
            grid.setCell(x + offset, y, glyph, style: taskStyle)
        }
        if style == .block { return }
        if style == .capsule || style == .track {
            if style == .track {
                if options.endpoints == .points {
                    let tStyle = ganttTrackCellStyle(options)
                    grid.setCell(x + start, y, "●", style: tStyle)
                    grid.setCell(x + end, y, "●", style: tStyle)
                }
                return
            }
            let caps = ganttCapGlyphs(options.line ?? .thin)
            grid.setCell(x + start, y, caps.start, style: taskStyle)
            grid.setCell(x + end, y, caps.end, style: taskStyle)
            return
        }
        if style == .points {
            grid.setCell(x + start, y, "●", style: taskStyle)
            grid.setCell(x + end, y, "●", style: taskStyle)
            return
        }
        grid.setCell(x + start, y, "┣", style: taskStyle)
        grid.setCell(x + end, y, "┫", style: taskStyle)
    }

    private static func ganttEntryLabel(_ diagram: GanttDiagram, index: Int, layout: GanttLabelLayout) -> String {
        let entry = diagram.entries[index]
        switch entry {
        case .section(let section):
            return section.label
        case .task(let task):
            if layout != .tree { return task.label }
            let isLast: Bool
            if index + 1 < diagram.entries.count, case .task = diagram.entries[index + 1] {
                isLast = false
            } else {
                isLast = true
            }
            return "  \(isLast ? "└" : "├")─ \(task.label)"
        }
    }

    private static func ganttLineGlyph(_ line: GanttLineStyle) -> String {
        switch line {
        case .thin: return "─"
        case .double: return "═"
        case .dashed: return "╌"
        case .heavy: return "━"
        }
    }

    private static func ganttCapGlyphs(_ line: GanttLineStyle) -> (start: String, end: String) {
        switch line {
        case .thin, .dashed: return ("╶", "╴")
        case .double: return ("╞", "╡")
        case .heavy: return ("╺", "╸")
        }
    }

    private static func ganttTrackCellStyle(_ options: GanttDiagramRenderOptions) -> GanttCellStyle {
        switch options.trackTone {
        case .medium: return .trackMedium
        case .dim: return .trackDim
        case .faint, nil: return .trackFaint
        }
    }

    private static func pad2(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    private static func formatGanttTime(_ value: Double, format: String) -> String {
        let parts = civilFromUTCMillis(value)
        return format
            .replacingOccurrences(of: "%Y", with: String(parts.year))
            .replacingOccurrences(of: "%m", with: pad2(parts.month))
            .replacingOccurrences(of: "%d", with: pad2(parts.day))
            .replacingOccurrences(of: "%H", with: pad2(parts.hour))
            .replacingOccurrences(of: "%M", with: pad2(parts.minute))
            .replacingOccurrences(of: "%S", with: pad2(parts.second))
    }

    // MARK: - Gantt Diagram (`gantt/diagram.ts`)

    // parity: merman/src/gantt/diagram.ts#renderGanttDiagram [status=implemented hash=f646f17a0c32]
    public static func renderGanttDiagram(
        _ content: String,
        options: GanttDiagramRenderOptions = GanttDiagramRenderOptions()
    ) throws -> String {
        renderGanttGridText(try drawGanttDiagramGrid(try parseMermaidGanttDiagram(content), options: options))
    }
}
