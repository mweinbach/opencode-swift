import Foundation

extension Merman {
    // MARK: - Diagram Assertion Helper (`test/diagram.ts`)

    public struct DiagramAssertionError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    public struct DiagramExpectation: Sendable {
        public let value: String

        public init(value: String) {
            self.value = value
        }

        private static func normalizeDiagram(_ value: String) -> String {
            var lines = value.replacingOccurrences(of: "\r\n", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            while let first = lines.first, jsTrim(first).isEmpty { lines.removeFirst() }
            while let last = lines.last, jsTrim(last).isEmpty { lines.removeLast() }
            let nonEmpty = lines.filter { !jsTrim($0).isEmpty }
            let indentation = nonEmpty.map { line -> Int in
                line.prefix(while: \.isWhitespace).count
            }.min() ?? 0
            return lines.map { line in
                line.count >= indentation ? String(line.dropFirst(indentation)) : ""
            }.joined(separator: "\n")
        }

        public func toEqualDiagram(_ expected: String) throws {
            let normalized = Self.normalizeDiagram(expected)
            if value != normalized {
                throw DiagramAssertionError("Diagram mismatch.\nExpected:\n\(normalized)\nActual:\n\(value)")
            }
        }

        public func toContainInOrder(_ needles: String...) throws {
            try toContainInOrder(needles)
        }

        public func toContainInOrder(_ needles: [String]) throws {
            var searchStart = value.startIndex
            for needle in needles {
                guard let range = value.range(of: needle, range: searchStart..<value.endIndex) else {
                    throw DiagramAssertionError("Expected diagram output to contain \"\(needle)\" in order")
                }
                searchStart = range.lowerBound < value.endIndex ? value.index(after: range.lowerBound) : value.endIndex
            }
        }
    }

    // parity: merman/src/test/diagram.ts#expectDiagram [status=implemented hash=5eedf33f2141]
    public static func expectDiagram(_ value: String) -> DiagramExpectation {
        DiagramExpectation(value: value)
    }

    // MARK: - Layout Audit Fixtures (`test/layout-audit/fixtures.ts`)

    public enum LayoutLabelProfile: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case short
        case long
        case unicode
    }

    public enum LayoutFixtureKind: String, Equatable, Hashable, Sendable, Codable {
        case flowchart
        case state
    }

    // parity: merman/src/test/layout-audit/fixtures.ts#LayoutFixture [status=implemented hash=4550907b7ea3]
    public struct LayoutFixture: Equatable, Hashable, Sendable, Codable {
        public var id: String
        public var kind: LayoutFixtureKind
        public var family: String
        public var profile: LayoutLabelProfile
        public var source: String
        public var curated: Bool?

        public init(
            id: String,
            kind: LayoutFixtureKind,
            family: String,
            profile: LayoutLabelProfile,
            source: String,
            curated: Bool? = nil
        ) {
            self.id = id
            self.kind = kind
            self.family = family
            self.profile = profile
            self.source = source
            self.curated = curated
        }
    }

    // parity: merman/src/test/layout-audit/fixtures.ts#deploymentArchitectureSource [status=implemented hash=3dc103d7bae5]
    public static let deploymentArchitectureSource: String = """
    flowchart LR
        Client[OpenCode client]

        subgraph CF[Cloudflare]
          DNS[opencode.ai]
          Web[Console frontend Worker]
          Proxy[Console API proxy Worker]
          Infer[inference-next Worker]
          KV[Model registry KV]
          Redis[Upstash Redis]
          Logs[Axiom / Cloudflare logs]
          Lake[Pipeline to R2 data lake]
        end

        subgraph AWS[AWS]
          EKS[EKS cluster]
          API[Console API pod<br/>1 replica]
          OTEL[OTel collector]
          ECR[ECR]
        end

        DB[(PlanetScale)]
        Models[Anthropic / OpenAI / other providers]

        Client -->|/inference/*| DNS --> Infer
        Client -->|/console/*| DNS --> Web
        Web -->|/console/api, /auth, etc.| Proxy
        Proxy -->|Cloudflare VPC service| API

        Infer -->|public DATABASE_URL| DB
        Infer --> KV
        Infer --> Redis
        Infer --> Models
        Infer --> Logs
        Infer --> Lake

        API -->|private DATABASE_AWS_URL| DB
        API --> OTEL
        ECR --> API
    """

    private static let auditFlowVariants: [(FlowchartDirection, LayoutLabelProfile)] = [
        (.TB, .short), (.TD, .long), (.BT, .unicode), (.LR, .short), (.RL, .long),
        (.TB, .unicode), (.TD, .short), (.BT, .long), (.LR, .unicode), (.RL, .short),
        (.LR, .long), (.TD, .unicode), (.TB, .long), (.BT, .short), (.RL, .unicode),
    ]

    private static let auditStateVariants: [(StateDiagramDirection, LayoutLabelProfile)] = [
        (.TB, .short), (.TD, .long), (.LR, .unicode), (.RL, .short), (.TB, .long),
        (.TD, .unicode), (.LR, .short), (.RL, .long), (.LR, .long), (.TD, .short),
        (.TB, .unicode), (.RL, .unicode), (.BT, .short), (.BT, .long), (.BT, .unicode),
    ]

