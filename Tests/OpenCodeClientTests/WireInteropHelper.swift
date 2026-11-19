#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeClient
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

/// Raw OpenCode 2.3.2 JSON wire fixtures & response builders for `WireInteropTests`.
/// Kept separate from `WireInteropTests.swift` so test files importing `Testing` never import `Foundation`
/// (macOS CLT cross-import overlay rule).
enum WireInteropFixtures {
    static func rawJSONResponse(
        status: Int = 200,
        contentType: String = "application/json; charset=utf-8",
        headers: [String: String] = [:],
        json: String
    ) -> HTTPResponse {
        var merged = headers
        if ClientHTTPHeaders.value(in: merged, for: "content-type") == nil {
            merged["Content-Type"] = contentType
        }
        return HTTPResponse(
            head: HTTPResponseHead(statusCode: status, headers: merged),
            body: Array(json.utf8)
        )
    }

    static func rawTextResponse(
        status: Int,
        contentType: String? = "text/plain; charset=utf-8",
        body: String
    ) -> HTTPResponse {
        var headers: [String: String] = [:]
        if let contentType {
            headers["Content-Type"] = contentType
        }
        return HTTPResponse(
            head: HTTPResponseHead(statusCode: status, headers: headers),
            body: Array(body.utf8)
        )
    }

    static func decodeRequestJSON(_ bytes: [UInt8]?) throws -> JSONValue {
        guard let bytes, !bytes.isEmpty else { return .null }
        return try JSONDecoder().decode(JSONValue.self, from: Data(bytes))
    }

    // MARK: - Authentic OpenCode 2.3.2 Wire Fixtures

    static let serverInfo232JSON = """
    {
      "version": "2.3.2",
      "pid": 48291,
      "hostname": "workstation.local",
      "urls": ["http://127.0.0.1:49374"],
      "paths": {
        "tmp": "/var/folders/oc/tmp/opencode"
      },
      "capabilities": {
        "persistentPty": true
      }
    }
    """

    static let locationGet232JSON = """
    {
      "directory": "/Users/dev/my repo",
      "project": {
        "id": "proj_01972a1b2c3d",
        "directory": "/Users/dev/my repo",
        "canonical": "/Users/dev/my repo"
      }
    }
    """

    static let sessionInfo232Object = """
    {
      "id": "ses_01972a1b2c3d7e4f8a9b0c1d2e3f4a5b",
      "projectID": "proj_01972a1b2c3d",
      "agent": "build",
      "model": {
        "id": "claude-sonnet-4-20250514",
        "providerID": "anthropic",
        "variant": "high"
      },
      "cost": 0.0125,
      "tokens": {
        "input": 1200,
        "output": 450,
        "reasoning": 200,
        "cache": {
          "read": 800,
          "write": 100
        }
      },
      "outcome": "succeeded",
      "time": {
        "created": 1763500000000,
        "updated": 1763500010000,
        "busy": 1763500001000,
        "idle": 1763500010000
      },
      "title": "Wire interop verification",
      "location": {
        "directory": "/Users/dev/my repo"
      }
    }
    """

    static let sessionList232JSON = """
    {
      "data": [
        \(sessionInfo232Object)
      ],
      "cursor": {
        "next": "eyJ0aW1lIjoxNzYzNTAwMDAwMDAwfQ"
      }
    }
    """

    static let sessionEnvelope232JSON = """
    {
      "data": \(sessionInfo232Object)
    }
    """

    static let sessionPrompt232JSON = """
    {
      "data": {
        "id": "msg_01972a1b2c3d0001",
        "sessionID": "ses_01972a1b2c3d7e4f8a9b0c1d2e3f4a5b",
        "time": {
          "created": 1763500002000
        },
        "type": "user",
        "payload": {
          "text": "Explain wire interop"
        },
        "delivery": "steer"
      }
    }
    """

    static let sessionInterrupt232JSON = """
    {
      "interrupted": true
    }
    """

    static let messageList232JSON = """
    {
      "data": [
        {
          "type": "user",
          "id": "msg_01972a1b2c3d0001",
          "time": { "created": 1763500002000 },
          "text": "Explain wire interop"
        },
        {
          "type": "assistant",
          "id": "msg_01972a1b2c3d0002",
          "agent": "build",
          "model": {
            "id": "claude-sonnet-4-20250514",
            "providerID": "anthropic",
            "variant": "high"
          },
          "content": [
            {
              "type": "reasoning",
              "text": "Checking RFC 7617 Base64 encoding",
              "time": { "created": 1763500002100, "completed": 1763500002300 }
            },
            {
              "type": "text",
              "text": "Basic auth uses standard padded Base64 per RFC 7617."
            }
          ],
          "finish": "stop",
          "cost": 0.0042,
          "tokens": {
            "input": 600,
            "output": 120,
            "reasoning": 50,
            "cache": { "read": 300, "write": 0 }
          },
          "time": {
            "created": 1763500002050,
            "firstToken": 1763500002400,
            "streamed": 1763500002900,
            "completed": 1763500003000
          }
        },
        {
          "type": "idle",
          "id": "msg_01972a1b2c3d0003",
          "time": { "created": 1763500003100 },
          "outcome": "succeeded"
        }
      ],
      "cursor": {
        "previous": "prev_tok_1",
        "next": "next_tok_2"
      }
    }
    """

