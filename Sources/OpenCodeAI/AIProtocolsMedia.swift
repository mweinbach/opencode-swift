/// Portable media, embeddings, decisions, speech, transcription, image, and video protocols for `OpenCodeAI`.
///
/// Ports all 29 non-chat protocol modules under `packages/ai/src/protocols/*`:
/// `alibaba-images`, `assemblyai-transcription`, `cartesia-speech`, `cloudflare-run-decisions`,
/// `cloudflare-workers-ai-images`, `deepgram-speech`, `deepgram-transcription`, `elevenlabs-speech`,
/// `elevenlabs-transcription`, `google-decisions`, `google-embed-content`, `google-images`,
/// `google-interactions-video`, `google-speech`, `google-transcription`,
/// `google-vertex-predict-embeddings`, `meta-images`, `minimax-images`, `minimax-video`,
/// `openai-decisions`, `openai-embeddings`, `openai-images`, `openai-speech`,
/// `openai-transcription`, `openrouter-video`, `seedance-video`, `xai-images`,
/// `xai-video`, and `zai-images`.
///
/// Strictly PORTABLE tier: zero OS imports, all HTTP via `OpenCodePlatform.HTTPTransport`.

import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

extension AIProtocols {

    // MARK: Shared Media / Embedding / Decision Protocol Primitives

    public enum MediaMode: String, Equatable, Hashable, Sendable, Codable {
        case inline
        case stream
        case queued
    }

    public struct MediaModelInput: Equatable, Hashable, Sendable {
        public let id: String
        public let provider: String?
        public let baseURL: String?
        public let providerOptions: [String: JSONValue]?

        public init(
            id: String,
            provider: String? = nil,
            baseURL: String? = nil,
            providerOptions: [String: JSONValue]? = nil
        ) {
            self.id = id
            self.provider = provider
            self.baseURL = baseURL
            self.providerOptions = providerOptions
        }
    }

    public struct MediaModelHandle: Equatable, Hashable, Sendable {
        public let id: String
        public let provider: String
        public let protocolID: String
        public let baseURL: String?
        public let path: String
        public let mode: MediaMode
        public let providerOptions: [String: JSONValue]?

        public init(
            id: String,
            provider: String,
            protocolID: String,
            baseURL: String?,
            path: String,
            mode: MediaMode,
            providerOptions: [String: JSONValue]? = nil
        ) {
            self.id = id
            self.provider = provider
            self.protocolID = protocolID
            self.baseURL = baseURL
            self.path = path
            self.mode = mode
            self.providerOptions = providerOptions
        }
    }

    public struct MediaProtocolSpec: Sendable {
        public let identity: AIProtocolUtils.MediaIdentity
        public let mode: MediaMode
        public let defaultBaseURL: String?
        public let path: String
        public let buildBody: @Sendable ([String: JSONValue]) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue]

