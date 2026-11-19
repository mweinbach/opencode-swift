/// Portable AI provider definitions, endpoint/auth/header builders, and typed model factories
/// (Part B: `google.ts` through `zai.ts` — 33 upstream provider modules, 255 symbols).
///
/// Strictly PORTABLE tier: zero OS imports, all HTTP via `OpenCodePlatform.HTTPTransport`
/// and environment lookups via `OpenCodePlatform.EnvironmentProviding`.

import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

extension AIProviders {

    // MARK: - 18. Google (google.ts, google/interactions.ts — 25 symbols)

    public enum Google {
        // parity: ai/src/providers/google.ts#GeminiOptionsInput [status=implemented hash=41017b456841]
        public typealias GeminiOptionsInput = AIProtocols.Gemini.OptionsInput
        // parity: ai/src/providers/google.ts#GeminiProviderOptionsInput [status=implemented hash=c4493546d072]
        public typealias GeminiProviderOptionsInput = AIProtocols.Gemini.ProviderOptionsInput
        // parity: ai/src/providers/google.ts#GoogleInteractionsOptionsInput [status=implemented hash=82744cb45cea]
        public typealias GoogleInteractionsOptionsInput = AIProtocols.GoogleInteractions.OptionsInput
        // parity: ai/src/providers/google.ts#GoogleDecisionsOptionsInput [status=implemented hash=540f604e0c78]
        public typealias GoogleDecisionsOptionsInput = AIProtocols.GoogleDecisions.OptionsInput
        // parity: ai/src/providers/google.ts#id [status=implemented hash=9b4f28cfbffb]
        public static let id = "google"
        // parity: ai/src/providers/google.ts#routes [status=implemented hash=c773595e1f95]
        public static let routes: [AIProtocols.ChatRouteSpec] = [AIProtocols.Gemini.route, AIProtocols.GoogleInteractions.route]
        // parity: ai/src/providers/google.ts#Config [status=implemented hash=759f7a42cf87]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/google.ts#Settings [status=implemented hash=e14422450169]
        public typealias Settings = ProviderConfig

        // parity: ai/src/providers/google.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            let auth = resolveHeaderAuth(config: input, envVars: ["GOOGLE_GENERATIVE_AI_API_KEY"], headerName: "x-goog-api-key", environment: environment)
            return ConfiguredProvider(
                id: id,
                baseURL: input.baseURL ?? AIProtocols.Gemini.DEFAULT_BASE_URL,
                auth: auth,
                headers: input.headers ?? [:],
                routes: routes,
                defaultRoute: AIProtocols.Gemini.route,
                defaultProviderOptions: input.providerOptions ?? [:]
            )
        }

