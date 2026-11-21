#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - VideoGenerateTool (`core/src/tool/plugin/video-generate.ts`)

extension CoreTool {
    public enum VideoGenerateTool {
        // parity: core/src/tool/plugin/video-generate.ts#name [status=implemented hash=f3155e367087]
        public static let name: String = "experimental_video_generate"

        // parity: core/src/tool/plugin/video-generate.ts#MAX_INPUT_BYTES [status=implemented hash=1a4e7cbd63d2]
        public static let MAX_INPUT_BYTES: Int = 100 * 1024 * 1024

        private static let URL_TYPES: [String: String] = [
            "mp4": "video/mp4",
            "mov": "video/quicktime",
            "webm": "video/webm",
            "mp3": "audio/mpeg",
            "wav": "audio/wav",
            "m4a": "audio/mp4",
            "ogg": "audio/ogg",
            "flac": "audio/flac",
        ]

        // parity: core/src/tool/plugin/video-generate.ts#description [status=implemented hash=987a1c0f6e00]
        public static let description: String = [
            "Generates a video from a prompt, optionally starting or ending on given images and guided by reference images, videos or audio.",
            "Only call this when the user asks for a video: videos are slow and expensive.",
            "It runs in the background, and you are notified with every saved file when it finishes. Never poll, sleep, or check for the file while you wait.",
        ].joined(separator: "\n")

        // parity: core/src/tool/plugin/video-generate.ts#Input [status=implemented hash=728a276f8e8a]
        public struct Input: Equatable, Hashable, Sendable, Codable {
            public let prompt: String
            public let start: String?
            public let end: String?
            public let references: [String]?
            public let duration: Int?
            public let aspect: String?
            public let resolution: String?
            public let sound: Bool?
            public let model: String?
            public let path: String?

            public init(
                prompt: String,
                start: String? = nil,
                end: String? = nil,
                references: [String]? = nil,
                duration: Int? = nil,
                aspect: String? = nil,
                resolution: String? = nil,
                sound: Bool? = nil,
                model: String? = nil,
                path: String? = nil
            ) {
                self.prompt = prompt
                self.start = start
                self.end = end
                self.references = references
                self.duration = duration
                self.aspect = aspect
                self.resolution = resolution
                self.sound = sound
                self.model = model
                self.path = path
            }

            /// Upstream schema checks: a non-empty prompt and sources, at least one reference when given, a positive
            /// whole duration.
            func validate() throws {
                if prompt.isEmpty { throw AISchema.ToolFailure(message: "prompt must not be empty") }
                for source in [start, end].compactMap({ $0 }) + (references ?? []) where source.isEmpty {
                    throw AISchema.ToolFailure(message: "Media sources must not be empty")
                }
                if let references, references.isEmpty {
                    throw AISchema.ToolFailure(message: "references must list at least one source")
                }
                if let duration, duration <= 0 {
                    throw AISchema.ToolFailure(message: "duration must be greater than 0")
                }
            }
        }

