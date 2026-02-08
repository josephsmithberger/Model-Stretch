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
    /// If this message was produced via a revision request, who requested it
    var revisedBy: String?

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

// MARK: - Revision Request Store

/// Thread-safe storage for revision requests made by agents via tool calling.
/// Shared between `RequestRevisionTool` instances and the `AgentManager` so
/// the manager can check whether a revision was requested after each agent
/// finishes generating.
actor RevisionRequestStore {
    private var pending: (targetAgentName: String, revisionRequest: String)?

    func set(targetAgentName: String, revisionRequest: String) {
        pending = (targetAgentName, revisionRequest)
    }

    func consume() -> (targetAgentName: String, revisionRequest: String)? {
        let value = pending
        pending = nil
        return value
    }
}

// MARK: - Tool: Request Revision

/// A tool that allows an agent to request a revision from another agent.
///
/// When an agent calls this tool during generation, the Foundation Models
/// framework automatically invokes `call(arguments:)`, records the result,
/// and feeds it back to the model. After the agent's generation completes,
/// the `AgentManager` checks `RevisionRequestStore` for any pending
/// revision and — if found — spins up a fresh session for the target agent.
///
/// Example: Rexa the Reviewer finds a bug and calls this tool to ask
/// Cody the Coder to fix it. The relay loops back to Cody with the
/// specific revision request.
struct RequestRevisionTool: Tool {
    let agents: [AgentConfig]
    let store: RevisionRequestStore

    @Generable
    struct Arguments {
        @Guide(description: "The name of the agent to ask for a revision. Must match one of the available agent names exactly.")
        var targetAgentName: String

        @Guide(description: "A clear, specific description of what needs to be revised or reconsidered.")
        var revisionRequest: String
    }

    var description: String {
        let names = agents.map(\.name).joined(separator: ", ")
        return "Request a revision from another agent in the relay. Available agents: \(names). Use this when you identify an issue that a specific other agent should fix or reconsider. The target agent will receive your revision request and produce an updated response."
    }

    func call(arguments: Arguments) async throws -> String {
        guard agents.contains(where: { $0.name.lowercased() == arguments.targetAgentName.lowercased() }) else {
            let names = agents.map(\.name).joined(separator: ", ")
            return "Invalid agent name '\(arguments.targetAgentName)'. Available agents: \(names)"
        }

        await store.set(
            targetAgentName: arguments.targetAgentName,
            revisionRequest: arguments.revisionRequest
        )

        return "Revision request sent to \(arguments.targetAgentName). They will review: \(arguments.revisionRequest)"
    }
}

// MARK: - Agent Manager

