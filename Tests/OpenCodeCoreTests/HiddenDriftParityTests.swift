import Testing
import OpenCodeCore
import OpenCodeSchema

/// Upstream changes (opencode 3aaac77..85951cb) that sat past the old scanner's hashed prefix.
@Suite("Hidden drift: background-result notices, Claude connection env and status, idle background")
struct HiddenDriftParityTests {
    typealias Claude = CorePlugin.ClaudeAgent

    @Test("shell and image completion notices render as <background-result>")
    func backgroundResultNotices() {
        let shell = CoreShell.ResultHelper.notification(CoreShell.ResultHelper.NotificationInput(
            shellID: "sh_1",
            jobID: "job_1",
            command: "ls",
            state: "completed",
            text: "done"
        ))
        #expect(shell.text == "<background-result kind=\"shell\" id=\"job_1\" state=\"completed\" command=\"ls\">\ndone\n</background-result>")
        let noJob = CoreShell.ResultHelper.notification(CoreShell.ResultHelper.NotificationInput(
            shellID: "sh_2",
            command: "pwd",
            state: "error",
            text: "boom"
        ))
        #expect(noJob.text.hasPrefix("<background-result kind=\"shell\" id=\"sh_2\" state=\"error\""))
        #expect(
            CoreIntegration.Image.Notice.text(id: "img_1", state: "completed", body: "Saved")
                == "<background-result kind=\"image\" id=\"img_1\" state=\"completed\">\nSaved\n</background-result>"
        )
    }

    @Test("connectionEnv maps settings, the first config folder, headers and body")
    func connectionEnv() {
        let env = Claude.QueryOptions.connectionEnv(
            settings: [
                "baseURL": .string("https://proxy.example"),
                "apiKey": .string("sk"),
                "authToken": .string("tok"),
                "headerTimeout": .int(30000),
                "chunkTimeout": .double(1500),
                "configDir": .array([.string("~/.claude-work"), .string("/second")]),
                "ignored": .bool(true),
            ],
            headers: ["x-b": "2", "x-a": "1"],
            body: ["metadata": .object(["user": .string("u/1")])],
            home: "/Users/me",
            cwd: "/repo"
        )
        #expect(env == [
            "ANTHROPIC_BASE_URL": "https://proxy.example",
            "ANTHROPIC_API_KEY": "sk",
            "ANTHROPIC_AUTH_TOKEN": "tok",
            "API_TIMEOUT_MS": "30000",
            "CLAUDE_STREAM_IDLE_TIMEOUT_MS": "1500",
            "CLAUDE_CONFIG_DIR": "/Users/me/.claude-work",
            "ANTHROPIC_CUSTOM_HEADERS": "x-a: 1\nx-b: 2",
            "CLAUDE_CODE_EXTRA_BODY": "{\"metadata\":{\"user\":\"u/1\"}}",
        ])
        // Wrong types are skipped; an empty body and no headers add nothing.
        #expect(Claude.QueryOptions.connectionEnv(
            settings: ["apiKey": .int(1), "headerTimeout": .string("5"), "configDir": .int(2)],
            headers: [:],
            body: [:]
        ) == [:])
        #expect(Claude.QueryOptions.connectionEnv() == [:])
    }

    @Test("a ready status names its config folder, and chat reports from another account are ignored")
    func statusConfigDir() async {
        let io = Claude.IO.Interface(
            env: { [:] },
            probe: { Claude.Probe.Result(version: "2.0", tokenSource: "oauth") }
        )
        let tracker = Claude.Status.make(
            io: io,
            connection: { ["CLAUDE_CONFIG_DIR": "/work"] },
            configDirs: { ["/work", "/team"] }
        )
        let refreshed = await tracker.refresh()
        #expect(refreshed == .ready(version: "2.0", models: [], configDir: "/work"))
        #expect(refreshed.configDir == "/work")

        await tracker.report(.ready(version: "9", models: [], configDir: "/stranger", fromChat: true))
        #expect(await tracker.current() == refreshed)
        let fromChat = Claude.Status.State.ready(version: "3", models: [], configDir: "/team", fromChat: true)
        await tracker.report(fromChat)
        #expect(await tracker.current() == fromChat)
        await tracker.report(.unauthenticated)
        #expect(await tracker.current() == .unauthenticated)
    }

    @Test("idle hooks can report a background video, and the puzzle icon exists")
    func idleVideoAndIcon() {
        let item = PluginEffect.SessionIdleBackground.video(sessionID: SessionID(rawValue: "ses_1")!, path: "out.mp4")
        let idle = PluginEffect.SessionIdle(sessionID: SessionID(rawValue: "ses_1")!, background: [item])
        #expect(idle.background == [item])
        #expect(PluginPromise.SessionIdleBackground.video(sessionID: SessionID(rawValue: "ses_1")!, path: "out.mp4") == item)
        #expect(PluginGui.AppIconName(rawValue: "puzzle") == .puzzle)
    }
}
