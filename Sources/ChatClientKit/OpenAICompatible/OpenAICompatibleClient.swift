import Foundation
import ServerEvent

open class OpenAICompatibleClient: BaseChatClient, @unchecked Sendable {
    open var baseURL: String?
    open var path: String?
    open var apiKey: String?
    open var defaultHeaders: [String: String]
    open var defaultQueryItems: [URLQueryItem]
    open var requestCustomization: [String: Any]

    public enum Error: Swift.Error {
        case invalidURL
        case invalidApiKey
        case invalidData
    }

    let eventSourceFactory: EventSourceProducing
    let chunkDecoderFactory: @Sendable () -> JSONDecoding
    let errorExtractor: CompletionErrorExtractor

    public convenience init(
        baseURL: String? = nil,
        path: String? = nil,
        apiKey: String? = nil,
        defaultHeaders: [String: String] = [:],
        defaultQueryItems: [URLQueryItem] = [],
        requestCustomization: [String: Any] = [:]
    ) {
        self.init(
            baseURL: baseURL,
            path: path,
            apiKey: apiKey,
            defaultHeaders: defaultHeaders,
            defaultQueryItems: defaultQueryItems,
            requestCustomization: requestCustomization,
            dependencies: .live
        )
    }

    public init(
        baseURL: String? = nil,
        path: String? = nil,
        apiKey: String? = nil,
        defaultHeaders: [String: String] = [:],
        defaultQueryItems: [URLQueryItem] = [],
        requestCustomization: [String: Any] = [:],
        errorCollector: ErrorCollector = .new(),
        dependencies: RemoteClientDependencies
    ) {
        self.baseURL = baseURL
        self.path = path
        self.apiKey = apiKey
        self.defaultHeaders = defaultHeaders
        self.defaultQueryItems = defaultQueryItems
        self.requestCustomization = requestCustomization
        eventSourceFactory = dependencies.eventSourceFactory
        chunkDecoderFactory = dependencies.chunkDecoderFactory
        errorExtractor = dependencies.errorExtractor
        super.init(errorCollector: errorCollector)
    }

    override open func provideStreamingChat(
        body: ChatRequestBody
    ) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        let requestBody = applyModelSettings(to: body, streaming: true)
        let request = try makeURLRequest(body: requestBody)
        logger.info("starting streaming request to model: \(body.model) with \(body.messages.count) messages, temperature: \(body.temperature ?? 1.0)")

        let processor = OpenAICompatibleStreamProcessor(
            eventSourceFactory: eventSourceFactory,
            chunkDecoder: chunkDecoderFactory(),
            errorExtractor: errorExtractor
        )

        return processor.stream(request: request) { [weak self] error in
            await self?.collect(error: error)
        }
    }

    func makeRequestBuilder() -> OpenAICompatibleRequestBuilder {
        OpenAICompatibleRequestBuilder(
            baseURL: baseURL,
            path: path,
            apiKey: apiKey,
            defaultHeaders: defaultHeaders,
            additionalQueryItems: defaultQueryItems
        )
    }

    func makeURLRequest(body: ChatRequestBody) throws -> URLRequest {
        let builder = makeRequestBuilder()
        return try builder.makeRequest(body: body, requestCustomization: requestCustomization)
    }

    func applyModelSettings(to body: ChatRequestBody, streaming: Bool) -> ChatRequestBody {
        var requestBody = body
        requestBody.stream = streaming
        return requestBody
    }

    override open func extractConnectionError(from response: Data?, statusCode: Int) -> String {
        if let data = response, let decodedError = errorExtractor.extractError(from: data) {
            return decodedError.localizedDescription
        }
        return String(localized: "Connection error: \(statusCode)")
    }
}