/// Manages loading agent configurations and orchestrating the relay pipeline.
///
/// ## Key Design Decisions
///
/// - **Fresh sessions**: Every agent invocation creates a brand-new
///   `LanguageModelSession`. No session is ever reused. This prevents
///   "context rot" — each agent only sees what it needs to see.
///
/// - **Minimal context**: Each agent receives only the original user request
///   and the immediately previous agent's output. No full conversation dump.
///
/// - **Tool calling**: Agents are given tools (like `RequestRevisionTool`)
///   via `LanguageModelSession(instructions:tools:)`. The Foundation Models
///   framework handles tool invocation automatically during `respond(to:)` /
///   `streamResponse(to:)`. After generation, the manager checks the shared
///   `RevisionRequestStore` and acts on any pending revision.
///
/// - **Extensible tools**: All tools are built in `buildTools()`. To add a
///   new capability, just create a struct conforming to `Tool` and append it.
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

    /// Shared store for revision requests made via tool calling
    private let revisionStore = RevisionRequestStore()

    /// Maximum number of revision loops per turn to prevent infinite cycles
    private let maxRevisionLoops = 3

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

    /// Starts a relay run. Each agent gets a **fresh** `LanguageModelSession`
    /// with only the minimal context it needs (user request + previous
    /// agent's output). Agents can request revisions from each other via
    /// the `RequestRevisionTool`.
    func startRelay(userMessage: String, temperature: Double, useStreaming: Bool) {
        guard !agents.isEmpty else { return }

        isRunning = true

        let turn = RelayTurn(
            userMessage: userMessage,
            agentMessages: agents.map {
                AgentMessage(agentConfig: $0, text: "", isComplete: false, revisedBy: nil)
            }
        )
        relayTurns.append(turn)
        let turnIndex = relayTurns.count - 1

        currentTask = Task {
            var previousOutput = userMessage
            var previousAgentName = "User"
            var revisionCount = 0
            var agentOutputs: [String: String] = [:]

            for (agentIdx, agent) in agents.enumerated() {
                guard !Task.isCancelled else { break }

                currentAgentIndex = agentIdx

                // ── Run the agent with a fresh session ──
                let output = await runAgent(
                    agent: agent,
                    userMessage: userMessage,
                    previousAgentName: previousAgentName,
                    previousOutput: previousOutput,
                    temperature: temperature,
                    useStreaming: useStreaming,
                    turnIndex: turnIndex,
                    messageIndex: agentIdx
                )

                agentOutputs[agent.name] = output

                // ── Check for revision requests from tool calling ──
                if let revision = await revisionStore.consume(),
                   revisionCount < maxRevisionLoops,
                   let targetConfig = agents.first(where: {
                       $0.name.lowercased() == revision.targetAgentName.lowercased()
                   }) {
                    revisionCount += 1

                    // Add a revision bubble to the UI
                    let revMsg = AgentMessage(
                        agentConfig: targetConfig,
                        text: "",
                        isComplete: false,
                        revisedBy: agent.name
                    )
                    relayTurns[turnIndex].agentMessages.append(revMsg)
                    let revMsgIdx = relayTurns[turnIndex].agentMessages.count - 1
                    currentAgentIndex = revMsgIdx

                    // Build revision-specific context
                    let revisionContext = """
                        \(agent.name) requested a revision from you.

                        Revision request: \(revision.revisionRequest)

                        Your original output:
                        \(agentOutputs[targetConfig.name] ?? "(none yet)")

                        \(agent.name)'s latest output:
                        \(output)
                        """

                    let revOutput = await runAgent(
                        agent: targetConfig,
                        userMessage: userMessage,
                        previousAgentName: agent.name,
                        previousOutput: revisionContext,
                        temperature: temperature,
                        useStreaming: useStreaming,
                        turnIndex: turnIndex,
                        messageIndex: revMsgIdx
                    )

                    agentOutputs[targetConfig.name] = revOutput

                    // Next sequential agent picks up from the revision
                    previousOutput = revOutput
                    previousAgentName = targetConfig.name
                } else {
                    // Normal handoff
                    previousOutput = output
                    previousAgentName = agent.name
                }
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

    // MARK: - Single Agent Run

    /// Creates a **fresh** `LanguageModelSession` for the given agent, sends
    /// it a focused prompt, and streams/awaits the response. Returns the
    /// agent's final output text.
    ///
    /// Every call to this method creates a new session — no session is ever
    /// reused. This is the core "no context rot" guarantee.
    private func runAgent(
        agent: AgentConfig,
        userMessage: String,
        previousAgentName: String,
        previousOutput: String,
        temperature: Double,
        useStreaming: Bool,
        turnIndex: Int,
        messageIndex: Int
    ) async -> String {
        let tools = buildTools()
        let session = LanguageModelSession(
            tools: tools,
            instructions: agent.systemPrompt
        )
        let options = GenerationOptions(temperature: temperature)

        let prompt = buildFocusedPrompt(
            previousAgentName: previousAgentName,
            previousOutput: previousOutput,
            userMessage: userMessage
        )

        do {
            if useStreaming {
                let stream = session.streamResponse(to: prompt, options: options)
                for try await partial in stream {
                    guard !Task.isCancelled else { break }
                    relayTurns[turnIndex].agentMessages[messageIndex].text = partial.content
                }
            } else {
                let response = try await session.respond(to: prompt, options: options)
                relayTurns[turnIndex].agentMessages[messageIndex].text = response.content
            }
        } catch is CancellationError {
            // Cancelled — leave text as-is
        } catch {
            relayTurns[turnIndex].agentMessages[messageIndex].text = "⚠️ Error: \(error.localizedDescription)"
        }

        relayTurns[turnIndex].agentMessages[messageIndex].isComplete = true
        return relayTurns[turnIndex].agentMessages[messageIndex].text
    }

    // MARK: - Tool Registry

    /// Builds the array of tools available to all agents.
    ///
    /// **To add a new tool:**
    /// 1. Create a struct conforming to `Tool` (from FoundationModels)
    /// 2. Define an `Arguments` struct (Codable) with `@Guide` annotations
    /// 3. Implement `call(arguments:) async throws -> ToolOutput`
    /// 4. Append an instance here
    ///
    /// The Foundation Models framework automatically describes your tools to
    /// the model, invokes them when the model requests, and feeds the result
    /// back into generation.
    private func buildTools() -> [any Tool] {
        var tools: [any Tool] = []

        // Revision tool — lets agents request help from each other
        tools.append(RequestRevisionTool(agents: agents, store: revisionStore))

        // ── Add future tools below ──────────────────────────────
        // tools.append(WebSearchTool())
        // tools.append(FileReadTool())
        // tools.append(CalculatorTool())
        // tools.append(CodeExecutionTool())
        // ────────────────────────────────────────────────────────

        return tools
    }

    // MARK: - Focused Prompt Building

    /// Builds a minimal, focused prompt for an agent. Only includes:
    /// - The original user request (for grounding)
    /// - The previous agent's name and output (for continuity)
    ///
    /// This prevents context rot by never dumping the full conversation.
    private func buildFocusedPrompt(
        previousAgentName: String,
        previousOutput: String,
        userMessage: String
    ) -> String {
        if previousAgentName == "User" {
            return """
                [User Request]:
                \(userMessage)
                """
        } else {
            return """
                [User Request]:
                \(userMessage)

                [Previous Agent — \(previousAgentName)]:
                \(previousOutput)
                """
        }
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