    private static func auditNodeLabel(_ id: String, _ profile: LayoutLabelProfile) -> String {
        switch profile {
        case .long: return "\(id) deliberate deployment stage with a long descriptive label"
        case .unicode: return "\(id) 東京<br/>résumé 🚀"
        case .short: return "\(id) node"
        }
    }

    private static func auditEdgeLabel(_ id: String, _ profile: LayoutLabelProfile) -> String {
        switch profile {
        case .long: return "\(id) transition carrying detailed deployment context"
        case .unicode: return "\(id) 東京<br/>✓ prêt"
        case .short: return "\(id) edge"
        }
    }

    private static func auditFlowNode(_ id: String, _ profile: LayoutLabelProfile) -> String {
        "  \(id)[\"\(auditNodeLabel(id, profile))\"]"
    }

    private static func auditFlowEdge(_ from: String, _ to: String, _ id: String, _ profile: LayoutLabelProfile) -> String {
        "  \(from) -->|\"\(auditEdgeLabel(id, profile))\"| \(to)"
    }

    private static func auditFlowSource(
        _ direction: FlowchartDirection,
        _ profile: LayoutLabelProfile,
        nodes: [String],
        edges: [(String, String, String)]
    ) -> String {
        (["flowchart \(direction.rawValue)"]
            + nodes.map { auditFlowNode($0, profile) }
            + edges.map { auditFlowEdge($0.0, $0.1, $0.2, profile) }).joined(separator: "\n")
    }

    private static func auditStateDecl(_ id: String, _ profile: LayoutLabelProfile, indent: String = "  ") -> String {
        "\(indent)state \"\(auditNodeLabel(id, profile))\" as \(id)"
    }

    private static func auditStateTrans(_ from: String, _ to: String, _ id: String, _ profile: LayoutLabelProfile, indent: String = "  ") -> String {
        "\(indent)\(from) --> \(to): \(auditEdgeLabel(id, profile))"
    }

    private static func auditStateSource(
        _ direction: StateDiagramDirection,
        _ profile: LayoutLabelProfile,
        states: [String],
        transitions: [(String, String, String)],
        extra: [String] = []
    ) -> String {
        (["stateDiagram-v2", "  direction \(direction.rawValue)"]
            + states.map { auditStateDecl($0, profile) }
            + extra
            + transitions.map { auditStateTrans($0.0, $0.1, $0.2, profile) }).joined(separator: "\n")
    }

