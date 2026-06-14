//
//  ConversationSession.swift
//  LanguageModelChatUI
//
//  Coordinates messages and inference for a single conversation.
//  Adapted from FlowDown's ConversationSession with model-scoped clients.
//

import ChatClientKit
import Combine
import Foundation

public typealias ModelIdentifier = String

/// Coordinates the message state and inference execution for a conversation.
@MainActor
public final class ConversationSession: Identifiable, Sendable {
    public struct Model: Sendable {
        public var model: String
        public var client: any ChatClient
        public var capabilities: Set<ModelCapability>
        public var contextLength: Int

        public init(
            model: String,
            client: any ChatClient,
            capabilities: Set<ModelCapability> = [],
            contextLength: Int = 0
        ) {
            self.model = model
            self.client = client
            self.capabilities = capabilities
            self.contextLength = contextLength
        }
    }

    public struct Models: Sendable {
        public var chat: ModelIdentifier?
        public var titleGeneration: ModelIdentifier?

        public init(chat: ModelIdentifier? = nil, titleGeneration: ModelIdentifier? = nil) {
            self.chat = chat
            self.titleGeneration = titleGeneration
        }
    }

    public typealias ModelResolver = @MainActor (ModelIdentifier) -> Model?

    public struct Configuration: Sendable {
        public let storage: StorageProvider
        public let tools: ToolProvider?
        public let delegate: SessionDelegate?
        public let systemPrompt: String
        public let collapseReasoningWhenComplete: Bool
        public let modelResolver: ModelResolver?

        public init(
            storage: StorageProvider,
            tools: ToolProvider? = nil,
            delegate: SessionDelegate? = nil,
            systemPrompt: String = "You are a helpful assistant.",
            collapseReasoningWhenComplete: Bool = true,
            modelResolver: ModelResolver? = nil
        ) {
            self.storage = storage
            self.tools = tools
            self.delegate = delegate
            self.systemPrompt = systemPrompt
            self.collapseReasoningWhenComplete = collapseReasoningWhenComplete
            self.modelResolver = modelResolver
        }
    }

    public let id: String

    private(set) var messages: [ConversationMessage] = []
    var currentTask: Task<Void, Never>?

    // MARK: - Providers

    let storageProvider: StorageProvider
    let toolProvider: ToolProvider?
    let sessionDelegate: SessionDelegate?
    let systemPrompt: String
    let collapseReasoningWhenComplete: Bool
    let modelResolver: ModelResolver?

    // MARK: - Reactive

    private lazy var messagesSubject: CurrentValueSubject<
        ([ConversationMessage], Bool), Never
    > = .init((messages, false))

    public var messagesDidChange: AnyPublisher<([ConversationMessage], Bool), Never> {
        messagesSubject.eraseToAnyPublisher()
    }

    private lazy var userDidSendMessageSubject = PassthroughSubject<ConversationMessage, Never>()
    public var userDidSendMessage: AnyPublisher<ConversationMessage, Never> {
        userDidSendMessageSubject.eraseToAnyPublisher()
    }

    // MARK: - Usage Tracking

    /// Token usage from the last inference execution.
    public private(set) var lastUsage: TokenUsage?

    private lazy var usageSubject = PassthroughSubject<TokenUsage, Never>()

    /// Publisher emitting token usage after each inference step.
    public var usageDidChange: AnyPublisher<TokenUsage, Never> {
        usageSubject.eraseToAnyPublisher()
    }

    func reportUsage(_ usage: TokenUsage) {
        lastUsage = usage
        usageSubject.send(usage)
        sessionDelegate?.sessionDidReportUsage(usage, for: id)
    }

    // MARK: - Model Selection

    public var models: Models

    // MARK: - Thinking Timer

    private var thinkingDurationTimer: [String: Timer] = [:]

    // MARK: - Lifecycle

    nonisolated deinit {
        let sessionId = id
        DispatchQueue.main.async {
            ConversationSessionManager.shared.markSessionCompleted(sessionId)
        }
    }

