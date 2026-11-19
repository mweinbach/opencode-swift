extension Merman {
    // parity: merman/src/detect.ts#detectMermaidDiagram [status=implemented hash=631249b12071]
    public static func detectMermaidDiagram(_ content: String) -> MermaidDiagramKind? {
        if isMermaidFlowchartDiagram(content) { return .flowchart }
        if isMermaidGanttDiagram(content) { return .gantt }
        if isMermaidGitGraphDiagram(content) { return .gitGraph }
        if isMermaidSequenceDiagram(content) { return .sequence }
        if isMermaidStateDiagram(content) { return .state }
        if isMermaidTimelineDiagram(content) { return .timeline }
        return nil
    }
}
