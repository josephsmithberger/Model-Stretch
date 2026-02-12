//
//  DebugLog.swift
//  Apple Intelligence Chat
//
//  Internal debug logging utilities. Not exposed in release builds.
//

import Foundation
import SwiftUI
import Combine

enum DebugEventKind: String, CaseIterable {
    case conversation
    case toolCall
    case toolCallMiss
    case handoff
    case narration
}

struct DebugEvent: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let kind: DebugEventKind
    let conversationId: UUID
    let actor: String
    let content: String
}

final class DebugLog: ObservableObject {
    static let shared = DebugLog()

    @Published private(set) var events: [DebugEvent] = []

    private init() {}

    func record(
        kind: DebugEventKind,
        conversationId: UUID,
        actor: String,
        content: String
    ) {
#if DEBUG
        let event = DebugEvent(
            timestamp: Date(),
            kind: kind,
            conversationId: conversationId,
            actor: actor,
            content: content
        )
        DispatchQueue.main.async {
            self.events.append(event)
        }
#endif
    }

    func conversationIds() -> [UUID] {
        let ids = events.map { $0.conversationId }
        var seen = Set<UUID>()
        var ordered: [UUID] = []
        for id in ids.reversed() {
            if !seen.contains(id) {
                seen.insert(id)
                ordered.append(id)
            }
        }
        return ordered.reversed()
    }

    func events(
        kind: DebugEventKind?,
        conversationId: UUID?
    ) -> [DebugEvent] {
        return events.filter { event in
            let kindMatch = kind == nil || event.kind == kind
            let convoMatch = conversationId == nil || event.conversationId == conversationId
            return kindMatch && convoMatch
        }
    }

    func shortId(_ id: UUID) -> String {
        return String(id.uuidString.prefix(8))
    }

    func formattedDump(conversationId: UUID?) -> String {
        let ids = conversationId != nil ? [conversationId!] : conversationIds()
        var sections: [String] = []

        for id in ids {
            let header = "Conversation \(shortId(id))"
            sections.append(header)

            sections.append(formatSection(title: "Conversation", events: events(kind: .conversation, conversationId: id)))
            sections.append(formatSection(title: "Tool Calls", events: events(kind: .toolCall, conversationId: id)))
            sections.append(formatSection(title: "Missed Tool Calls", events: events(kind: .toolCallMiss, conversationId: id)))
            sections.append(formatSection(title: "Handoffs", events: events(kind: .handoff, conversationId: id)))
            sections.append(formatSection(title: "Narration", events: events(kind: .narration, conversationId: id)))
        }

        return sections.joined(separator: "\n\n")
    }

    func formatSection(title: String, events: [DebugEvent]) -> String {
        if events.isEmpty {
            return "\(title): (none)"
        }

        let lines = events.map { event in
            let time = DebugLog.dateFormatter.string(from: event.timestamp)
            return "[\(time)] \(event.actor): \(event.content)"
        }
        return "\(title):\n" + lines.joined(separator: "\n")
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

struct ToolCallDetector {
    static func extractMissedToolCalls(from text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var matches: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let lower = trimmed.lowercased()
            if lower.contains("tool_call")
                || lower.contains("call_tool")
                || lower.contains("tool:")
                || lower.contains("requestrevisiontool")
                || lower.contains("request_revision")
                || lower.contains("function:") {
                matches.append(trimmed)
            }
        }

        return matches
    }
}
