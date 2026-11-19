import Foundation
import OpenTUICore

extension Merman {
    // MARK: - Timeline Types (`timeline/types.ts`)

    // parity: merman/src/timeline/types.ts#TimelineDirection [status=implemented hash=76ecb81befb0]
    public enum TimelineDirection: String, Equatable, Hashable, Sendable, Codable {
        case TD
        case LR
    }

    // parity: merman/src/timeline/types.ts#TimelineSection [status=implemented hash=d63d2d0b0929]
    public struct TimelineSection: Equatable, Hashable, Sendable, Codable {
        public var label: String

        public init(label: String) {
            self.label = label
        }
    }

    // parity: merman/src/timeline/types.ts#TimelinePeriod [status=implemented hash=86ced33f9fb2]
    public struct TimelinePeriod: Equatable, Hashable, Sendable, Codable {
        public var period: String
        public var events: [String]

        public init(period: String, events: [String]) {
            self.period = period
            self.events = events
        }
    }

    // parity: merman/src/timeline/types.ts#TimelineEntry [status=implemented hash=a9b4285777da]
    public enum TimelineEntry: Equatable, Hashable, Sendable, Codable {
        case section(TimelineSection)
        case period(TimelinePeriod)
    }

    // parity: merman/src/timeline/types.ts#TimelineDiagram [status=implemented hash=f32042ac6c90]
    public struct TimelineDiagram: Equatable, Hashable, Sendable, Codable {
        public var direction: TimelineDirection
        public var title: String?
        public var sections: [TimelineSection]
        public var periods: [TimelinePeriod]
        public var entries: [TimelineEntry]

        public init(
            direction: TimelineDirection,
            title: String? = nil,
            sections: [TimelineSection],
            periods: [TimelinePeriod],
            entries: [TimelineEntry]
        ) {
            self.direction = direction
            self.title = title
            self.sections = sections
            self.periods = periods
            self.entries = entries
        }
    }

    // parity: merman/src/timeline/types.ts#TimelineDiagramRenderOptions [status=implemented hash=06b79f8f5def]
    public struct TimelineDiagramRenderOptions: Equatable, Hashable, Sendable {
        public var direction: TimelineDirection?

        public init(direction: TimelineDirection? = nil) {
            self.direction = direction
        }
    }