    public init(id: String, configuration: Configuration) {
        self.id = id
        storageProvider = configuration.storage
        toolProvider = configuration.tools
        sessionDelegate = configuration.delegate
        systemPrompt = configuration.systemPrompt
        collapseReasoningWhenComplete = configuration.collapseReasoningWhenComplete
        modelResolver = configuration.modelResolver
        models = .init()
        refreshContentsFromDatabase()
    }

    /// Map a `ModelIdentifier` to a freshly-built `Model` using the configured resolver.
    /// Returns `nil` if no resolver is configured or the resolver cannot map the identifier.
    public func resolveModel(_ identifier: ModelIdentifier) -> Model? {
        modelResolver?(identifier)
    }

    // MARK: - Message Management

    @discardableResult
    public func appendLocalMessage(
        role: MessageRole,
        configure: ((ConversationMessage) -> Void)? = nil,
        scrolling: Bool = true
    ) -> ConversationMessage {
        let message = appendNewMessage(role: role, configure: configure)
        persistMessages()
        notifyMessagesDidChange(scrolling: scrolling)
        return message
    }

    @discardableResult
    func appendNewMessage(role: MessageRole, configure: ((ConversationMessage) -> Void)? = nil) -> ConversationMessage {
        let message = storageProvider.createMessage(in: id, role: role)
        configure?(message)
        messages.append(message)
        if role == .user { userDidSendMessageSubject.send(message) }
        return message
    }

    func notifyMessagesDidChange(scrolling: Bool = true) {
        messagesSubject.send((messages, scrolling))
    }

    func refreshContentsFromDatabase(scrolling: Bool = true) {
        messages.removeAll()
        messages = storageProvider.messages(in: id)
        notifyMessagesDidChange(scrolling: scrolling)
    }

    func persistMessages() {
        storageProvider.save(messages)
    }

    func message(for messageID: String) -> ConversationMessage? {
        messages.first { $0.id == messageID }
    }

    func removeMessage(with messageID: String) {
        messages.removeAll { $0.id == messageID }
    }

    public func delete(_ messageID: String) {
        cancelCurrentTask { [self] in
            storageProvider.delete([messageID])
            refreshContentsFromDatabase()
        }
    }

    public func delete(after messageID: String, completion: @escaping () -> Void = {}) {
        cancelCurrentTask { [self] in
            guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
                completion()
                return
            }
            let idsToDelete = messages.dropFirst(index + 1).map(\.id)
            if !idsToDelete.isEmpty {
                storageProvider.delete(idsToDelete)
            }
            refreshContentsFromDatabase()
            completion()
        }
    }

    public func clear(completion: @escaping () -> Void = {}) {
        cancelCurrentTask { [self] in
            stopThinkingForAll()
            let messageIDs = messages.map(\.id)
            if !messageIDs.isEmpty {
                storageProvider.delete(messageIDs)
            }
            lastUsage = nil
            refreshContentsFromDatabase(scrolling: false)
            completion()
        }
    }

    func cancelCurrentTask(then action: @escaping () -> Void) {
        if let task = currentTask {
            task.cancel()
            currentTask = nil
            action()
        } else {
            action()
        }
    }

    // MARK: - Thinking Duration

    func startThinking(for messageID: String) {
        if thinkingDurationTimer[messageID] != nil { return }
        guard let message = message(for: messageID) else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                for (index, part) in message.parts.enumerated() {
                    if case var .reasoning(reasoningPart) = part {
                        reasoningPart.duration += 1
                        message.parts[index] = .reasoning(reasoningPart)
                        break
                    }
                }
                notifyMessagesDidChange(scrolling: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        thinkingDurationTimer[messageID] = timer
    }

    func stopThinkingForAll() {
        thinkingDurationTimer.values.forEach { $0.invalidate() }
        thinkingDurationTimer.removeAll()
    }

    func stopThinking(for messageID: String) {
        thinkingDurationTimer[messageID]?.invalidate()
        thinkingDurationTimer.removeValue(forKey: messageID)
    }
}