    // parity: merman/src/test/layout-audit/fixtures.ts#layoutFixtures [status=implemented hash=133f7e0fabce]
    public static func layoutFixtures() -> [LayoutFixture] {
        let flowFamilies: [(String, (FlowchartDirection, LayoutLabelProfile) -> String)] = [
            ("chain", { d, p in auditFlowSource(d, p, nodes: ["A", "B", "C", "D", "E", "F"], edges: [("A", "B", "E01"), ("B", "C", "E02"), ("C", "D", "E03"), ("D", "E", "E04"), ("E", "F", "E05")]) }),
            ("fork", { d, p in auditFlowSource(d, p, nodes: ["A", "B", "C", "D", "E"], edges: [("A", "B", "E01"), ("A", "C", "E02"), ("A", "D", "E03"), ("A", "E", "E04")]) }),
            ("join", { d, p in auditFlowSource(d, p, nodes: ["A", "B", "C", "D", "E"], edges: [("A", "E", "E01"), ("B", "E", "E02"), ("C", "E", "E03"), ("D", "E", "E04")]) }),
            ("cycle", { d, p in auditFlowSource(d, p, nodes: ["A", "B", "C", "D"], edges: [("A", "B", "E01"), ("B", "C", "E02"), ("C", "D", "E03"), ("D", "A", "E04"), ("C", "A", "E05")]) }),
            ("crossing", { d, p in auditFlowSource(d, p, nodes: ["A", "B", "C", "D", "E", "F"], edges: [("A", "C", "E01"), ("A", "D", "E02"), ("B", "C", "E03"), ("B", "D", "E04"), ("C", "E", "E05"), ("D", "F", "E06")]) }),
            ("decision-loops", { d, p in auditFlowSource(d, p, nodes: ["A", "B", "C", "D", "E", "F", "G", "H", "I"], edges: [("A", "B", "E01"), ("A", "C", "E02"), ("B", "D", "E03"), ("D", "E", "E04"), ("E", "B", "E05"), ("C", "F", "E06"), ("F", "G", "E07"), ("G", "C", "E08"), ("E", "H", "E09"), ("G", "H", "E10"), ("H", "A", "E11"), ("D", "I", "E12"), ("F", "I", "E13")]) }),
            ("parallel", { d, p in auditFlowSource(d, p, nodes: ["A", "B", "C"], edges: [("A", "B", "E01"), ("A", "B", "E02"), ("A", "B", "E03"), ("B", "C", "E04"), ("B", "C", "E05")]) }),
            ("self", { d, p in auditFlowSource(d, p, nodes: ["A", "B", "C"], edges: [("A", "A", "E01"), ("A", "B", "E02"), ("B", "B", "E03"), ("B", "C", "E04")]) }),
            ("subgraph", { d, p in
                [
                    "flowchart \(d.rawValue)",
                    "  subgraph Left[\"Left \(auditNodeLabel("SG1", p))\"]",
                    auditFlowNode("A", p), auditFlowNode("B", p),
                    "  end",
                    "  subgraph Right[\"Right \(auditNodeLabel("SG2", p))\"]",
                    auditFlowNode("C", p), auditFlowNode("D", p),
                    "  end",
                    auditFlowEdge("A", "B", "E01", p), auditFlowEdge("A", "C", "E02", p),
                    auditFlowEdge("B", "D", "E03", p), auditFlowEdge("C", "D", "E04", p),
                ].joined(separator: "\n")
            }),
            ("nested-subgraph", { d, p in
                let local = (d == .LR || d == .RL) ? "TB" : "LR"
                return [
                    "flowchart \(d.rawValue)",
                    "  subgraph Outer[\"Outer \(auditNodeLabel("SG1", p))\"]",
                    "    direction \(local)",
                    "    subgraph Inner[\"Inner \(auditNodeLabel("SG2", p))\"]",
                    auditFlowNode("A", p), auditFlowNode("B", p),
                    "    end",
                    auditFlowNode("C", p),
                    "  end",
                    auditFlowNode("D", p),
                    auditFlowEdge("A", "B", "E01", p), auditFlowEdge("A", "C", "E02", p),
                    auditFlowEdge("B", "D", "E03", p), auditFlowEdge("C", "D", "E04", p),
                ].joined(separator: "\n")
            }),
        ]

        let stateFamilies: [(String, (StateDiagramDirection, LayoutLabelProfile) -> String)] = [
            ("chain", { d, p in auditStateSource(d, p, states: ["A", "B", "C", "D", "E"], transitions: [("A", "B", "E01"), ("B", "C", "E02"), ("C", "D", "E03"), ("D", "E", "E04")], extra: ["  [*] --> A", "  E --> [*]"]) }),
            ("fork", { d, p in auditStateSource(d, p, states: ["A", "B", "C", "D"], transitions: [("A", "B", "E01"), ("A", "C", "E02"), ("A", "D", "E03")]) }),
            ("join", { d, p in auditStateSource(d, p, states: ["A", "B", "C", "D"], transitions: [("A", "D", "E01"), ("B", "D", "E02"), ("C", "D", "E03")]) }),
            ("cycle", { d, p in auditStateSource(d, p, states: ["A", "B", "C", "D"], transitions: [("A", "B", "E01"), ("B", "C", "E02"), ("C", "D", "E03"), ("D", "A", "E04"), ("C", "A", "E05")]) }),
            ("crossing", { d, p in auditStateSource(d, p, states: ["A", "B", "C", "D"], transitions: [("A", "C", "E01"), ("A", "D", "E02"), ("B", "C", "E03"), ("B", "D", "E04")]) }),
            ("parallel", { d, p in auditStateSource(d, p, states: ["A", "B", "C"], transitions: [("A", "B", "E01"), ("A", "B", "E02"), ("A", "B", "E03"), ("B", "C", "E04")]) }),
            ("self", { d, p in auditStateSource(d, p, states: ["A", "B", "C"], transitions: [("A", "A", "E01"), ("A", "B", "E02"), ("B", "B", "E03"), ("B", "C", "E04")]) }),
            ("choice", { d, p in auditStateSource(d, p, states: ["A", "B", "C"], transitions: [("A", "Choice", "E01"), ("Choice", "B", "E02"), ("Choice", "C", "E03"), ("C", "A", "E04")], extra: ["  state Choice <<choice>>"]) }),
            ("notes", { d, p in auditStateSource(d, p, states: ["A", "B", "C"], transitions: [("A", "B", "E01"), ("B", "C", "E02"), ("C", "A", "E03")], extra: ["  note left of A: \(auditEdgeLabel("N01", p))", "  note right of B: \(auditEdgeLabel("N02", p))", "  note right of C: \(auditEdgeLabel("N03", p))"]) }),
            ("composite", { d, p in
                [
                    "stateDiagram-v2",
                    "  direction \(d.rawValue)",
                    "  state \"\(auditNodeLabel("Outer", p))\" as Outer {",
                    auditStateDecl("A", p, indent: "    "),
                    auditStateDecl("B", p, indent: "    "),
                    "    [*] --> A",
                    auditStateTrans("A", "B", "E01", p, indent: "    "),
                    "    B --> [*]",
                    "  }",
                    auditStateDecl("Done", p),
                    auditStateTrans("Outer", "Done", "E02", p),
                    "  note right of B: \(auditEdgeLabel("N01", p))",
                ].joined(separator: "\n")
            }),
            ("nested-composite", { d, p in
                [
                    "stateDiagram-v2",
                    "  direction \(d.rawValue)",
                    "  state \"\(auditNodeLabel("Session", p))\" as Session {",
                    "    [*] --> Open",
                    "    state \"\(auditNodeLabel("Open", p))\" as Open {",
                    auditStateDecl("Clean", p, indent: "      "),
                    auditStateDecl("Dirty", p, indent: "      "),
                    "      [*] --> Clean",
                    auditStateTrans("Clean", "Dirty", "E01", p, indent: "      "),
                    auditStateTrans("Dirty", "Clean", "E02", p, indent: "      "),
                    "      Dirty --> [*]",
                    "    }",
                    "    Open --> [*]",
                    "  }",
                    auditStateDecl("Done", p),
                    auditStateTrans("Session", "Done", "E03", p),
                    "  note right of Dirty: \(auditEdgeLabel("N01", p))",
                ].joined(separator: "\n")
            }),
        ]

        var fixtures: [LayoutFixture] = []
        for (family, builder) in flowFamilies {
            for (dir, profile) in auditFlowVariants {
                fixtures.append(LayoutFixture(
                    id: "flowchart/\(family)/\(dir.rawValue.lowercased())-\(profile.rawValue)",
                    kind: .flowchart,
                    family: family,
                    profile: profile,
                    source: builder(dir, profile)
                ))
            }
        }
        fixtures.append(LayoutFixture(
            id: "flowchart/deployment-architecture/curated",
            kind: .flowchart,
            family: "deployment-architecture",
            profile: .short,
            source: deploymentArchitectureSource,
            curated: true
        ))
        fixtures.append(LayoutFixture(
            id: "flowchart/grouped-fanout/curated",
            kind: .flowchart,
            family: "grouped-fanout",
            profile: .short,
            source: """
            flowchart TD
              subgraph Group
                S[Source]
                S -->|route 0 detail| N0[Node 0]
                S -->|route 1 detail| N1[Node 1]
                S -->|route 2 detail| N2[Node 2]
                S -->|route 3 detail| N3[Node 3]
              end
            """,
            curated: true
        ))
        fixtures.append(LayoutFixture(
            id: "flowchart/subgraph-pipeline/curated",
            kind: .flowchart,
            family: "subgraph-pipeline",
            profile: .short,
            source: """
            flowchart TD
              subgraph S1["1. provider.transform (seed)"]
                A1["Catalog model → copy catalog variants"]
                A2["Custom model → apply package/modelID/limit + seed default variants"]
              end
              subgraph S2["2. plugin model.transform"]
                B["Plugin can replace variants, clear to [], or ignore"]
              end
              subgraph S3["3. config model.transform (post)"]
                C1{"Config sets reasoning or variants?"}
                C1 -- yes --> C2["Apply explicit config"]
                C1 -- no --> C3{"Config changed package (or recreated removed model)?"}
                C3 -- yes --> C4["Respell / reseed variants"]
                C3 -- no --> C5["Keep current variants"]
              end
              S1 --> S2 --> S3
            """,
            curated: true
        ))
        for (family, builder) in stateFamilies {
            for (dir, profile) in auditStateVariants {
                fixtures.append(LayoutFixture(
                    id: "state/\(family)/\(dir.rawValue.lowercased())-\(profile.rawValue)",
                    kind: .state,
                    family: family,
                    profile: profile,
                    source: builder(dir, profile)
                ))
            }
        }
        return fixtures
    }

