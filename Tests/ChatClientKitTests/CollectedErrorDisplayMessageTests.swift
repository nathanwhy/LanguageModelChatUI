//
//  CollectedErrorDisplayMessageTests.swift
//  ChatClientKitTests
//

@testable import ChatClientKit
import Foundation
import Testing

struct CollectedErrorDisplayMessageTests {
    @Test("Prefers non-empty collected error over fallback")
    func prefersNonEmptyCollectedErrorOverFallback() {
        let message = CollectedErrorDisplayMessage.resolve(
            collectedError: "Upstream quota exceeded.",
            fallback: "No response from model."
        )

        #expect(message == "Upstream quota exceeded.")
    }

    @Test("Uses fallback when collected error is empty")
    func usesFallbackWhenCollectedErrorIsEmpty() {
        let message = CollectedErrorDisplayMessage.resolve(
            collectedError: "   \n",
            fallback: "No response from model."
        )

        #expect(message == "No response from model.")
    }
}
