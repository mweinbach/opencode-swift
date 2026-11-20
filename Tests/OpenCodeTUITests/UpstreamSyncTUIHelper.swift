import Foundation
import OpenCodeSchema

/// JSON fixtures for `UpstreamSyncTUITests` (kept out of the `import Testing` file per the CLT cross-import rule).
enum UpstreamSyncTUIHelper {
    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    static func job(_ json: String) throws -> JobSchema.Info {
        try decode(JobSchema.Info.self, json)
    }

    /// An assistant message whose only part is a completed `execute` call that moved `jobID` to the background.
    static func executeMessage(code: String, jobID: String) throws -> SessionMessageSchema.Info {
        let codeJSON = String(decoding: try JSONEncoder().encode(code), as: UTF8.self)
        return try decode(SessionMessageSchema.Info.self, """
        {
          "id": "msg_1", "type": "assistant", "agent": "build",
          "model": { "id": "m", "providerID": "p" },
          "time": { "created": 1 },
          "content": [
            {
              "type": "tool", "id": "part_1", "name": "execute", "time": { "created": 1 },
              "state": { "status": "completed", "input": { "code": \(codeJSON) }, "content": [{ "type": "text", "text": "moved to background" }], "metadata": { "jobID": "\(jobID)" } }
            }
          ]
        }
        """)
    }
}

extension UpstreamSyncTUIHelper {
    /// An assistant message with one text part and one reasoning part; `completed` sets `time.completed`.
    static func assistant(text: String, reasoning: String, completed: Bool) throws -> SessionMessageSchema.Assistant {
        let textJSON = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        let reasoningJSON = String(decoding: try JSONEncoder().encode(reasoning), as: UTF8.self)
        let info = try decode(SessionMessageSchema.Info.self, """
        {
          "id": "msg_2", "type": "assistant", "agent": "build",
          "model": { "id": "m", "providerID": "p" },
          "time": { "created": 1\(completed ? ", \"completed\": 2" : "") },
          "content": [
            { "type": "reasoning", "id": "part_r", "text": \(reasoningJSON), "time": { "created": 1 } },
            { "type": "text", "id": "part_t", "text": \(textJSON) }
          ]
        }
        """)
        guard case .assistant(let message) = info else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not assistant")) }
        return message
    }
}