    // MARK: - Layout Audit Harness (`test/layout-audit/harness.ts`)

    // parity: merman/src/test/layout-audit/harness.ts#auditViewports [status=implemented hash=8506186c8ebb]
    public static let auditViewports: [Int] = [60, 80, 120]

    // parity: merman/src/test/layout-audit/harness.ts#LayoutMetrics [status=implemented hash=0875ca6e0ef2]
    public struct LayoutMetrics: Equatable, Hashable, Sendable, Codable {
        public var width: Int
        public var height: Int
        public var area: Int
        public var routeLength: Int
        public var bends: Int
        public var crossings: Int
        public var sharedRouteCells: Int
        public var overflow: Int

        public init(width: Int, height: Int, area: Int, routeLength: Int, bends: Int, crossings: Int, sharedRouteCells: Int, overflow: Int) {
            self.width = width
            self.height = height
            self.area = area
            self.routeLength = routeLength
            self.bends = bends
            self.crossings = crossings
            self.sharedRouteCells = sharedRouteCells
            self.overflow = overflow
        }

        public func value(for metric: LayoutMetricKey) -> Int {
            switch metric {
            case .width: return width
            case .height: return height
            case .area: return area
            case .routeLength: return routeLength
            case .bends: return bends
            case .crossings: return crossings
            case .sharedRouteCells: return sharedRouteCells
            case .overflow: return overflow
            }
        }
    }

    public enum LayoutMetricKey: String, CaseIterable, Equatable, Hashable, Sendable {
        case width
        case height
        case area
        case routeLength
        case bends
        case crossings
        case sharedRouteCells
        case overflow
    }

    // parity: merman/src/test/layout-audit/harness.ts#LayoutAudit [status=implemented hash=dc57e0e96d68]
    public struct LayoutAudit: Equatable, Hashable, Sendable, Codable {
        public var fixture: LayoutFixture
        public var viewport: Int
        public var output: String
        public var metrics: LayoutMetrics
        public var violations: [String]

        public init(fixture: LayoutFixture, viewport: Int, output: String, metrics: LayoutMetrics, violations: [String]) {
            self.fixture = fixture
            self.viewport = viewport
            self.output = output
            self.metrics = metrics
            self.violations = violations
        }
    }

    public struct LayoutAuditSectionSummary: Equatable, Hashable, Sendable {
        public let runs: Int
        public let sources: Int
        public let violations: Int
        public let areaP50: Int
        public let areaP95: Int
        public let areaMax: Int
        public let bendsP95: Int
        public let bendsMax: Int
        public let crossingsTotal: Int
        public let crossingsMax: Int
        public let routeLengthP95: Int
        public let routeLengthMax: Int
        public let sharedRouteCellsP95: Int
        public let sharedRouteCellsMax: Int
        public let overflowP95: Int
        public let overflowMax: Int
    }

