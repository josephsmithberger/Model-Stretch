//
//  SettingsView.swift
//  Apple Intelligence Chat
//
//  Created by Pallav Agarwal on 6/9/25.
//

import SwiftUI

/// App-wide settings stored in UserDefaults
enum AppSettings {
    @AppStorage("useStreaming") static var useStreaming: Bool = true
    @AppStorage("temperature") static var temperature: Double = 0.7
    @AppStorage("systemInstructions") static var systemInstructions: String = "You are a helpful assistant."
    @AppStorage("agentModeEnabled") static var agentModeEnabled: Bool = false
}

/// Settings screen for configuring AI behavior
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var onDismiss: (() -> Void)?

    @AppStorage("useStreaming") private var useStreaming = AppSettings.useStreaming
    @AppStorage("temperature") private var temperature = AppSettings.temperature
    @AppStorage("systemInstructions") private var systemInstructions = AppSettings.systemInstructions
    @AppStorage("agentModeEnabled") private var agentModeEnabled = AppSettings.agentModeEnabled

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // MARK: - Agent Mode
                    SettingsSection(title: "Mode", footer: agentModeEnabled
                        ? "System prompt is disabled in Agent Mode — each agent uses its own prompt defined in AgentConfiguration.json."
                        : nil,
                        footerStyle: agentModeEnabled ? .orange : .secondary) {
                            Toggle(isOn: $agentModeEnabled) {
                                HStack(spacing: 10) {
                                    Text("🤖")
                                        .font(.title2)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Agent Mode")
                                            .fontWeight(.semibold)
                                        Text("Agents collaborate in a relay to answer your questions")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .tint(.purple)
                        }

                    // MARK: - Generation
                    SettingsSection(title: "Generation") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Stream Responses", isOn: $useStreaming)
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Temperature")
                                    Spacer()
                                    Text("\(temperature, specifier: "%.2f")")
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $temperature, in: 0.0...2.0, step: 0.1)
                            }
                        }
                    }

                    // MARK: - System Instructions (hidden in agent mode)
                    if !agentModeEnabled {
                        SettingsSection(title: "System Instructions") {
                            TextEditor(text: $systemInstructions)
                                .frame(minHeight: 120)
                                .font(.body)
                        }
                    }

                    // MARK: - Agent Info (shown in agent mode)
                    if agentModeEnabled {
                        SettingsSection(title: "Agent Roster", footer: "Edit AgentConfiguration.json to add, remove, or reorder agents.") {
                            AgentRosterView()
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(AppColors.groupedBackground)
            .navigationTitle("Settings")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onDisappear { onDismiss?() }
    }
}

/// Displays a preview list of agents loaded from the JSON configuration
struct AgentRosterView: View {
    @State private var agents: [AgentConfig] = []

    var body: some View {
        Group {
            if agents.isEmpty {
                Text("No agents configured")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                        HStack(spacing: 12) {
                            // Order badge
                            ZStack {
                                Circle()
                                    .fill(agent.swiftUIColor.opacity(0.15))
                                    .frame(width: 32, height: 32)
                                Text("\(index + 1)")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundStyle(agent.swiftUIColor)
                            }

                            Text(agent.emoji)
                                .font(.title2)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.name)
                                    .fontWeight(.medium)
                                    .foregroundStyle(agent.swiftUIColor)
                                Text(agent.systemPrompt)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer()

                            // Relay arrow
                            if index < agents.count - 1 {
                                Image(systemName: "arrow.right.circle.fill")
                                    .foregroundStyle(agent.swiftUIColor.opacity(0.4))
                                    .font(.caption)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green.opacity(0.6))
                                    .font(.caption)
                            }
                        }
                        if index < agents.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear { loadAgents() }
    }

    private func loadAgents() {
        guard let url = Bundle.main.url(forResource: "AgentConfiguration", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([AgentConfig].self, from: data) else {
            return
        }
        agents = decoded.sorted { $0.order < $1.order }
    }
}

/// Card-style settings section with padding and optional footer
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    var footerStyle: Color = .secondary
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textCase(nil)
            content()
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(footerStyle)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppColors.cardBackground.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppColors.cardBorder.opacity(0.3))
        )
#if os(iOS)
        .glassEffect(.regular)
#endif
    }
}

enum AppColors {
#if canImport(UIKit)
    static let groupedBackground = Color(UIColor.systemGroupedBackground)
    static let cardBackground = Color(UIColor.secondarySystemGroupedBackground)
    static let cardBorder = Color(UIColor.separator)
#elseif canImport(AppKit)
    static let groupedBackground = Color(nsColor: .windowBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let cardBorder = Color(nsColor: .separatorColor)
#else
    static let groupedBackground = Color.gray.opacity(0.12)
    static let cardBackground = Color.gray.opacity(0.08)
    static let cardBorder = Color.gray.opacity(0.25)
#endif
}

