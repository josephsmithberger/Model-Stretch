//
//  DebugPanelView.swift
//  Apple Intelligence Chat
//
//  Internal debug panel UI. Only compiled in DEBUG builds.
//

import SwiftUI

#if DEBUG
struct DebugPanelView: View {
    @ObservedObject private var debugLog = DebugLog.shared
    @State private var selectedConversationId: UUID?
    @State private var selectedTab: DebugEventKind? = nil

    var body: some View {
        VStack(spacing: 12) {
            header

            Picker("View", selection: $selectedTab) {
                Text("All").tag(Optional<DebugEventKind>.none)
                Text("Conversation").tag(Optional(DebugEventKind.conversation))
                Text("Tool Calls").tag(Optional(DebugEventKind.toolCall))
                Text("Missed Tool Calls").tag(Optional(DebugEventKind.toolCallMiss))
                Text("Handoffs").tag(Optional(DebugEventKind.handoff))
                Text("Narration").tag(Optional(DebugEventKind.narration))
            }
            .pickerStyle(.segmented)

            if debugLog.events.isEmpty {
                Text("No debug events yet")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(formattedText)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
            }
        }
        .padding()
        .onAppear {
            if selectedConversationId == nil {
                selectedConversationId = debugLog.conversationIds().last
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Debug Panel")
                .font(.headline)

            Spacer()

            Picker("Conversation", selection: $selectedConversationId) {
                Text("All").tag(UUID?.none)
                ForEach(debugLog.conversationIds(), id: \.self) { id in
                    Text(debugLog.shortId(id)).tag(Optional(id))
                }
            }
            .frame(maxWidth: 220)
        }
    }

    private var formattedText: String {
        if selectedTab == nil {
            return debugLog.formattedDump(conversationId: selectedConversationId)
        }

        let ids = selectedConversationId != nil
            ? [selectedConversationId!]
            : debugLog.conversationIds()

        var sections: [String] = []
        for id in ids {
            let header = "Conversation \(debugLog.shortId(id))"
            sections.append(header)

            let events = debugLog.events(kind: selectedTab, conversationId: id)
            let title = selectedTabTitle(selectedTab)
            sections.append(debugLog.formatSection(title: title, events: events))
        }
        return sections.joined(separator: "\n\n")
    }

    private func selectedTabTitle(_ kind: DebugEventKind?) -> String {
        switch kind {
        case .conversation: return "Conversation"
        case .toolCall: return "Tool Calls"
        case .toolCallMiss: return "Missed Tool Calls"
        case .handoff: return "Handoffs"
        case .narration: return "Narration"
        case .none: return ""
        }
    }
}
#endif