    public struct LayoutAuditSummary: Equatable, Hashable, Sendable {
        public let total: LayoutAuditSectionSummary
        public let flowchart: LayoutAuditSectionSummary
        public let state: LayoutAuditSectionSummary
    }

    private struct AuditedRoute {
        let from: String
        let to: String
        let points: [DiagramPoint]
    }

    private static func auditBoundsOverlap(_ l: DiagramBounds, _ r: DiagramBounds) -> Bool {
        l.left < r.left + r.width && l.left + l.width > r.left && l.top < r.top + r.height && l.top + l.height > r.top
    }

    private static func auditBoundsContain(_ outer: DiagramBounds, _ inner: DiagramBounds) -> Bool {
        inner.left >= outer.left && inner.top >= outer.top
            && inner.left + inner.width <= outer.left + outer.width
            && inner.top + inner.height <= outer.top + outer.height
    }

    private static func auditPointInBounds(_ pt: DiagramPoint, _ b: DiagramBounds) -> Bool {
        pt.x >= b.left && pt.x < b.left + b.width && pt.y >= b.top && pt.y < b.top + b.height
    }

    private static func auditPointTouchesBounds(_ pt: DiagramPoint, _ b: DiagramBounds) -> Bool {
        if auditPointInBounds(pt, b) { return true }
        return ((pt.x == b.left - 1 || pt.x == b.left + b.width) && pt.y >= b.top && pt.y < b.top + b.height)
            || ((pt.y == b.top - 1 || pt.y == b.top + b.height) && pt.x >= b.left && pt.x < b.left + b.width)
    }

    private static func auditIsOrthogonal(_ pts: [DiagramPoint]) -> Bool {
        for i in 1..<pts.count {
            if pts[i - 1].x != pts[i].x && pts[i - 1].y != pts[i].y { return false }
        }
        return true
    }

    private static func auditRouteSegments(_ pts: [DiagramPoint]) -> [DiagramSegment] {
        guard pts.count >= 2 else { return [] }
        return (1..<pts.count).compactMap { segmentBetween(pts[$0 - 1], pts[$0]) }
    }

    private static func auditRouteBends(_ pts: [DiagramPoint]) -> Int {
        var dirs: [DiagramAxis] = []
        for i in 1..<pts.count {
            if pts[i].x == pts[i - 1].x && pts[i].y != pts[i - 1].y { dirs.append(.y) }
            else if pts[i].y == pts[i - 1].y && pts[i].x != pts[i - 1].x { dirs.append(.x) }
        }
        guard dirs.count >= 2 else { return 0 }
        return (1..<dirs.count).filter { dirs[$0] != dirs[$0 - 1] }.count
    }

    private static func auditCrossingCount(_ routes: [AuditedRoute]) -> Int {
        var count = 0
        for i in 0..<routes.count {
            let segsA = auditRouteSegments(routes[i].points)
            for j in (i + 1)..<routes.count {
                let segsB = auditRouteSegments(routes[j].points)
                for seg in segsA {
                    for other in segsB {
                        if seg.axis == other.axis { continue }
                        let horiz = seg.axis == .x ? seg : other
                        let vert = seg.axis == .y ? seg : other
                        let x = vert.from.x
                        let y = horiz.from.y
                        let hMin = min(horiz.from.x, horiz.to.x)
                        let hMax = max(horiz.from.x, horiz.to.x)
                        let vMin = min(vert.from.y, vert.to.y)
                        let vMax = max(vert.from.y, vert.to.y)
                        if x > hMin && x < hMax && y > vMin && y < vMax { count += 1 }
                    }
                }
            }
        }
        return count
    }

    private static func auditSharedRouteCellCount(_ routes: [AuditedRoute]) -> Int {
        var count = 0
        let cellSets = routes.map { r -> Set<DiagramPoint> in
            auditIsOrthogonal(r.points) ? Set(orthogonalPathPoints(r.points)) : []
        }
        for i in 0..<cellSets.count {
            for j in (i + 1)..<cellSets.count {
                for cell in cellSets[i] where cellSets[j].contains(cell) { count += 1 }
            }
        }
        return count
    }

    private static func auditMetrics(width: Int, height: Int, routes: [AuditedRoute], viewport: Int) -> LayoutMetrics {
        let totalLen = routes.reduce(0) { sum, r in sum + auditRouteSegments(r.points).reduce(0) { $0 + $1.length } }
        let totalBends = routes.reduce(0) { $0 + auditRouteBends($1.points) }
        return LayoutMetrics(
            width: width,
            height: height,
            area: width * height,
            routeLength: totalLen,
            bends: totalBends,
            crossings: auditCrossingCount(routes),
            sharedRouteCells: auditSharedRouteCellCount(routes),
            overflow: max(0, width - viewport)
        )
    }

    private static func auditRequireOutputLines(_ output: String, lines: [String], owner: String, violations: inout [String]) {
        for line in lines.map(jsTrim).filter({ !$0.isEmpty }) {
            if !output.contains(line) {
                violations.append("\(owner) content missing: \"\(line)\"")
            }
        }
    }