        public init(
            identity: AIProtocolUtils.MediaIdentity,
            mode: MediaMode,
            defaultBaseURL: String? = nil,
            path: String = "",
            buildBody: @escaping @Sendable ([String: JSONValue]) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue] = { $0 }
        ) {
            self.identity = identity
            self.mode = mode
            self.defaultBaseURL = defaultBaseURL
            self.path = path
            self.buildBody = buildBody
        }

        public func makeModel(_ input: MediaModelInput, pathOverride: String? = nil) -> MediaModelHandle {
            MediaModelHandle(
                id: input.id,
                provider: input.provider ?? identity.provider,
                protocolID: identity.id,
                baseURL: input.baseURL ?? defaultBaseURL,
                path: pathOverride ?? path,
                mode: mode,
                providerOptions: input.providerOptions
            )
        }
    }

    public struct ImageRequestPayload: Equatable, Hashable, Sendable {
        public let modelID: String
        public let prompt: String
        public let n: Int?
        public let aspect: String?
        public let resolution: String?
        public let images: [AIProtocolUtils.MediaAsset]?
        public let providerOptions: [String: JSONValue]?

        public init(
            modelID: String,
            prompt: String,
            n: Int? = nil,
            aspect: String? = nil,
            resolution: String? = nil,
            images: [AIProtocolUtils.MediaAsset]? = nil,
            providerOptions: [String: JSONValue]? = nil
        ) {
            self.modelID = modelID; self.prompt = prompt; self.n = n
            self.aspect = aspect; self.resolution = resolution
            self.images = images; self.providerOptions = providerOptions
        }
    }

    public struct SpeechRequestPayload: Equatable, Hashable, Sendable {
        public let modelID: String
        public let text: String
        public let voice: String?
        public let instructions: String?
        public let format: String?
        public let speed: Double?
        public let language: String?
        public let timestamps: Bool?
        public let streaming: Bool
        public let providerOptions: [String: JSONValue]?

        public init(
            modelID: String, text: String, voice: String? = nil, instructions: String? = nil,
            format: String? = nil, speed: Double? = nil, language: String? = nil,
            timestamps: Bool? = nil, streaming: Bool = false, providerOptions: [String: JSONValue]? = nil
        ) {
            self.modelID = modelID; self.text = text; self.voice = voice
            self.instructions = instructions; self.format = format; self.speed = speed
            self.language = language; self.timestamps = timestamps
            self.streaming = streaming; self.providerOptions = providerOptions
        }
    }

    public struct TranscriptionRequestPayload: Equatable, Hashable, Sendable {
        public let modelID: String
        public let audio: AIProtocolUtils.MediaAsset
        public let language: String?
        public let prompt: String?
        public let diarize: Bool?
        public let timestamps: String?
        public let streaming: Bool
        public let providerOptions: [String: JSONValue]?

        public init(
            modelID: String, audio: AIProtocolUtils.MediaAsset, language: String? = nil,
            prompt: String? = nil, diarize: Bool? = nil, timestamps: String? = nil,
            streaming: Bool = false, providerOptions: [String: JSONValue]? = nil
        ) {
            self.modelID = modelID; self.audio = audio; self.language = language
            self.prompt = prompt; self.diarize = diarize; self.timestamps = timestamps
            self.streaming = streaming; self.providerOptions = providerOptions
        }
    }

    public struct VideoRequestPayload: Equatable, Hashable, Sendable {
        public let modelID: String
        public let prompt: String
        public let durationSeconds: Int?
        public let aspect: String?
        public let resolution: String?
        public let images: [AIProtocolUtils.MediaAsset]?
        public let providerOptions: [String: JSONValue]?

        public init(
            modelID: String, prompt: String, durationSeconds: Int? = nil,
            aspect: String? = nil, resolution: String? = nil,
            images: [AIProtocolUtils.MediaAsset]? = nil, providerOptions: [String: JSONValue]? = nil
        ) {
            self.modelID = modelID; self.prompt = prompt; self.durationSeconds = durationSeconds
            self.aspect = aspect; self.resolution = resolution; self.images = images
            self.providerOptions = providerOptions
        }
    }

    public enum EmbeddingInputValue: Equatable, Hashable, Sendable {
        case text(String)
        case media(AIProtocolUtils.MediaAsset)
    }

    public struct EmbeddingRequestPayload: Equatable, Hashable, Sendable {
        public let model: AIProtocolUtils.ModelDescriptor
        public let values: [EmbeddingInputValue]
        public let dimensions: Int?
        public let inputType: String?
        public let providerOptions: [String: JSONValue]?
        public let httpBody: [String: JSONValue]?

        public init(
            model: AIProtocolUtils.ModelDescriptor,
            values: [EmbeddingInputValue],
            dimensions: Int? = nil,
            inputType: String? = nil,
            providerOptions: [String: JSONValue]? = nil,
            httpBody: [String: JSONValue]? = nil
        ) {
            self.model = model; self.values = values; self.dimensions = dimensions
            self.inputType = inputType; self.providerOptions = providerOptions; self.httpBody = httpBody
        }
    }

    public struct EmbeddingResponsePayload: Equatable, Hashable, Sendable {
        public let embeddings: [[Double]]
        public let inputTokens: Double?
        public let providerMetadata: AIProtocolUtils.ProviderMetadata

        public init(embeddings: [[Double]], inputTokens: Double? = nil, providerMetadata: AIProtocolUtils.ProviderMetadata = [:]) {
            self.embeddings = embeddings; self.inputTokens = inputTokens; self.providerMetadata = providerMetadata
        }
    }

    public struct EmbeddingProtocolSpec: Sendable {
        public let id: String
        public let name: String
        public let buildBody: @Sendable (EmbeddingRequestPayload) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue]
        public let decodeResponse: @Sendable (String, String) throws(AIProtocolUtils.ProtocolError) -> EmbeddingResponsePayload

        public init(
            id: String,
            name: String,
            buildBody: @escaping @Sendable (EmbeddingRequestPayload) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue],
            decodeResponse: @escaping @Sendable (String, String) throws(AIProtocolUtils.ProtocolError) -> EmbeddingResponsePayload
        ) {
            self.id = id; self.name = name; self.buildBody = buildBody; self.decodeResponse = decodeResponse
        }
    }

    public struct EmbeddingRouteSpec: Sendable {
        public let id: String
        public let provider: String
        public let `protocol`: EmbeddingProtocolSpec
        public let defaultBaseURL: String?
        public let pathBuilder: @Sendable (String) -> String
        public let maxValues: Int?

        public init(
            id: String,
            provider: String,
            protocol proto: EmbeddingProtocolSpec,
            defaultBaseURL: String? = nil,
            path: String,
            maxValues: Int? = nil
        ) {
            self.id = id; self.provider = provider; self.`protocol` = proto
            self.defaultBaseURL = defaultBaseURL; self.pathBuilder = { _ in path }; self.maxValues = maxValues
        }

        public init(
            id: String,
            provider: String,
            protocol proto: EmbeddingProtocolSpec,
            defaultBaseURL: String? = nil,
            pathBuilder: @escaping @Sendable (String) -> String,
            maxValues: Int? = nil
        ) {
            self.id = id; self.provider = provider; self.`protocol` = proto
            self.defaultBaseURL = defaultBaseURL; self.pathBuilder = pathBuilder; self.maxValues = maxValues
        }
    }

    public struct DecisionProtocolSpec: Sendable {
        public let id: String
        public let name: String
        public let provider: String
        public let buildBody: @Sendable (SystemOneProtocol.DecisionRequest) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue]

        public init(
            id: String,
            name: String,
            provider: String,
            buildBody: @escaping @Sendable (SystemOneProtocol.DecisionRequest) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue]
        ) {
            self.id = id; self.name = name; self.provider = provider; self.buildBody = buildBody
        }
    }

    public struct DecisionRouteSpec: Sendable {
        public let id: String
        public let provider: String
        public let `protocol`: DecisionProtocolSpec
        public let defaultBaseURL: String?
        public let pathBuilder: @Sendable (String) -> String

        public init(
            id: String,
            provider: String,
            protocol proto: DecisionProtocolSpec,
            defaultBaseURL: String? = nil,
            path: String
        ) {
            self.id = id; self.provider = provider; self.`protocol` = proto
            self.defaultBaseURL = defaultBaseURL; self.pathBuilder = { _ in path }
        }

        public init(
            id: String,
            provider: String,
            protocol proto: DecisionProtocolSpec,
            defaultBaseURL: String? = nil,
            pathBuilder: @escaping @Sendable (String) -> String
        ) {
            self.id = id; self.provider = provider; self.`protocol` = proto
            self.defaultBaseURL = defaultBaseURL; self.pathBuilder = pathBuilder
        }
    }

    // MARK: - 1. AlibabaImages (packages/ai/src/protocols/alibaba-images.ts — 6 symbols)

    public enum AlibabaImages {
        // parity: ai/src/protocols/alibaba-images.ts#PATH [status=implemented hash=27ab16aeb685]
        public static let PATH = "/services/aigc/multimodal-generation/generation"

        // parity: ai/src/protocols/alibaba-images.ts#AlibabaImageOptions [status=implemented hash=68d293979af4]
        public typealias AlibabaImageOptions = [String: JSONValue]

        // parity: ai/src/protocols/alibaba-images.ts#Request [status=implemented hash=52a04160fbc7]
        public typealias Request = ImageRequestPayload

        // parity: ai/src/protocols/alibaba-images.ts#protocol [status=implemented hash=ddeb3a42695c]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "alibaba-images", name: "Alibaba Images", provider: "alibaba"),
            mode: .inline,
            path: PATH
        )

        // parity: ai/src/protocols/alibaba-images.ts#model [status=implemented hash=6a93000bf9e0]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/alibaba-images.ts#AlibabaImages [status=implemented hash=c9f4054fc133]
        public static let AlibabaImages = AIProtocols.AlibabaImages.self
    }

    // MARK: - 2. AssemblyAITranscription (packages/ai/src/protocols/assemblyai-transcription.ts — 9 symbols)

    public enum AssemblyAITranscription {
        // parity: ai/src/protocols/assemblyai-transcription.ts#DEFAULT_BASE_URL [status=implemented hash=cda670435821]
        public static let DEFAULT_BASE_URL = "https://api.assemblyai.com"

        // parity: ai/src/protocols/assemblyai-transcription.ts#PATH [status=implemented hash=4e90f44c27bd]
        public static let PATH = "/v2/transcript"

        // parity: ai/src/protocols/assemblyai-transcription.ts#UPLOAD_PATH [status=implemented hash=95a896564a6a]
        public static let UPLOAD_PATH = "/v2/upload"

        // parity: ai/src/protocols/assemblyai-transcription.ts#AssemblyAITranscriptionOptions [status=implemented hash=66db719a9692]
        public typealias AssemblyAITranscriptionOptions = [String: JSONValue]

        // parity: ai/src/protocols/assemblyai-transcription.ts#Request [status=implemented hash=ae2fc21d671a]
        public typealias Request = TranscriptionRequestPayload

        // parity: ai/src/protocols/assemblyai-transcription.ts#Token [status=implemented hash=ca68b738b186]
        public struct Token: Equatable, Hashable, Sendable, Codable {
            public let transcriptID: String
            public init(transcriptID: String) { self.transcriptID = transcriptID }
        }

        // parity: ai/src/protocols/assemblyai-transcription.ts#protocol [status=implemented hash=037842d32075]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "assemblyai-transcription", name: "AssemblyAI", provider: "assemblyai"),
            mode: .queued,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/assemblyai-transcription.ts#model [status=implemented hash=c2dd45b37590]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/assemblyai-transcription.ts#AssemblyAITranscription [status=implemented hash=0deea6803c6d]
        public static let AssemblyAITranscription = AIProtocols.AssemblyAITranscription.self
    }

    // MARK: - 3. CartesiaSpeech (packages/ai/src/protocols/cartesia-speech.ts — 10 symbols)

    public enum CartesiaSpeech {
        // parity: ai/src/protocols/cartesia-speech.ts#DEFAULT_BASE_URL [status=implemented hash=497d69cbc59b]
        public static let DEFAULT_BASE_URL = "https://api.cartesia.ai"

        // parity: ai/src/protocols/cartesia-speech.ts#API_VERSION [status=implemented hash=3216859930a6]
        public static let API_VERSION = "2026-08-14"

        // parity: ai/src/protocols/cartesia-speech.ts#BYTES_PATH [status=implemented hash=559345b3508b]
        public static let BYTES_PATH = "/tts/bytes"

        // parity: ai/src/protocols/cartesia-speech.ts#SSE_PATH [status=implemented hash=e30f9f5f8d81]
        public static let SSE_PATH = "/tts/sse"

        // parity: ai/src/protocols/cartesia-speech.ts#CartesiaEncoding [status=implemented hash=e659e0a52d26]
        public typealias CartesiaEncoding = AIProtocolUtils.SpeechStream.PcmEncoding

        // parity: ai/src/protocols/cartesia-speech.ts#CartesiaSpeechOptions [status=implemented hash=1b4952b339d5]
        public typealias CartesiaSpeechOptions = [String: JSONValue]

        // parity: ai/src/protocols/cartesia-speech.ts#Request [status=implemented hash=8f386fc9e7be]
        public typealias Request = SpeechRequestPayload

        // parity: ai/src/protocols/cartesia-speech.ts#protocol [status=implemented hash=462ef07f59c9]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "cartesia-speech", name: "Cartesia", provider: "cartesia"),
            mode: .stream,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: BYTES_PATH
        )

        // parity: ai/src/protocols/cartesia-speech.ts#model [status=implemented hash=43d92a99c499]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/cartesia-speech.ts#CartesiaSpeech [status=implemented hash=b6fd92a9a368]
        public static let CartesiaSpeech = AIProtocols.CartesiaSpeech.self
    }

    // MARK: - 4. CloudflareRunDecisions (packages/ai/src/protocols/cloudflare-run-decisions.ts — 3 symbols)

    public enum CloudflareRunDecisions {
        // parity: ai/src/protocols/cloudflare-run-decisions.ts#protocol [status=implemented hash=0c4459b549fc]
        public static let `protocol` = DecisionProtocolSpec(
            id: "cloudflare-run-decisions",
            name: "Cloudflare Run Decisions",
            provider: "cloudflare-workers-ai",
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                try SystemOneProtocol.encodeBody(req, fallbackMediaInput: "assets")
            }
        )

        // parity: ai/src/protocols/cloudflare-run-decisions.ts#route [status=implemented hash=e488ef52b189]
        public static let route = DecisionRouteSpec(
            id: "cloudflare-run-decisions",
            provider: "cloudflare-workers-ai",
            protocol: `protocol`,
            pathBuilder: { modelID in "/\(modelID)" }
        )

        // parity: ai/src/protocols/cloudflare-run-decisions.ts#CloudflareRunDecisions [status=implemented hash=5d0d0f14d5f1]
        public static let CloudflareRunDecisions = AIProtocols.CloudflareRunDecisions.self
    }

    // MARK: - 5. CloudflareWorkersAIImages (packages/ai/src/protocols/cloudflare-workers-ai-images.ts — 5 symbols)

    public enum CloudflareWorkersAIImages {
        // parity: ai/src/protocols/cloudflare-workers-ai-images.ts#CloudflareWorkersAIImageOptions [status=implemented hash=6496e61ef66a]
        public typealias CloudflareWorkersAIImageOptions = [String: JSONValue]

        // parity: ai/src/protocols/cloudflare-workers-ai-images.ts#Request [status=implemented hash=163fb959970f]
        public typealias Request = ImageRequestPayload

        // parity: ai/src/protocols/cloudflare-workers-ai-images.ts#protocol [status=implemented hash=ddeb3a42695c]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "cloudflare-workers-ai-images", name: "Cloudflare Workers AI Images", provider: "cloudflare-workers-ai"),
            mode: .inline
        )

        // parity: ai/src/protocols/cloudflare-workers-ai-images.ts#model [status=implemented hash=cc4d8047dc9f]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input, pathOverride: "/\(input.id)")
        }

        // parity: ai/src/protocols/cloudflare-workers-ai-images.ts#CloudflareWorkersAIImages [status=implemented hash=60a880751516]
        public static let CloudflareWorkersAIImages = AIProtocols.CloudflareWorkersAIImages.self
    }

    // MARK: - 6. DeepgramSpeech (packages/ai/src/protocols/deepgram-speech.ts — 8 symbols)

    public enum DeepgramSpeech {
        // parity: ai/src/protocols/deepgram-speech.ts#DEFAULT_BASE_URL [status=implemented hash=0a1f66140d03]
        public static let DEFAULT_BASE_URL = "https://api.deepgram.com"

        // parity: ai/src/protocols/deepgram-speech.ts#PATH [status=implemented hash=47b420561e5c]
        public static let PATH = "/v1/speak"

        // parity: ai/src/protocols/deepgram-speech.ts#DeepgramEncoding [status=implemented hash=4e5c0fc0fe62]
        public typealias DeepgramEncoding = String

        // parity: ai/src/protocols/deepgram-speech.ts#DeepgramSpeechOptions [status=implemented hash=99fe387c82ea]
        public typealias DeepgramSpeechOptions = [String: JSONValue]

        // parity: ai/src/protocols/deepgram-speech.ts#Request [status=implemented hash=560a21e16471]
        public typealias Request = SpeechRequestPayload

        // parity: ai/src/protocols/deepgram-speech.ts#protocol [status=implemented hash=bf40225b95bc]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "deepgram-speech", name: "Deepgram", provider: "deepgram"),
            mode: .stream,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/deepgram-speech.ts#model [status=implemented hash=1e39f292f031]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/deepgram-speech.ts#DeepgramSpeech [status=implemented hash=192ffa13fd8b]
        public static let DeepgramSpeech = AIProtocols.DeepgramSpeech.self
    }

    // MARK: - 7. DeepgramTranscription (packages/ai/src/protocols/deepgram-transcription.ts — 7 symbols)

    public enum DeepgramTranscription {
        // parity: ai/src/protocols/deepgram-transcription.ts#DEFAULT_BASE_URL [status=implemented hash=0a1f66140d03]
        public static let DEFAULT_BASE_URL = "https://api.deepgram.com"

        // parity: ai/src/protocols/deepgram-transcription.ts#PATH [status=implemented hash=dca308dcac99]
        public static let PATH = "/v1/listen"

        // parity: ai/src/protocols/deepgram-transcription.ts#DeepgramTranscriptionOptions [status=implemented hash=fc5b3e0b5222]
        public typealias DeepgramTranscriptionOptions = [String: JSONValue]

        // parity: ai/src/protocols/deepgram-transcription.ts#Request [status=implemented hash=c7a294bf58a6]
        public typealias Request = TranscriptionRequestPayload

        // parity: ai/src/protocols/deepgram-transcription.ts#protocol [status=implemented hash=2ce8755724dc]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "deepgram-transcription", name: "Deepgram", provider: "deepgram"),
            mode: .inline,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/deepgram-transcription.ts#model [status=implemented hash=878217d650d2]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/deepgram-transcription.ts#DeepgramTranscription [status=implemented hash=865725519976]
        public static let DeepgramTranscription = AIProtocols.DeepgramTranscription.self
    }

    // MARK: - 8. ElevenLabsSpeech (packages/ai/src/protocols/elevenlabs-speech.ts — 8 symbols)

    public enum ElevenLabsSpeech {
        // parity: ai/src/protocols/elevenlabs-speech.ts#DEFAULT_BASE_URL [status=implemented hash=3992eb92ee13]
        public static let DEFAULT_BASE_URL = "https://api.elevenlabs.io"

        // parity: ai/src/protocols/elevenlabs-speech.ts#PATH [status=implemented hash=11a9ef52923a]
        public static let PATH = "/v1/text-to-speech"

        // parity: ai/src/protocols/elevenlabs-speech.ts#ElevenLabsOutputFormat [status=implemented hash=6c118966f4ce]
        public typealias ElevenLabsOutputFormat = String

        // parity: ai/src/protocols/elevenlabs-speech.ts#ElevenLabsSpeechOptions [status=implemented hash=4b5dec88d564]
        public typealias ElevenLabsSpeechOptions = [String: JSONValue]

        // parity: ai/src/protocols/elevenlabs-speech.ts#Request [status=implemented hash=97ed8161a20a]
        public typealias Request = SpeechRequestPayload

        // parity: ai/src/protocols/elevenlabs-speech.ts#protocol [status=implemented hash=4dec28f6877d]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "elevenlabs-speech", name: "ElevenLabs", provider: "elevenlabs"),
            mode: .stream,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/elevenlabs-speech.ts#model [status=implemented hash=92f1b6aa91f6]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/elevenlabs-speech.ts#ElevenLabsSpeech [status=implemented hash=0014c198c3a2]
        public static let ElevenLabsSpeech = AIProtocols.ElevenLabsSpeech.self
    }

    // MARK: - 9. ElevenLabsTranscription (packages/ai/src/protocols/elevenlabs-transcription.ts — 7 symbols)

    public enum ElevenLabsTranscription {
        // parity: ai/src/protocols/elevenlabs-transcription.ts#DEFAULT_BASE_URL [status=implemented hash=3992eb92ee13]
        public static let DEFAULT_BASE_URL = "https://api.elevenlabs.io"

        // parity: ai/src/protocols/elevenlabs-transcription.ts#PATH [status=implemented hash=fab9f6321ee5]
        public static let PATH = "/v1/speech-to-text"

        // parity: ai/src/protocols/elevenlabs-transcription.ts#ElevenLabsTranscriptionOptions [status=implemented hash=a6b9c171b2fc]
        public typealias ElevenLabsTranscriptionOptions = [String: JSONValue]

        // parity: ai/src/protocols/elevenlabs-transcription.ts#Request [status=implemented hash=0dffb2c6bc51]
        public typealias Request = TranscriptionRequestPayload

        // parity: ai/src/protocols/elevenlabs-transcription.ts#protocol [status=implemented hash=ac1d8349b514]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "elevenlabs-transcription", name: "ElevenLabs", provider: "elevenlabs"),
            mode: .inline,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/elevenlabs-transcription.ts#model [status=implemented hash=4f9ee2933015]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/elevenlabs-transcription.ts#ElevenLabsTranscription [status=implemented hash=40c187fc97bf]
        public static let ElevenLabsTranscription = AIProtocols.ElevenLabsTranscription.self
    }

    // MARK: - 10. GoogleDecisions (packages/ai/src/protocols/google-decisions.ts — 4 symbols)

    public enum GoogleDecisions {
        // parity: ai/src/protocols/google-decisions.ts#DEFAULT_BASE_URL [status=implemented hash=ae7b30027e03]
        public static let DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

        // parity: ai/src/protocols/google-decisions.ts#OptionsInput [status=implemented hash=f75e9b8ed22c]
        public typealias OptionsInput = [String: JSONValue]

        // parity: ai/src/protocols/google-decisions.ts#protocol [status=implemented hash=dd17ba538021]
        public static let `protocol` = DecisionProtocolSpec(
            id: "google-decisions",
            name: "Google Decisions",
            provider: "google",
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                try SystemOneProtocol.encodeBody(req, fallbackMediaInput: "state")
            }
        )

        // parity: ai/src/protocols/google-decisions.ts#route [status=implemented hash=c99a4814ded5]
        public static let route = DecisionRouteSpec(
            id: "google-decisions",
            provider: "google",
            protocol: `protocol`,
            defaultBaseURL: DEFAULT_BASE_URL,
            pathBuilder: { modelID in "/models/\(modelID):generateContent" }
        )
    }

    // MARK: - 11. GoogleEmbedContent (packages/ai/src/protocols/google-embed-content.ts — 9 symbols)

    public enum GoogleEmbedContent {
        // parity: ai/src/protocols/google-embed-content.ts#DEFAULT_BASE_URL [status=implemented hash=ae7b30027e03]
        public static let DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

        // parity: ai/src/protocols/google-embed-content.ts#MAX_BATCH [status=implemented hash=0232bf763a89]
        public static let MAX_BATCH = 100

        // parity: ai/src/protocols/google-embed-content.ts#TaskType [status=implemented hash=38995862b2e1]
        public typealias TaskType = String

        // parity: ai/src/protocols/google-embed-content.ts#OptionsInput [status=implemented hash=f0b4bb236a5c]
        public struct OptionsInput: Equatable, Hashable, Sendable {
            public var taskType: TaskType?
            public var title: String?
            public init(taskType: TaskType? = nil, title: String? = nil) {
                self.taskType = taskType; self.title = title
            }
        }

        // parity: ai/src/protocols/google-embed-content.ts#VertexOptionsInput [status=implemented hash=3c1304b1122c]
        public struct VertexOptionsInput: Equatable, Hashable, Sendable {
            public var taskType: TaskType?
            public var title: String?
            public var autoTruncate: Bool?
            public var documentOcr: Bool?
            public var audioTrackExtraction: Bool?
            public init(
                taskType: TaskType? = nil, title: String? = nil,
                autoTruncate: Bool? = nil, documentOcr: Bool? = nil, audioTrackExtraction: Bool? = nil
            ) {
                self.taskType = taskType; self.title = title
                self.autoTruncate = autoTruncate; self.documentOcr = documentOcr
                self.audioTrackExtraction = audioTrackExtraction
            }
        }

        private static func encodeContent(_ value: EmbeddingInputValue) throws(AIProtocolUtils.ProtocolError) -> JSONValue {
            switch value {
            case .text(let s):
                return .object(["parts": .array([.object(["text": .string(s)])])])
            case .media(let asset):
                let part = try AIProtocolUtils.GeminiGenerateContent.mediaPart(route: "Google embedContent", asset: asset)
                return .object(["parts": .array([.object(part)])])
            }
        }

        private static func buildConfig(_ req: EmbeddingRequestPayload) -> [String: JSONValue] {
            var cfg = req.providerOptions ?? [:]
            if let inputType = req.inputType, cfg["taskType"] == nil {
                if inputType == "query" { cfg["taskType"] = .string("RETRIEVAL_QUERY") }
                else if inputType == "document" { cfg["taskType"] = .string("RETRIEVAL_DOCUMENT") }
            }
            if let dims = req.dimensions { cfg["outputDimensionality"] = .int(Int64(dims)) }
            return cfg
        }

        // parity: ai/src/protocols/google-embed-content.ts#protocol [status=implemented hash=c1e02e2cec22]
        public static let `protocol` = EmbeddingProtocolSpec(
            id: "google-embed-content",
            name: "Google embedContent",
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                var items: [JSONValue] = []
                let fields = buildConfig(req)
                for value in req.values {
                    var entry = fields
                    entry["model"] = .string("models/\(req.model.id)")
                    entry["content"] = try encodeContent(value)
                    items.append(.object(entry))
                }
                return AIProtocolUtils.JSONCodec.mergeObjects(["requests": .array(items)], req.httpBody)
            },
            decodeResponse: { text, metaKey throws(AIProtocolUtils.ProtocolError) in
                let parsed = try AIProtocolUtils.ProviderShared.parseJson(route: "google-embed-content", input: text, message: "Invalid Google embedContent response")
                guard let obj = AIProtocolUtils.JSONCodec.objectValue(parsed),
                      let list = AIProtocolUtils.JSONCodec.arrayValue(obj["embeddings"]) else {
                    throw AIProtocolUtils.ProviderShared.eventError("google-embed-content", "Missing embeddings array", body: text)
                }
                let vectors: [[Double]] = list.map { entry in
                    let vals = AIProtocolUtils.JSONCodec.arrayValue(AIProtocolUtils.JSONCodec.objectValue(entry)?["values"]) ?? []
                    return vals.compactMap(AIProtocolUtils.JSONCodec.doubleValue)
                }
                let usageMeta = AIProtocolUtils.JSONCodec.objectValue(obj["usageMetadata"])
                let tokens = AIProtocolUtils.JSONCodec.doubleValue(usageMeta?["promptTokenCount"])
                return EmbeddingResponsePayload(
                    embeddings: vectors,
                    inputTokens: tokens,
                    providerMetadata: [metaKey: usageMeta.map { ["usageMetadata": .object($0)] } ?? [:]]
                )
            }
        )

        // parity: ai/src/protocols/google-embed-content.ts#vertexProtocol [status=implemented hash=db79bb2dc4e6]
        public static let vertexProtocol = EmbeddingProtocolSpec(
            id: "google-vertex-embed-content",
            name: "Google Vertex embedContent",
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                guard let first = req.values.first else {
                    throw AIProtocolUtils.ProviderShared.invalidRequest("Google Vertex embedContent requires at least one value")
                }
                let fields = buildConfig(req)
                var base: [String: JSONValue] = ["content": try encodeContent(first)]
                if !fields.isEmpty { base["embedContentConfig"] = .object(fields) }
                return AIProtocolUtils.JSONCodec.mergeObjects(base, req.httpBody)
            },
            decodeResponse: { text, metaKey throws(AIProtocolUtils.ProtocolError) in
                let parsed = try AIProtocolUtils.ProviderShared.parseJson(route: "google-vertex-embed-content", input: text, message: "Invalid Vertex embedContent response")
                guard let obj = AIProtocolUtils.JSONCodec.objectValue(parsed),
                      let embObj = AIProtocolUtils.JSONCodec.objectValue(obj["embedding"]),
                      let vals = AIProtocolUtils.JSONCodec.arrayValue(embObj["values"]) else {
                    throw AIProtocolUtils.ProviderShared.eventError("google-vertex-embed-content", "Missing embedding values", body: text)
                }
                let vector = vals.compactMap(AIProtocolUtils.JSONCodec.doubleValue)
                let usageMeta = AIProtocolUtils.JSONCodec.objectValue(obj["usageMetadata"])
                let tokens = AIProtocolUtils.JSONCodec.doubleValue(usageMeta?["promptTokenCount"])
                var meta: [String: JSONValue] = [:]
                if let usageMeta { meta["usageMetadata"] = .object(usageMeta) }
                if let trunc = obj["truncated"] { meta["truncated"] = trunc }
                return EmbeddingResponsePayload(embeddings: [vector], inputTokens: tokens, providerMetadata: [metaKey: meta])
            }
        )

        // parity: ai/src/protocols/google-embed-content.ts#route [status=implemented hash=f7172ea6d720]
        public static let route = EmbeddingRouteSpec(
            id: "google-embed-content",
            provider: "google",
            protocol: `protocol`,
            defaultBaseURL: DEFAULT_BASE_URL,
            pathBuilder: { modelID in "/models/\(modelID):batchEmbedContents" },
            maxValues: MAX_BATCH
        )

        // parity: ai/src/protocols/google-embed-content.ts#GoogleEmbedContent [status=implemented hash=c7d838de1807]
        public static let GoogleEmbedContent = AIProtocols.GoogleEmbedContent.self
    }

    // MARK: - 12. GoogleImages (packages/ai/src/protocols/google-images.ts — 6 symbols)

    public enum GoogleImages {
        // parity: ai/src/protocols/google-images.ts#DEFAULT_BASE_URL [status=implemented hash=ae7b30027e03]
        public static let DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

        // parity: ai/src/protocols/google-images.ts#GoogleImageOptions [status=implemented hash=950cf5daf5d6]
        public typealias GoogleImageOptions = [String: JSONValue]

        // parity: ai/src/protocols/google-images.ts#Request [status=implemented hash=513264af475e]
        public typealias Request = ImageRequestPayload

        // parity: ai/src/protocols/google-images.ts#protocol [status=implemented hash=ddeb3a42695c]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "google-images", name: "Google Images", provider: "google"),
            mode: .inline,
            defaultBaseURL: DEFAULT_BASE_URL
        )

        // parity: ai/src/protocols/google-images.ts#model [status=implemented hash=23a027c23eb9]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input, pathOverride: "/models/\(input.id):generateContent")
        }

        // parity: ai/src/protocols/google-images.ts#GoogleImages [status=implemented hash=32ce11fe1ab7]
        public static let GoogleImages = AIProtocols.GoogleImages.self
    }

    // MARK: - 13. GoogleInteractionsVideo (packages/ai/src/protocols/google-interactions-video.ts — 8 symbols)

    public enum GoogleInteractionsVideo {
        // parity: ai/src/protocols/google-interactions-video.ts#DEFAULT_BASE_URL [status=implemented hash=31b1fd2b0c34]
        public static let DEFAULT_BASE_URL = GoogleInteractions.DEFAULT_BASE_URL

        // parity: ai/src/protocols/google-interactions-video.ts#PATH [status=implemented hash=d93a8211098f]
        public static let PATH = "/interactions"

        // parity: ai/src/protocols/google-interactions-video.ts#GoogleVideoOptions [status=implemented hash=de0034fcebc6]
        public typealias GoogleVideoOptions = [String: JSONValue]

        // parity: ai/src/protocols/google-interactions-video.ts#Request [status=implemented hash=1aae4c979925]
        public typealias Request = VideoRequestPayload

        // parity: ai/src/protocols/google-interactions-video.ts#Token [status=implemented hash=3db348ce72a1]
        public typealias Token = String

        // parity: ai/src/protocols/google-interactions-video.ts#protocol [status=implemented hash=1480833e8bd3]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "google-interactions-video", name: "Google Video", provider: "google"),
            mode: .queued,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/google-interactions-video.ts#model [status=implemented hash=ec588dbd7b0a]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/google-interactions-video.ts#GoogleInteractionsVideo [status=implemented hash=f9c80ae47383]
        public static let GoogleInteractionsVideo = AIProtocols.GoogleInteractionsVideo.self
    }

    // MARK: - 14. GoogleSpeech (packages/ai/src/protocols/google-speech.ts — 6 symbols)

    public enum GoogleSpeech {
        // parity: ai/src/protocols/google-speech.ts#DEFAULT_BASE_URL [status=implemented hash=ae7b30027e03]
        public static let DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

        // parity: ai/src/protocols/google-speech.ts#GoogleSpeechOptions [status=implemented hash=24d02db83ed0]
        public typealias GoogleSpeechOptions = [String: JSONValue]

        // parity: ai/src/protocols/google-speech.ts#Request [status=implemented hash=fecd1ffd582e]
        public typealias Request = SpeechRequestPayload

        // parity: ai/src/protocols/google-speech.ts#protocol [status=implemented hash=2297854cbca2]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "google-speech", name: "Google Speech", provider: "google"),
            mode: .stream,
            defaultBaseURL: DEFAULT_BASE_URL
        )

        // parity: ai/src/protocols/google-speech.ts#model [status=implemented hash=e936971ed3d9]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input, pathOverride: AIProtocolUtils.GeminiGenerateContent.path(model: input.id, streaming: true))
        }

        // parity: ai/src/protocols/google-speech.ts#GoogleSpeech [status=implemented hash=bd37e83cc4e5]
        public static let GoogleSpeech = AIProtocols.GoogleSpeech.self
    }

    // MARK: - 15. GoogleTranscription (packages/ai/src/protocols/google-transcription.ts — 6 symbols)

    public enum GoogleTranscription {
        // parity: ai/src/protocols/google-transcription.ts#DEFAULT_BASE_URL [status=implemented hash=ae7b30027e03]
        public static let DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

        // parity: ai/src/protocols/google-transcription.ts#GoogleTranscriptionOptions [status=implemented hash=e70faa35a8d3]
        public typealias GoogleTranscriptionOptions = [String: JSONValue]

        // parity: ai/src/protocols/google-transcription.ts#Request [status=implemented hash=f70e255f0961]
        public typealias Request = TranscriptionRequestPayload

        // parity: ai/src/protocols/google-transcription.ts#protocol [status=implemented hash=853d56766669]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "google-transcription", name: "Google Transcription", provider: "google"),
            mode: .stream,
            defaultBaseURL: DEFAULT_BASE_URL
        )

        // parity: ai/src/protocols/google-transcription.ts#model [status=implemented hash=eca87337bdb5]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input, pathOverride: AIProtocolUtils.GeminiGenerateContent.path(model: input.id, streaming: true))
        }

        // parity: ai/src/protocols/google-transcription.ts#GoogleTranscription [status=implemented hash=f1359b2ba1e1]
        public static let GoogleTranscription = AIProtocols.GoogleTranscription.self
    }

    // MARK: - 16. GoogleVertexPredictEmbeddings (packages/ai/src/protocols/google-vertex-predict-embeddings.ts — 4 symbols)

    public enum GoogleVertexPredictEmbeddings {
        // parity: ai/src/protocols/google-vertex-predict-embeddings.ts#MAX_INSTANCES [status=implemented hash=67c6709cc88f]
        public static let MAX_INSTANCES = 250

        // parity: ai/src/protocols/google-vertex-predict-embeddings.ts#OptionsInput [status=implemented hash=b89786fa8ba4]
        public struct OptionsInput: Equatable, Hashable, Sendable {
            public var taskType: String?
            public var title: String?
            public var autoTruncate: Bool?
            public init(taskType: String? = nil, title: String? = nil, autoTruncate: Bool? = nil) {
                self.taskType = taskType; self.title = title; self.autoTruncate = autoTruncate
            }
        }

        // parity: ai/src/protocols/google-vertex-predict-embeddings.ts#protocol [status=implemented hash=7fa9e4c38a3f]
        public static let `protocol` = EmbeddingProtocolSpec(
            id: "google-vertex-predict-embeddings",
            name: "Google Vertex Predict Embeddings",
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                var instances: [JSONValue] = []
                for v in req.values {
                    guard case .text(let s) = v else {
                        throw AIProtocolUtils.ProviderShared.unsupportedOperation(
                            operation: "embedding.media",
                            message: "Google Vertex predict embeddings accepts text values",
                            provider: req.model.provider,
                            route: req.model.routeID
                        )
                    }
                    var inst: [String: JSONValue] = ["content": .string(s)]
                    if let tt = req.providerOptions?["taskType"] { inst["task_type"] = tt }
                    if let title = req.providerOptions?["title"] { inst["title"] = title }
                    instances.append(.object(inst))
                }
                var params: [String: JSONValue] = [:]
                if let dims = req.dimensions { params["outputDimensionality"] = .int(Int64(dims)) }
                if let trunc = req.providerOptions?["autoTruncate"] { params["autoTruncate"] = trunc }
                var body: [String: JSONValue] = ["instances": .array(instances)]
                if !params.isEmpty { body["parameters"] = .object(params) }
                return AIProtocolUtils.JSONCodec.mergeObjects(body, req.httpBody)
            },
            decodeResponse: { text, metaKey throws(AIProtocolUtils.ProtocolError) in
                let parsed = try AIProtocolUtils.ProviderShared.parseJson(route: "google-vertex-predict-embeddings", input: text, message: "Invalid Vertex predict embeddings response")
                guard let obj = AIProtocolUtils.JSONCodec.objectValue(parsed),
                      let preds = AIProtocolUtils.JSONCodec.arrayValue(obj["predictions"]) else {
                    throw AIProtocolUtils.ProviderShared.eventError("google-vertex-predict-embeddings", "Missing predictions array", body: text)
                }
                var vectors: [[Double]] = []
                var tokenSum = 0.0
                var hasTokens = false
                for pred in preds {
                    let embObj = AIProtocolUtils.JSONCodec.objectValue(AIProtocolUtils.JSONCodec.objectValue(pred)?["embeddings"])
                    let vals = (AIProtocolUtils.JSONCodec.arrayValue(embObj?["values"]) ?? []).compactMap(AIProtocolUtils.JSONCodec.doubleValue)
                    vectors.append(vals)
                    if let stats = AIProtocolUtils.JSONCodec.objectValue(embObj?["statistics"]),
                       let tc = AIProtocolUtils.JSONCodec.doubleValue(stats["token_count"]) {
                        tokenSum += tc
                        hasTokens = true
                    }
                }
                return EmbeddingResponsePayload(
                    embeddings: vectors,
                    inputTokens: hasTokens ? tokenSum : nil,
                    providerMetadata: [metaKey: [:]]
                )
            }
        )

        // parity: ai/src/protocols/google-vertex-predict-embeddings.ts#GoogleVertexPredictEmbeddings [status=implemented hash=7e72ea2544a5]
        public static let GoogleVertexPredictEmbeddings = AIProtocols.GoogleVertexPredictEmbeddings.self
    }

    // MARK: - 17. MetaImages (packages/ai/src/protocols/meta-images.ts — 5 symbols)

    public enum MetaImages {
        // parity: ai/src/protocols/meta-images.ts#DEFAULT_BASE_URL [status=implemented hash=80087103d2e6]
        public static let DEFAULT_BASE_URL = "https://api.meta.ai/v1"

        // parity: ai/src/protocols/meta-images.ts#ImageOptions [status=implemented hash=95d0dedfbc0b]
        public typealias ImageOptions = [String: JSONValue]

        // parity: ai/src/protocols/meta-images.ts#Request [status=implemented hash=e92ff3a61f7d]
        public typealias Request = ImageRequestPayload

        // parity: ai/src/protocols/meta-images.ts#protocol [status=implemented hash=ddeb3a42695c]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "meta-images", name: "Meta Images", provider: "meta"),
            mode: .inline,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: "/responses"
        )

        // parity: ai/src/protocols/meta-images.ts#model [status=implemented hash=83cb67ca4115]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }
    }

    // MARK: - 18. MiniMaxImages (packages/ai/src/protocols/minimax-images.ts — 7 symbols)

    public enum MiniMaxImages {
        // parity: ai/src/protocols/minimax-images.ts#DEFAULT_BASE_URL [status=implemented hash=0af1a202e8a7]
        public static let DEFAULT_BASE_URL = "https://api.minimax.io/v1"

        // parity: ai/src/protocols/minimax-images.ts#PATH [status=implemented hash=8dbe77a7f9ba]
        public static let PATH = "/image_generation"

        // parity: ai/src/protocols/minimax-images.ts#MiniMaxImageOptions [status=implemented hash=1bb55dda48f0]
        public typealias MiniMaxImageOptions = [String: JSONValue]

        // parity: ai/src/protocols/minimax-images.ts#Request [status=implemented hash=7525daf2128e]
        public typealias Request = ImageRequestPayload

        // parity: ai/src/protocols/minimax-images.ts#protocol [status=implemented hash=ddeb3a42695c]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "minimax-images", name: "MiniMax Images", provider: "minimax"),
            mode: .inline,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/minimax-images.ts#model [status=implemented hash=f69c391c2a85]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/minimax-images.ts#MiniMaxImages [status=implemented hash=51f49808d238]
        public static let MiniMaxImages = AIProtocols.MiniMaxImages.self
    }

    // MARK: - 19. MiniMaxVideo (packages/ai/src/protocols/minimax-video.ts — 15 symbols)

    public enum MiniMaxVideo {
        // parity: ai/src/protocols/minimax-video.ts#DEFAULT_BASE_URL [status=implemented hash=5ca08f8937f2]
        public static let DEFAULT_BASE_URL = "https://api.minimax.io"

        // parity: ai/src/protocols/minimax-video.ts#PATH [status=implemented hash=c92613212e27]
        public static let PATH = "/v2/video_generation"

        // parity: ai/src/protocols/minimax-video.ts#STATUS_PATH [status=implemented hash=13da0e842513]
        public static let STATUS_PATH = "/v2/query/video_generation"

        // parity: ai/src/protocols/minimax-video.ts#HAILUO_PATH [status=implemented hash=7ba7524a651f]
        public static let HAILUO_PATH = "/v1/video_generation"

        // parity: ai/src/protocols/minimax-video.ts#HAILUO_STATUS_PATH [status=implemented hash=d71fb3abfce4]
        public static let HAILUO_STATUS_PATH = "/v1/query/video_generation"

        // parity: ai/src/protocols/minimax-video.ts#FILE_PATH [status=implemented hash=23849ef9707d]
        public static let FILE_PATH = "/v1/files/retrieve"

        // parity: ai/src/protocols/minimax-video.ts#MiniMaxVideoOptions [status=implemented hash=bcd292f524ee]
        public typealias MiniMaxVideoOptions = [String: JSONValue]

        // parity: ai/src/protocols/minimax-video.ts#Request [status=implemented hash=92ffd4f20077]
        public typealias Request = VideoRequestPayload

        // parity: ai/src/protocols/minimax-video.ts#Token [status=implemented hash=3db348ce72a1]
        public typealias Token = String

        // parity: ai/src/protocols/minimax-video.ts#protocol [status=implemented hash=e660004989d4]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "minimax-video", name: "MiniMax Video", provider: "minimax"),
            mode: .queued,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/minimax-video.ts#hailuoProtocol [status=implemented hash=938836a58031]
        public static let hailuoProtocol = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "minimax-hailuo-video", name: "MiniMax Hailuo Video", provider: "minimax"),
            mode: .queued,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: HAILUO_PATH
        )

        // parity: ai/src/protocols/minimax-video.ts#h3Model [status=implemented hash=4e612547fdb0]
        public static func h3Model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/minimax-video.ts#hailuoModel [status=implemented hash=2a188847ec79]
        public static func hailuoModel(_ input: MediaModelInput) -> MediaModelHandle {
            hailuoProtocol.makeModel(input)
        }

        private static func isHailuo(_ id: String) -> Bool {
            let lower = id.lowercased()
            return lower.contains("hailuo") || lower.hasPrefix("t2v-") || lower.hasPrefix("i2v-") || lower.hasPrefix("s2v-")
        }

        // parity: ai/src/protocols/minimax-video.ts#model [status=implemented hash=dc08017272f5]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            isHailuo(input.id) ? hailuoModel(input) : h3Model(input)
        }

        // parity: ai/src/protocols/minimax-video.ts#MiniMaxVideo [status=implemented hash=f759f11ca94e]
        public static let MiniMaxVideo = AIProtocols.MiniMaxVideo.self
    }

    // MARK: - 20. OpenAIDecisions (packages/ai/src/protocols/openai-decisions.ts — 6 symbols)

    public enum OpenAIDecisions {
        // parity: ai/src/protocols/openai-decisions.ts#DEFAULT_BASE_URL [status=implemented hash=97f5685da742]
        public static let DEFAULT_BASE_URL = "https://api.openai.com/v1"

        // parity: ai/src/protocols/openai-decisions.ts#PATH [status=implemented hash=18206621d2e1]
        public static let PATH = "/decisions"

        // parity: ai/src/protocols/openai-decisions.ts#OptionsInput [status=implemented hash=f75e9b8ed22c]
        public typealias OptionsInput = [String: JSONValue]

        // parity: ai/src/protocols/openai-decisions.ts#protocol [status=implemented hash=b72e3d89e394]
        public static let `protocol` = DecisionProtocolSpec(
            id: "openai-decisions",
            name: "OpenAI Decisions",
            provider: "openai",
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                var body = try SystemOneProtocol.encodeBody(req, fallbackMediaInput: "state")
                body["model"] = .string(req.model.id)
                return body
            }
        )

        // parity: ai/src/protocols/openai-decisions.ts#route [status=implemented hash=75fd1f0a3aef]
        public static let route = DecisionRouteSpec(
            id: "openai-decisions",
            provider: "openai",
            protocol: `protocol`,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/openai-decisions.ts#OpenAIDecisions [status=implemented hash=6831402606bd]
        public static let OpenAIDecisions = AIProtocols.OpenAIDecisions.self
    }

    // MARK: - 21. OpenAIEmbeddings (packages/ai/src/protocols/openai-embeddings.ts — 6 symbols)

    public enum OpenAIEmbeddings {
        // parity: ai/src/protocols/openai-embeddings.ts#DEFAULT_BASE_URL [status=implemented hash=97f5685da742]
        public static let DEFAULT_BASE_URL = "https://api.openai.com/v1"

        // parity: ai/src/protocols/openai-embeddings.ts#PATH [status=implemented hash=ce30353f9610]
        public static let PATH = "/embeddings"

        // parity: ai/src/protocols/openai-embeddings.ts#OptionsInput [status=implemented hash=6183e4f0a516]
        public struct OptionsInput: Equatable, Hashable, Sendable {
            public var user: String?
            public var encodingFormat: String?
            public init(user: String? = nil, encodingFormat: String? = nil) {
                self.user = user; self.encodingFormat = encodingFormat
            }
        }

        private static func decodeBase64Float32LE(_ encoded: String) throws(AIProtocolUtils.ProtocolError) -> [Double] {
            let bytes: [UInt8]
            do {
                bytes = try base64ToBytes(encoded)
            } catch {
                throw AIProtocolUtils.ProviderShared.eventError("openai-embeddings", "OpenAI Embeddings returned an invalid base64 embedding")
            }
            guard bytes.count % 4 == 0 else {
                throw AIProtocolUtils.ProviderShared.eventError("openai-embeddings", "OpenAI Embeddings base64 byte length is not a multiple of 4")
            }
            var out: [Double] = []
            out.reserveCapacity(bytes.count / 4)
            var i = 0
            while i + 4 <= bytes.count {
                let bits = UInt32(bytes[i])
                    | (UInt32(bytes[i + 1]) << 8)
                    | (UInt32(bytes[i + 2]) << 16)
                    | (UInt32(bytes[i + 3]) << 24)
                out.append(Double(Float(bitPattern: bits)))
                i += 4
            }
            return out
        }

        // parity: ai/src/protocols/openai-embeddings.ts#protocol [status=implemented hash=2e346b027db9]
        public static let `protocol` = EmbeddingProtocolSpec(
            id: "openai-embeddings",
            name: "OpenAI Embeddings",
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                var strings: [JSONValue] = []
                for v in req.values {
                    guard case .text(let s) = v else {
                        throw AIProtocolUtils.ProviderShared.unsupportedOperation(
                            operation: "embedding.media",
                            message: "OpenAI Embeddings embeds text only; pass media values to a host with a multimodal embedding API",
                            provider: req.model.provider,
                            route: req.model.routeID
                        )
                    }
                    strings.append(.string(s))
                }
                var defaults: [String: JSONValue] = ["encoding_format": .string("float")]
                if let po = req.providerOptions {
                    for (k, v) in po { defaults[k] = v }
                }
                var merged = AIProtocolUtils.JSONCodec.mergeObjects(defaults, req.httpBody)
                merged["model"] = .string(req.model.id)
                merged["input"] = .array(strings)
                if let dims = req.dimensions { merged["dimensions"] = .int(Int64(dims)) }
                return merged
            },
            decodeResponse: { text, metaKey throws(AIProtocolUtils.ProtocolError) in
                let parsed = try AIProtocolUtils.ProviderShared.parseJson(route: "openai-embeddings", input: text, message: "Invalid OpenAI Embeddings response")
                guard let obj = AIProtocolUtils.JSONCodec.objectValue(parsed),
                      let data = AIProtocolUtils.JSONCodec.arrayValue(obj["data"]) else {
                    throw AIProtocolUtils.ProviderShared.eventError("openai-embeddings", "Missing data array", body: text)
                }
                var indexed: [(Int, JSONValue)] = []
                for (pos, entry) in data.enumerated() {
                    guard let item = AIProtocolUtils.JSONCodec.objectValue(entry),
                          let emb = item["embedding"] else { continue }
                    let idx = AIProtocolUtils.JSONCodec.intValue(item["index"]) ?? pos
                    indexed.append((idx, emb))
                }
                indexed.sort { $0.0 < $1.0 }
                var vectors: [[Double]] = []
                for (_, emb) in indexed {
                    if case .string(let b64) = emb {
                        vectors.append(try decodeBase64Float32LE(b64))
                    } else if case .array(let nums) = emb {
                        vectors.append(nums.compactMap(AIProtocolUtils.JSONCodec.doubleValue))
                    }
                }
                let usageObj = AIProtocolUtils.JSONCodec.objectValue(obj["usage"])
                let promptTokens = AIProtocolUtils.JSONCodec.doubleValue(usageObj?["prompt_tokens"])
                var meta: [String: JSONValue] = [:]
                if let m = obj["model"] { meta["model"] = m }
                if let usageObj { meta["usage"] = .object(usageObj) }
                return EmbeddingResponsePayload(
                    embeddings: vectors,
                    inputTokens: promptTokens,
                    providerMetadata: [metaKey: meta]
                )
            }
        )

        // parity: ai/src/protocols/openai-embeddings.ts#route [status=implemented hash=0da12329409e]
        public static let route = EmbeddingRouteSpec(
            id: "openai-embeddings",
            provider: "openai",
            protocol: `protocol`,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/openai-embeddings.ts#OpenAIEmbeddings [status=implemented hash=020454b03b5c]
        public static let OpenAIEmbeddings = AIProtocols.OpenAIEmbeddings.self
    }

    // MARK: - 22. OpenAIImages (packages/ai/src/protocols/openai-images.ts — 10 symbols)

    public enum OpenAIImages {
        // parity: ai/src/protocols/openai-images.ts#DEFAULT_BASE_URL [status=implemented hash=97f5685da742]
        public static let DEFAULT_BASE_URL = "https://api.openai.com/v1"

        // parity: ai/src/protocols/openai-images.ts#PATH [status=implemented hash=bb919f32959f]
        public static let PATH = "/images/generations"

        // parity: ai/src/protocols/openai-images.ts#EDIT_PATH [status=implemented hash=4f5d44e3ad14]
        public static let EDIT_PATH = "/images/edits"

        // parity: ai/src/protocols/openai-images.ts#OpenAIImageOptions [status=implemented hash=87d4ff9ae9b4]
        public typealias OpenAIImageOptions = [String: JSONValue]

        // parity: ai/src/protocols/openai-images.ts#Request [status=implemented hash=3cd9daa23813]
        public typealias Request = ImageRequestPayload

        // parity: ai/src/protocols/openai-images.ts#OpenAIImageSizing [status=implemented hash=daaf1ed6450e]
        public typealias OpenAIImageSizing = @Sendable (Request) -> [String: JSONValue]?

        // parity: ai/src/protocols/openai-images.ts#OpenAIImageInput [status=implemented hash=33738af924f8]
        public enum OpenAIImageInput: String, Equatable, Hashable, Sendable, Codable {
            case edits
            case jsonEdits = "json-edits"
            case references
        }

        public static func pixelSize(_ request: Request) -> [String: JSONValue]? {
            let shape = AIProtocolUtils.ImageSizing.Shape(aspect: request.aspect, resolution: request.resolution)
            guard AIProtocolUtils.ImageSizing.isRequested(shape) else { return nil }
            let id = request.modelID.split(separator: "/").last.map(String.init) ?? request.modelID
            let size: AIProtocolUtils.ImageSizing.Size
            if id.hasPrefix("dall-e-2") {
                size = AIProtocolUtils.ImageSizing.nearest(shape, sizes: [256, 512, 1024].map { .init(width: $0, height: $0) })
            } else if id.hasPrefix("dall-e-3") {
                size = AIProtocolUtils.ImageSizing.nearest(shape, sizes: [.init(width: 1024, height: 1024), .init(width: 1792, height: 1024), .init(width: 1024, height: 1792)])
            } else if id.hasPrefix("gpt-image-1") || id.hasPrefix("chatgpt-image") {
                size = AIProtocolUtils.ImageSizing.nearest(shape, sizes: [.init(width: 1024, height: 1024), .init(width: 1536, height: 1024), .init(width: 1024, height: 1536)])
            } else if id.hasPrefix("gpt-image-") {
                size = AIProtocolUtils.ImageSizing.fit(shape, limits: .init(multiple: 16, maxEdge: 3840, minPixels: 655_360, maxPixels: 8_294_400, maxRatio: 3))
            } else {
                size = AIProtocolUtils.ImageSizing.fit(shape, limits: .init(multiple: 16))
            }
            return ["size": .string("\(size.width)x\(size.height)")]
        }

        // parity: ai/src/protocols/openai-images.ts#protocol [status=implemented hash=67acee9f2c33]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "openai-images", name: "OpenAI Images", provider: "openai"),
            mode: .inline,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/openai-images.ts#model [status=implemented hash=20a6a9827cf3]
        public static func model(_ input: MediaModelInput, imageInput: OpenAIImageInput = .edits) -> MediaModelHandle {
            _ = imageInput
            return `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/openai-images.ts#OpenAIImages [status=implemented hash=347f95615e0a]
        public static let OpenAIImages = AIProtocols.OpenAIImages.self
    }

    // MARK: - 23. OpenAISpeech (packages/ai/src/protocols/openai-speech.ts — 7 symbols)

    public enum OpenAISpeech {
        // parity: ai/src/protocols/openai-speech.ts#DEFAULT_BASE_URL [status=implemented hash=97f5685da742]
        public static let DEFAULT_BASE_URL = "https://api.openai.com/v1"

        // parity: ai/src/protocols/openai-speech.ts#PATH [status=implemented hash=f3777d5f6bc0]
        public static let PATH = "/audio/speech"

        // parity: ai/src/protocols/openai-speech.ts#OpenAISpeechOptions [status=implemented hash=40aa56548d7f]
        public typealias OpenAISpeechOptions = [String: JSONValue]

        // parity: ai/src/protocols/openai-speech.ts#Request [status=implemented hash=da62c94cf290]
        public typealias Request = SpeechRequestPayload

        // parity: ai/src/protocols/openai-speech.ts#protocol [status=implemented hash=98af27e9358f]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "openai-speech", name: "OpenAI Speech", provider: "openai"),
            mode: .stream,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/openai-speech.ts#model [status=implemented hash=f945df719144]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/openai-speech.ts#OpenAISpeech [status=implemented hash=9049292b675c]
        public static let OpenAISpeech = AIProtocols.OpenAISpeech.self
    }

    // MARK: - 24. OpenAITranscription (packages/ai/src/protocols/openai-transcription.ts — 7 symbols)

    public enum OpenAITranscription {
        // parity: ai/src/protocols/openai-transcription.ts#DEFAULT_BASE_URL [status=implemented hash=97f5685da742]
        public static let DEFAULT_BASE_URL = "https://api.openai.com/v1"

        // parity: ai/src/protocols/openai-transcription.ts#PATH [status=implemented hash=c49cf2ccf6b6]
        public static let PATH = "/audio/transcriptions"

        // parity: ai/src/protocols/openai-transcription.ts#OpenAITranscriptionOptions [status=implemented hash=89657e28856f]
        public typealias OpenAITranscriptionOptions = [String: JSONValue]

        // parity: ai/src/protocols/openai-transcription.ts#Request [status=implemented hash=b35dbdd7ad13]
        public typealias Request = TranscriptionRequestPayload

        // parity: ai/src/protocols/openai-transcription.ts#protocol [status=implemented hash=7b276d1d40f2]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "openai-transcription", name: "OpenAI Transcription", provider: "openai"),
            mode: .stream,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/openai-transcription.ts#model [status=implemented hash=ea04abff90e8]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/openai-transcription.ts#OpenAITranscription [status=implemented hash=d3d7a35453ac]
        public static let OpenAITranscription = AIProtocols.OpenAITranscription.self
    }

    // MARK: - 25. OpenRouterVideo (packages/ai/src/protocols/openrouter-video.ts — 8 symbols)

    public enum OpenRouterVideo {
        // parity: ai/src/protocols/openrouter-video.ts#DEFAULT_BASE_URL [status=implemented hash=b9d1cc5c7087]
        public static let DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"

        // parity: ai/src/protocols/openrouter-video.ts#PATH [status=implemented hash=365083670db9]
        public static let PATH = "/videos"

        // parity: ai/src/protocols/openrouter-video.ts#OpenRouterVideoOptions [status=implemented hash=efb09a37acbb]
        public typealias OpenRouterVideoOptions = [String: JSONValue]

        // parity: ai/src/protocols/openrouter-video.ts#Request [status=implemented hash=48d02dadda1e]
        public typealias Request = VideoRequestPayload

        // parity: ai/src/protocols/openrouter-video.ts#Token [status=implemented hash=3db348ce72a1]
        public typealias Token = String

        // parity: ai/src/protocols/openrouter-video.ts#protocol [status=implemented hash=1bbddd2ca7ba]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "openrouter-video", name: "OpenRouter Video", provider: "openrouter"),
            mode: .queued,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/openrouter-video.ts#model [status=implemented hash=9636accbda25]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/openrouter-video.ts#OpenRouterVideo [status=implemented hash=c990c6299cb5]
        public static let OpenRouterVideo = AIProtocols.OpenRouterVideo.self
    }

    // MARK: - 26. SeedanceVideo (packages/ai/src/protocols/seedance-video.ts — 7 symbols)

    public enum SeedanceVideo {
        // parity: ai/src/protocols/seedance-video.ts#VOLCENGINE_BASE_URL [status=implemented hash=e66a3c7eaca8]
        public static let VOLCENGINE_BASE_URL = "https://ark.cn-beijing.volces.com/api/v3"

        // parity: ai/src/protocols/seedance-video.ts#BYTEPLUS_BASE_URL [status=implemented hash=520f2876fed9]
        public static let BYTEPLUS_BASE_URL = "https://ark.ap-southeast.bytepluses.com/api/v3"

        // parity: ai/src/protocols/seedance-video.ts#PATH [status=implemented hash=c9999adb2411]
        public static let PATH = "/contents/generations/tasks"

        // parity: ai/src/protocols/seedance-video.ts#SeedanceVideoOptions [status=implemented hash=7a4257ce6d95]
        public typealias SeedanceVideoOptions = [String: JSONValue]

        // parity: ai/src/protocols/seedance-video.ts#Request [status=implemented hash=3118ffc4310e]
        public typealias Request = VideoRequestPayload

        // parity: ai/src/protocols/seedance-video.ts#Token [status=implemented hash=3db348ce72a1]
        public typealias Token = String

        // parity: ai/src/protocols/seedance-video.ts#Provider [status=implemented hash=4887c47d908e]
        public enum Provider: String, Equatable, Hashable, Sendable, Codable {
            case volcengine
            case byteplus

            public var defaultBaseURL: String {
                switch self {
                case .volcengine: return SeedanceVideo.VOLCENGINE_BASE_URL
                case .byteplus: return SeedanceVideo.BYTEPLUS_BASE_URL
                }
            }
        }

        public static func model(_ input: MediaModelInput, provider: Provider = .volcengine) -> MediaModelHandle {
            MediaModelHandle(
                id: input.id,
                provider: input.provider ?? provider.rawValue,
                protocolID: "seedance-video",
                baseURL: input.baseURL ?? provider.defaultBaseURL,
                path: PATH,
                mode: .queued,
                providerOptions: input.providerOptions
            )
        }
    }

    // MARK: - 27. XAIImages (packages/ai/src/protocols/xai-images.ts — 9 symbols)

    public enum XAIImages {
        // parity: ai/src/protocols/xai-images.ts#DEFAULT_BASE_URL [status=implemented hash=cc60095d3c12]
        public static let DEFAULT_BASE_URL = "https://api.x.ai/v1"

        // parity: ai/src/protocols/xai-images.ts#PATH [status=implemented hash=bb919f32959f]
        public static let PATH = "/images/generations"

        // parity: ai/src/protocols/xai-images.ts#EDIT_PATH [status=implemented hash=4f5d44e3ad14]
        public static let EDIT_PATH = "/images/edits"

        // parity: ai/src/protocols/xai-images.ts#XAIImageOptions [status=implemented hash=613d0e24b39f]
        public typealias XAIImageOptions = [String: JSONValue]

        // parity: ai/src/protocols/xai-images.ts#Request [status=implemented hash=57a5c6dbf3c6]
        public typealias Request = ImageRequestPayload

        // parity: ai/src/protocols/xai-images.ts#resolution [status=implemented hash=571513d918fc]
        public static func resolution(_ requested: String?) -> String? {
            guard let requested else { return nil }
            return (AIProtocolUtils.ImageSizing.tier(requested) ?? 1.0) < 1.5 ? "1k" : "2k"
        }

        // parity: ai/src/protocols/xai-images.ts#protocol [status=implemented hash=ddeb3a42695c]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "xai-images", name: "xAI Images", provider: "xai"),
            mode: .inline,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/xai-images.ts#model [status=implemented hash=b1f1a2e21049]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/xai-images.ts#XAIImages [status=implemented hash=218256aa10ab]
        public static let XAIImages = AIProtocols.XAIImages.self
    }

    // MARK: - 28. XAIVideo (packages/ai/src/protocols/xai-video.ts — 11 symbols)

    public enum XAIVideo {
        // parity: ai/src/protocols/xai-video.ts#DEFAULT_BASE_URL [status=implemented hash=cc60095d3c12]
        public static let DEFAULT_BASE_URL = "https://api.x.ai/v1"

        // parity: ai/src/protocols/xai-video.ts#PATH [status=implemented hash=7a24ace06b7d]
        public static let PATH = "/videos/generations"

        // parity: ai/src/protocols/xai-video.ts#EDIT_PATH [status=implemented hash=1c7af90e4f01]
        public static let EDIT_PATH = "/videos/edits"

        // parity: ai/src/protocols/xai-video.ts#EXTEND_PATH [status=implemented hash=87756a355faf]
        public static let EXTEND_PATH = "/videos/extensions"

        // parity: ai/src/protocols/xai-video.ts#STATUS_PATH [status=implemented hash=823277b18653]
        public static let STATUS_PATH = "/videos"

        // parity: ai/src/protocols/xai-video.ts#XAIVideoOptions [status=implemented hash=8fbeee9be4f3]
        public typealias XAIVideoOptions = [String: JSONValue]

        // parity: ai/src/protocols/xai-video.ts#Request [status=implemented hash=cde0226bdc76]
        public typealias Request = VideoRequestPayload

        // parity: ai/src/protocols/xai-video.ts#Token [status=implemented hash=3db348ce72a1]
        public typealias Token = String

        // parity: ai/src/protocols/xai-video.ts#protocol [status=implemented hash=22c1b5ec2702]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "xai-video", name: "xAI Video", provider: "xai"),
            mode: .queued,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/xai-video.ts#model [status=implemented hash=c308ae45f397]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/xai-video.ts#XAIVideo [status=implemented hash=f80ab3d74128]
        public static let XAIVideo = AIProtocols.XAIVideo.self
    }

    // MARK: - 29. ZAIImages (packages/ai/src/protocols/zai-images.ts — 7 symbols)

    public enum ZAIImages {
        // parity: ai/src/protocols/zai-images.ts#DEFAULT_BASE_URL [status=implemented hash=e01b2ebca740]
        public static let DEFAULT_BASE_URL = "https://api.z.ai/api/paas/v4"

        // parity: ai/src/protocols/zai-images.ts#PATH [status=implemented hash=bb919f32959f]
        public static let PATH = "/images/generations"

        // parity: ai/src/protocols/zai-images.ts#ZAIImageOptions [status=implemented hash=2f7ce57416f5]
        public typealias ZAIImageOptions = [String: JSONValue]

        // parity: ai/src/protocols/zai-images.ts#Request [status=implemented hash=b4603ea8320c]
        public typealias Request = ImageRequestPayload

        // parity: ai/src/protocols/zai-images.ts#protocol [status=implemented hash=39c16089ff60]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "zai-images", name: "Z.ai Images", provider: "zai"),
            mode: .inline,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/zai-images.ts#model [status=implemented hash=9918339341ca]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/zai-images.ts#ZAIImages [status=implemented hash=0053cec11267]
        public static let ZAIImages = AIProtocols.ZAIImages.self
    }
}
