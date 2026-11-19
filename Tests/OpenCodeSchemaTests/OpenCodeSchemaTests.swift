import Testing
import OpenCodeSchema

@Suite("OpenCodeSchema Tests")
struct OpenCodeSchemaTests {
    @Test("Identifier ascending sorts forward and descending reverses order")
    func identifierOrdering() {
        var generator = Identifier.Generator()
        let a1 = generator.create(descending: false, timestamp: 1_700_000_000_000)
        let a2 = generator.create(descending: false, timestamp: 1_700_000_000_000)
        let a3 = generator.create(descending: false, timestamp: 1_700_000_000_005)
        #expect(a1.count == 26)
        #expect(a2.count == 26)
        #expect(a1 < a2)
        #expect(a2 < a3)

        let d1 = generator.create(descending: true, timestamp: 1_700_000_000_010)
        let d2 = generator.create(descending: true, timestamp: 1_700_000_000_010)
        let d3 = generator.create(descending: true, timestamp: 1_700_000_000_020)
        #expect(d1.count == 26)
        #expect(d1 > d2)
        #expect(d2 > d3)
    }

    @Test("Branded IDs enforce prefix invariants")
    func brandedIDs() {
        let sid = SessionID(rawValue: "ses_" + Identifier.encode(descending: true, timestamp: 1_700_000_000_000, counter: 1, randomBytes: Array(repeating: 0, count: 14)))
        #expect(sid != nil)
        #expect(sid?.rawValue.hasPrefix("ses_") == true)
        #expect(sid?.rawValue.count == 30)
        #expect(SessionID(rawValue: "bad_123") == nil)

        let wid = WorkspaceID(rawValue: "wrk_" + Identifier.encode(descending: false, timestamp: 1_700_000_000_000, counter: 1, randomBytes: Array(repeating: 0, count: 14)))
        #expect(wid != nil)
        #expect(wid?.rawValue.hasPrefix("wrk_") == true)
        #expect(wid?.rawValue.count == 30)
        #expect(WorkspaceID(rawValue: "bad_123") == nil)

        #expect(ProjectID.global.rawValue == "global")
    }
}