        // parity: ai/src/providers/google.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/google.ts#model [status=implemented hash=3f8421fc40e1]
        public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel { configure(settings).model(modelID, route: AIProtocols.Gemini.route) }
        // parity: ai/src/providers/google.ts#imageModel [status=implemented hash=6b232dacc4c7]
        public static func imageModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.GoogleImages.model(.init(id: modelID, provider: id, baseURL: settings.baseURL, providerOptions: settings.providerOptions))
        }
        // parity: ai/src/providers/google.ts#videoModel [status=implemented hash=a5eb00d79b4d]
        public static func videoModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.GoogleInteractionsVideo.model(.init(id: modelID, provider: id, baseURL: settings.baseURL, providerOptions: settings.providerOptions))
        }
        // parity: ai/src/providers/google.ts#embeddingModel [status=implemented hash=c6d9ffa465c5]
        public static func embeddingModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "google-embed-content", baseURL: settings.baseURL ?? AIProtocols.GoogleEmbedContent.DEFAULT_BASE_URL, path: "/models/\(modelID):batchEmbedContents", mode: .inline, providerOptions: settings.providerOptions)
        }
        // parity: ai/src/providers/google.ts#decisionModel [status=implemented hash=7432f6ac602f]
        public static func decisionModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "google-decisions", baseURL: settings.baseURL ?? AIProtocols.GoogleDecisions.DEFAULT_BASE_URL, path: "/models/\(modelID):generateContent", mode: .inline, providerOptions: settings.providerOptions)
        }
        // parity: ai/src/providers/google.ts#image [status=implemented hash=25839c138732]
        public static func image(_ modelID: String) -> AIProtocols.MediaModelHandle { imageModel(modelID) }
        // parity: ai/src/providers/google.ts#video [status=implemented hash=04f893e14126]
        public static func video(_ modelID: String) -> AIProtocols.MediaModelHandle { videoModel(modelID) }
        // parity: ai/src/providers/google.ts#embedding [status=implemented hash=8c37d296d564]
        public static func embedding(_ modelID: String) -> AIProtocols.MediaModelHandle { embeddingModel(modelID) }
        // parity: ai/src/providers/google.ts#gemini [status=implemented hash=96cc2e1107ba]
        public static func gemini(_ modelID: String) -> ConfiguredModel { provider.model(modelID, route: AIProtocols.Gemini.route) }
        // parity: ai/src/providers/google.ts#interactions [status=implemented hash=afa95cabe810]
        public static func interactions(_ modelID: String) -> ConfiguredModel { provider.model(modelID, route: AIProtocols.GoogleInteractions.route) }
        // parity: ai/src/providers/google.ts#speech [status=implemented hash=5cc6042ca4db]
        public static func speech(_ modelID: String) -> AIProtocols.MediaModelHandle { AIProtocols.GoogleSpeech.model(.init(id: modelID, provider: id)) }
        // parity: ai/src/providers/google.ts#transcription [status=implemented hash=287f8a2250f5]
        public static func transcription(_ modelID: String) -> AIProtocols.MediaModelHandle { AIProtocols.GoogleTranscription.model(.init(id: modelID, provider: id)) }
        // parity: ai/src/providers/google.ts#decision [status=implemented hash=e92859a494dc]
        public static func decision(_ modelID: String) -> AIProtocols.MediaModelHandle { decisionModel(modelID) }

        public enum Interactions {
            // parity: ai/src/providers/google/interactions.ts#Settings [status=implemented hash=0ac2a34710e6]
            public typealias Settings = ProviderConfig
            // parity: ai/src/providers/google/interactions.ts#model [status=implemented hash=699523e3fe28]
            public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel {
                configure(settings).model(modelID, route: AIProtocols.GoogleInteractions.route)
            }
        }
    }

    // MARK: - 19. Groq (groq.ts — 9 symbols)

    public enum Groq {
        public static let defaultBaseURL = "https://api.groq.com/openai/v1"
        // parity: ai/src/providers/groq.ts#id [status=implemented hash=02e9c4275855]
        public static let id = "groq"
        // parity: ai/src/providers/groq.ts#ProviderOptions [status=implemented hash=ed95c208df18]
        public struct ProviderOptions: Equatable, Hashable, Sendable {
            public var reasoningEffort: String?
            public var includeReasoning: Bool?
            public var parallelToolCalls: Bool?
            public var serviceTier: String?
            public var user: String?
            public init(reasoningEffort: String? = nil, includeReasoning: Bool? = nil, parallelToolCalls: Bool? = nil, serviceTier: String? = nil, user: String? = nil) {
                self.reasoningEffort = reasoningEffort; self.includeReasoning = includeReasoning
                self.parallelToolCalls = parallelToolCalls; self.serviceTier = serviceTier; self.user = user
            }
        }
        // parity: ai/src/providers/groq.ts#Config [status=implemented hash=f162f7402734]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/groq.ts#Settings [status=implemented hash=a9f0863d35ff]
        public typealias Settings = ProviderConfig
        // parity: ai/src/providers/groq.ts#protocol [status=implemented hash=8c05f27a22c3]
        public static let `protocol` = AIProtocols.ChatProtocolSpec(
            id: "groq-chat", framing: .sseWithDone,
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                var body = try AIProtocols.OpenAIChat.fromRequest(req)
                let gptOSS = req.model.id.hasPrefix("openai/gpt-oss-")
                if !gptOSS { body["reasoning_format"] = .string("parsed") }
                else if let inc = req.providerOptions?["includeReasoning"] { body["include_reasoning"] = inc }
                if let user = req.providerOptions?["user"] { body["user"] = user }
                return body
            },
            parseStream: AIProtocols.OpenAIChat.parseSSEStream
        )
        // parity: ai/src/providers/groq.ts#route [status=implemented hash=85482bd2cc0a]
        public static let route = AIProtocols.ChatRouteSpec(id: "groq-chat", provider: id, providerMetadataKey: id, protocol: `protocol`, defaultBaseURL: defaultBaseURL, path: "/chat/completions")
        // parity: ai/src/providers/groq.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? defaultBaseURL, auth: resolveBearerAuth(config: input, envVars: ["GROQ_API_KEY"], environment: environment), headers: input.headers ?? [:], routes: [route], defaultRoute: route, defaultProviderOptions: input.providerOptions ?? [:], defaultCompatibility: .init(reasoningField: "reasoning", requireReasoning: false, maxTokensField: "max_completion_tokens"), defaultCapabilities: .init(strictTools: false))
        }
        // parity: ai/src/providers/groq.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/groq.ts#model [status=implemented hash=47f0128310dc]
        public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel { configure(settings).model(modelID) }
    }

    // MARK: - 20. Meta (meta.ts — 21 symbols)

    public enum Meta {
        public static let defaultBaseURL = "https://api.meta.ai/v1"
        // parity: ai/src/providers/meta.ts#id [status=implemented hash=076eb252a9b6]
        public static let id = "meta"
        // parity: ai/src/providers/meta.ts#ProviderOptionsInput [status=implemented hash=eb925919a6f6]
        public typealias ProviderOptionsInput = [String: JSONValue]
        // parity: ai/src/providers/meta.ts#MessagesOptionsInput [status=implemented hash=01cdd58737df]
        public typealias MessagesOptionsInput = [String: JSONValue]
        // parity: ai/src/providers/meta.ts#ImageOptions [status=implemented hash=ca8a3afea9bb]
        public typealias ImageOptions = AIProtocols.MetaImages.ImageOptions

        // parity: ai/src/providers/meta.ts#WebSearchOptions [status=implemented hash=31849b5b9b05]
        public struct WebSearchOptions: Equatable, Hashable, Sendable {
            public var searchContextSize: String?
            public var city: String?
            public var region: String?
            public var country: String?
            public var timezone: String?
            public init(searchContextSize: String? = nil, city: String? = nil, region: String? = nil, country: String? = nil, timezone: String? = nil) {
                self.searchContextSize = searchContextSize; self.city = city; self.region = region; self.country = country; self.timezone = timezone
            }
        }

        // parity: ai/src/providers/meta.ts#webSearch [status=implemented hash=fae59c0ab74f]
        public static func webSearch(_ options: WebSearchOptions = WebSearchOptions()) -> AIProtocolUtils.ToolDefinition {
            var metaObj: [String: JSONValue] = ["type": .string("web_search")]
            if let s = options.searchContextSize { metaObj["search_context_size"] = .string(s) }
            if options.city != nil || options.region != nil || options.country != nil || options.timezone != nil {
                var loc: [String: JSONValue] = ["type": .string("approximate")]
                if let c = options.city { loc["city"] = .string(c) }
                if let r = options.region { loc["region"] = .string(r) }
                if let co = options.country { loc["country"] = .string(co) }
                if let tz = options.timezone { loc["timezone"] = .string(tz) }
                metaObj["user_location"] = .object(loc)
            }
            return AIProtocolUtils.ToolDefinition(
                name: "web_search",
                description: "Search the web with Meta's hosted search tool.",
                inputSchema: ["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)],
                native: ["meta": .object(metaObj)]
            )
        }

        // parity: ai/src/providers/meta.ts#ImageGenerationOptions [status=implemented hash=84f4b110efde]
        public struct ImageGenerationOptions: Equatable, Hashable, Sendable {
            public var size: String?
            public var outputFormat: String?
            public var reasoningStrength: String?
            public var enableImageSearch: Bool?
            public var enableWebSearch: Bool?
            public var enableShell: Bool?
            public init(size: String? = nil, outputFormat: String? = nil, reasoningStrength: String? = nil, enableImageSearch: Bool? = nil, enableWebSearch: Bool? = nil, enableShell: Bool? = nil) {
                self.size = size; self.outputFormat = outputFormat; self.reasoningStrength = reasoningStrength
                self.enableImageSearch = enableImageSearch; self.enableWebSearch = enableWebSearch; self.enableShell = enableShell
            }
        }

        // parity: ai/src/providers/meta.ts#imageGeneration [status=implemented hash=f4ef433de101]
        public static func imageGeneration(_ options: ImageGenerationOptions = ImageGenerationOptions()) -> AIProtocolUtils.ToolDefinition {
            var metaObj: [String: JSONValue] = ["type": .string("image_generation")]
            if let s = options.size { metaObj["size"] = .string(s) }
            if let f = options.outputFormat { metaObj["output_format"] = .string(f) }
            if let r = options.reasoningStrength { metaObj["reasoning_strength"] = .string(r) }
            if let v = options.enableImageSearch { metaObj["enable_image_search"] = .bool(v) }
            if let v = options.enableWebSearch { metaObj["enable_web_search"] = .bool(v) }
            if let v = options.enableShell { metaObj["enable_shell"] = .bool(v) }
            return AIProtocolUtils.ToolDefinition(
                name: "image_generation",
                description: "Generate or edit an image with Muse Image.",
                inputSchema: ["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)],
                native: ["meta": .object(metaObj)]
            )
        }

        // parity: ai/src/providers/meta.ts#Config [status=implemented hash=261fb466307a]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/meta.ts#Settings [status=implemented hash=b28e11f4b908]
        public typealias Settings = ProviderConfig

        public static let responsesRoute = AIProtocols.ChatRouteSpec(id: "meta-responses", provider: id, providerMetadataKey: id, protocol: AIProtocols.MetaResponses.`protocol`, defaultBaseURL: defaultBaseURL, path: "/responses", defaultProviderOptions: ["store": .bool(false), "include": .array([.string("reasoning.encrypted_content")])])
        public static let chatRoute = AIProtocols.ChatRouteSpec(id: "meta-chat", provider: id, providerMetadataKey: id, protocol: AIProtocols.OpenAIChat.`protocol`, defaultBaseURL: defaultBaseURL, path: "/chat/completions")
        public static let messagesRoute = AIProtocols.ChatRouteSpec(id: "meta-messages", provider: id, providerMetadataKey: id, protocol: AIProtocols.MetaMessages.`protocol`, defaultBaseURL: defaultBaseURL, path: "/messages", defaultProviderOptions: ["thinking": .object(["type": .string("adaptive"), "display": .string("omitted")])])

        // parity: ai/src/providers/meta.ts#routes [status=implemented hash=507b1ad0c8b2]
        public static let routes: [AIProtocols.ChatRouteSpec] = [responsesRoute, chatRoute, messagesRoute]
        // parity: ai/src/providers/meta.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? defaultBaseURL, auth: resolveBearerAuth(config: input, envVars: ["META_API_KEY"], environment: environment), headers: input.headers ?? [:], routes: routes, defaultRoute: responsesRoute, defaultProviderOptions: input.providerOptions ?? [:])
        }
        // parity: ai/src/providers/meta.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/meta.ts#responses [status=implemented hash=8ec09f32a8ac]
        public static func responses(_ modelID: String) -> ConfiguredModel { provider.model(modelID, route: responsesRoute) }
        // parity: ai/src/providers/meta.ts#chat [status=implemented hash=c527949cbec3]
        public static func chat(_ modelID: String) -> ConfiguredModel { provider.model(modelID, route: chatRoute) }
        // parity: ai/src/providers/meta.ts#messages [status=implemented hash=bfa381d2428b]
        public static func messages(_ modelID: String) -> ConfiguredModel { provider.model(modelID, route: messagesRoute) }
        // parity: ai/src/providers/meta.ts#image [status=implemented hash=25839c138732]
        public static func image(_ modelID: String) -> AIProtocols.MediaModelHandle { AIProtocols.MetaImages.model(.init(id: modelID, provider: id)) }
        // parity: ai/src/providers/meta.ts#model [status=implemented hash=8fc15416d5f8]
        public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel { configure(settings).model(modelID, route: responsesRoute) }
        // parity: ai/src/providers/meta.ts#chatModel [status=implemented hash=6f3c43c7a644]
        public static func chatModel(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel { configure(settings).model(modelID, route: chatRoute) }
        // parity: ai/src/providers/meta.ts#messagesModel [status=implemented hash=d8f5bbff7ef2]
        public static func messagesModel(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel { configure(settings).model(modelID, route: messagesRoute) }
        // parity: ai/src/providers/meta.ts#imageModel [status=implemented hash=138fac784778]
        public static func imageModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.MetaImages.model(.init(id: modelID, provider: id, baseURL: settings.baseURL, providerOptions: settings.providerOptions))
        }
    }

    // MARK: - 21. MiniMax (minimax.ts + 4 subfiles — 13 symbols)

    public enum MiniMax {
        public static let defaultBaseURL = "https://api.minimax.io/v1"
        public static let anthropicBaseURL = "https://api.minimax.io/anthropic/v1"
        // parity: ai/src/providers/minimax.ts#id [status=implemented hash=7e188d671389]
        public static let id = "minimax"
        // parity: ai/src/providers/minimax.ts#MessagesOptionsInput [status=implemented hash=9769350ecab7]
        public typealias MessagesOptionsInput = AIProtocols.AnthropicMessages.OptionsInput
        // parity: ai/src/providers/minimax.ts#ChatOptionsInput [status=implemented hash=db9240508aa6]
        public typealias ChatOptionsInput = [String: JSONValue]
        // parity: ai/src/providers/minimax.ts#ResponsesOptionsInput [status=implemented hash=2eb12bdc0055]
        public typealias ResponsesOptionsInput = [String: JSONValue]
        // parity: ai/src/providers/minimax.ts#ProviderOptionsInput [status=implemented hash=6ecbdb337858]
        public typealias ProviderOptionsInput = [String: JSONValue]
        // parity: ai/src/providers/minimax.ts#Config [status=implemented hash=a5dd90dee917]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/minimax.ts#Settings [status=implemented hash=362613596def]
        public typealias Settings = ProviderConfig

        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? anthropicBaseURL, auth: resolveBearerAuth(config: input, envVars: ["MINIMAX_API_KEY"], environment: environment), headers: input.headers ?? ["anthropic-version": "2023-06-01"], routes: [AIProtocols.AnthropicMessages.route, AIProtocols.OpenAIChat.route, AIProtocols.OpenResponses.`protocol`.id == "open-responses" ? AIProtocols.OpenAICompatibleResponses.route : AIProtocols.OpenAIChat.route], defaultRoute: AIProtocols.AnthropicMessages.route)
        }

        public enum Chat {
            // parity: ai/src/providers/minimax/chat.ts#Settings [status=implemented hash=375593a2577f]
            public typealias Settings = ProviderConfig
            // parity: ai/src/providers/minimax/chat.ts#model [status=implemented hash=db1a0fa5fe76]
            public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel {
                var adjusted = settings
                if adjusted.baseURL == nil { adjusted.baseURL = defaultBaseURL }
                return configure(adjusted).model(modelID, route: AIProtocols.OpenAIChat.route)
            }
        }

        public enum Images {
            // parity: ai/src/providers/minimax/images.ts#Settings [status=implemented hash=d79eda829b52]
            public typealias Settings = ProviderConfig
        }

        public enum Responses {
            // parity: ai/src/providers/minimax/responses.ts#Settings [status=implemented hash=a6a4268d415b]
            public typealias Settings = ProviderConfig
            // parity: ai/src/providers/minimax/responses.ts#model [status=implemented hash=1e02e9c8fad6]
            public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel {
                var adjusted = settings
                if adjusted.baseURL == nil { adjusted.baseURL = defaultBaseURL }
                return configure(adjusted).model(modelID, route: AIProtocols.OpenAICompatibleResponses.route)
            }
        }

        public enum Videos {
            // parity: ai/src/providers/minimax/videos.ts#Settings [status=implemented hash=e0f91ab66586]
            public typealias Settings = ProviderConfig
        }
    }

    // MARK: - 22. Mistral & Moonshot (20 symbols)

    public enum Mistral {
        // parity: ai/src/providers/mistral.ts#id [status=implemented hash=f16794f090c7]
        public static let id = "mistral"
        // parity: ai/src/providers/mistral.ts#ProviderOptions [status=implemented hash=e7a31d8b2e64]
        public typealias ProviderOptions = AIProtocols.MistralChat.ProviderOptionsInput
        // parity: ai/src/providers/mistral.ts#Config [status=implemented hash=f162f7402734]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/mistral.ts#Settings [status=implemented hash=a9f0863d35ff]
        public typealias Settings = ProviderConfig
        // parity: ai/src/providers/mistral.ts#route [status=implemented hash=2f4f180da857]
        public static let route = AIProtocols.MistralChat.route
        // parity: ai/src/providers/mistral.ts#routes [status=implemented hash=d8efbd745746]
        public static let routes: [AIProtocols.ChatRouteSpec] = [route]
        // parity: ai/src/providers/mistral.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? AIProtocols.MistralChat.DEFAULT_BASE_URL, auth: resolveBearerAuth(config: input, envVars: ["MISTRAL_API_KEY"], environment: environment), headers: input.headers ?? [:], routes: routes, defaultRoute: route, defaultProviderOptions: input.providerOptions ?? [:])
        }
        // parity: ai/src/providers/mistral.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/mistral.ts#model [status=implemented hash=47f0128310dc]
        public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel { configure(settings).model(modelID) }
    }

    public enum Moonshot {
        public static let defaultBaseURL = "https://api.moonshot.ai/v1"
        public static let anthropicBaseURL = "https://api.moonshot.ai/anthropic/v1"
        // parity: ai/src/providers/moonshot.ts#id [status=implemented hash=763ab26d3fb6]
        public static let id = "moonshotai"
        // parity: ai/src/providers/moonshot.ts#ReasoningEffort [status=implemented hash=4d3a67487f7e]
        public typealias ReasoningEffort = String
        // parity: ai/src/providers/moonshot.ts#ChatOptionsInput [status=implemented hash=810bd7950dc8]
        public typealias ChatOptionsInput = [String: JSONValue]
        // parity: ai/src/providers/moonshot.ts#MessagesOptionsInput [status=implemented hash=0b535c1dff49]
        public typealias MessagesOptionsInput = [String: JSONValue]
        // parity: ai/src/providers/moonshot.ts#ResponsesOptionsInput [status=implemented hash=348a3f696fda]
        public typealias ResponsesOptionsInput = [String: JSONValue]
        // parity: ai/src/providers/moonshot.ts#Config [status=implemented hash=c6636ff1f0a4]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/moonshot.ts#Settings [status=implemented hash=3996ed9f51d2]
        public typealias Settings = ProviderConfig

        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? defaultBaseURL, auth: resolveBearerAuth(config: input, envVars: ["MOONSHOT_API_KEY", "MOONSHOTAI_API_KEY"], environment: environment), headers: input.headers ?? [:], routes: [AIProtocols.OpenAIChat.route], defaultRoute: AIProtocols.OpenAIChat.route)
        }

        public enum Messages {
            // parity: ai/src/providers/moonshot/messages.ts#Settings [status=implemented hash=37b7ea0fbd1c]
            public typealias Settings = ProviderConfig
            // parity: ai/src/providers/moonshot/messages.ts#model [status=implemented hash=d417b0985a8a]
            public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel {
                var adjusted = settings
                if adjusted.baseURL == nil { adjusted.baseURL = anthropicBaseURL }
                return configure(adjusted).model(modelID, route: AIProtocols.AnthropicMessages.route)
            }
        }

        public enum Responses {
            // parity: ai/src/providers/moonshot/responses.ts#Settings [status=implemented hash=06836650b2a6]
            public typealias Settings = ProviderConfig
            // parity: ai/src/providers/moonshot/responses.ts#model [status=implemented hash=62aa655eb2c5]
            public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel {
                configure(settings).model(modelID, route: AIProtocols.OpenAICompatibleResponses.route)
            }
        }
    }

    // MARK: - 23. OpenResponsesOptionsFacade, OpenAIOptions, OpenAICompatible*, OpenAI, OpenCode (53 symbols)

    public enum OpenResponsesOptionsFacade {
        // parity: ai/src/providers/open-responses-options.ts#OpenResponsesOptionsInput [status=implemented hash=c72333fa4fd5]
        public typealias OpenResponsesOptionsInput = AIProtocolUtils.OpenResponsesOptions.Options
        // parity: ai/src/providers/open-responses-options.ts#OpenResponsesProviderOptionsInput [status=implemented hash=b5ed2d4e5fa6]
        public typealias OpenResponsesProviderOptionsInput = OpenResponsesOptionsInput
    }

    public enum OpenAIOptions {
        // parity: ai/src/providers/openai-options.ts#OpenAIResponseIncludable [status=implemented hash=1fc7424e9b0e]
        public typealias OpenAIResponseIncludable = AIProtocolUtils.OpenResponsesOptions.ResponseIncludable
        // parity: ai/src/providers/openai-options.ts#OpenAIServiceTier [status=implemented hash=e3ceb8baf8c4]
        public typealias OpenAIServiceTier = String
        // parity: ai/src/providers/openai-options.ts#OpenAIOptionsInput [status=implemented hash=67fef60b8fa5]
        public typealias OpenAIOptionsInput = [String: JSONValue]
        // parity: ai/src/providers/openai-options.ts#OpenAIProviderOptionsInput [status=implemented hash=6dce1af1126d]
        public typealias OpenAIProviderOptionsInput = OpenAIOptionsInput

        // parity: ai/src/providers/openai-options.ts#gpt5DefaultOptions [status=implemented hash=7c6fac66fbeb]
        public static func gpt5DefaultOptions(_ modelID: String) -> [String: JSONValue]? {
            let id = modelID.lowercased()
            guard id.contains("gpt-5"), !id.contains("gpt-5-chat"), !id.contains("gpt-5-pro") else { return nil }
            return [
                "reasoningEffort": .string("medium"),
                "reasoningSummary": .string("auto"),
                "include": .array([.string("reasoning.encrypted_content")]),
            ]
        }

        // parity: ai/src/providers/openai-options.ts#openAIDefaultOptions [status=implemented hash=d5be06c8ddd6]
        public static func openAIDefaultOptions(_ modelID: String) -> [String: JSONValue] {
            AIProtocolUtils.JSONCodec.mergeObjects(["store": .bool(false)], gpt5DefaultOptions(modelID))
        }

        // parity: ai/src/providers/openai-options.ts#withOpenAIOptions [status=implemented hash=82d3febff914]
        public static func withOpenAIOptions(_ modelID: String, providerOptions: [String: JSONValue]?) -> [String: JSONValue] {
            AIProtocolUtils.JSONCodec.mergeObjects(openAIDefaultOptions(modelID), providerOptions)
        }
    }

    public enum OpenAICompatibleResponses {
        // parity: ai/src/providers/openai-compatible-responses.ts#id [status=implemented hash=c6e007a4a6b9]
        public static let id = "openai-compatible"
        // parity: ai/src/providers/openai-compatible-responses.ts#Config [status=implemented hash=8c931b93ba7e]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/openai-compatible-responses.ts#Settings [status=implemented hash=d009f0aef57e]
        public typealias Settings = ProviderConfig
        // parity: ai/src/providers/openai-compatible-responses.ts#routes [status=implemented hash=57698b9e93ee]
        public static let routes: [AIProtocols.ChatRouteSpec] = [AIProtocols.OpenAICompatibleResponses.route]
        // parity: ai/src/providers/openai-compatible-responses.ts#configure [status=implemented hash=d06fa5fb7a62]
        public static func configure(_ input: Config) -> ConfiguredProvider {
            let prov = input.providerOverride ?? id
            return ConfiguredProvider(id: prov, baseURL: input.baseURL, auth: resolveBearerAuth(config: input, envVars: []), headers: input.headers ?? [:], routes: routes, defaultRoute: AIProtocols.OpenAICompatibleResponses.route, defaultProviderOptions: input.providerOptions ?? [:])
        }
        // parity: ai/src/providers/openai-compatible-responses.ts#provider [status=implemented hash=ce1b6df0aba2]
        public static let provider = (id: id, routes: routes)
        // parity: ai/src/providers/openai-compatible-responses.ts#model [status=implemented hash=e4effa641a9a]
        public static func model(_ modelID: String, settings: Settings) -> ConfiguredModel { configure(settings).model(modelID) }
    }

    public enum OpenAICompatible {
        // parity: ai/src/providers/openai-compatible.ts#id [status=implemented hash=c6e007a4a6b9]
        public static let id = "openai-compatible"
        // parity: ai/src/providers/openai-compatible.ts#Config [status=implemented hash=4da9e29ed365]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/openai-compatible.ts#Settings [status=implemented hash=96d6b5417de0]
        public typealias Settings = ProviderConfig
        // parity: ai/src/providers/openai-compatible.ts#routes [status=implemented hash=eaf422a231de]
        public static let routes: [AIProtocols.ChatRouteSpec] = [AIProtocols.OpenAICompatibleChat.route]
        // parity: ai/src/providers/openai-compatible.ts#configure [status=implemented hash=dde98d7ae799]
        public static func configure(_ input: Config) -> ConfiguredProvider {
            let prov = input.providerOverride ?? id
            return ConfiguredProvider(id: prov, baseURL: input.baseURL, auth: resolveBearerAuth(config: input, envVars: []), headers: input.headers ?? [:], routes: routes, defaultRoute: AIProtocols.OpenAICompatibleChat.route, defaultProviderOptions: input.providerOptions ?? [:])
        }
        // parity: ai/src/providers/openai-compatible.ts#provider [status=implemented hash=ce1b6df0aba2]
        public static let provider = (id: id, routes: routes)
        // parity: ai/src/providers/openai-compatible.ts#model [status=implemented hash=61635358c550]
        public static func model(_ modelID: String, settings: Settings) -> ConfiguredModel { configure(settings).model(modelID) }
        // parity: ai/src/providers/openai-compatible.ts#imageModel [status=implemented hash=8435b8056403]
        public static func imageModel(_ modelID: String, settings: Settings) -> AIProtocols.MediaModelHandle {
            AIProtocols.OpenAIImages.model(.init(id: modelID, provider: settings.providerOverride ?? id, baseURL: settings.baseURL, providerOptions: settings.providerOptions))
        }
        // parity: ai/src/providers/openai-compatible.ts#embeddingModel [status=implemented hash=653fe90141a8]
        public static func embeddingModel(_ modelID: String, settings: Settings) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: settings.providerOverride ?? id, protocolID: "openai-embeddings", baseURL: settings.baseURL, path: AIProtocols.OpenAIEmbeddings.PATH, mode: .inline, providerOptions: settings.providerOptions)
        }
        // parity: ai/src/providers/openai-compatible.ts#decisionModel [status=implemented hash=88cf044213fb]
        public static func decisionModel(_ modelID: String, settings: Settings) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: settings.providerOverride ?? id, protocolID: "system-one", baseURL: settings.baseURL, path: AIProtocols.SystemOneProtocol.DEFAULT_PATH, mode: .inline, providerOptions: settings.providerOptions)
        }
    }

    public enum OpenAI {
        // parity: ai/src/providers/openai.ts#id [status=implemented hash=ced84e8dd00f]
        public static let id = "openai"
        // parity: ai/src/providers/openai.ts#routes [status=implemented hash=a590d46296eb]
        public static let routes: [AIProtocols.ChatRouteSpec] = [AIProtocols.OpenAIResponses.route, AIProtocols.OpenAIChat.route]
        // parity: ai/src/providers/openai.ts#Config [status=implemented hash=cbe3e09ab380]
        public typealias Config = ProviderConfig

        // parity: ai/src/providers/openai.ts#ImageGenerationOptions [status=implemented hash=9e1f8d619dee]
        public struct ImageGenerationOptions: Equatable, Hashable, Sendable {
            public var action: String?
            public var background: String?
            public var inputFidelity: String?
            public var outputCompression: Int?
            public var outputFormat: String?
            public var partialImages: Int?
            public var quality: String?
            public var size: String?
            public init(action: String? = nil, background: String? = nil, inputFidelity: String? = nil, outputCompression: Int? = nil, outputFormat: String? = nil, partialImages: Int? = nil, quality: String? = nil, size: String? = nil) {
                self.action = action; self.background = background; self.inputFidelity = inputFidelity
                self.outputCompression = outputCompression; self.outputFormat = outputFormat
                self.partialImages = partialImages; self.quality = quality; self.size = size
            }
        }

        // parity: ai/src/providers/openai.ts#imageGeneration [status=implemented hash=f4ef433de101]
        public static func imageGeneration(_ options: ImageGenerationOptions = ImageGenerationOptions()) -> AIProtocolUtils.ToolDefinition {
            var spec: [String: JSONValue] = ["type": .string("image_generation")]
            if let v = options.action { spec["action"] = .string(v) }
            if let v = options.background { spec["background"] = .string(v) }
            if let v = options.inputFidelity { spec["input_fidelity"] = .string(v) }
            if let v = options.outputCompression { spec["output_compression"] = .int(Int64(v)) }
            if let v = options.outputFormat { spec["output_format"] = .string(v) }
            if let v = options.partialImages { spec["partial_images"] = .int(Int64(v)) }
            if let v = options.quality { spec["quality"] = .string(v) }
            if let v = options.size { spec["size"] = .string(v) }
            return AIProtocolUtils.ToolDefinition(
                name: "image_generation",
                description: "Generate or edit an image using OpenAI's hosted image generation tool.",
                inputSchema: ["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)],
                native: ["openai": .object(spec)]
            )
        }

        // parity: ai/src/providers/openai.ts#Settings [status=implemented hash=9421cacd9954]
        public typealias Settings = ProviderConfig

        // parity: ai/src/providers/openai.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            var hdrs: [String: String] = [:]
            if let org = input.organization { hdrs["OpenAI-Organization"] = org }
            if let proj = input.project { hdrs["OpenAI-Project"] = proj }
            if let given = input.headers { for (k, v) in given { hdrs[k] = v } }
            return ConfiguredProvider(
                id: id,
                baseURL: input.baseURL ?? AIProtocols.OpenAIResponses.DEFAULT_BASE_URL,
                auth: resolveBearerAuth(config: input, envVars: ["OPENAI_API_KEY"], environment: environment),
                headers: hdrs,
                routes: routes,
                defaultRoute: AIProtocols.OpenAIResponses.route,
                defaultProviderOptions: input.providerOptions ?? [:]
            )
        }

        // parity: ai/src/providers/openai.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/openai.ts#model [status=implemented hash=c22c4a05ede2]
        public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel {
            configure(settings).model(modelID, route: AIProtocols.OpenAIResponses.route, providerOptions: OpenAIOptions.withOpenAIOptions(modelID, providerOptions: settings.providerOptions))
        }
        // parity: ai/src/providers/openai.ts#chatModel [status=implemented hash=fa477414f442]
        public static func chatModel(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel {
            configure(settings).model(modelID, route: AIProtocols.OpenAIChat.route, capabilities: .init(promptCacheKey: true), providerOptions: OpenAIOptions.withOpenAIOptions(modelID, providerOptions: settings.providerOptions))
        }
        // parity: ai/src/providers/openai.ts#imageModel [status=implemented hash=2f7c46a66434]
        public static func imageModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            let inputMode: AIProtocols.OpenAIImages.OpenAIImageInput = (settings.baseURL?.hasPrefix("https://chatgpt.com/") == true) ? .jsonEdits : .edits
            return AIProtocols.OpenAIImages.model(.init(id: modelID, provider: id, baseURL: settings.baseURL, providerOptions: settings.providerOptions), imageInput: inputMode)
        }
        // parity: ai/src/providers/openai.ts#decisionModel [status=implemented hash=0d3ba148cd1b]
        public static func decisionModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "openai-decisions", baseURL: settings.baseURL ?? AIProtocols.OpenAIDecisions.DEFAULT_BASE_URL, path: AIProtocols.OpenAIDecisions.PATH, mode: .inline, providerOptions: settings.providerOptions)
        }
        // parity: ai/src/providers/openai.ts#embeddingModel [status=implemented hash=351167581585]
        public static func embeddingModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "openai-embeddings", baseURL: settings.baseURL ?? AIProtocols.OpenAIEmbeddings.DEFAULT_BASE_URL, path: AIProtocols.OpenAIEmbeddings.PATH, mode: .inline, providerOptions: settings.providerOptions)
        }
        // parity: ai/src/providers/openai.ts#responses [status=implemented hash=8ec09f32a8ac]
        public static func responses(_ modelID: String) -> ConfiguredModel { model(modelID) }
        // parity: ai/src/providers/openai.ts#chat [status=implemented hash=c527949cbec3]
        public static func chat(_ modelID: String) -> ConfiguredModel { chatModel(modelID) }
        // parity: ai/src/providers/openai.ts#image [status=implemented hash=25839c138732]
        public static func image(_ modelID: String) -> AIProtocols.MediaModelHandle { imageModel(modelID) }
        // parity: ai/src/providers/openai.ts#speech [status=implemented hash=5cc6042ca4db]
        public static func speech(_ modelID: String) -> AIProtocols.MediaModelHandle { AIProtocols.OpenAISpeech.model(.init(id: modelID, provider: id)) }
        // parity: ai/src/providers/openai.ts#transcription [status=implemented hash=287f8a2250f5]
        public static func transcription(_ modelID: String) -> AIProtocols.MediaModelHandle { AIProtocols.OpenAITranscription.model(.init(id: modelID, provider: id)) }
        // parity: ai/src/providers/openai.ts#decision [status=implemented hash=e92859a494dc]
        public static func decision(_ modelID: String) -> AIProtocols.MediaModelHandle { decisionModel(modelID) }
        // parity: ai/src/providers/openai.ts#embedding [status=implemented hash=8c37d296d564]
        public static func embedding(_ modelID: String) -> AIProtocols.MediaModelHandle { embeddingModel(modelID) }
    }

    public enum OpenCode {
        public static let defaultBaseURL = "https://opencode.ai/inference/systemone/v1"
        // parity: ai/src/providers/opencode.ts#id [status=implemented hash=e319d996cf4e]
        public static let id = "opencode"
        // parity: ai/src/providers/opencode.ts#Config [status=implemented hash=e2282dcfffaf]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/opencode.ts#Settings [status=implemented hash=2ea0351d9bdd]
        public typealias Settings = ProviderConfig
        // parity: ai/src/providers/opencode.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? defaultBaseURL, auth: resolveBearerAuth(config: input, envVars: ["OPENCODE_API_KEY"], environment: environment), headers: input.headers ?? [:])
        }
        // parity: ai/src/providers/opencode.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/opencode.ts#decision [status=implemented hash=e92859a494dc]
        public static func decision(_ modelID: String) -> AIProtocols.MediaModelHandle { decisionModel(modelID) }
        // parity: ai/src/providers/opencode.ts#decisionModel [status=implemented hash=7432f6ac602f]
        public static func decisionModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "system-one", baseURL: settings.baseURL ?? defaultBaseURL, path: AIProtocols.SystemOneProtocol.DEFAULT_PATH, mode: .inline, providerOptions: settings.providerOptions)
        }
    }

    // MARK: - 24. ProviderSettings (settings.ts — 2 symbols)

    public enum ProviderSettings {
        // parity: ai/src/providers/settings.ts#toConfig [status=implemented hash=0d0d5977dadc]
        public static func toConfig(_ settings: ProviderConfig = ProviderConfig()) -> ProviderConfig {
            settings
        }

        public struct BearerRouteDefaults: Sendable {
            public let baseURL: String?
            public let auth: AIProtocolUtils.AuthStrategy
            public let headers: [String: String]?
            public let providerOptions: [String: JSONValue]?

            public init(baseURL: String?, auth: AIProtocolUtils.AuthStrategy, headers: [String: String]? = nil, providerOptions: [String: JSONValue]? = nil) {
                self.baseURL = baseURL; self.auth = auth; self.headers = headers; self.providerOptions = providerOptions
            }
        }

        // parity: ai/src/providers/settings.ts#bearerRouteDefaults [status=implemented hash=eb65782535c5]
        public static func bearerRouteDefaults(
            _ input: ProviderConfig,
            envVars: [String],
            baseURL: String? = nil,
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) -> BearerRouteDefaults {
            BearerRouteDefaults(
                baseURL: input.baseURL ?? baseURL,
                auth: resolveBearerAuth(config: input, envVars: envVars, environment: environment),
                headers: input.headers,
                providerOptions: input.providerOptions
            )
        }
    }

    // MARK: - 25. OpenRouter (openrouter.ts, openrouter/responses.ts — 29 symbols)

    public enum OpenRouter {
        public static let defaultBaseURL = "https://openrouter.ai/api/v1"

        // parity: ai/src/providers/openrouter.ts#id [status=implemented hash=78e687ee698e]
        public static let id = "openrouter"

        // parity: ai/src/providers/openrouter.ts#OpenRouterProviderRouting [status=implemented hash=e4c76524991c]
        public struct OpenRouterProviderRouting: Equatable, Hashable, Sendable, Codable {
            public var order: [String]?
            public var allowFallbacks: Bool?
            public var requireParameters: Bool?
            public var dataCollection: String?
            public var only: [String]?
            public var ignore: [String]?
            public var quantizations: [String]?
            public var sort: String?
            public var zdr: Bool?
            public init(order: [String]? = nil, allowFallbacks: Bool? = nil, requireParameters: Bool? = nil, dataCollection: String? = nil, only: [String]? = nil, ignore: [String]? = nil, quantizations: [String]? = nil, sort: String? = nil, zdr: Bool? = nil) {
                self.order = order; self.allowFallbacks = allowFallbacks; self.requireParameters = requireParameters
                self.dataCollection = dataCollection; self.only = only; self.ignore = ignore
                self.quantizations = quantizations; self.sort = sort; self.zdr = zdr
            }
        }

        // parity: ai/src/providers/openrouter.ts#OpenRouterPlugin [status=implemented hash=8be1f61e5f42]
        public struct OpenRouterPlugin: Equatable, Hashable, Sendable {
            public let id: String
            public let options: [String: JSONValue]
            public init(id: String, options: [String: JSONValue] = [:]) { self.id = id; self.options = options }
        }

        // parity: ai/src/providers/openrouter.ts#OpenRouterOptions [status=implemented hash=1472219e2e08]
        public struct OpenRouterOptions: Equatable, Hashable, Sendable {
            public var models: [String]?
            public var plugins: [OpenRouterPlugin]?
            public var provider: OpenRouterProviderRouting?
            public var user: String?
            public var includeUsage: Bool?
            public init(models: [String]? = nil, plugins: [OpenRouterPlugin]? = nil, provider: OpenRouterProviderRouting? = nil, user: String? = nil, includeUsage: Bool? = nil) {
                self.models = models; self.plugins = plugins; self.provider = provider; self.user = user; self.includeUsage = includeUsage
            }
        }

        // parity: ai/src/providers/openrouter.ts#OpenRouterProviderOptionsInput [status=implemented hash=227bcf6a59e9]
        public typealias OpenRouterProviderOptionsInput = OpenRouterOptions
        // parity: ai/src/providers/openrouter.ts#OpenRouterResponsesProviderOptionsInput [status=implemented hash=5cec46fae19b]
        public typealias OpenRouterResponsesProviderOptionsInput = [String: JSONValue]

        // parity: ai/src/providers/openrouter.ts#OpenRouterDecisionOptions [status=implemented hash=4bd3905433a5]
        public struct OpenRouterDecisionOptions: Equatable, Hashable, Sendable {
            public var provider: OpenRouterProviderRouting?
            public var sessionID: String?
            public var user: String?
            public init(provider: OpenRouterProviderRouting? = nil, sessionID: String? = nil, user: String? = nil) {
                self.provider = provider; self.sessionID = sessionID; self.user = user
            }
        }

        // parity: ai/src/providers/openrouter.ts#OpenRouterEmbeddingOptions [status=implemented hash=3dfa352e81aa]
        public struct OpenRouterEmbeddingOptions: Equatable, Hashable, Sendable {
            public var provider: OpenRouterProviderRouting?
            public var user: String?
            public init(provider: OpenRouterProviderRouting? = nil, user: String? = nil) {
                self.provider = provider; self.user = user
            }
        }

        // parity: ai/src/providers/openrouter.ts#Config [status=implemented hash=517f54c3791d]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/openrouter.ts#Settings [status=implemented hash=0235412fd7e4]
        public typealias Settings = ProviderConfig
        // parity: ai/src/providers/openrouter.ts#OpenRouterBody [status=implemented hash=31bfd990dfae]
        public typealias OpenRouterBody = [String: JSONValue]

        // parity: ai/src/providers/openrouter.ts#protocol [status=implemented hash=d42911dfde3b]
        public static let `protocol` = AIProtocols.ChatProtocolSpec(
            id: "openrouter-chat", framing: .sseWithDone,
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                var body = try AIProtocols.OpenAIChat.fromRequest(req, useCacheControl: true)
                let opts = req.providerOptions ?? [:]
                if opts["usage"] == nil {
                    body["usage"] = .object(["include": .bool(true)])
                } else if case .bool(let b) = opts["usage"] {
                    body["usage"] = .object(["include": .bool(b)])
                } else if let u = opts["usage"] {
                    body["usage"] = u
                }
                for key in ["models", "provider", "plugins", "debug", "user", "web_search_options"] {
                    if let val = opts[key] { body[key] = val }
                }
                if let r = AIProtocolUtils.JSONCodec.objectValue(opts["reasoning"]) {
                    var fitted = r
                    if let maxT = AIProtocolUtils.JSONCodec.intValue(r["max_tokens"]) {
                        fitted["max_tokens"] = .int(Int64(AIProtocolUtils.ProviderShared.fitThinkingBudget(maxT, maxTokens: req.maxTokens, minimum: 1_024)))
                    }
                    body["reasoning"] = .object(fitted)
                }
                return body
            },
            parseStream: AIProtocols.OpenAIChat.parseSSEStream
        )

        // parity: ai/src/providers/openrouter.ts#route [status=implemented hash=cd9c33d5b1c2]
        public static let route = AIProtocols.ChatRouteSpec(id: id, provider: id, providerMetadataKey: id, protocol: `protocol`, defaultBaseURL: defaultBaseURL, path: "/chat/completions")
        public static let responsesRoute = AIProtocols.ChatRouteSpec(id: "openrouter-responses", provider: id, providerMetadataKey: id, protocol: AIProtocols.OpenResponses.`protocol`, defaultBaseURL: defaultBaseURL, path: "/responses", defaultProviderOptions: ["store": .bool(false), "include": .array([.string("reasoning.encrypted_content")])])
        // parity: ai/src/providers/openrouter.ts#routes [status=implemented hash=8fdb0460cbc8]
        public static let routes: [AIProtocols.ChatRouteSpec] = [route, responsesRoute]

        // parity: ai/src/providers/openrouter.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            let defaults = ProviderSettings.bearerRouteDefaults(input, envVars: ["OPENROUTER_API_KEY"], baseURL: defaultBaseURL, environment: environment)
            return ConfiguredProvider(id: id, baseURL: defaults.baseURL, auth: defaults.auth, headers: defaults.headers ?? [:], routes: routes, defaultRoute: route, defaultProviderOptions: defaults.providerOptions ?? [:], defaultCapabilities: .init(promptCacheKey: true))
        }

        // parity: ai/src/providers/openrouter.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/openrouter.ts#decision [status=implemented hash=e92859a494dc]
        public static func decision(_ modelID: String) -> AIProtocols.MediaModelHandle { decisionModel(modelID) }
        // parity: ai/src/providers/openrouter.ts#embedding [status=implemented hash=8c37d296d564]
        public static func embedding(_ modelID: String) -> AIProtocols.MediaModelHandle { embeddingModel(modelID) }
        // parity: ai/src/providers/openrouter.ts#image [status=implemented hash=25839c138732]
        public static func image(_ modelID: String) -> AIProtocols.MediaModelHandle { imageModel(modelID) }
        // parity: ai/src/providers/openrouter.ts#video [status=implemented hash=04f893e14126]
        public static func video(_ modelID: String) -> AIProtocols.MediaModelHandle { videoModel(modelID) }
        // parity: ai/src/providers/openrouter.ts#chat [status=implemented hash=c527949cbec3]
        public static func chat(_ modelID: String) -> ConfiguredModel { provider.model(modelID, route: route) }
        // parity: ai/src/providers/openrouter.ts#responses [status=implemented hash=8ec09f32a8ac]
        public static func responses(_ modelID: String) -> ConfiguredModel { provider.model(modelID, route: responsesRoute) }
        // parity: ai/src/providers/openrouter.ts#model [status=implemented hash=540b31ba39cd]
        public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel { configure(settings).model(modelID, route: route) }
        // parity: ai/src/providers/openrouter.ts#responsesModel [status=implemented hash=cfab73c14f1e]
        public static func responsesModel(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel { configure(settings).model(modelID, route: responsesRoute) }
        // parity: ai/src/providers/openrouter.ts#imageModel [status=implemented hash=6b232dacc4c7]
        public static func imageModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.OpenAIImages.model(.init(id: modelID, provider: id, baseURL: settings.baseURL ?? defaultBaseURL, providerOptions: settings.providerOptions), imageInput: .references)
        }
        // parity: ai/src/providers/openrouter.ts#videoModel [status=implemented hash=a5eb00d79b4d]
        public static func videoModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.OpenRouterVideo.model(.init(id: modelID, provider: id, baseURL: settings.baseURL, providerOptions: settings.providerOptions))
        }
        // parity: ai/src/providers/openrouter.ts#decisionModel [status=implemented hash=7432f6ac602f]
        public static func decisionModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "system-one", baseURL: settings.baseURL ?? defaultBaseURL, path: AIProtocols.SystemOneProtocol.DEFAULT_PATH, mode: .inline, providerOptions: settings.providerOptions)
        }
        // parity: ai/src/providers/openrouter.ts#embeddingModel [status=implemented hash=c6d9ffa465c5]
        public static func embeddingModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "openai-embeddings", baseURL: settings.baseURL ?? defaultBaseURL, path: AIProtocols.OpenAIEmbeddings.PATH, mode: .inline, providerOptions: settings.providerOptions)
        }

        public enum Responses {
            // parity: ai/src/providers/openrouter/responses.ts#Settings [status=implemented hash=355bf6d90015]
            public typealias Settings = ProviderConfig
        }
    }

    // MARK: - 26. TogetherAI, TypeSafeAI, Venice (27 symbols)

    public enum TogetherAI {
        public static let defaultBaseURL = "https://api.together.xyz/v1"
        // parity: ai/src/providers/togetherai.ts#id [status=implemented hash=9a44a0916bb0]
        public static let id = "togetherai"
        // parity: ai/src/providers/togetherai.ts#Config [status=implemented hash=3f41ed19d775]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/togetherai.ts#Settings [status=implemented hash=8b7d78d33938]
        public typealias Settings = ProviderConfig
        // parity: ai/src/providers/togetherai.ts#route [status=implemented hash=585619a1a727]
        public static let route = AIProtocols.OpenAIChat.route.with(id: id, provider: id, providerMetadataKey: id, baseURL: defaultBaseURL)
        // parity: ai/src/providers/togetherai.ts#routes [status=implemented hash=d8efbd745746]
        public static let routes: [AIProtocols.ChatRouteSpec] = [route]
        // parity: ai/src/providers/togetherai.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? defaultBaseURL, auth: resolveBearerAuth(config: input, envVars: ["TOGETHER_API_KEY", "TOGETHER_AI_API_KEY"], environment: environment), headers: input.headers ?? [:], routes: routes, defaultRoute: route, defaultProviderOptions: input.providerOptions ?? [:])
        }
        // parity: ai/src/providers/togetherai.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/togetherai.ts#model [status=implemented hash=5cfdd0ca1b72]
        public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel { configure(settings).model(modelID) }
    }

    public enum TypeSafeAI {
        public static let defaultBaseURL = "https://api.typesafe.ai/v1"
        // parity: ai/src/providers/typesafe-ai.ts#id [status=implemented hash=2170e36b9ee5]
        public static let id = "typesafe-ai"
        // parity: ai/src/providers/typesafe-ai.ts#Config [status=implemented hash=e2282dcfffaf]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/typesafe-ai.ts#Settings [status=implemented hash=2ea0351d9bdd]
        public typealias Settings = ProviderConfig
        // parity: ai/src/providers/typesafe-ai.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? defaultBaseURL, auth: resolveBearerAuth(config: input, envVars: ["TYPESAFE_API_KEY"], environment: environment), headers: input.headers ?? [:])
        }
        // parity: ai/src/providers/typesafe-ai.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/typesafe-ai.ts#decision [status=implemented hash=e92859a494dc]
        public static func decision(_ modelID: String) -> AIProtocols.MediaModelHandle { decisionModel(modelID) }
        // parity: ai/src/providers/typesafe-ai.ts#decisionModel [status=implemented hash=7432f6ac602f]
        public static func decisionModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "system-one", baseURL: settings.baseURL ?? defaultBaseURL, path: AIProtocols.SystemOneProtocol.DEFAULT_PATH, mode: .inline, providerOptions: settings.providerOptions)
        }
    }

    public enum Venice {
        public static let defaultBaseURL = "https://api.venice.ai/api/v1"
        // parity: ai/src/providers/venice.ts#id [status=implemented hash=28cac946913a]
        public static let id = "venice"
        // parity: ai/src/providers/venice.ts#ChatOptionsInput [status=implemented hash=62cb18ad7416]
        public typealias ChatOptionsInput = AIProtocols.VeniceChat.OptionsInput
        // parity: ai/src/providers/venice.ts#Config [status=implemented hash=f9bf917f8ad1]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/venice.ts#Settings [status=implemented hash=b0892b483de2]
        public typealias Settings = ProviderConfig
        public static let chatRoute = AIProtocols.ChatRouteSpec(id: "venice-chat", provider: id, providerMetadataKey: id, protocol: AIProtocols.VeniceChat.`protocol`, defaultBaseURL: defaultBaseURL, path: "/chat/completions")
        public static let responsesRoute = AIProtocols.ChatRouteSpec(id: "venice-responses", provider: id, providerMetadataKey: id, protocol: AIProtocols.OpenResponses.`protocol`, defaultBaseURL: defaultBaseURL, path: "/responses", defaultProviderOptions: ["store": .bool(false), "include": .array([.string("reasoning.encrypted_content")])])
        // parity: ai/src/providers/venice.ts#routes [status=implemented hash=8fdb0460cbc8]
        public static let routes: [AIProtocols.ChatRouteSpec] = [chatRoute, responsesRoute]
        // parity: ai/src/providers/venice.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? defaultBaseURL, auth: resolveBearerAuth(config: input, envVars: ["VENICE_API_KEY"], environment: environment), headers: input.headers ?? [:], routes: routes, defaultRoute: chatRoute, defaultProviderOptions: input.providerOptions ?? [:], defaultCompatibility: AIProtocols.VeniceChat.compatibility, defaultCapabilities: AIProtocols.VeniceChat.capabilities)
        }
        // parity: ai/src/providers/venice.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/venice.ts#chat [status=implemented hash=c527949cbec3]
        public static func chat(_ modelID: String) -> ConfiguredModel { provider.model(modelID, route: chatRoute) }
        // parity: ai/src/providers/venice.ts#responses [status=implemented hash=8ec09f32a8ac]
        public static func responses(_ modelID: String) -> ConfiguredModel { provider.model(modelID, route: responsesRoute) }
        // parity: ai/src/providers/venice.ts#model [status=implemented hash=f2cf10adf51b]
        public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel { configure(settings).model(modelID, route: chatRoute) }
        // parity: ai/src/providers/venice.ts#responsesModel [status=implemented hash=cfab73c14f1e]
        public static func responsesModel(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel { configure(settings).model(modelID, route: responsesRoute) }

        public enum Responses {
            // parity: ai/src/providers/venice/responses.ts#Settings [status=implemented hash=aa8acc2ce3fe]
            public typealias Settings = ProviderConfig
        }
    }

    // MARK: - 27. VercelAIGateway (vercel-ai-gateway.ts — 21 symbols)

    public enum VercelAIGateway {
        public static let defaultBaseURL = "https://ai-gateway.vercel.sh/v1"
        // parity: ai/src/providers/vercel-ai-gateway.ts#id [status=implemented hash=458084d94bfc]
        public static let id = "vercel-ai-gateway"

        // parity: ai/src/providers/vercel-ai-gateway.ts#GatewayOptions [status=implemented hash=bd03d32c49ed]
        public struct GatewayOptions: Equatable, Hashable, Sendable, Codable {
            public var caching: String?
            public var only: [String]?
            public var order: [String]?
            public var sort: String?
            public var zeroDataRetention: Bool?
            public var disallowPromptTraining: Bool?
            public var has: [String]?
            public var quotaEntityId: String?
            public var serviceTier: String?
            public var user: String?
            public var tags: [String]?
            public var inferenceRegion: String?
            public init(caching: String? = nil, only: [String]? = nil, order: [String]? = nil, sort: String? = nil, zeroDataRetention: Bool? = nil, disallowPromptTraining: Bool? = nil, has: [String]? = nil, quotaEntityId: String? = nil, serviceTier: String? = nil, user: String? = nil, tags: [String]? = nil, inferenceRegion: String? = nil) {
                self.caching = caching; self.only = only; self.order = order; self.sort = sort
                self.zeroDataRetention = zeroDataRetention; self.disallowPromptTraining = disallowPromptTraining
                self.has = has; self.quotaEntityId = quotaEntityId; self.serviceTier = serviceTier
                self.user = user; self.tags = tags; self.inferenceRegion = inferenceRegion
            }
        }

        // parity: ai/src/providers/vercel-ai-gateway.ts#ProviderOptionsInput [status=implemented hash=a6c18a4b6b94]
        public typealias ProviderOptionsInput = [String: JSONValue]
        // parity: ai/src/providers/vercel-ai-gateway.ts#Config [status=implemented hash=261fb466307a]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/vercel-ai-gateway.ts#Settings [status=implemented hash=4fcbaf05db4e]
        public typealias Settings = ProviderConfig

        public static let messagesRoute = AIProtocols.ChatRouteSpec(id: "vercel-ai-gateway-messages", provider: id, providerMetadataKey: id, protocol: AIProtocols.AnthropicMessages.`protocol`, defaultBaseURL: defaultBaseURL, path: "/messages", defaultHeaders: ["anthropic-version": "2023-06-01"])
        public static let responsesRoute = AIProtocols.ChatRouteSpec(id: "vercel-ai-gateway-responses", provider: id, providerMetadataKey: id, protocol: AIProtocols.OpenResponses.`protocol`, defaultBaseURL: defaultBaseURL, path: "/responses", defaultProviderOptions: ["store": .bool(false), "include": .array([.string("reasoning.encrypted_content")])])
        public static let chatRoute = AIProtocols.ChatRouteSpec(id: "vercel-ai-gateway-chat", provider: id, providerMetadataKey: id, protocol: AIProtocols.OpenAIChat.`protocol`, defaultBaseURL: defaultBaseURL, path: "/chat/completions")

        // parity: ai/src/providers/vercel-ai-gateway.ts#routes [status=implemented hash=99eacc6db6bd]
        public static let routes: [AIProtocols.ChatRouteSpec] = [messagesRoute, responsesRoute, chatRoute]

        // parity: ai/src/providers/vercel-ai-gateway.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            let defaults = ProviderSettings.bearerRouteDefaults(input, envVars: ["AI_GATEWAY_API_KEY", "VERCEL_OIDC_TOKEN"], baseURL: defaultBaseURL, environment: environment)
            return ConfiguredProvider(id: id, baseURL: defaults.baseURL, auth: defaults.auth, headers: defaults.headers ?? [:], routes: routes, defaultRoute: messagesRoute, defaultProviderOptions: defaults.providerOptions ?? [:])
        }

        // parity: ai/src/providers/vercel-ai-gateway.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/vercel-ai-gateway.ts#decision [status=implemented hash=e92859a494dc]
        public static func decision(_ modelID: String) -> AIProtocols.MediaModelHandle { decisionModel(modelID) }
        // parity: ai/src/providers/vercel-ai-gateway.ts#embedding [status=implemented hash=8c37d296d564]
        public static func embedding(_ modelID: String) -> AIProtocols.MediaModelHandle { embeddingModel(modelID) }
        // parity: ai/src/providers/vercel-ai-gateway.ts#messages [status=implemented hash=bfa381d2428b]
        public static func messages(_ modelID: String) -> ConfiguredModel { provider.model(modelID, route: messagesRoute, compatibility: .init(requireSignature: modelID.hasPrefix("anthropic/"))) }
        // parity: ai/src/providers/vercel-ai-gateway.ts#responses [status=implemented hash=8ec09f32a8ac]
        public static func responses(_ modelID: String) -> ConfiguredModel { provider.model(modelID, route: responsesRoute) }
        // parity: ai/src/providers/vercel-ai-gateway.ts#chat [status=implemented hash=c527949cbec3]
        public static func chat(_ modelID: String) -> ConfiguredModel { provider.model(modelID, route: chatRoute, compatibility: .init(reasoningField: "reasoning")) }
        // parity: ai/src/providers/vercel-ai-gateway.ts#image [status=implemented hash=25839c138732]
        public static func image(_ modelID: String) -> AIProtocols.MediaModelHandle { imageModel(modelID) }

        // parity: ai/src/providers/vercel-ai-gateway.ts#model [status=implemented hash=b9dc4d8a5f47]
        public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel {
            if modelID.hasPrefix("openai/gpt-") || modelID.hasPrefix("spacexai/grok-") {
                return responsesModel(modelID, settings: settings)
            }
            if modelID.hasPrefix("meta/muse-") {
                return chatModel(modelID, settings: settings)
            }
            return messagesModel(modelID, settings: settings)
        }
        // parity: ai/src/providers/vercel-ai-gateway.ts#messagesModel [status=implemented hash=386b4dc21e72]
        public static func messagesModel(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel {
            configure(settings).model(modelID, route: messagesRoute, compatibility: .init(requireSignature: modelID.hasPrefix("anthropic/")))
        }
        // parity: ai/src/providers/vercel-ai-gateway.ts#responsesModel [status=implemented hash=de3ed1280d55]
        public static func responsesModel(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel { configure(settings).model(modelID, route: responsesRoute) }
        // parity: ai/src/providers/vercel-ai-gateway.ts#chatModel [status=implemented hash=3b4f0bea6597]
        public static func chatModel(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel { configure(settings).model(modelID, route: chatRoute, compatibility: .init(reasoningField: "reasoning")) }
        // parity: ai/src/providers/vercel-ai-gateway.ts#imageModel [status=implemented hash=6b232dacc4c7]
        public static func imageModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.OpenAIImages.model(.init(id: modelID, provider: id, baseURL: settings.baseURL ?? defaultBaseURL, providerOptions: settings.providerOptions))
        }
        // parity: ai/src/providers/vercel-ai-gateway.ts#decisionModel [status=implemented hash=7432f6ac602f]
        public static func decisionModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "openai-decisions", baseURL: settings.baseURL ?? defaultBaseURL, path: AIProtocols.OpenAIDecisions.PATH, mode: .inline, providerOptions: settings.providerOptions)
        }
        // parity: ai/src/providers/vercel-ai-gateway.ts#embeddingModel [status=implemented hash=c6d9ffa465c5]
        public static func embeddingModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "openai-embeddings", baseURL: settings.baseURL ?? defaultBaseURL, path: AIProtocols.OpenAIEmbeddings.PATH, mode: .inline, providerOptions: settings.providerOptions)
        }
    }

    // MARK: - 28. Volcengine, XAI, ZAICodingPlan & ZAI (35 symbols)

    public enum Volcengine {
        // parity: ai/src/providers/volcengine.ts#id [status=implemented hash=63dcee9aa09c]
        public static let id = "volcengine"
        // parity: ai/src/providers/volcengine.ts#Config [status=implemented hash=e2282dcfffaf]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/volcengine.ts#Settings [status=implemented hash=5dc534ea0f5c]
        public typealias Settings = ProviderConfig
        // parity: ai/src/providers/volcengine.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? AIProtocols.SeedanceVideo.VOLCENGINE_BASE_URL, auth: resolveBearerAuth(config: input, envVars: ["ARK_API_KEY"], environment: environment), headers: input.headers ?? [:])
        }
        // parity: ai/src/providers/volcengine.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/volcengine.ts#videoModel [status=implemented hash=a5eb00d79b4d]
        public static func videoModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.SeedanceVideo.model(.init(id: modelID, provider: id, baseURL: settings.baseURL, providerOptions: settings.providerOptions), provider: .volcengine)
        }
        // parity: ai/src/providers/volcengine.ts#video [status=implemented hash=04f893e14126]
        public static func video(_ modelID: String) -> AIProtocols.MediaModelHandle { videoModel(modelID) }
    }

    public enum XAI {
        public static let defaultBaseURL = "https://api.x.ai/v1"
        // parity: ai/src/providers/xai.ts#id [status=implemented hash=b80fec3062af]
        public static let id = "xai"
        // parity: ai/src/providers/xai.ts#XAIProviderOptionsInput [status=implemented hash=e2eff0eb7acb]
        public typealias XAIProviderOptionsInput = [String: JSONValue]
        // parity: ai/src/providers/xai.ts#Config [status=implemented hash=b57abc182f57]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/xai.ts#Settings [status=implemented hash=6db8b0173544]
        public typealias Settings = ProviderConfig

        public static let responsesRoute = AIProtocols.ChatRouteSpec(id: "xai-responses", provider: id, providerMetadataKey: id, protocol: AIProtocols.XAIResponses.`protocol`, defaultBaseURL: defaultBaseURL, path: "/responses", defaultProviderOptions: ["store": .bool(false), "include": .array([.string("reasoning.encrypted_content")])])
        public static let chatRoute = AIProtocols.ChatRouteSpec(id: "xai-chat", provider: id, providerMetadataKey: id, protocol: AIProtocols.OpenAIChat.`protocol`, defaultBaseURL: defaultBaseURL, path: "/chat/completions")

        // parity: ai/src/providers/xai.ts#routes [status=implemented hash=e73c5af69a31]
        public static let routes: [AIProtocols.ChatRouteSpec] = [responsesRoute, chatRoute]
        // parity: ai/src/providers/xai.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? defaultBaseURL, auth: resolveBearerAuth(config: input, envVars: ["XAI_API_KEY"], environment: environment), headers: input.headers ?? [:], routes: routes, defaultRoute: responsesRoute, defaultProviderOptions: input.providerOptions ?? [:])
        }
        // parity: ai/src/providers/xai.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/xai.ts#model [status=implemented hash=117765bb8400]
        public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel { configure(settings).model(modelID, route: responsesRoute) }
        // parity: ai/src/providers/xai.ts#imageModel [status=implemented hash=6b232dacc4c7]
        public static func imageModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.XAIImages.model(.init(id: modelID, provider: id, baseURL: settings.baseURL, providerOptions: settings.providerOptions))
        }
        // parity: ai/src/providers/xai.ts#videoModel [status=implemented hash=a5eb00d79b4d]
        public static func videoModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.XAIVideo.model(.init(id: modelID, provider: id, baseURL: settings.baseURL, providerOptions: settings.providerOptions))
        }
        // parity: ai/src/providers/xai.ts#responses [status=implemented hash=8ec09f32a8ac]
        public static func responses(_ modelID: String) -> ConfiguredModel { provider.model(modelID, route: responsesRoute) }
        // parity: ai/src/providers/xai.ts#chat [status=implemented hash=c527949cbec3]
        public static func chat(_ modelID: String) -> ConfiguredModel { provider.model(modelID, route: chatRoute) }
        // parity: ai/src/providers/xai.ts#image [status=implemented hash=25839c138732]
        public static func image(_ modelID: String) -> AIProtocols.MediaModelHandle { imageModel(modelID) }
        // parity: ai/src/providers/xai.ts#video [status=implemented hash=04f893e14126]
        public static func video(_ modelID: String) -> AIProtocols.MediaModelHandle { videoModel(modelID) }
    }

    public enum ZAICodingPlan {
        public static let defaultBaseURL = "https://api.z.ai/api/coding/paas/v4"
        public static let anthropicBaseURL = "https://api.z.ai/api/anthropic/v1"
        public static let responsesBaseURL = "https://api.z.ai/api/v1"

        // parity: ai/src/providers/zai-coding-plan.ts#id [status=implemented hash=d391eff3a46c]
        public static let id = "zai-coding-plan"
        // parity: ai/src/providers/zai-coding-plan.ts#ChatOptionsInput [status=implemented hash=089f588fa233]
        public typealias ChatOptionsInput = AIProtocols.ZAIChat.OptionsInput
        // parity: ai/src/providers/zai-coding-plan.ts#MessagesOptionsInput [status=implemented hash=3ccfd39fc1b7]
        public typealias MessagesOptionsInput = AIProtocols.ZAIMessages.OptionsInput
        // parity: ai/src/providers/zai-coding-plan.ts#ResponsesOptionsInput [status=implemented hash=b3a5658b28bd]
        public typealias ResponsesOptionsInput = [String: JSONValue]
        // parity: ai/src/providers/zai-coding-plan.ts#Config [status=implemented hash=4f3ef9031f82]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/zai-coding-plan.ts#Settings [status=implemented hash=3996ed9f51d2]
        public typealias Settings = ProviderConfig

        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? defaultBaseURL, auth: resolveBearerAuth(config: input, envVars: ["ZAI_API_KEY"], environment: environment), headers: input.headers ?? [:], routes: [AIProtocols.ChatRouteSpec(id: "zai-coding-plan-chat", provider: id, protocol: AIProtocols.ZAIChat.`protocol`, defaultBaseURL: defaultBaseURL, path: "/chat/completions")], defaultCompatibility: AIProtocols.ZAIChat.compatibility, defaultCapabilities: AIProtocols.ZAIChat.capabilities)
        }

        public enum Messages {
            // parity: ai/src/providers/zai-coding-plan/messages.ts#Settings [status=implemented hash=982de6632698]
            public typealias Settings = ProviderConfig
            // parity: ai/src/providers/zai-coding-plan/messages.ts#model [status=implemented hash=9abddcbeda92]
            public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel {
                var adjusted = settings
                if adjusted.baseURL == nil { adjusted.baseURL = anthropicBaseURL }
                let route = AIProtocols.ChatRouteSpec(id: "zai-coding-plan-messages", provider: id, protocol: AIProtocols.ZAIMessages.`protocol`, defaultBaseURL: anthropicBaseURL, path: "/messages", defaultHeaders: ["anthropic-version": "2023-06-01"])
                return configure(adjusted).model(modelID, route: route)
            }
        }

        public enum Responses {
            // parity: ai/src/providers/zai-coding-plan/responses.ts#Settings [status=implemented hash=883c128db5dc]
            public typealias Settings = ProviderConfig
            // parity: ai/src/providers/zai-coding-plan/responses.ts#model [status=implemented hash=342668c991cc]
            public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel {
                var adjusted = settings
                if adjusted.baseURL == nil { adjusted.baseURL = responsesBaseURL }
                return configure(adjusted).model(modelID, route: AIProtocols.OpenAICompatibleResponses.route)
            }
        }
    }

    public enum ZAI {
        public static let defaultBaseURL = "https://api.z.ai/api/paas/v4"
        // parity: ai/src/providers/zai.ts#id [status=implemented hash=19523925e147]
        public static let id = "zai"
        // parity: ai/src/providers/zai.ts#ChatOptionsInput [status=implemented hash=089f588fa233]
        public typealias ChatOptionsInput = AIProtocols.ZAIChat.OptionsInput
        // parity: ai/src/providers/zai.ts#Config [status=implemented hash=7d37e26eebb5]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/zai.ts#Settings [status=implemented hash=6e73954e8035]
        public typealias Settings = ProviderConfig

        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            let route = AIProtocols.ChatRouteSpec(id: "zai-chat", provider: id, protocol: AIProtocols.ZAIChat.`protocol`, defaultBaseURL: defaultBaseURL, path: "/chat/completions")
            return ConfiguredProvider(id: id, baseURL: input.baseURL ?? defaultBaseURL, auth: resolveBearerAuth(config: input, envVars: ["ZAI_API_KEY"], environment: environment), headers: input.headers ?? [:], routes: [route], defaultRoute: route, defaultCompatibility: AIProtocols.ZAIChat.compatibility, defaultCapabilities: AIProtocols.ZAIChat.capabilities)
        }
    }

    // MARK: - Provider Catalog Metadata

    public struct ProviderCatalogEntry: Equatable, Hashable, Sendable {
        public let id: String
        public let defaultBaseURL: String?
        public let envVars: [String]
        public let authHeader: String

        public init(id: String, defaultBaseURL: String?, envVars: [String], authHeader: String) {
            self.id = id
            self.defaultBaseURL = defaultBaseURL
            self.envVars = envVars
            self.authHeader = authHeader
        }
    }

    public static let catalog: [ProviderCatalogEntry] = [
        .init(id: Alibaba.id, defaultBaseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", envVars: ["DASHSCOPE_API_KEY", "ALIBABA_API_KEY"], authHeader: "authorization"),
        .init(id: AmazonBedrock.id, defaultBaseURL: "https://bedrock-runtime.us-east-1.amazonaws.com", envVars: ["AWS_BEARER_TOKEN_BEDROCK"], authHeader: "authorization"),
        .init(id: Anthropic.id, defaultBaseURL: AIProtocols.AnthropicMessages.DEFAULT_BASE_URL, envVars: ["ANTHROPIC_API_KEY"], authHeader: "x-api-key"),
        .init(id: AnthropicCompatible.id, defaultBaseURL: nil, envVars: [], authHeader: "x-api-key"),
        .init(id: AssemblyAI.id, defaultBaseURL: AIProtocols.AssemblyAITranscription.DEFAULT_BASE_URL, envVars: ["ASSEMBLYAI_API_KEY"], authHeader: "authorization"),
        .init(id: Azure.id, defaultBaseURL: nil, envVars: ["AZURE_OPENAI_API_KEY"], authHeader: "api-key"),
        .init(id: Baseten.id, defaultBaseURL: Baseten.defaultBaseURL, envVars: ["BASETEN_API_KEY"], authHeader: "authorization"),
        .init(id: BytePlus.id, defaultBaseURL: AIProtocols.SeedanceVideo.BYTEPLUS_BASE_URL, envVars: ["BYTEPLUS_API_KEY"], authHeader: "authorization"),
        .init(id: Cartesia.id, defaultBaseURL: AIProtocols.CartesiaSpeech.DEFAULT_BASE_URL, envVars: ["CARTESIA_API_KEY"], authHeader: "authorization"),
        .init(id: Cerebras.id, defaultBaseURL: Cerebras.defaultBaseURL, envVars: ["CEREBRAS_API_KEY"], authHeader: "authorization"),
        .init(id: CloudflareAIGateway.id, defaultBaseURL: nil, envVars: CloudflareAIGateway.authEnvVars, authHeader: "authorization"),
        .init(id: CloudflareWorkersAI.id, defaultBaseURL: nil, envVars: CloudflareWorkersAI.authEnvVars, authHeader: "authorization"),
        .init(id: Cohere.id, defaultBaseURL: AIProtocols.CohereChat.DEFAULT_BASE_URL, envVars: ["COHERE_API_KEY"], authHeader: "authorization"),
        .init(id: Deepgram.id, defaultBaseURL: AIProtocols.DeepgramSpeech.DEFAULT_BASE_URL, envVars: ["DEEPGRAM_API_KEY"], authHeader: "authorization"),
        .init(id: DeepInfra.id, defaultBaseURL: DeepInfra.defaultBaseURL, envVars: ["DEEPINFRA_API_KEY"], authHeader: "authorization"),
        .init(id: DeepSeek.id, defaultBaseURL: DeepSeek.defaultBaseURL, envVars: ["DEEPSEEK_API_KEY"], authHeader: "authorization"),
        .init(id: DigitalOcean.id, defaultBaseURL: DigitalOcean.defaultBaseURL, envVars: ["DIGITALOCEAN_ACCESS_TOKEN", "DIGITALOCEAN_API_KEY", "DO_INFERENCE_API_KEY"], authHeader: "authorization"),
        .init(id: ElevenLabs.id, defaultBaseURL: AIProtocols.ElevenLabsSpeech.DEFAULT_BASE_URL, envVars: ["ELEVENLABS_API_KEY"], authHeader: "xi-api-key"),
        .init(id: Fireworks.id, defaultBaseURL: Fireworks.defaultBaseURL, envVars: ["FIREWORKS_API_KEY"], authHeader: "authorization"),
        .init(id: Google.id, defaultBaseURL: AIProtocols.Gemini.DEFAULT_BASE_URL, envVars: ["GOOGLE_GENERATIVE_AI_API_KEY"], authHeader: "x-goog-api-key"),
        .init(id: GoogleVertex.id, defaultBaseURL: "https://aiplatform.googleapis.com/v1/publishers/google", envVars: ["GOOGLE_VERTEX_API_KEY"], authHeader: "authorization"),
        .init(id: Groq.id, defaultBaseURL: Groq.defaultBaseURL, envVars: ["GROQ_API_KEY"], authHeader: "authorization"),
        .init(id: Meta.id, defaultBaseURL: Meta.defaultBaseURL, envVars: ["META_API_KEY"], authHeader: "authorization"),
        .init(id: MiniMax.id, defaultBaseURL: MiniMax.anthropicBaseURL, envVars: ["MINIMAX_API_KEY"], authHeader: "authorization"),
        .init(id: Mistral.id, defaultBaseURL: AIProtocols.MistralChat.DEFAULT_BASE_URL, envVars: ["MISTRAL_API_KEY"], authHeader: "authorization"),
        .init(id: Moonshot.id, defaultBaseURL: Moonshot.defaultBaseURL, envVars: ["MOONSHOT_API_KEY", "MOONSHOTAI_API_KEY"], authHeader: "authorization"),
        .init(id: OpenAI.id, defaultBaseURL: AIProtocols.OpenAIResponses.DEFAULT_BASE_URL, envVars: ["OPENAI_API_KEY"], authHeader: "authorization"),
        .init(id: OpenAICompatible.id, defaultBaseURL: nil, envVars: [], authHeader: "authorization"),
        .init(id: OpenCode.id, defaultBaseURL: OpenCode.defaultBaseURL, envVars: ["OPENCODE_API_KEY"], authHeader: "authorization"),
        .init(id: OpenRouter.id, defaultBaseURL: OpenRouter.defaultBaseURL, envVars: ["OPENROUTER_API_KEY"], authHeader: "authorization"),
        .init(id: TogetherAI.id, defaultBaseURL: TogetherAI.defaultBaseURL, envVars: ["TOGETHER_API_KEY", "TOGETHER_AI_API_KEY"], authHeader: "authorization"),
        .init(id: TypeSafeAI.id, defaultBaseURL: TypeSafeAI.defaultBaseURL, envVars: ["TYPESAFE_API_KEY"], authHeader: "authorization"),
        .init(id: Venice.id, defaultBaseURL: Venice.defaultBaseURL, envVars: ["VENICE_API_KEY"], authHeader: "authorization"),
        .init(id: VercelAIGateway.id, defaultBaseURL: VercelAIGateway.defaultBaseURL, envVars: ["AI_GATEWAY_API_KEY", "VERCEL_OIDC_TOKEN"], authHeader: "authorization"),
        .init(id: Volcengine.id, defaultBaseURL: AIProtocols.SeedanceVideo.VOLCENGINE_BASE_URL, envVars: ["ARK_API_KEY"], authHeader: "authorization"),
        .init(id: XAI.id, defaultBaseURL: XAI.defaultBaseURL, envVars: ["XAI_API_KEY"], authHeader: "authorization"),
        .init(id: ZAI.id, defaultBaseURL: ZAI.defaultBaseURL, envVars: ["ZAI_API_KEY"], authHeader: "authorization"),
        .init(id: ZAICodingPlan.id, defaultBaseURL: ZAICodingPlan.defaultBaseURL, envVars: ["ZAI_API_KEY"], authHeader: "authorization"),
    ]

    public static func catalogEntry(for providerID: String) -> ProviderCatalogEntry? {
        catalog.first { $0.id == providerID }
    }
}
