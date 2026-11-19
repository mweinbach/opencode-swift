import OpenCodeCore
import OpenCodeSchema
import OpenCodeTUI
import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables
import Synchronization
import Testing

@Suite("Merman Built-In TUI Mermaid Renderer Plugin Parity")
struct MermanPluginParityTests {

    // MARK: - 1. Detection & Core Primitives

    @Test("detectMermaidDiagram identifies all 6 diagram kinds past leading comments")
    func diagramDetection() {
        #expect(Merman.detectMermaidDiagram("%% comment\nflowchart LR\n  A --> B") == .flowchart)
        #expect(Merman.detectMermaidDiagram("graph TD\n  A --> B") == .flowchart)
        #expect(Merman.detectMermaidDiagram("sequenceDiagram\n  A->>B: hi") == .sequence)
        #expect(Merman.detectMermaidDiagram("stateDiagram-v2\n  [*] --> Idle") == .state)
        #expect(Merman.detectMermaidDiagram("stateDiagram\n  Idle --> Active") == .state)
        #expect(Merman.detectMermaidDiagram("timeline\n  2024 : Launch") == .timeline)
        #expect(Merman.detectMermaidDiagram("gitGraph\n  commit") == .gitGraph)
        #expect(Merman.detectMermaidDiagram("gantt\n  title Plan") == .gantt)
        #expect(Merman.detectMermaidDiagram("%% only comments\n") == nil)
        #expect(Merman.detectMermaidDiagram("pie\n  \"A\" : 50") == nil)
    }