    private static func auditValidateBodies(_ bounds: [String: DiagramBounds], ids: [String], violations: inout [String]) throws {
        var occupied = SpatialIndex.empty()
        for id in ids {
            guard let bound = bounds[id] else {
                violations.append("missing body bound \(id)")
                continue
            }
            if bound.width <= 0 || bound.height <= 0 {
                violations.append("body \(id) has invalid bounds")
                continue
            }
            let claim = try spatialRectClaim(id: "body:\(id)", owner: "body:\(id)", role: .body, bounds: bound)
            let conflicts = try occupied.conflicts(claim)
            for otherId in Set(conflicts.map { String($0.existing.owner.dropFirst("body:".count)) }).sorted() {
                violations.append("bodies \(id) and \(otherId) overlap")
            }
            occupied = try occupied.add(claim)
        }
    }

    private static func auditValidateRoutes(_ routes: [AuditedRoute], bounds: [String: DiagramBounds], bodyIds: [String], violations: inout [String]) throws {
        for (index, route) in routes.enumerated() {
            if route.points.count < 2 {
                violations.append("route \(index) \(route.from)->\(route.to) is empty")
                continue
            }
            let ortho = auditIsOrthogonal(route.points)
            if !ortho {
                violations.append("route \(index) \(route.from)->\(route.to) is not finite and orthogonal")
            }
            guard let from = bounds[route.from], let to = bounds[route.to] else {
                violations.append("route \(index) \(route.from)->\(route.to) has a missing endpoint bound")
                continue
            }
            if !auditPointTouchesBounds(route.points[0], from) {
                violations.append("route \(index) does not touch source \(route.from)")
            }
            if !auditPointTouchesBounds(route.points[route.points.count - 1], to) {
                violations.append("route \(index) does not touch target \(route.to)")
            }
            if !ortho { continue }
            var claims: [SpatialClaim] = []
            for id in bodyIds where id != route.from && id != route.to {
                if let b = bounds[id] {
                    claims.append(try spatialRectClaim(id: "body:\(id)", owner: "body:\(id)", role: .body, bounds: b))
                }
            }
            let bodySpace = try SpatialIndex.empty().add(claims: claims)
            let conflicts = try bodySpace.conflicts(try spatialPathClaim(id: "route:\(index)", owner: "route:\(index)", role: .route, points: route.points))
            for id in Set(conflicts.map { String($0.existing.owner.dropFirst("body:".count)) }).sorted() {
                violations.append("route \(index) \(route.from)->\(route.to) intersects unrelated body \(id)")
            }
        }
    }

    private static func auditFlowchartFixture(_ fixture: LayoutFixture, viewport: Int) throws -> LayoutAudit {
        var violations: [String] = []
        let diagram = try parseMermaidFlowchartDiagram(fixture.source)
        let opts = FlowchartDiagramRenderOptions(compact: true, layoutMaxWidth: viewport)
        let layout = layoutFlowchartDiagram(diagram, options: opts)
        let grid = try drawFlowchartDiagramGrid(diagram, options: opts)
        let trimOpts = DiagramCanvasTextOptions(trimTop: true, trimBottom: true)
        let output = grid.toString(trimOpts)
        let size = grid.getTextSize(trimOpts)
        let routes = layout.routes.map { AuditedRoute(from: $0.edge.from, to: $0.edge.to, points: $0.points) }
        let bodyIds = layout.diagram.nodes.map(\.id)
        var endpointBounds: [String: DiagramBounds] = [:]
        for (k, v) in layout.subgraphBounds { endpointBounds[k] = v.diagramBounds }
        for (k, v) in layout.bounds { endpointBounds[k] = v.diagramBounds }
        let bodyBounds = Dictionary(uniqueKeysWithValues: layout.bounds.map { ($0.key, $0.value.diagramBounds) })

        if size.width <= 0 || size.height <= 0 { violations.append("rendered grid has invalid dimensions") }
        if layout.width <= 0 || layout.height <= 0 { violations.append("layout has invalid dimensions") }
        if layout.routes.count != layout.diagram.edges.filter({ $0.orderOnly != true }).count {
            violations.append("rendered route count does not match visible edge count")
        }
        try auditValidateBodies(bodyBounds, ids: bodyIds, violations: &violations)
        try auditValidateRoutes(routes, bounds: endpointBounds, bodyIds: bodyIds, violations: &violations)

        for node in layout.diagram.nodes {
            auditRequireOutputLines(output, lines: layout.bounds[node.id]?.lines ?? [], owner: "node \(node.id)", violations: &violations)
        }
        for route in layout.routes where !route.edge.label.isEmpty {
            let lbl = flowchartRouteLabelLayout(route, measure: diagramTextWidth)
            auditRequireOutputLines(output, lines: lbl.lines, owner: "edge \(route.edge.from)->\(route.edge.to)", violations: &violations)
            let targets = Set(layout.diagram.edges.filter { !$0.label.isEmpty && $0.from == route.edge.from }.map(\.to))
            let sources = Set(layout.diagram.edges.filter { !$0.label.isEmpty && $0.to == route.edge.to }.map(\.from))
            if fixture.family == "grouped-fanout" && (targets.count > 1 || sources.count > 1) && lbl.point.x + lbl.width > viewport {
                violations.append("grouped edge \(route.edge.from)->\(route.edge.to) label exceeds viewport")
            }
        }
        let subgraphs = layout.diagram.subgraphs ?? []
        let subById = Dictionary(uniqueKeysWithValues: subgraphs.map { ($0.id, $0) })
        func ancestorOf(_ ancestor: String, _ id: String) -> Bool {
            var pid = subById[id]?.parentId
            while let cur = pid {
                if cur == ancestor { return true }
                pid = subById[cur]?.parentId
            }
            return false
        }
        for sub in subgraphs {
            let bound = layout.subgraphBounds[sub.id]
            if bound == nil || bound!.width <= 0 || bound!.height <= 0 {
                violations.append("subgraph \(sub.id) has invalid bounds")
            }
            auditRequireOutputLines(output, lines: splitDiagramLines(sub.label), owner: "subgraph \(sub.id)", violations: &violations)
            if let b = bound {
                for nid in sub.nodeIds {
                    if let nb = layout.bounds[nid], !auditBoundsContain(b.diagramBounds, nb.diagramBounds) {
                        violations.append("subgraph \(sub.id) does not contain \(nid)")
                    }
                }
            }
        }
        for i in 0..<subgraphs.count {
            guard let b = layout.subgraphBounds[subgraphs[i].id] else { continue }
            for j in (i + 1)..<subgraphs.count {
                if ancestorOf(subgraphs[i].id, subgraphs[j].id) || ancestorOf(subgraphs[j].id, subgraphs[i].id) { continue }
                if let ob = layout.subgraphBounds[subgraphs[j].id], auditBoundsOverlap(b.diagramBounds, ob.diagramBounds) {
                    violations.append("subgraphs \(subgraphs[i].id) and \(subgraphs[j].id) overlap")
                }
            }
        }
        return LayoutAudit(fixture: fixture, viewport: viewport, output: output, metrics: auditMetrics(width: size.width, height: size.height, routes: routes, viewport: viewport), violations: violations)
    }

