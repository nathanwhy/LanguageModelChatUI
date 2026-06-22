//
//  ConversationSession+HeadlessExecute.swift
//  LanguageModelChatUI
//
//  Headless inference entry point — no UI view required.
//  Designed for use in App Intents, background tasks, and other non-UI contexts.
//

import ChatClientKit
import Foundation

public extension ConversationSession {
    /// Executes a single inference round without any UI dependency.
    ///
    /// Suitable for App Intents and other headless contexts. Persists the user and
    /// assistant messages via the configured `StorageProvider` and returns the
    /// assistant's response text.
    ///
    /// - Parameter input: The user input to send.
    /// - Returns: The assistant's response text.
    /// - Throws: `InferenceError.noModelConfigured` if no chat model is set,
    ///           or any error thrown by the underlying `ChatClient`.
    func runHeadlessInference(input: UserInput) async throws -> String {
        guard let chatID = models.chat, let model = resolveModel(chatID) else {
            throw InferenceError.noModelConfigured
        }

        let capabilities = model.capabilities

        // Build request messages from existing conversation history.
        var requestMessages = buildRequestMessages(capabilities: capabilities)

        // Persist and append the user message to the session.
        _ = appendNewMessage(role: .user) { msg in
            msg.textContent = input.text
            for attachment in input.attachments {
                msg.parts.append(attachment)
            }
        }
        persistMessages()

        // Append the user turn to the outgoing request.
        requestMessages.append(
            buildUserRequestMessage(
                text: input.text,
                attachments: input.attachments,
                capabilities: capabilities
            )
        )

        // Inject system prompt.
        await injectSystemPrompt(&requestMessages, capabilities: capabilities)

        // Trim to context window.
        await trimToContextLength(&requestMessages, tools: nil, maxTokens: model.contextLength)

        // Call the API (non-streaming — simpler and appropriate for background contexts).
        let response = try await model.client.chat(
            body: .init(model: model.model, messages: requestMessages)
        )

        let responseText = response.text

        // Persist the assistant message.
        _ = appendNewMessage(role: .assistant) { msg in
            msg.textContent = responseText
            let trimmedReasoning = response.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedReasoning.isEmpty {
                msg.reasoningContent = trimmedReasoning
            }
        }
        persistMessages()
        notifyMessagesDidChange()

        return responseText
    }
}
