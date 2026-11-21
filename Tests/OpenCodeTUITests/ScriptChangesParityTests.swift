import Testing
import OpenCodeSchema
import OpenCodeTUI

@Suite("TUI Script Changes & Change Counts Parity Tests")
struct ScriptChangesParityTests {
    @Test("parseScriptChanges parses per-change script metadata with optional patches and counts")
    func parseScriptChangesBehavior() {
        let raw: JSONValue = .array([
            .object([
                "file": .string("a.ts"),
                "status": .string("modified"),
                "additions": .int(1),
                "deletions": .int(1),
                "patch": .string("@@ -1 +1 @@\n-a\n+b\n"),
            ]),
            .object([
                "file": .string("a.ts"),
                "status": .string("modified"),
                "additions": .int(2),
                "deletions": .int(0),
            ]),
            .object(["file": .string("copy.txt"), "status": .string("added")]),
            .object(["file": .string("gone.bin"), "status": .string("deleted")]),
            .object(["file": .string(""), "status": .string("added")]),
            .object(["file": .string("x.ts"), "status": .string("renamed")]),
            .string("junk"),
        ])

        let parsed = TUIRoutes.parseScriptChanges(raw)
        #expect(parsed == [
            .init(type: "update", relativePath: "a.ts", filePath: "a.ts", patch: "@@ -1 +1 @@\n-a\n+b\n", additions: 1, deletions: 1, movePath: nil),
            .init(type: "update", relativePath: "a.ts", filePath: "a.ts", patch: "", additions: 2, deletions: 0, movePath: nil),
            .init(type: "add", relativePath: "copy.txt", filePath: "copy.txt", patch: "", additions: nil, deletions: nil, movePath: nil),
            .init(type: "delete", relativePath: "gone.bin", filePath: "gone.bin", patch: "", additions: nil, deletions: nil, movePath: nil),
        ])
    }

    @Test("changeCounts formats line summaries and returns nil when unknown or zero")
    func changeCountsBehavior() {
        func text(_ adds: Int? = nil, _ dels: Int? = nil) -> String? {
            guard let c = TUIRoutes.changeCounts(additions: adds, deletions: dels) else { return nil }
            let parts = [c.additions, c.deletions].filter { !$0.isEmpty }
            return parts.joined(separator: " ") + c.unit
        }

        #expect(text(2, 0) == "+2 lines")
        #expect(text(nil, 40) == "-40 lines")
        #expect(text(nil, 1) == "-1 line")
        #expect(text(5, 1) == "+5 -1 lines")
        #expect(text(0, 0) == nil)
        #expect(text(nil, nil) == nil)
    }
}
