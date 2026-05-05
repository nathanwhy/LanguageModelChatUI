//
//  CollectedErrorDisplayMessage.swift
//  ChatClientKit
//

import Foundation

public enum CollectedErrorDisplayMessage {
    public static func resolve(collectedError: String?, fallback: String) -> String {
        let trimmed = collectedError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }
}
