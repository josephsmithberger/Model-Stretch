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
            Form {
                // MARK: - Agent Mode
                Section {
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
                } header: {
                    Text("Mode")
                } footer: {
                    if agentModeEnabled {
                        Text("System prompt is disabled in Agent Mode — each agent uses its own prompt defined in AgentConfiguration.json.")
                            .foregroundStyle(.orange)
                    }
                }

                // MARK: - Generation
                Section("Generation") {
                    Toggle("Stream Responses", isOn: $useStreaming)
                    VStack(alignment: .leading) {
                        Text("Temperature: \(temperature, specifier: "%.2f")")
                        Slider(value: $temperature, in: 0.0...2.0, step: 0.1)
                    }
                    .padding(.vertical, 4)
                }

                // MARK: - System Instructions (hidden in agent mode)
                if !agentModeEnabled {
                    Section("System Instructions") {
                        TextEditor(text: $systemInstructions)
                            .frame(minHeight: 100)
                            .font(.body)
                    }
                }

                // MARK: - Agent Info (shown in agent mode)
                if agentModeEnabled {
                    Section {
                        AgentRosterView()
                    } header: {
                        Text("Agent Roster")
                    } footer: {
                        Text("Edit AgentConfiguration.json to add, remove, or reorder agents.")
                    }
                }
            }
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
                    .padding(.vertical, 4)
                }
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