    @Test("Core canvas, text lines, HTML entity decoding, drawing, and spatial index")
    func corePrimitives() throws {
        // HTML entity decoding & rich italic runs
        #expect(Merman.decodeMermaidText("A &amp; B &rarr; &quot;ok&quot;") == "A & B → \"ok\"")
        #expect(Merman.stripMermaidQuotes("\"hello &lt;world&gt;\"") == "hello <world>")

        let parsedLines = Merman.parseDiagramTextLines("Hello <i>world</i><br/><em>again</em>")
        #expect(parsedLines.count == 2)
        #expect(parsedLines[0].text == "Hello world")
        #expect(parsedLines[0].runs == [
            Merman.DiagramTextRun(text: "Hello ", italic: false),
            Merman.DiagramTextRun(text: "world", italic: true),
        ])
        #expect(parsedLines[1].text == "again")
        #expect(parsedLines[1].runs == [Merman.DiagramTextRun(text: "again", italic: true)])

        // Canvas text sizing, wide CJK chars, and 250k cell limit guard
        let canvas = try Merman.DiagramCanvas<String, Merman.EmptyCanvasMetadata>(width: 20, height: 4)
        canvas.setText(1, 1, "東京 ok", style: "node")
        #expect(canvas.getTextSize(Merman.DiagramCanvasTextOptions(trimTop: true, trimBottom: true)) == Merman.DiagramCanvasTextSize(width: 8, height: 1))
        #expect(canvas.toString(Merman.DiagramCanvasTextOptions(trimTop: true, trimBottom: true)) == " 東京 ok")

        #expect(throws: Merman.DiagramCanvasSizeError.self) {
            _ = try Merman.DiagramCanvas<String, Merman.EmptyCanvasMetadata>(width: 1000, height: 1000)
        }
        #expect(throws: Merman.DiagramCanvasSizeError.self) {
            _ = try Merman.DiagramCanvas<String, Merman.EmptyCanvasMetadata>(width: -1, height: 5)
        }

        // Line glyph merging and arrow heads
        #expect(Merman.mergeDiagramLineGlyph("─", "│") == "┼")
        #expect(Merman.mergeDiagramLineGlyph("─", "│", cornerStyle: .rounded) == "┼")
        #expect(Merman.mergeDiagramLineGlyph("━", "┃") == "╋")
        #expect(Merman.diagramArrowHead(.right, style: .filled) == "▶")
        #expect(Merman.diagramArrowHead(.down, style: .line) == "↓")

        // SpatialIndex collision detection with contacts and clearance
        let box = try Merman.spatialRectClaim(id: "b1", owner: "node1", role: .body, left: 4, top: 4, width: 4, height: 3)
        let idx = try Merman.SpatialIndex.empty().add(box)
        let collidingRoute = try Merman.spatialPathClaim(id: "r1", owner: "edge1", role: .route, points: [Merman.point(2, 5), Merman.point(10, 5)])
        #expect(try !idx.isFree(collidingRoute))
        let touchingRoute = try Merman.spatialPathClaim(id: "r2", owner: "edge2", role: .route, points: [Merman.point(2, 5), Merman.point(4, 5)])
        #expect(try idx.isFree(
            touchingRoute,
            policy: Merman.SpatialCollisionPolicy(contacts: [Merman.SpatialContact(owner: "node1", points: [Merman.point(4, 5)])])
        ))
        let clearRoute = try Merman.spatialPathClaim(id: "r3", owner: "edge3", role: .route, points: [Merman.point(0, 0), Merman.point(3, 0)])
        #expect(try idx.isFree(clearRoute))
    }

    // MARK: - 2. Flowcharts

    @Test("Flowchart renders all node shapes, edge styles, subgraphs, and responsive folding")
    func flowchartRenderingAndGeometry() throws {
        let source = """
        flowchart LR
          A[Start] --> B(Process)
          B ==>|fast| C{Check?}
          C -.->|yes| D[(Database)]
          C -->|no| E[[Subroutine]]
        """
        let diagram = try Merman.parseMermaidFlowchartDiagram(source)
        #expect(diagram.direction == .LR)
        #expect(diagram.nodes.count == 5)
        #expect(diagram.nodes.map(\.shape) == [.box, .rounded, .decision, .database, .subroutine])
        #expect(diagram.edges.count == 4)
        #expect(diagram.edges[1].style == .thick)
        #expect(diagram.edges[2].style == .dashed)

        let rendered = try Merman.renderFlowchartDiagram(source, options: Merman.FlowchartDiagramRenderOptions(compact: true))
        let expectedFlowchart =
            "                                                                ╭──────────╮\n" +
            "                                                                ├──────────┤\n" +
            "                                                     ╭── yes ──▶│ Database │\n" +
            "                                                     │          ├──────────┤\n" +
            "                                       ╭───────╮     │          ╰──────────╯\n" +
            "╭───────╮    ╭─────────╮             ╭─╯       ╰─╮   │\n" +
            "│ Start ├───▶│ Process ├━━━ fast ━━━▶│  Check?   ├───┤\n" +
            "╰───────╯    ╰─────────╯             ╰─╮       ╭─╯   │\n" +
            "                                       ╰───────╯     │\n" +
            "                                                     │\n" +
            "                                                     │        ╭─┬──────────┬─╮\n" +
            "                                                     ╰─ no ──▶│ │Subroutine│ │\n" +
            "                                                              ╰─┴──────────┴─╯"
        try Merman.expectDiagram(rendered).toEqualDiagram(expectedFlowchart)

        // Subgraphs, nested subgraphs, and responsive folding when layoutMaxWidth is tight
        let folded = try Merman.renderFlowchartDiagram(
            Merman.deploymentArchitectureSource,
            options: Merman.FlowchartDiagramRenderOptions(compact: true, layoutMaxWidth: 80)
        )
        #expect(folded.contains("Cloudflare"))
        #expect(folded.contains("AWS"))
        #expect(folded.contains("PlanetScale"))

        // StyledText output preserves italic attributes from <i> tags
        let italicGrid = try Merman.drawFlowchartDiagramGrid(
            try Merman.parseMermaidFlowchartDiagram("flowchart LR\n  A[\"<i>Italic</i>\"] --> B[End]")
        )
        let styled = Merman.renderGridStyledText(italicGrid, colors: Merman.resolveFlowchartStyleColors())
        #expect(styled.plainText.contains("Italic"))
        #expect(styled.chunks.contains { $0.text.contains("Italic") && (($0.attributes ?? 0) & TextAttributes.italic) != 0 })

        // Chained `&` node groups and syntax errors
        let chained = try Merman.parseMermaidFlowchartDiagram("flowchart TD\n  A & B --> C & D")
        #expect(chained.edges.count == 4)

        #expect(throws: Merman.MermaidSyntaxError.self) {
            _ = try Merman.parseMermaidFlowchartDiagram("flowchart TD\n  subgraph G\n    A --> B")
        }
    }

    // MARK: - 3. Sequence Diagrams

    @Test("Sequence diagram renders participants, groups, autonumber, fragments, activations, notes, and self-messages")
    func sequenceDiagramRendering() throws {
        let source = """
        sequenceDiagram
          autonumber
          box Blue Frontend
            participant U as User
            participant W as Web App
          end
          participant API as Backend API
          U->>+W: Submit form
          W->>+API: POST /items
          alt Valid
            API-->>W: 201 Created
          else Invalid
            API--xW: 400 Bad Request
          end
          deactivate API
          W->>W: Update cache
          Note right of W: Cached locally
          W-->>-U: Done
        """
        let diagram = try Merman.parseMermaidSequenceDiagram(source)
        #expect(diagram.participants.count == 3)
        #expect(diagram.groups.count == 1)
        #expect(diagram.groups[0].label == "Frontend")
        #expect(diagram.groups[0].participantIds == ["U", "W"])
        #expect(diagram.messages.count == 6)
        #expect(diagram.messages[0].number == 1)
        #expect(diagram.messages[0].activate == "W")
        #expect(diagram.messages[3].head == .cross)
        #expect(diagram.messages[5].deactivate == "W")

        let output = try Merman.renderSequenceDiagram(source)
        try Merman.expectDiagram(output).toContainInOrder(
            "Frontend",
            "User",
            "Web App",
            "Backend API",
            "1. Submit form",
            "2. POST /items",
            "alt: Valid",
            "3. 201 Created",
            "else: Invalid",
            "4. 400 Bad Request",
            "5. Update cache",
            "Cached locally",
            "6. Done"
        )
        let expectedSequence =
            "╭─ Frontend ─────────────────────────────────╮\n" +
            "│ User               Web App                 │  Backend API\n" +
            "│ ──┬─               ───┬───                 │  ─────┬─────\n" +
            "│   │                   │                    │       │\n" +
            "│   │ 1. Submit form    │                    │       │\n" +
            "│   ├───────────────────►                    │       │\n" +
            "│   │                   ┃                    │       │\n" +
            "│   │                   ┃ 2. POST /items     │       │\n" +
            "│   │                   ├────────────────────────────►\n" +
            "│   │                   ┃                    │       ┃\n" +
            "│╭─ alt: Valid ─────────────────────────────────────────╮\n" +
            "││  │                   ┃                    │       ┃  │\n" +
            "││  │                   ┃ 3. 201 Created     │       ┃  │\n" +
            "││  │                   ◄────────────────────────────┤  │\n" +
            "││  │                   ┃                    │       ┃  │\n" +
            "│├─ else: Invalid ──────────────────────────────────────┤\n" +
            "││  │                   ┃                    │       ┃  │\n" +
            "││  │                   ┃ 4. 400 Bad Request │       ┃  │\n" +
            "││  │                   ┃✕───────────────────────────┤  │\n" +
            "││  │                   ┃                    │       │  │\n" +
            "│╰──────────────────────────────────────────────────────╯\n" +
            "│   │                   ┃                    │       │\n" +
            "│   │                   ├──────────────────╮ │       │\n" +
            "│   │                   ┃ 5. Update cache  │ │       │\n" +
            "│   │                   ◄──────────────────╯ │       │\n" +
            "│   │                   ┃                    │       │\n" +
            "│   │                   ┃                    │       │\n" +
            "│   │                   ┃   Cached locally   │       │\n" +
            "│   │                   ┃                    │       │\n" +
            "│   │ 6. Done           ┃                    │       │\n" +
            "│   ◄───────────────────┤                    │       │\n" +
            "│   │                   │                    │       │\n" +
            "╰────────────────────────────────────────────╯"
        try Merman.expectDiagram(output).toEqualDiagram(expectedSequence)

        // Compact mode & StyledText
        let compactGrid = try Merman.drawSequenceDiagramGrid(diagram, options: Merman.SequenceDiagramRenderOptions(compact: true))
        let compactStyled = Merman.renderSequenceGridStyledText(compactGrid, colors: Merman.resolveSequenceStyleColors())
        #expect(!compactStyled.chunks.isEmpty)
        #expect(compactStyled.plainText.contains("Submit form"))

        // Error handling
        #expect(throws: Merman.MermaidSyntaxError.self) {
            _ = try Merman.parseMermaidSequenceDiagram("sequenceDiagram\n  else stray")
        }
        #expect(throws: Merman.MermaidSyntaxError.self) {
            _ = try Merman.parseMermaidSequenceDiagram("sequenceDiagram\n  alt open\n  A->>B: hi")
        }
    }

    // MARK: - 4. State Diagrams

    @Test("State diagram renders markers, choices, composites, notes, feedback loops, and responsive folding")
    func stateDiagramRendering() throws {
        let source = """
        stateDiagram-v2
          direction LR
          [*] --> Idle
          state "Working" as Active {
            [*] --> Running
            Running --> Paused: pause
            Paused --> Running: resume
            Running --> [*]
          }
          state Check <<choice>>
          Idle --> Check: start
          Check --> Active: ok
          Check --> Idle: retry
          Active --> [*]: finish
          note right of Active: Managed lifecycle
        """
        let diagram = try Merman.parseMermaidStateDiagram(source)
        #expect(diagram.direction == .LR)
        #expect(diagram.composites.count == 1)
        #expect(diagram.notes.count == 1)
        #expect(diagram.states.contains { $0.kind == .choice && $0.id == "Check" })

        let rendered = try Merman.renderStateDiagram(source, options: Merman.StateDiagramRenderOptions(layoutMaxWidth: 100))
        let expectedState =
            "                                         ╭─ Working ────────────────╮\n" +
            "                                         │                          │\n" +
            "              ╭──────╮   start           ok      ╭─────────╮   finish\n" +
            "●────────────▶│ Idle ├────────────▶◆────────────▶│ Running ├────────────▶◎\n" +
            "              ╰──────╯             │     │       ╰──┬──────╯        │\n" +
            "               ▲                   │     │          │   ▲         ╔═══════════════════╗\n" +
            "               │                   │     │pause     │   │     ════╣ Managed lifecycle ║\n" +
            "               │                   │     │          ▼   │         ╚═══════════════════╝\n" +
            "               │                   │     │       ╭──────┴─╮   resume│\n" +
            "               │                   │     │       │ Paused │         │\n" +
            "               │                   │     │       ╰────────╯         │\n" +
            "               │                   │     │                          │\n" +
            "               │                   │     ╰──────────────────────────╯\n" +
            "               │                   │\n" +
            "               │                   │\n" +
            "               │      retry        │\n" +
            "               ╰───────────────────╯"
        try Merman.expectDiagram(rendered).toEqualDiagram(expectedState)

        let grid = try Merman.drawStateDiagramGrid(diagram)
        let styled = Merman.renderStateGridStyledText(grid, colors: Merman.resolveStateStyleColors())
        let trimmedStyled = styled.plainText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var end = line.endIndex
                while end > line.startIndex && line[line.index(before: end)] == " " {
                    end = line.index(before: end)
                }
                return String(line[..<end])
            }
            .joined(separator: "\n")
        #expect(trimmedStyled == Merman.renderStateGridText(grid))

        #expect(throws: Merman.MermaidSyntaxError.self) {
            _ = try Merman.parseMermaidStateDiagram("stateDiagram-v2\n  state A {\n    X --> Y")
        }
    }

    // MARK: - 5. Timeline, GitGraph, and Gantt Diagrams

    @Test("Timeline diagram parses sections, continuations, and renders vertical spine")
    func timelineDiagramRendering() throws {
        let source = """
        timeline
          title Release Roadmap
          section Q1
            Jan : Alpha : Design review
                : Internal demo
          section Q2
            Apr : Public beta
        """
        let diagram = try Merman.parseMermaidTimelineDiagram(source)
        #expect(diagram.title == "Release Roadmap")
        #expect(diagram.sections.count == 2)
        #expect(diagram.periods.count == 2)
        #expect(diagram.periods[0].events == ["Alpha", "Design review", "Internal demo"])

        let rendered = try Merman.renderTimelineDiagram(source)
        let expectedTimeline =
            "    Release Roadmap\n" +
            "\n" +
            " Q1 ───┐\n" +
            "       │\n" +
            "Jan ───●  Alpha\n" +
            "       │  Design review\n" +
            "       │  Internal demo\n" +
            "       │\n" +
            " Q2 ───┤\n" +
            "       │\n" +
            "Apr ───●  Public beta\n" +
            "       │"
        #expect(rendered == expectedTimeline)

        #expect(throws: Merman.MermaidSyntaxError.self) {
            _ = try Merman.parseMermaidTimelineDiagram("timeline\n  : orphan event")
        }
    }

    @Test("GitGraph diagram parses branches, order, commits, tags, merges, and renders lanes")
    func gitGraphDiagramRendering() throws {
        let source = """
        gitGraph
          commit id: "init" tag: "v0.1"
          branch feature order: 2
          commit id: "feat-1" type: HIGHLIGHT
          checkout main
          commit id: "fix-1" type: REVERSE
          merge feature id: "merge-1" tag: "v1.0"
        """
        let diagram = try Merman.parseMermaidGitGraphDiagram(source)
        #expect(diagram.branches.map(\.name) == ["main", "feature"])
        #expect(diagram.commits.count == 4)
        #expect(diagram.commits[1].type == .HIGHLIGHT)
        #expect(diagram.commits[2].type == .REVERSE)
        #expect(diagram.commits[3].parents == ["fix-1", "feat-1"])

        let rendered = try Merman.renderGitGraphDiagram(source)
        try Merman.expectDiagram(rendered).toEqualDiagram(
            """
            ●    init  [v0.1]
            ├─╮
            │ ◆  feat-1  [feature]
            ⊗ │  fix-1
            ◎─╯  merge-1  [main] [v1.0]
            """
        )

        #expect(throws: Merman.MermaidSyntaxError.self) {
            _ = try Merman.parseMermaidGitGraphDiagram("gitGraph\n  cherry-pick id: \"abc\"")
        }
    }

    @Test("Gantt diagram parses dates, durations, after-dependencies, and renders all chart styles")
    func ganttDiagramRendering() throws {
        let source = """
        gantt
          title Launch Plan
          dateFormat YYYY-MM-DD
          axisFormat %m-%d
          section Build
            Design :done, des1, 2026-01-01, 4d
            Implement :active, imp1, after des1, 6d
          section Ship
            Audit :crit, aud1, after imp1, 3d
            Release :milestone, after aud1, 0d
        """
        let diagram = try Merman.parseMermaidGanttDiagram(source)
        #expect(diagram.title == "Launch Plan")
        #expect(diagram.tasks.count == 4)
        #expect(diagram.tasks.map(\.state) == [.done, .active, .critical, .milestone])
        #expect(diagram.tasks[1].start == diagram.tasks[0].end)

        let trackOutput = try Merman.renderGanttDiagram(source, options: Merman.GanttDiagramRenderOptions(style: .track, labels: .tree))
        let expectedGantt =
            "                                          Launch Plan\n" +
            "\n" +
            "                01-01                           01-08\n" +
            "                ┬─────────────────────────────────┬─────────────────────────────\n" +
            "Build\n" +
            "  ├─ Design     ────────────────────────────────────────────────────────────────\n" +
            "  └─ Implement  ────────────────────────────────────────────────────────────────\n" +
            "\n" +
            "Ship\n" +
            "  ├─ Audit      ────────────────────────────────────────────────────────────────\n" +
            "  └─ Release                                                                   ◆"
        #expect(trackOutput == expectedGantt)

        let blockOutput = try Merman.renderGanttDiagram(source, options: Merman.GanttDiagramRenderOptions(style: .block))
        #expect(blockOutput.contains("█"))
        let railOutput = try Merman.renderGanttDiagram(source, options: Merman.GanttDiagramRenderOptions(style: .rail))
        #expect(railOutput.contains("┣") && railOutput.contains("┫"))
        let capsuleOutput = try Merman.renderGanttDiagram(source, options: Merman.GanttDiagramRenderOptions(style: .capsule))
        #expect(capsuleOutput.contains("╶") && capsuleOutput.contains("╴"))
    }

    // MARK: - 6. Palette Resolution

    @Test("createOpenCodeDiagramPalette and resolveOpenCodeDiagramPalette match upstream neutral ladder and mode selection")
    func paletteParity() throws {
        struct Case {
            let text: Merman.DiagramRgb
            let subdued: Merman.DiagramRgb
            let secondary: Merman.DiagramRgb
            let muted: Merman.DiagramRgb
        }
        let cases: [Case] = [
            Case(text: (230, 232, 240), subdued: (114, 120, 138), secondary: (172, 176, 189), muted: (149, 154, 169)),
            Case(text: (32, 35, 43), subdued: (119, 125, 138), secondary: (76, 80, 91), muted: (93, 98, 110)),
        ]
        for c in cases {
            let primary = Merman.rgba(c.text)
            let subdued = Merman.rgba(c.subdued)
            let info = RGBA.fromInts(40, 120, 220)
            let success = RGBA.fromInts(80, 180, 120)
            let warning = RGBA.fromInts(220, 160, 80)
            let background = RGBA.fromInts(10, 20, 30)
            let accent = Merman.OpenCodeDiagramPaletteAccent(
                soft: RGBA.fromInts(180, 100, 40),
                clear: RGBA.fromInts(240, 160, 80)
            )
            let palette = Merman.createOpenCodeDiagramPalette(Merman.OpenCodeDiagramPaletteInput(
                text: primary,
                subdued: subdued,
                info: info,
                success: success,
                warning: warning,
                background: background,
                accent: accent
            ))
            #expect(palette.text == primary)
            #expect(palette.primary == primary)
            #expect(palette.secondary.equals(Merman.rgba(c.secondary)))
            #expect(palette.muted.equals(Merman.rgba(c.muted)))
            #expect(palette.warning == info)
            #expect(palette.background == background)
            #expect(palette.request == success)
            #expect(palette.response == warning)
            #expect(palette.note == primary)
            #expect(palette.noteBackground.equals(Merman.blendColor(background, subdued, 0.25)))
            #expect(palette.boxText == primary)
            #expect(palette.boxBorder.equals(Merman.rgba(c.muted)))
            #expect(palette.line.equals(subdued))
            #expect(palette.labelBackground.toInts().3 == 20)
            #expect(palette.group == accent.soft)
            #expect(palette.groupText == accent.soft)
            #expect(palette.marker.equals(Merman.rgba(c.secondary)))
            #expect(palette.noteBorder == accent.soft)
            #expect(palette.noteText == accent.clear)
            #expect(palette.noteConnector == accent.soft)
        }

        // Theme resolution for dark and light modes using real OpenCode default theme
        let darkTheme = try resolveThemeDocument(ThemeDefaults.opencode, mode: .dark)
        let darkPalette = Merman.resolveOpenCodeDiagramPalette(theme: darkTheme, mode: .dark)
        let darkAccent = darkTheme.categorical.count > 3 ? darkTheme.categorical[3] : darkTheme.categorical[0]
        #expect(darkPalette.group == darkAccent[.s300])
        #expect(darkPalette.noteText == darkAccent[.s200])

        let lightTheme = try resolveThemeDocument(ThemeDefaults.opencode, mode: .light)
        let lightPalette = Merman.resolveOpenCodeDiagramPalette(theme: lightTheme, mode: .light)
        let lightAccent = lightTheme.categorical.count > 3 ? lightTheme.categorical[3] : lightTheme.categorical[0]
        #expect(lightPalette.group == lightAccent[.s700])
        #expect(lightPalette.noteText == lightAccent[.s800])
    }

    // MARK: - 7. Markdown Integration & Plugin Descriptor

    @Test("Markdown code-block renderer renders fenced Mermaid blocks and recovers gracefully while streaming")
    func markdownRendererAndStreamingRecovery() throws {
        let tr = createTestRenderer(width: 100, height: 30)
        let darkTheme = try resolveThemeDocument(ThemeDefaults.opencode, mode: .dark)
        let palette = Merman.resolveOpenCodeDiagramPalette(theme: darkTheme, mode: .dark)
        let opts = Merman.MermaidMarkdownRendererOptions(colors: palette.asColorOverrides())

        let codeBlockRenderer = Merman.createMermaidCodeBlockRenderer(ctx: tr.renderer, options: opts)
        let style = SyntaxStyle.create()
        let defaultStub = TextRenderable(ctx: tr.renderer, options: TextOptions(id: "fence-1", content: .string("fallback")))
        let nodeContext = MarkdownRenderNodeContext(
            syntaxStyle: style,
            conceal: false,
            concealCode: false,
            defaultRender: { defaultStub }
        )

        // Complete valid flowchart block
        let validBlock = MarkdownCodeBlock(
            index: 0,
            lang: "mermaid",
            info: "mermaid",
            closed: true,
            raw: "```mermaid\nflowchart LR\n  A[Start] --> B[End]\n```",
            text: "flowchart LR\n  A[Start] --> B[End]"
        )
        let rendered = codeBlockRenderer(validBlock, nodeContext)
        let textRenderable = try #require(rendered as? TextRenderable)
        #expect(textRenderable.plainText.contains("Start"))
        #expect(textRenderable.plainText.contains("End"))

        // Streaming incomplete trailing line keeps last-good diagram rendered
        let streamingBlock = MarkdownCodeBlock(
            index: 0,
            lang: "mermaid",
            info: "mermaid",
            closed: false,
            raw: "```mermaid\nflowchart LR\n  A[Start] --> B[End]\n  B --",
            text: "flowchart LR\n  A[Start] --> B[End]\n  B --"
        )
        let recovered = codeBlockRenderer(streamingBlock, nodeContext)
        let recoveredText = try #require(recovered as? TextRenderable)
        #expect(recoveredText.plainText.contains("Start"))
        #expect(recoveredText.plainText.contains("End"))

        // Fresh key with trailing incomplete line strips trailing partial line
        let freshStub = TextRenderable(ctx: tr.renderer, options: TextOptions(id: "fence-2", content: .string("fallback")))
        let freshContext = MarkdownRenderNodeContext(
            syntaxStyle: style,
            conceal: false,
            concealCode: false,
            defaultRender: { freshStub }
        )
        let partialRendered = codeBlockRenderer(streamingBlock, freshContext)
        let partialText = try #require(partialRendered as? TextRenderable)
        #expect(partialText.plainText.contains("Start"))

        // Full MarkdownRenderable integration via createMermaidMarkdownRenderer
        let mdNodeRenderer = Merman.createMermaidMarkdownRenderer(ctx: tr.renderer, options: opts)
        let markdown = MarkdownRenderable(
            ctx: tr.renderer,
            options: MarkdownOptions(
                content: "# Title\n\n```mermaid\nflowchart LR\n  X[Input] --> Y[Output]\n```\n\n```swift\nlet a = 1\n```\n",
                syntaxStyle: style,
                renderNode: mdNodeRenderer
            )
        )
        tr.renderer.root.add(markdown)
        tr.renderOnce()
        let frame = tr.captureCharFrame()
        #expect(frame.contains("Input"))
        #expect(frame.contains("Output"))
    }

    @Test("Merman.plugin defines opencode.merman and registers mermaid renderer on PluginTui & TUIPluginHost")
    func pluginRegistration() async throws {
        #expect(Merman.plugin.id == "opencode.merman")

        // Verify direct registration on PluginTui.DescriptorRegistry
        let descriptorRegistry = PluginTui.DescriptorRegistry()
        let descriptorCleanup = try await descriptorRegistry.register(Merman.plugin)
        #expect(descriptorRegistry.codeBlockLanguages() == ["mermaid"])
        await descriptorCleanup()
        #expect(descriptorRegistry.codeBlockLanguages().isEmpty)

        // Verify TUIPluginHost.PluginRuntimeContext integration & end-to-end rendering
        let registry = TUIPluginHost.Registry()
        let hostCtx = TUIPluginHost.createPluginContext(
            host: TUIPluginHost.HostServices(),
            id: "opencode.merman",
            registry: registry
        )
        let hostUnregister = try Merman.setupHostPlugin(hostCtx)
        #expect(registry.hasMarkdown("mermaid"))
        let renderedText = try #require(registry.markdownRenderers()["mermaid"]?("flowchart LR\n  A[One] --> B[Two]"))
        #expect(renderedText.contains("One"))
        #expect(renderedText.contains("Two"))
        hostUnregister()
        #expect(!registry.hasMarkdown("mermaid"))
    }

    // MARK: - 8. Full Upstream Layout Audit Suite (All 318 Fixtures)

    @Test("Full upstream layout audit passes with zero violations across all flowchart and state families")
    func fullUpstreamLayoutAudit() throws {
        let fixtures = Merman.layoutFixtures()
        let flowcharts = fixtures.filter { $0.kind == .flowchart }
        let states = fixtures.filter { $0.kind == .state }
        #expect(flowcharts.count >= 100)
        #expect(states.count >= 100)
        #expect(Set(fixtures.map(\.id)).count == fixtures.count)

        let audits = try Merman.auditAllFixtures()
        let violations = audits.flatMap { audit in
            audit.violations.map { "\(audit.fixture.id) @\(audit.viewport): \($0)" }
        }
        let summary = Merman.summarizeAudits(audits)

        #expect(audits.count >= fixtures.count)
        #expect(violations.isEmpty, "Layout audit violations: \(violations.prefix(10).joined(separator: "; "))")

        for audit in audits where audit.fixture.kind == .state {
            let expectedViewport = audit.fixture.profile == .short ? 60 : (audit.fixture.profile == .unicode ? 80 : 120)
            #expect(audit.viewport == expectedViewport)
        }
        for id in ["state/chain/lr-long", "state/chain/rl-long"] {
            let audit = try #require(audits.first { $0.fixture.id == id })
            #expect(audit.viewport == 120)
            #expect(audit.metrics.width == 84)
            #expect(audit.metrics.height == 41)
            #expect(audit.metrics.overflow == 0)
        }
        #expect(
            audits.filter { $0.fixture.id == "flowchart/deployment-architecture/curated" }.map(\.viewport) == [60, 80, 120]
        )

        let established = Merman.summarizeAudits(audits.filter { $0.fixture.family != "decision-loops" }).total
        #expect(established.areaMax <= 11_011)
        #expect(established.areaP95 <= 5_313)
        #expect(established.bendsMax <= 30)
        #expect(established.bendsP95 <= 11)
        #expect(established.crossingsTotal <= 40)
        #expect(established.crossingsMax <= 3)
        #expect(established.routeLengthMax <= 930)
        #expect(established.routeLengthP95 <= 364)
        #expect(established.sharedRouteCellsMax <= 547)
        #expect(established.sharedRouteCellsP95 <= 122)
        #expect(established.overflowMax <= 170)
        #expect(established.overflowP95 <= 99)

        let decisionLoops = Merman.summarizeAudits(audits.filter { $0.fixture.family == "decision-loops" }).total
        #expect(decisionLoops.runs > 0)
        #expect(decisionLoops.areaMax <= 8_784)
        #expect(decisionLoops.bendsMax <= 24)
        #expect(decisionLoops.crossingsTotal <= 24)
        #expect(decisionLoops.crossingsMax <= 8)
        #expect(decisionLoops.routeLengthMax <= 526)
        #expect(decisionLoops.sharedRouteCellsMax <= 352)
        #expect(decisionLoops.overflowMax <= 84)
        #expect(summary.state.crossingsTotal == 0)

        // Determinism check across every family
        var seenFamilies = Set<String>()
        for fixture in fixtures {
            let key = "\(fixture.kind.rawValue)/\(fixture.family)"
            if !seenFamilies.insert(key).inserted { continue }
            let first = try Merman.auditFixture(fixture, viewport: 80)
            let second = try Merman.auditFixture(fixture, viewport: 80)
            #expect(second.output == first.output)
            #expect(second.metrics == first.metrics)
            #expect(second.violations == first.violations)
        }

        let worstByArea = Merman.worstAudits(audits, metric: .area, limit: 3)
        #expect(worstByArea.count == 3)
        #expect(worstByArea[0].metrics.area >= worstByArea[1].metrics.area)
    }
}
