//
//  AgentManager.swift
//  Apple Intelligence Chat
//
//  Created by Pallav Agarwal on 2/7/26.
//

import SwiftUI
import FoundationModels

// MARK: - Agent Configuration Model

/// A single agent definition loaded from AgentConfiguration.json
struct AgentConfig: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let emoji: String
    let color: String
    let systemPrompt: String
    let order: Int

    /// Parses the hex color string into a SwiftUI `Color`
    var swiftUIColor: Color {
        Color(hex: color)
    }
}

// MARK: - Agent Message Model

/// A message produced by an agent during a relay run
struct AgentMessage: Identifiable, Equatable {
    let id = UUID()
    let agentConfig: AgentConfig
    var text: String
    var isComplete: Bool

    static func == (lhs: AgentMessage, rhs: AgentMessage) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text && lhs.isComplete == rhs.isComplete
    }
}

// MARK: - Relay Turn

/// Groups together user input and agent relay responses for one "turn"
struct RelayTurn: Identifiable, Equatable {
    let id = UUID()
    let userMessage: String
    var agentMessages: [AgentMessage]
}

// MARK: - Agent Manager

/// Manages loading agent configurations and orchestrating the relay pipeline
@MainActor
@Observable
class AgentManager {

    // MARK: - Published State

    var agents: [AgentConfig] = []
    var relayTurns: [RelayTurn] = []
    var isRunning = false
    var currentAgentIndex: Int?

    // MARK: - Private

    private var currentTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        loadAgents()
    }

    // MARK: - Agent Loading

    /// Loads agents from AgentConfiguration.json in the app bundle
    func loadAgents() {
        guard let url = Bundle.main.url(forResource: "AgentConfiguration", withExtension: "json") else {
            print("⚠️ AgentConfiguration.json not found in bundle")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([AgentConfig].self, from: data)
            agents = decoded.sorted { $0.order < $1.order }
        } catch {
            print("⚠️ Failed to decode AgentConfiguration.json: \(error)")
        }
    }

    // MARK: - Relay Pipeline

    /// Starts a relay run: each agent gets the accumulated conversation context
    /// and produces a response, which is handed to the next agent.
    func startRelay(userMessage: String, temperature: Double, useStreaming: Bool) {
        guard !agents.isEmpty else { return }

        isRunning = true

        // Build a new turn with placeholder agent messages
        var turn = RelayTurn(
            userMessage: userMessage,
            agentMessages: agents.map { AgentMessage(agentConfig: $0, text: "", isComplete: false) }
        )
        relayTurns.append(turn)
        let turnIndex = relayTurns.count - 1

        currentTask = Task {
            // Build conversation history from all previous turns for context
            var conversationContext = buildConversationHistory(upToTurn: turnIndex)
            conversationContext += "\n\n[User]: \(userMessage)"

            for (agentIdx, agent) in agents.enumerated() {
                guard !Task.isCancelled else { break }

                currentAgentIndex = agentIdx

                // Each agent gets its own session with its own system prompt
                let session = LanguageModelSession(instructions: agent.systemPrompt)
                let options = GenerationOptions(temperature: temperature)

                // Build the prompt: full context + what previous agents said this turn
                var agentPrompt = conversationContext
                for prevIdx in 0..<agentIdx {
                    let prevAgent = agents[prevIdx]
                    let prevText = relayTurns[turnIndex].agentMessages[prevIdx].text
                    agentPrompt += "\n\n[\(prevAgent.name)]: \(prevText)"
                }

                do {
                    if useStreaming {
                        let stream = session.streamResponse(to: agentPrompt, options: options)
                        for try await partial in stream {
                            guard !Task.isCancelled else { break }
                            relayTurns[turnIndex].agentMessages[agentIdx].text = partial.content
                        }
                    } else {
                        let response = try await session.respond(to: agentPrompt, options: options)
                        relayTurns[turnIndex].agentMessages[agentIdx].text = response.content
                    }
                } catch is CancellationError {
                    // Cancelled
                } catch {
                    relayTurns[turnIndex].agentMessages[agentIdx].text = "⚠️ Error: \(error.localizedDescription)"
                }

                relayTurns[turnIndex].agentMessages[agentIdx].isComplete = true
            }

            currentAgentIndex = nil
            isRunning = false
            currentTask = nil
        }
    }

    /// Stops the current relay run
    func stopRelay() {
        currentTask?.cancel()
        currentTask = nil
        isRunning = false
        currentAgentIndex = nil
    }

    /// Resets all relay history
    func reset() {
        stopRelay()
        relayTurns.removeAll()
    }

    // MARK: - Helpers

    /// Builds a text summary of all previous turns for context
    private func buildConversationHistory(upToTurn turnIndex: Int) -> String {
        var history = ""
        for i in 0..<turnIndex {
            let turn = relayTurns[i]
            history += "\n[User]: \(turn.userMessage)"
            for msg in turn.agentMessages where msg.isComplete {
                history += "\n[\(msg.agentConfig.name)]: \(msg.text)"
            }
        }
        return history
    }
}

// MARK: - Color Hex Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
        default:
            r = 1; g = 1; b = 1
        }
        self.init(red: r, green: g, blue: b)
    }
}