    // parity: merman/src/timeline/types.ts#TimelineBaseCellStyle [status=implemented hash=7db63fc342d3]
    public enum TimelineBaseCellStyle: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case title
        case section
        case period
        case spine
        case event
    }

    // parity: merman/src/timeline/types.ts#TimelineFadeStep [status=implemented hash=7857a992557e]
    public enum TimelineFadeStep: Int, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case s1 = 1
        case s2 = 2
        case s3 = 3
    }

    // parity: merman/src/timeline/types.ts#TimelineSectionFadeStyle [status=implemented hash=d09e3b0c1fb8]
    public enum TimelineSectionFadeStyle: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case sectionFade1
        case sectionFade2
        case sectionFade3
    }

    // parity: merman/src/timeline/types.ts#TimelinePeriodFadeStyle [status=implemented hash=47a057d65079]
    public enum TimelinePeriodFadeStyle: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case periodFade1
        case periodFade2
        case periodFade3
    }

    // parity: merman/src/timeline/types.ts#TimelineCellStyle [status=implemented hash=eb98a8b57389]
    public enum TimelineCellStyle: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case title
        case section
        case period
        case spine
        case event
        case sectionFade1
        case sectionFade2
        case sectionFade3
        case periodFade1
        case periodFade2
        case periodFade3
    }

    // MARK: - Timeline Style (`timeline/style.ts`)

    private static let timelineDefaultThemeRgb: [TimelineBaseCellStyle: DiagramRgb] = [
        .title: (228, 239, 232),
        .section: (154, 184, 169),
        .period: (230, 177, 126),
        .spine: (111, 138, 126),
        .event: (134, 225, 200),
    ]

    // parity: merman/src/timeline/style.ts#TimelineStyleColors [status=implemented hash=37ef8f021547]
    public typealias TimelineStyleColors = [TimelineCellStyle: RGBA]

    // parity: merman/src/timeline/style.ts#TIMELINE_SECTION_FADE_STYLES [status=implemented hash=2593bff1561d]
    public static let TIMELINE_SECTION_FADE_STYLES: [TimelineCellStyle] = [.sectionFade1, .sectionFade2, .sectionFade3]

    // parity: merman/src/timeline/style.ts#TIMELINE_PERIOD_FADE_STYLES [status=implemented hash=cbc1b593d70a]
    public static let TIMELINE_PERIOD_FADE_STYLES: [TimelineCellStyle] = [.periodFade1, .periodFade2, .periodFade3]

    // parity: merman/src/timeline/style.ts#resolveTimelineStyleColors [status=implemented hash=11f46ce766f5]
    public static func resolveTimelineStyleColors(
        _ colors: [TimelineBaseCellStyle: RGBA?] = [:]
    ) -> TimelineStyleColors {
        let section = (colors[.section] ?? nil) ?? rgba(timelineDefaultThemeRgb[.section]!)
        let period = (colors[.period] ?? nil) ?? rgba(timelineDefaultThemeRgb[.period]!)
        let spine = (colors[.spine] ?? nil) ?? rgba(timelineDefaultThemeRgb[.spine]!)
        return [
            .title: (colors[.title] ?? nil) ?? rgba(timelineDefaultThemeRgb[.title]!),
            .section: section,
            .period: period,
            .spine: spine,
            .event: (colors[.event] ?? nil) ?? rgba(timelineDefaultThemeRgb[.event]!),
            .sectionFade1: blendColor(section, spine, 0.5),
            .sectionFade2: blendColor(section, spine, 0.67),
            .sectionFade3: blendColor(section, spine, 0.83),
            .periodFade1: blendColor(period, spine, 0.5),
            .periodFade2: blendColor(period, spine, 0.67),
            .periodFade3: blendColor(period, spine, 0.83),
        ]
    }

    // MARK: - Timeline Parser (`timeline/parser.ts`)

    private static let timelineHeaderPattern = #"^timeline(?:\s+(TD|LR))?$"#
    private static let timelineTitlePattern = #"^title(?:\s+(.+))?$"#
    private static let timelineSectionPattern = #"^section(?:\s+(.+))?$"#
    private static let timelineAccessibilityPattern = #"^acc(?:Title|Descr)(?::|\s|$)"#

    // parity: merman/src/timeline/parser.ts#isMermaidTimelineDiagram [status=implemented hash=85bf959c4d77]
    public static func isMermaidTimelineDiagram(_ content: String) -> Bool {
        regexTest(timelineHeaderPattern, in: firstMeaningfulMermaidLine(content) ?? "", options: [.caseInsensitive])
    }

    // parity: merman/src/timeline/parser.ts#parseMermaidTimelineDiagram [status=implemented hash=1e13dbab2868]
    public static func parseMermaidTimelineDiagram(_ content: String) throws -> TimelineDiagram {
        var sections: [TimelineSection] = []
        var periods: [TimelinePeriod] = []
        var entries: [TimelineEntry] = []
        var direction: TimelineDirection = .LR
        var title: String?
        var currentPeriodIndex: Int?
        var currentEntryIndex: Int?
        var inAccessibilityDescription = false

        for source in meaningfulNumberedMermaidLines(content) {
            let line = stripTimelineComment(source.text)
            if inAccessibilityDescription {
                if line == "}" { inAccessibilityDescription = false }
                continue
            }
            if regexTest(#"^accDescr\s*\{$"#, in: line, options: [.caseInsensitive]) {
                inAccessibilityDescription = true
                continue
            }
            if line.isEmpty || line.hasPrefix("#") || regexTest(timelineAccessibilityPattern, in: line, options: [.caseInsensitive]) {
                continue
            }
            if let header = regexFirstMatch(timelineHeaderPattern, in: line, options: [.caseInsensitive]) {
                if let dirRaw = header[1]?.uppercased(), let parsedDir = TimelineDirection(rawValue: dirRaw) {
                    direction = parsedDir
                } else {
                    direction = .LR
                }
                continue
            }
            if let titleMatch = regexFirstMatch(timelineTitlePattern, in: line, options: [.caseInsensitive]) {
                guard let raw = titleMatch[1], !raw.isEmpty else {
                    throw timelineSyntaxError(source.lineNumber, line, "Timeline title cannot be empty")
                }
                title = stripMermaidQuotes(raw)
                continue
            }
            if let sectionMatch = regexFirstMatch(timelineSectionPattern, in: line, options: [.caseInsensitive]) {
                guard let raw = sectionMatch[1], !raw.isEmpty else {
                    throw timelineSyntaxError(source.lineNumber, line, "Timeline section cannot be empty")
                }
                let section = TimelineSection(label: stripMermaidQuotes(raw))
                sections.append(section)
                entries.append(.section(section))
                currentPeriodIndex = nil
                currentEntryIndex = nil
                continue
            }
            if line.hasPrefix(":") {
                guard let pIdx = currentPeriodIndex, let eIdx = currentEntryIndex else {
                    throw timelineSyntaxError(source.lineNumber, line, "Timeline continuation requires a preceding period")
                }
                let moreEvents = try parseTimelineEvents(String(line.dropFirst()), lineNumber: source.lineNumber, sourceLine: line)
                periods[pIdx].events.append(contentsOf: moreEvents)
                entries[eIdx] = .period(periods[pIdx])
                continue
            }

            var fields = splitTimelineEventFields(line)
            let periodLabel = stripMermaidQuotes(fields.removeFirst())
            if periodLabel.isEmpty {
                throw timelineSyntaxError(source.lineNumber, line, "Timeline period cannot be empty")
            }
            let events = fields.isEmpty ? [] : try parseTimelineEventFields(fields, lineNumber: source.lineNumber, sourceLine: line)
            let period = TimelinePeriod(period: periodLabel, events: events)
            currentPeriodIndex = periods.count
            periods.append(period)
            currentEntryIndex = entries.count
            entries.append(.period(period))
        }

        return TimelineDiagram(
            direction: direction,
            title: title,
            sections: sections,
            periods: periods,
            entries: entries
        )
    }

    private static func parseTimelineEvents(_ value: String, lineNumber: Int, sourceLine: String) throws -> [String] {
        try parseTimelineEventFields(splitTimelineEventFields(value), lineNumber: lineNumber, sourceLine: sourceLine)
    }

    private static func parseTimelineEventFields(_ fields: [String], lineNumber: Int, sourceLine: String) throws -> [String] {
        let events = fields.map(stripMermaidQuotes)
        if events.isEmpty || events.contains(where: \.isEmpty) {
            throw timelineSyntaxError(lineNumber, sourceLine, "Timeline event cannot be empty")
        }
        return events
    }

    private static func splitTimelineEventFields(_ value: String) -> [String] {
        var fields: [String] = []
        var quote: Character?
        let chars = Array(value)
        var start = 0
        for index in 0..<chars.count {
            let char = chars[index]
            if char == "\"" || char == "'" {
                if quote == char {
                    quote = nil
                } else if quote == nil && jsTrim(String(chars[start..<index])).isEmpty {
                    quote = char
                }
                continue
            }
            let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
            if char != ":" || quote != nil || (next != nil && !next!.isWhitespace) {
                continue
            }
            fields.append(String(chars[start..<index]))
            start = index + 1
        }
        fields.append(String(chars[start...]))
        return fields
    }

    private static func stripTimelineComment(_ value: String) -> String {
        if let range = value.range(of: "%%") {
            return jsTrim(String(value[..<range.lowerBound]))
        }
        return jsTrim(value)
    }

    private static func timelineSyntaxError(_ lineNumber: Int, _ sourceLine: String, _ reason: String = "Unsupported syntax") -> MermaidSyntaxError {
        MermaidSyntaxError(kind: .timeline, lineNumber: lineNumber, sourceLine: sourceLine, reason: reason)
    }

    // MARK: - Timeline Render Grid (`timeline/render-grid.ts`)

    // parity: merman/src/timeline/render-grid.ts#TimelineGrid [status=implemented hash=f5b02224fd63]
    public typealias TimelineGrid = DiagramCanvas<TimelineCellStyle, EmptyCanvasMetadata>

    // parity: merman/src/timeline/render-grid.ts#renderTimelineGridText [status=implemented hash=5a13cfba9c2e]
    public static func renderTimelineGridText(_ grid: TimelineGrid) -> String {
        grid.toString(DiagramCanvasTextOptions(trimBottom: true))
    }

    // parity: merman/src/timeline/render-grid.ts#renderTimelineGridStyledText [status=implemented hash=1e4417679965]
    public static func renderTimelineGridStyledText(_ grid: TimelineGrid, colors: TimelineStyleColors) -> StyledText {
        renderDiagramGridStyledText(
            grid,
            fg: { run in run.style.flatMap { colors[$0] } },
            bg: nil,
            options: DiagramCanvasRunOptions(trimBottom: true)
        )
    }

    // MARK: - Timeline Drawing (`timeline/drawing.ts`)

    private struct TimelinePeriodLayout {
        let periodLines: [String]
        let eventLines: [[String]]
        let height: Int
    }

    // parity: merman/src/timeline/drawing.ts#drawTimelineDiagramGrid [status=implemented hash=01483666dc19]
    public static func drawTimelineDiagramGrid(
        _ diagram: TimelineDiagram,
        options: TimelineDiagramRenderOptions = TimelineDiagramRenderOptions()
    ) throws -> TimelineGrid {
        _ = options
        let joinWidth = TIMELINE_SECTION_FADE_STYLES.count
        let spineOffset = joinWidth + 1
        let eventOffset = 3

        var periodLayouts: [Int: TimelinePeriodLayout] = [:]
        var leftWidth = 0
        var rightWidth = 0
        var bodyHeight = 0

        for (entryIdx, entry) in diagram.entries.enumerated() {
            switch entry {
            case .section(let section):
                let lines = splitDiagramLines(section.label)
                bodyHeight += lines.count + 1
                for line in lines { leftWidth = max(leftWidth, diagramTextWidth(line)) }
            case .period(let period):
                let periodLines = splitDiagramLines(period.period)
                let eventLines = period.events.map(splitDiagramLines)
                let eventHeight = eventLines.reduce(0) { $0 + $1.count }
                let height = max(periodLines.count, eventHeight)
                periodLayouts[entryIdx] = TimelinePeriodLayout(periodLines: periodLines, eventLines: eventLines, height: height)
                for line in periodLines { leftWidth = max(leftWidth, diagramTextWidth(line)) }
                for lines in eventLines {
                    for line in lines { rightWidth = max(rightWidth, diagramTextWidth(line)) }
                }
                bodyHeight += height + 1
            }
        }

        let titleLines = diagram.title.map(splitDiagramLines) ?? []
        let bodyWidth = diagram.entries.isEmpty ? 0 : leftWidth + spineOffset + eventOffset + rightWidth + 1
        let titleWidth = titleLines.map(diagramTextWidth).max() ?? 0
        let width = max(bodyWidth, titleWidth)
        let titleHeight = titleLines.isEmpty ? 0 : titleLines.count + (diagram.entries.isEmpty ? 0 : 1)
        if width == 0 {
            return try TimelineGrid(width: 0, height: 0)
        }

        let grid = try TimelineGrid(width: width, height: titleHeight + bodyHeight)
        for (index, line) in titleLines.enumerated() {
            grid.setText(floorDiv(width - diagramTextWidth(line), 2), index, line, style: .title)
        }
        if diagram.entries.isEmpty { return grid }

        let spineX = leftWidth + spineOffset
        var y = titleHeight
        var railStarted = false
        for (entryIdx, entry) in diagram.entries.enumerated() {
            switch entry {
            case .section(let section):
                let lines = splitDiagramLines(section.label)
                for (index, line) in lines.enumerated() {
                    grid.setText(leftWidth - diagramTextWidth(line), y + index, line, style: .section)
                    if index > 0 {
                        grid.setCell(spineX, y + index, "│", style: .spine)
                    }
                }
                for (idx, style) in TIMELINE_SECTION_FADE_STYLES.enumerated() {
                    grid.setCell(leftWidth + idx + 1, y, "─", style: style)
                }
                grid.setCell(spineX, y, railStarted ? "┤" : "┐", style: .spine)
                grid.setCell(spineX, y + lines.count, "│", style: .spine)
                railStarted = true
                y += lines.count + 1

            case .period:
                guard let layout = periodLayouts[entryIdx] else { continue }
                for row in 0..<(layout.height + 1) {
                    grid.setCell(spineX, y + row, "│", style: .spine)
                }
                railStarted = true
                grid.setCell(spineX, y, "●", style: .spine)
                for (index, line) in layout.periodLines.enumerated() {
                    let lineWidth = diagramTextWidth(line)
                    grid.setText(leftWidth - lineWidth, y + index, line, style: .period)
                }
                for (idx, style) in TIMELINE_PERIOD_FADE_STYLES.enumerated() {
                    grid.setCell(leftWidth + idx + 1, y, "─", style: style)
                }
                var eventY = y
                for lines in layout.eventLines {
                    for (index, line) in lines.enumerated() {
                        grid.setText(spineX + eventOffset, eventY + index, line, style: .event)
                    }
                    eventY += lines.count
                }
                y += layout.height + 1
            }
        }
        return grid
    }

    // MARK: - Timeline Diagram (`timeline/diagram.ts`)

    // parity: merman/src/timeline/diagram.ts#renderTimelineDiagram [status=implemented hash=2b39b4e6a028]
    public static func renderTimelineDiagram(
        _ content: String,
        options: TimelineDiagramRenderOptions = TimelineDiagramRenderOptions()
    ) throws -> String {
        renderTimelineGridText(try drawTimelineDiagramGrid(try parseMermaidTimelineDiagram(content), options: options))
    }
}