        public static let inputSchema: AISchema.JsonSchema = [
            "type": .string("object"),
            "properties": .object([
                "prompt": .object([
                    "type": .string("string"),
                    "minLength": .int(1),
                    "description": .string("What happens in the video. Describe the subject, action, camera movement, style and, when sound is on, any dialogue or sound."),
                ]),
                "start": .object([
                    "type": .string("string"),
                    "minLength": .int(1),
                    "description": .string("Image the video starts on exactly. A local file path (relative to the session directory or absolute) or an http(s) URL."),
                ]),
                "end": .object([
                    "type": .string("string"),
                    "minLength": .int(1),
                    "description": .string("Image the video ends on exactly. A local file path or an http(s) URL."),
                ]),
                "references": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string"), "minLength": .int(1)]),
                    "minItems": .int(1),
                    "description": .string("Images, videos or audio that guide the subject, style, motion or voice without being shown as-is. Local file paths or http(s) URLs."),
                ]),
                "duration": .object([
                    "type": .string("integer"),
                    "exclusiveMinimum": .int(0),
                    "description": .string("Length in seconds."),
                ]),
                "aspect": .object([
                    "type": .string("string"),
                    "description": .string("Aspect ratio as \"width:height\", such as \"16:9\" or \"9:16\", or \"auto\" to follow the start image."),
                ]),
                "resolution": .object([
                    "type": .string("string"),
                    "description": .string("Output resolution, such as \"480p\", \"720p\", \"1080p\" or \"4k\"."),
                ]),
                "sound": .object([
                    "type": .string("boolean"),
                    "description": .string("Whether the video has generated sound. Unset uses the model's default."),
                ]),
                "model": .object([
                    "type": .string("string"),
                    "description": .string("NEVER set this unless the user explicitly asks for a particular video model. The value is written as \"providerID/modelID\". Do not guess the ID: look it up with the models tool using type: \"video\", filtering to your own provider first."),
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Where to save the video, relative to the session directory or absolute, usually ending in .mp4. An existing file is overwritten. Further videos from the same job go next to it with -1, -2, … before the extension. Defaults to a new file in the session's temp folder."),
                ]),
            ]),
            "required": .array([.string("prompt")]),
        ]

        // parity: core/src/tool/plugin/video-generate.ts#Output [status=implemented hash=36634a7f0860]
        public struct Output: Equatable, Hashable, Sendable, Codable {
            /// The video job's ID, repeated in its completion notice.
            public let id: String
            /// Where the first video will be saved.
            public let path: String
            /// providerID/modelID
            public let model: String

            public init(id: String, path: String, model: String) {
                self.id = id
                self.path = path
                self.model = model
            }
        }

        /// The completion notice for a background video job, tagged with its job ID like
        /// `<background-result kind="image" id=…>` notices.
        // parity: core/src/tool/plugin/video-generate.ts#notice [status=implemented hash=6ac6fe1767b8]
        public static func notice(id: String, state: String, body: String) -> String {
            "<background-result kind=\"video\" id=\"\(id)\" state=\"\(state)\">\n\(body)\n</background-result>"
        }

        /// Where the job's `index`th video is saved: the path itself for the first, then `cat-1.mp4`, `cat-2.mp4`, …
        // parity: core/src/tool/plugin/video-generate.ts#videoPath [status=implemented hash=1e891bc58cfe]
        public static func videoPath(_ file: String, index: Int) -> String {
            if index == 0 { return file }
            let ext = extname(file)
            return "\(file.dropLast(ext.count))-\(index)\(ext)"
        }

        /// Node's `path.extname`: the last `.` suffix of the basename, unless the basename starts with it.
        private static func extname(_ file: String) -> String {
            let base = file.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? file
            guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return "" }
            return String(base[dot...])
        }

        private static func urlType(_ url: String) -> String? {
            // `/\.([a-z0-9]+)(?:[?#]|$)/i`: the first extension followed by a query, fragment or the end.
            let chars = Array(url)
            var i = 0
            while i < chars.count {
                if chars[i] == "." {
                    var j = i + 1
                    while j < chars.count, chars[j].isASCII, chars[j].isLetter || chars[j].isNumber { j += 1 }
                    if j > i + 1, j == chars.count || chars[j] == "?" || chars[j] == "#" {
                        return URL_TYPES[String(chars[(i + 1)..<j]).lowercased()]
                    }
                }
                i += 1
            }
            return nil
        }

        public struct TrackInput: Sendable {
            public let jobs: any CoreJob.Interface
            public let sessions: (any CoreSession.Interface)?
            public let videos: any CoreIntegration.VideoGeneration.Interface
            public let blobs: any CoreBlobStore.Interface
            public let fileSystem: any OpenCodeFileSystem
            public let notificationID: SessionMessageSchema.ID
            public let sessionID: SessionID
            public let videoID: GenerateSchema.VideoID
            public let path: String
            public let title: String?
            public let notify: (@Sendable (CoreSessionSynthetic.Request) async throws -> Void)?

            public init(
                jobs: any CoreJob.Interface,
                sessions: (any CoreSession.Interface)?,
                videos: any CoreIntegration.VideoGeneration.Interface,
                blobs: any CoreBlobStore.Interface,
                fileSystem: any OpenCodeFileSystem,
                notificationID: SessionMessageSchema.ID,
                sessionID: SessionID,
                videoID: GenerateSchema.VideoID,
                path: String,
                title: String? = nil,
                notify: (@Sendable (CoreSessionSynthetic.Request) async throws -> Void)? = nil
            ) {
                self.jobs = jobs
                self.sessions = sessions
                self.videos = videos
                self.blobs = blobs
                self.fileSystem = fileSystem
                self.notificationID = notificationID
                self.sessionID = sessionID
                self.videoID = videoID
                self.path = path
                self.title = title
                self.notify = notify
            }
        }

        /// Wait for a video the server is generating, then copy each of its videos from the blob store into the
        /// workspace, as a background Job; when the job settles, post its completion notice to the session.
        // parity: core/src/tool/plugin/video-generate.ts#track [status=implemented hash=87f7ca87aca8]
        public static func track(_ input: TrackInput) async throws {
            let run: @Sendable () async throws -> String = {
                do {
                    let job = try await input.videos.wait(input.videoID)
                    let blobs: [BlobStoreSchema.Info]
                    switch job {
                    case .error(let failed):
                        throw AISchema.ToolFailure(message: failed.error)
                    case .running:
                        throw AISchema.ToolFailure(message: "The video is still running")
                    case .completed(let completed):
                        blobs = completed.blobs
                    }
                    // The blob is on the server's disk; the copy is a workspace write.
                    var files: [String] = []
                    for (index, blob) in blobs.enumerated() {
                        let file = videoPath(input.path, index: index)
                        let content = try await input.blobs.read(blob.id)
                        let bytes = try await input.fileSystem.readFile(at: content.path)
                        try await input.fileSystem.writeFile(bytes, to: file, createDirectories: true)
                        files.append(file)
                    }
                    return files.count == 1
                        ? "Video request finished. Saved video: \(files[0])."
                        : "Video request finished. Saved \(files.count) videos: \(files.joined(separator: ", "))."
                } catch {
                    // The job keeps this text, so a restart can still deliver the outcome.
                    let message = (error as? AISchema.ToolFailure)?.message ?? String(describing: error)
                    throw AISchema.ToolFailure(message: "Video request failed for \(input.path): \(message)")
                }
            }
            let videos = input.videos
            let videoID = input.videoID
            _ = try await input.jobs.start(CoreJob.StartInput(
                id: videoID.rawValue,
                type: name,
                title: input.title ?? input.path,
                metadata: ["sessionID": .string(input.sessionID.rawValue), "path": .string(input.path)],
                recovery: .video(sessionID: input.sessionID, path: input.path, videoID: videoID.rawValue),
                notificationID: input.notificationID.rawValue,
                background: true,
                run: run,
                cancel: { try? await videos.cancel(videoID) }
            ))
            let jobs = input.jobs
            Task {
                let info = await jobs.wait(CoreJob.WaitInput(id: videoID.rawValue)).info
                guard let info, info.status != .running else { return }
                let state = info.status.rawValue
                let body: String
                switch info.status {
                case .completed: body = info.output ?? ""
                case .error: body = info.error ?? "Video request failed for \(input.path)."
                default: body = "Video request for \(input.path) was cancelled."
                }
                let syntheticReq = CoreSessionSynthetic.Request(
                    sessionID: input.sessionID,
                    id: input.notificationID,
                    text: notice(id: videoID.rawValue, state: state, body: body),
                    description: "Video generation",
                    metadata: [
                        "source": .string(name),
                        "jobID": .string(videoID.rawValue),
                        "state": .string(state),
                        "path": .string(input.path),
                    ]
                )
                do {
                    if let notify = input.notify {
                        try await notify(syntheticReq)
                    } else if let sessions = input.sessions {
                        _ = try await sessions.synthetic(syntheticReq)
                    }
                    try? await jobs.completeBackground(input.notificationID.rawValue)
                } catch is CoreSessionErrors.NotFoundError {
                    try? await jobs.completeBackground(input.notificationID.rawValue)
                } catch {
                    // Leave the job row intact so a later restart sweep can deliver the outcome.
                }
            }
        }

        /// Whether the tool registers: the `video_generate` flag is on and some video model is available.
        public static func enabled(_ env: BuiltinEnvironment) async -> Bool {
            guard await env.flags.enabled(.videoGenerate) else { return false }
            guard env.videoGeneration != nil, env.blobStore != nil, env.jobs != nil, let models = env.model else { return false }
            let available = (try? await models.available(types: [.video])) ?? []
            return !available.isEmpty
        }

        private static func sessionProvider(_ env: BuiltinEnvironment, _ sessionID: SessionID) -> ProviderSchema.ID? {
            if let s = try? env.session?.get(sessionID), let pid = s.model?.providerID { return ProviderSchema.ID(rawValue: pid) }
            if let s = try? env.sessionStore?.get(sessionID), let pid = s.model?.providerID { return ProviderSchema.ID(rawValue: pid) }
            return nil
        }

        private static func configuredModel(_ entries: [CoreConfigEntry]) -> ConfigModelSchema.Selection? {
            for entry in entries.reversed() {
                if let selection = entry.info?.experimental?.videoGenerate?.options?.model {
                    return selection
                }
            }
            return nil
        }

        private static func resolveModel(_ value: String?, sessionID: SessionID, env: BuiltinEnvironment) async throws -> ModelSchema.Info {
            let available = (try? await env.model?.available(types: [.video])) ?? []
            guard let value else {
                if let entries = await env.config?.entries(), let configured = configuredModel(entries) {
                    let match = available.first { item in
                        item.providerID == configured.providerID && item.id == configured.model
                    }
                    guard let model = match else {
                        throw AISchema.ToolFailure(
                            message: "Configured video model \"\(configured.providerID.rawValue)/\(configured.model.rawValue)\" is not an available video model."
                        )
                    }
                    return model
                }
                let providerID = sessionProvider(env, sessionID)
                guard let model = available.first(where: { $0.providerID == providerID }) ?? available.first else {
                    throw AISchema.ToolFailure(message: "No video model is available.")
                }
                return model
            }
            let ref: ModelSchema.Ref
            do {
                ref = try ModelSchema.Ref.parse(value)
            } catch {
                throw AISchema.ToolFailure(message: "Invalid model \"\(value)\". Use \"providerID/modelID\".")
            }
            guard let model = available.first(where: { $0.providerID == ref.providerID && $0.id == ref.id }) else {
                throw AISchema.ToolFailure(
                    message: "Model \"\(ref.providerID.rawValue)/\(ref.id.rawValue)\" is not an available video model. Use the models tool with type: \"video\" to see what is available."
                )
            }
            return model
        }

        private static func kindList(_ kinds: [AIMedia.Kind]) -> String {
            let names = kinds.map(\.rawValue)
            guard names.count > 1 else { return names.first ?? "" }
            return names.dropLast().joined(separator: ", ") + " or " + names.last!
        }

        // URLs go to the provider as they are, which most video APIs prefer; local files are read and sent inline.
        private static func readMedia(
            _ value: String,
            context: ToolSchema.Context,
            kinds: [AIMedia.Kind],
            env: BuiltinEnvironment
        ) async throws -> AIMedia.Asset {
            let lower = value.lowercased()
            let asset: AIMedia.Asset
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                // The provider fetches the URL, but the agent chose it, so the webfetch rule still applies.
                let inv = CorePermission.invocation(context)
                try await env.permission.assert(CorePermission.AssertInput(
                    sessionID: inv.sessionID,
                    agent: inv.agent,
                    action: WebFetchTool.name,
                    resources: [value],
                    save: ["*"],
                    metadata: ["url": .string(value)],
                    source: inv.source
                ))
                asset = AIMedia.url(value, mediaType: urlType(value))
            } else {
                let target = try await env.fileAccess.authorizeRead(value, context: context, options: nil)
                let stat: FileStat
                do {
                    stat = try await env.fileSystem.stat(at: target.absolute.rawValue)
                } catch {
                    throw AISchema.ToolFailure(message: "File not found: \(value)")
                }
                if stat.size > Int64(MAX_INPUT_BYTES) {
                    throw AISchema.ToolFailure(message: "\(value) is larger than 100 MiB.")
                }
                let bytes = try await env.fileSystem.readFile(at: target.absolute.rawValue)
                guard let mime = AIUtils.detectMediaType(bytes) else {
                    throw AISchema.ToolFailure(message: "\(value) is not a supported image, video or audio file.")
                }
                asset = AIMedia.bytes(bytes, mediaType: mime)
            }
            // A URL without a known extension has no type yet; the provider checks it.
            if asset.kind != .other && !kinds.contains(asset.kind) {
                throw AISchema.ToolFailure(message: "\(value) must be \(kindList(kinds)).")
            }
            return asset
        }

        // Frames are images; `ImageAsset` keeps a URL whose type it can't tell for the provider to check.
        private static func readFrame(_ value: String, context: ToolSchema.Context, env: BuiltinEnvironment) async throws -> AIMedia.ImageAsset {
            let asset = try await readMedia(value, context: context, kinds: [.image], env: env)
            do {
                return try AIMedia.ImageAsset(validating: asset)
            } catch {
                throw AISchema.ToolFailure(message: "\(value) must be image.")
            }
        }

        // parity: core/src/tool/plugin/video-generate.ts#Plugin [status=adapted hash=3965bd6ac4e0]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.video-generate") { editor, env in
            // `registerAllBuiltins` resolves the flag and model availability; upstream reloads on `model.updated`.
            guard env.videoGenerate,
                  let videos = env.videoGeneration,
                  let blobs = env.blobStore,
                  let jobs = env.jobs
            else { return }
            editor.add(RegisteredTool(
                name: name,
                description: description,
                inputSchema: inputSchema,
                outputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The video job's ID, repeated in its completion notice")]),
                        "path": .object(["type": .string("string"), "description": .string("Where the first video will be saved")]),
                        "model": .object(["type": .string("string"), "description": .string("providerID/modelID")]),
                    ]),
                    "required": .array([.string("id"), .string("path"), .string("model")]),
                ],
                options: ToolSchema.Options(codemode: false)
            ) { rawInput, context in
                let input = try decodeToolJSON(Input.self, from: rawInput, toolName: name)
                do {
                    try input.validate()
                    let model = try await resolveModel(input.model, sessionID: context.sessionID, env: env)
                    let ref = "\(model.providerID.rawValue)/\(model.id.rawValue)"
                    var aspect: GenerateSchema.VideoAspect?
                    if let raw = input.aspect {
                        if raw == "auto" {
                            aspect = .auto
                        } else if let ratio = GenerateSchema.ImageAspect(rawValue: raw) {
                            aspect = .ratio(ratio)
                        } else {
                            throw AISchema.ToolFailure(message: "Invalid aspect \"\(raw)\". Use \"width:height\", such as \"16:9\", or \"auto\".")
                        }
                    }
                    let target = try await input.path.asyncMap { path in
                        try await env.fileAccess.resolve(CoreFilesystem.FileAccess.ResolveInput(path: path, kind: .file))
                    }

                    let inv = CorePermission.invocation(context)
                    var metadata: [String: JSONValue] = (encodeToolJSON(input).objectValue ?? [:])
                    metadata["model"] = .string(ref)
                    try await env.permission.assert(CorePermission.AssertInput(
                        sessionID: inv.sessionID,
                        agent: inv.agent,
                        action: name,
                        resources: [ref],
                        save: ["*"],
                        metadata: metadata,
                        source: inv.source
                    ))
                    if let target {
                        try await env.fileAccess.authorizeExternal([target], context: context, metadata: nil)
                        try await env.permission.assert(CorePermission.AssertInput(
                            sessionID: inv.sessionID,
                            agent: inv.agent,
                            action: "edit",
                            resources: [target.resource],
                            save: [CoreFilesystem.FileAccess.always(target)],
                            source: inv.source
                        ))
                    }
                    let start = try await input.start.asyncMap { try await readFrame($0, context: context, env: env) }
                    let end = try await input.end.asyncMap { try await readFrame($0, context: context, env: env) }
                    var references: [AIMedia.Asset]?
                    if let sources = input.references {
                        var loaded: [AIMedia.Asset] = []
                        for source in sources {
                            loaded.append(try await readMedia(source, context: context, kinds: [.image, .video, .audio], env: env))
                        }
                        references = loaded
                    }

                    // Submitting runs in the foreground so a rejected request fails the call; the wait runs as a job.
                    let sessionLocation = (try? env.session?.get(context.sessionID))?.location
                    let started = try await videos.start(
                        CoreIntegration.Generate.VideoInput(
                            model: ModelSchema.Ref(id: model.id, providerID: model.providerID),
                            prompt: input.prompt,
                            start: start,
                            end: end,
                            references: references,
                            duration: input.duration,
                            aspect: aspect,
                            resolution: input.resolution,
                            sound: input.sound
                        ),
                        options: CoreIntegration.VideoGeneration.StartOptions(location: sessionLocation.map {
                            LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: $0.directory), workspaceID: $0.workspaceID)
                        })
                    )
                    let id = started.id
                    let file = target?.absolute.rawValue ?? CoreConfigDiscovery.joinPath(
                        env.globalPaths.tmp,
                        "videos/\(context.sessionID.rawValue)/\(id.rawValue).mp4"
                    )
                    try await track(TrackInput(
                        jobs: jobs,
                        sessions: env.session,
                        videos: videos,
                        blobs: blobs,
                        fileSystem: env.fileSystem,
                        notificationID: SessionMessageSchema.ID.create(),
                        sessionID: context.sessionID,
                        videoID: id,
                        path: file,
                        title: input.prompt
                    ))
                    let out = Output(id: id.rawValue, path: file, model: ref)
                    return ToolSchema.Result(
                        output: encodeToolJSON(out),
                        content: .text([
                            // The model is named only when the tool picked it.
                            "Video job \(id.rawValue) started in the background\(input.model == nil ? " with \(ref)" : ""). It will be saved to \(file); if the model returns more than one video, the others are saved next to it with -1, -2, … added to the name.",
                            "You will be notified automatically when it finishes or fails. Videos usually take a few minutes.",
                            "DO NOT sleep, poll, check whether the file exists, or request the same video again while it runs.",
                            "Work on other tasks, or briefly tell the user what you started and end your response.",
                        ].joined(separator: "\n")),
                        metadata: ["path": .string(file), "model": .string(ref), "jobID": .string(id.rawValue)]
                    )
                } catch let err as CorePermission.DeclinedError {
                    throw err
                } catch let err as AISchema.ToolFailure {
                    throw err
                } catch {
                    throw AISchema.ToolFailure(message: "Unable to generate video: \(error)")
                }
            })
        }
    }
}

extension Optional {
    fileprivate func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}

extension JSONValue {
    fileprivate var objectValue: [String: JSONValue]? {
        if case .object(let dict) = self { return dict }
        return nil
    }
}