    private static func auditStateFixture(_ fixture: LayoutFixture, viewport: Int) throws -> LayoutAudit {
        var violations: [String] = []
        let parsed = try parseMermaidStateDiagram(fixture.source)
        let drawing = try createStateDiagramDrawing(parsed, options: StateDiagramRenderOptions(minStateGap: 5, layoutMaxWidth: viewport))
        let diagram = drawing.diagram
        let layout = drawing.layout
        let plans = drawing.transitionPlans
        let trimOpts = DiagramCanvasTextOptions(trimTop: true, trimBottom: true)
        let output = drawing.grid.toString(trimOpts)
        let size = drawing.grid.getTextSize(trimOpts)
        let routes = plans.map { AuditedRoute(from: $0.route.transition.from, to: $0.route.transition.to, points: $0.path) }
        let bodyIds = diagram.states.filter { !isHiddenCompositeMarker($0) }.map(\.id)
        let boxBounds = Dictionary(uniqueKeysWithValues: layout.bounds.map { ($0.key, $0.value.diagramBounds) })

        if size.width <= 0 || size.height <= 0 { violations.append("rendered grid has invalid dimensions") }
        if plans.count != diagram.transitions.count { violations.append("rendered route count does not match visible transition count") }
        try auditValidateBodies(boxBounds, ids: bodyIds, violations: &violations)
        try auditValidateRoutes(routes, bounds: boxBounds, bodyIds: bodyIds, violations: &violations)
        if diagram.direction == .BT && fixture.family == "chain" {
            for t in diagram.transitions where t.from != t.to {
                if let from = layout.bounds[t.from], let to = layout.bounds[t.to], from.centerY <= to.centerY {
                    violations.append("BT transition \(t.from)->\(t.to) does not travel upward")
                }
            }
        }
        for state in diagram.states where !isHiddenCompositeMarker(state) {
            auditRequireOutputLines(output, lines: layout.sizes[state.id]?.lines ?? [state.label], owner: "state \(state.id)", violations: &violations)
        }
        for plan in plans where !plan.route.transition.label.isEmpty {
            if plan.label == nil {
                violations.append("transition \(plan.route.transition.from)->\(plan.route.transition.to) has no label layout")
            }
            auditRequireOutputLines(output, lines: plan.label?.lines ?? [], owner: "transition \(plan.route.transition.from)->\(plan.route.transition.to)", violations: &violations)
        }
        let statesById = Dictionary(uniqueKeysWithValues: diagram.states.map { ($0.id, $0) })
        let compsById = Dictionary(uniqueKeysWithValues: diagram.composites.map { ($0.id, $0) })
        func descendantOf(_ id: String, _ compId: String) -> Bool {
            var pid = statesById[id]?.parentId ?? compsById[id]?.parentId
            while let cur = pid {
                if cur == compId { return true }
                pid = compsById[cur]?.parentId
            }
            return false
        }
        for comp in diagram.composites {
            guard let bound = layout.compositeBounds[comp.id], bound.width > 0, bound.height > 0 else {
                violations.append("composite \(comp.id) has invalid bounds")
                continue
            }
            auditRequireOutputLines(output, lines: splitDiagramLines(comp.label), owner: "composite \(comp.id)", violations: &violations)
            for state in diagram.states where !isHiddenCompositeMarker(state) && descendantOf(state.id, comp.id) {
                if let sb = layout.bounds[state.id], !auditBoundsContain(bound.diagramBounds, sb.diagramBounds) {
                    violations.append("composite \(comp.id) does not contain \(state.id)")
                }
            }
        }
        for (index, note) in layout.noteBounds.enumerated() {
            if note.width <= 0 || note.height <= 0 { violations.append("note \(index) has invalid bounds") }
            auditRequireOutputLines(output, lines: note.lines, owner: "note \(index)", violations: &violations)
            for id in bodyIds {
                if let b = layout.bounds[id], auditBoundsOverlap(note.diagramBounds, b.diagramBounds) {
                    violations.append("note \(index) overlaps state \(id)")
                }
            }
            for other in layout.noteBounds[(index + 1)...] {
                if auditBoundsOverlap(note.diagramBounds, other.diagramBounds) {
                    violations.append("notes \(index) and \(other.id) overlap")
                }
            }
            guard let target = layout.bounds[note.note.target] else {
                violations.append("note \(index) has no target bound")
                continue
            }
            let connPts = stateDiagramNoteConnector(note, target: target).points
            for pt in (auditIsOrthogonal(connPts) ? orthogonalPathPoints(connPts) : []) {
                for id in bodyIds where id != note.note.target {
                    if let b = layout.bounds[id], auditPointInBounds(pt, b.diagramBounds) {
                        violations.append("note \(index) connector intersects state \(id)")
                    }
                }
                for (oIdx, other) in layout.noteBounds.enumerated() where oIdx != index {
                    if auditPointInBounds(pt, other.diagramBounds) {
                        violations.append("note \(index) connector intersects note \(other.id)")
                    }
                }
            }
        }
        return LayoutAudit(fixture: fixture, viewport: viewport, output: output, metrics: auditMetrics(width: size.width, height: size.height, routes: routes, viewport: viewport), violations: violations)
    }