    static let agentList232JSON = """
    {
      "location": { "directory": "/Users/dev/my repo" },
      "data": [
        {
          "id": "build",
          "name": "Build",
          "model": {
            "id": "claude-sonnet-4-20250514",
            "providerID": "anthropic"
          },
          "request": {
            "settings": {},
            "headers": {},
            "body": {}
          },
          "description": "Default coding agent",
          "mode": "primary",
          "hidden": false,
          "color": "#3b82f6",
          "permissions": [
            { "action": "*", "resource": "*", "effect": "allow" }
          ]
        }
      ]
    }
    """

    static let modelList232JSON = """
    {
      "location": { "directory": "/Users/dev/my repo" },
      "data": [
        {
          "id": "claude-sonnet-4-20250514",
          "modelID": "claude-sonnet-4-20250514",
          "providerID": "anthropic",
          "type": "chat",
          "family": "claude-sonnet",
          "name": "Claude Sonnet 4",
          "capabilities": {
            "tools": true,
            "input": ["text", "image"],
            "output": ["text"],
            "temperature": true
          },
          "variants": [
            { "id": "high", "settings": { "thinking": true } }
          ],
          "time": { "released": 1747872000000 },
          "cost": [
            {
              "input": 3.0,
              "output": 15.0,
              "cache": { "read": 0.3, "write": 3.75 }
            }
          ],
          "status": "active",
          "enabled": true,
          "limit": {
            "context": 200000,
            "input": 180000,
            "output": 64000
          }
        }
      ]
    }
    """

    static let providerList232JSON = """
    {
      "location": { "directory": "/Users/dev/my repo" },
      "data": [
        {
          "id": "anthropic",
          "name": "Anthropic",
          "activation": "auto",
          "package": "@ai-sdk/anthropic",
          "settings": {
            "timeout": 300000,
            "compaction": { "type": "summary" },
            "cache": { "ttl": "5m" }
          }
        }
      ]
    }
    """

    static let mcpList232JSON = """
    {
      "location": { "directory": "/Users/dev/my repo" },
      "data": [
        {
          "name": "context7",
          "status": { "status": "connected" },
          "title": "Context7 Docs"
        },
        {
          "name": "linear",
          "status": { "status": "needs_auth", "error": "OAuth token expired" },
          "integrationID": "mcp-linear"
        },
        {
          "name": "local-broken",
          "status": { "status": "failed", "error": "spawn ENOENT" }
        }
      ]
    }
    """

    static let vcsGet232JSON = """
    {
      "location": { "directory": "/Users/dev/my repo" },
      "data": {
        "provider": "git",
        "branch": {
          "current": "t3/fix-wire-interop",
          "default": "main"
        }
      }
    }
    """

    static let unauthorized232JSON = """
    {
      "_tag": "UnauthorizedError",
      "message": "Authentication required"
    }
    """

    static func sseEvent232Chunks() -> [[UInt8]] {
        let connected = ": keepalive\n\ndata: {\"id\":\"evt_01\",\"type\":\"server.connected\",\"data\":{}}\n\n"
        // Include multi-byte UTF-8 ("✓ café 🚀") and split across chunk boundaries
        let deltaFull = "data: {\"id\":\"evt_02\",\"type\":\"session.text.delta\",\"created\":1763500002500,\"location\":{\"directory\":\"/Users/dev/my repo\"},\"data\":{\"sessionID\":\"ses_01972a1b2c3d7e4f8a9b0c1d2e3f4a5b\",\"delta\":\"Hello ✓ café 🚀\"}}\n\n"
        let deltaBytes = Array(deltaFull.utf8)
        let splitIdx = deltaBytes.firstIndex(of: 0xF0).map { $0 + 2 } ?? (deltaBytes.count / 2)
        let idle = "data: {\"id\":\"evt_03\",\"type\":\"session.idle\",\"created\":1763500003100,\"data\":{\"sessionID\":\"ses_01972a1b2c3d7e4f8a9b0c1d2e3f4a5b\"}}\n\n"
        return [
            Array(connected.utf8),
            Array(deltaBytes[..<splitIdx]),
            Array(deltaBytes[splitIdx...]),
            Array(idle.utf8),
        ]
    }
}