    // parity: merman/src/test/layout-audit/harness.ts#auditFixture [status=implemented hash=4686458cd11e]
    public static func auditFixture(_ fixture: LayoutFixture, viewport: Int = 120) throws -> LayoutAudit {
        fixture.kind == .flowchart
            ? try auditFlowchartFixture(fixture, viewport: viewport)
            : try auditStateFixture(fixture, viewport: viewport)
    }

    // parity: merman/src/test/layout-audit/harness.ts#auditAllFixtures [status=implemented hash=8808465ffcd5]
    public static func auditAllFixtures() throws -> [LayoutAudit] {
        var results: [LayoutAudit] = []
        for (index, fixture) in layoutFixtures().enumerated() {
            if fixture.curated == true {
                for viewport in auditViewports {
                    results.append(try auditFixture(fixture, viewport: viewport))
                }
            } else if fixture.kind == .flowchart {
                results.append(try auditFixture(fixture, viewport: auditViewports[index % auditViewports.count]))
            } else {
                let viewport = fixture.profile == .short ? 60 : (fixture.profile == .unicode ? 80 : 120)
                results.append(try auditFixture(fixture, viewport: viewport))
            }
        }
        return results
    }

    private static func auditPercentile(_ values: [Int], ratio: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * ratio)) - 1))
        return sorted[idx]
    }

    // parity: merman/src/test/layout-audit/harness.ts#summarizeAudits [status=implemented hash=49b00fd98db9]
    public static func summarizeAudits(_ audits: [LayoutAudit]) -> LayoutAuditSummary {
        func summarize(_ selected: [LayoutAudit]) -> LayoutAuditSectionSummary {
            LayoutAuditSectionSummary(
                runs: selected.count,
                sources: Set(selected.map(\.fixture.id)).count,
                violations: selected.reduce(0) { $0 + $1.violations.count },
                areaP50: auditPercentile(selected.map(\.metrics.area), ratio: 0.5),
                areaP95: auditPercentile(selected.map(\.metrics.area), ratio: 0.95),
                areaMax: selected.map(\.metrics.area).max() ?? 0,
                bendsP95: auditPercentile(selected.map(\.metrics.bends), ratio: 0.95),
                bendsMax: selected.map(\.metrics.bends).max() ?? 0,
                crossingsTotal: selected.reduce(0) { $0 + $1.metrics.crossings },
                crossingsMax: selected.map(\.metrics.crossings).max() ?? 0,
                routeLengthP95: auditPercentile(selected.map(\.metrics.routeLength), ratio: 0.95),
                routeLengthMax: selected.map(\.metrics.routeLength).max() ?? 0,
                sharedRouteCellsP95: auditPercentile(selected.map(\.metrics.sharedRouteCells), ratio: 0.95),
                sharedRouteCellsMax: selected.map(\.metrics.sharedRouteCells).max() ?? 0,
                overflowP95: auditPercentile(selected.map(\.metrics.overflow), ratio: 0.95),
                overflowMax: selected.map(\.metrics.overflow).max() ?? 0
            )
        }
        return LayoutAuditSummary(
            total: summarize(audits),
            flowchart: summarize(audits.filter { $0.fixture.kind == .flowchart }),
            state: summarize(audits.filter { $0.fixture.kind == .state })
        )
    }

    // parity: merman/src/test/layout-audit/harness.ts#worstAudits [status=implemented hash=91e34d52c5a9]
    public static func worstAudits(_ audits: [LayoutAudit], metric: LayoutMetricKey, limit: Int = 10) -> [LayoutAudit] {
        Array(
            audits.sorted { lhs, rhs in
                let lv = lhs.metrics.value(for: metric)
                let rv = rhs.metrics.value(for: metric)
                if lv != rv { return lv > rv }
                return lhs.fixture.id < rhs.fixture.id
            }.prefix(limit)
        )
    }
}
