//
//  AgentManager.swift
//  Apple Intelligence Chat
//
//  Created by Pallav Agarwal on 2/7/26.
//

import SwiftUI
import FoundationModels
// Ensure Tool, ToolOutput are available

// MARK: - Agent Configuration Model

/// A single agent definition loaded from AgentConfiguration.json
struct AgentConfig: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let emoji: String
    let color: String
    let systemPrompt: String
    let order: Int
    let canRequestRevisions: Bool

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
///
/// Includes duplicate detection to prevent the same agent from calling the
/// revision tool multiple times during a single generation.
actor RevisionRequestStore {
    private var pending: (requesterName: String, targetAgentName: String, revisionRequest: String)?
    /// Tracks whether a revision has already been requested in the current generation
    private var revisionAlreadyRequestedThisGeneration = false

    func set(requesterName: String, targetAgentName: String, revisionRequest: String) -> Bool {
        // Prevent duplicate revision requests during the same agent's generation
        if revisionAlreadyRequestedThisGeneration {
            return false  // Indicates the request was rejected
        }
        pending = (requesterName, targetAgentName, revisionRequest)
        revisionAlreadyRequestedThisGeneration = true
        return true  // Indicates success
    }

    func consume() -> (requesterName: String, targetAgentName: String, revisionRequest: String)? {
        let value = pending
        pending = nil
        return value
    }

    /// Call this at the start of each agent's generation to reset the flag
    func resetForNewGeneration() {
        revisionAlreadyRequestedThisGeneration = false
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
    static var name: String { "RequestRevision" }
    var name: String { Self.name }

    let agents: [AgentConfig]
    let store: RevisionRequestStore
    let conversationId: UUID
    /// The name of the agent currently generating — used to prevent self-revision.
    let callingAgentName: String
    /// Names of agents that have already produced output in this relay turn.
    let eligibleTargetNames: [String]

    @Generable
    struct Arguments {
        @Guide(description: "Format: <target agent name> | <revision request>. Example: Carmen | Handle null input in updatePhysics.")
        var request: String
    }

    var description: String {
        let eligible = eligibleTargetNames
            .filter { $0.lowercased() != callingAgentName.lowercased() }
        let otherNames = eligible.isEmpty ? "(none yet)" : eligible.joined(separator: ", ")
        return """
            Request a revision from a DIFFERENT agent in the relay. You are \(callingAgentName).
            
            IMPORTANT: Call this tool ONLY ONCE per response. Do not call it multiple times.
            
            Available targets (only agents who have already responded): \(otherNames)
            
            Use this ONLY when you identify a specific issue that another agent should fix.
            After calling this tool, explain your reasoning in your response text.
            """
    }

    func call(arguments: Arguments) async throws -> String {
#if DEBUG
        DebugLog.shared.record(
            kind: .toolCall,
            conversationId: conversationId,
            actor: "RequestRevisionTool",
            content: "request=\(arguments.request)"
        )
#endif

        let parts = arguments.request.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return "ERROR: Invalid request format. Use: <target agent name> | <revision request>."
        }

        let targetAgentName = parts[0]
        let revisionRequest = parts[1]

        // Reject self-revision
        guard targetAgentName.lowercased() != callingAgentName.lowercased() else {
            let errorMsg = "ERROR: You cannot request a revision from yourself. Choose a different agent, or skip the revision request entirely."
#if DEBUG
            DebugLog.shared.record(
                kind: .toolCall,
                conversationId: conversationId,
                actor: "RequestRevisionTool",
                content: "REJECTED: Self-revision attempted by \(callingAgentName)"
            )
#endif
            return errorMsg
        }

        guard agents.contains(where: { $0.name.lowercased() == targetAgentName.lowercased() }) else {
            let names = agents.map(\.name).joined(separator: ", ")
            let errorMsg = "ERROR: Invalid agent name '\(targetAgentName)'. Available agents: \(names)"
#if DEBUG
            DebugLog.shared.record(
                kind: .toolCall,
                conversationId: conversationId,
                actor: "RequestRevisionTool",
                content: "REJECTED: Invalid target '\(targetAgentName)'"
            )
#endif
            return errorMsg
        }

        let eligibleLowercased = Set(eligibleTargetNames.map { $0.lowercased() })
        guard eligibleLowercased.contains(targetAgentName.lowercased()) else {
            let errorMsg = "ERROR: You can only request revisions from agents who have already responded in this relay."
#if DEBUG
            DebugLog.shared.record(
                kind: .toolCall,
                conversationId: conversationId,
                actor: "RequestRevisionTool",
                content: "REJECTED: Target not yet eligible '\(targetAgentName)'"
            )
#endif
            return errorMsg
        }

        // Attempt to set the revision request — this will fail if already called
        let success = await store.set(
            requesterName: callingAgentName,
            targetAgentName: targetAgentName,
            revisionRequest: revisionRequest
        )

        if !success {
            let errorMsg = "ERROR: You have already requested a revision in this response. Do not call this tool again. Continue with your response."
#if DEBUG
            DebugLog.shared.record(
                kind: .toolCall,
                conversationId: conversationId,
                actor: "RequestRevisionTool",
                content: "REJECTED: Duplicate call by \(callingAgentName)"
            )
#endif
            return errorMsg
        }

#if DEBUG
        DebugLog.shared.record(
            kind: .toolCall,
            conversationId: conversationId,
            actor: "RequestRevisionTool",
            content: "ACCEPTED: \(callingAgentName) -> \(targetAgentName)"
        )
#endif

        return "Revision request successfully sent to \(targetAgentName). They will review: \(revisionRequest). Now continue with your own response explaining what you found."
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
    var conversationId = UUID()

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
            agentMessages: []  // Messages are added on-demand as each agent starts
        )
        relayTurns.append(turn)
        let turnIndex = relayTurns.count - 1

#if DEBUG
        DebugLog.shared.record(
            kind: .conversation,
            conversationId: conversationId,
            actor: "User",
            content: userMessage
        )
        DebugLog.shared.record(
            kind: .narration,
            conversationId: conversationId,
            actor: "System",
            content: "Relay started"
        )
#endif

        currentTask = Task {
            var previousOutput = userMessage
            var previousAgentName = "User"
            var revisionCount = 0
            var agentOutputs: [String: String] = [:]

            for (agentIdx, agent) in agents.enumerated() {
                guard !Task.isCancelled else { break }

                // Brief pause between agents to avoid overwhelming the
                // on-device model service (prevents ViewBridge disconnects)
                if agentIdx > 0 {
                    try? await Task.sleep(for: .milliseconds(500))
                }

                // Create the message slot for this agent on-demand
                let agentMsg = AgentMessage(
                    agentConfig: agent, text: "", isComplete: false, revisedBy: nil
                )
                relayTurns[turnIndex].agentMessages.append(agentMsg)
                let messageIndex = relayTurns[turnIndex].agentMessages.count - 1
                currentAgentIndex = messageIndex

#if DEBUG
                DebugLog.shared.record(
                    kind: .handoff,
                    conversationId: conversationId,
                    actor: "System",
                    content: "\(previousAgentName) -> \(agent.name)"
                )
#endif

                // ── Run the agent with a fresh session ──
                let output = await runAgent(
                    agent: agent,
                    userMessage: userMessage,
                    previousAgentName: previousAgentName,
                    previousOutput: previousOutput,
                    eligibleRevisionTargets: Array(agentOutputs.keys),
                    temperature: temperature,
                    useStreaming: useStreaming,
                    turnIndex: turnIndex,
                    messageIndex: messageIndex
                )

                agentOutputs[agent.name] = output

#if DEBUG
                DebugLog.shared.record(
                    kind: .conversation,
                    conversationId: conversationId,
                    actor: agent.name,
                    content: output
                )
                let misses = ToolCallDetector.extractMissedToolCalls(from: output)
                for miss in misses {
                    DebugLog.shared.record(
                        kind: .toolCallMiss,
                        conversationId: conversationId,
                        actor: agent.name,
                        content: miss
                    )
                }
#endif

                // ── Check for revision requests from tool calling ──
                // Skip revision processing if the agent errored out
                     if !output.hasPrefix("⚠️"),
                         let revision = await revisionStore.consume(),
                   revisionCount < maxRevisionLoops,
                   let targetConfig = agents.first(where: {
                       $0.name.lowercased() == revision.targetAgentName.lowercased()
                         }),
                         agentOutputs.keys.contains(where: { $0.lowercased() == targetConfig.name.lowercased() }),
                   // Extra safety: don't allow revision targeting the same agent
                         targetConfig.name.lowercased() != agent.name.lowercased() {
                    revisionCount += 1

#if DEBUG
                    DebugLog.shared.record(
                        kind: .narration,
                        conversationId: conversationId,
                        actor: "System",
                        content: "Revision requested by \(revision.requesterName) -> \(targetConfig.name)"
                    )
#endif

                    // Add a revision bubble to the UI
                    let revMsg = AgentMessage(
                        agentConfig: targetConfig,
                        text: "",
                        isComplete: false,
                        revisedBy: revision.requesterName
                    )
                    relayTurns[turnIndex].agentMessages.append(revMsg)
                    let revMsgIdx = relayTurns[turnIndex].agentMessages.count - 1
                    currentAgentIndex = revMsgIdx

                    // Build revision-specific context
                    let revisionContext = """
                        \(revision.requesterName) requested a revision from you.

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
                        eligibleRevisionTargets: Array(agentOutputs.keys),
                        temperature: temperature,
                        useStreaming: useStreaming,
                        turnIndex: turnIndex,
                        messageIndex: revMsgIdx
                    )

                    agentOutputs[targetConfig.name] = revOutput

#if DEBUG
                    DebugLog.shared.record(
                        kind: .conversation,
                        conversationId: conversationId,
                        actor: targetConfig.name,
                        content: revOutput
                    )
                    let revMisses = ToolCallDetector.extractMissedToolCalls(from: revOutput)
                    for miss in revMisses {
                        DebugLog.shared.record(
                            kind: .toolCallMiss,
                            conversationId: conversationId,
                            actor: targetConfig.name,
                            content: miss
                        )
                    }
#endif

                    // Next sequential agent picks up from the revision
                    previousOutput = revOutput
                    previousAgentName = targetConfig.name
                } else {
                    // Consume and discard any stale revision request (e.g. from
                    // an errored agent, self-revision that slipped through, or
                    // exceeding the revision cap)
                    _ = await revisionStore.consume()

                    // Normal handoff — only update context if the agent
                    // produced a real response (not an error fallback)
                    if !output.hasPrefix("⚠️") {
                        previousOutput = output
                        previousAgentName = agent.name
                    }
                    // If the agent errored, keep the previous valid output
                    // so the next agent still gets usable context
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
        conversationId = UUID()
    }

    // MARK: - Single Agent Run

    /// Creates a **fresh** `LanguageModelSession` for the given agent, sends
    /// it a focused prompt, and streams/awaits the response. Returns the
    /// agent's final output text.
    ///
    /// Every call to this method creates a new session — no session is ever
    /// reused. This is the core "no context rot" guarantee.
    ///
    /// Includes retry logic: if the session crashes (e.g. ViewBridge disconnect)
    /// or returns an empty response, the agent retries up to `maxRetries` times
    /// with a fresh session each attempt.
    private func runAgent(
        agent: AgentConfig,
        userMessage: String,
        previousAgentName: String,
        previousOutput: String,
        eligibleRevisionTargets: [String],
        temperature: Double,
        useStreaming: Bool,
        turnIndex: Int,
        messageIndex: Int,
        maxRetries: Int = 2
    ) async -> String {
        var lastError: Error?
        var disableToolsForRetry = false

        for attempt in 0...maxRetries {
            guard !Task.isCancelled else { break }

            // Pause before retries to let the on-device model service recover
            if attempt > 0 {
                relayTurns[turnIndex].agentMessages[messageIndex].text = ""
                try? await Task.sleep(for: .seconds(1))
            }

            // Reset revision flag at the start of each generation attempt
            await revisionStore.resetForNewGeneration()

            // Clear any stale revision requests from failed previous attempts
            _ = await revisionStore.consume()

            // Fresh session every attempt — never reuse
            // Each agent gets its own tool instances that know the caller's identity
            let tools = disableToolsForRetry
                ? []
                : buildTools(forAgent: agent, eligibleRevisionTargets: eligibleRevisionTargets)
            let session = LanguageModelSession(
                tools: tools,
                instructions: agent.systemPrompt
            )
            let options = GenerationOptions(temperature: temperature)

            let prompt = buildFocusedPrompt(
                agentName: agent.name,
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

                // Validate we got a non-empty, non-null response
                let result = relayTurns[turnIndex].agentMessages[messageIndex].text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Check for common failure patterns
                if result.isEmpty {
                    // Empty response — transient failure, will retry
                    lastError = nil
                    continue
                } else if result.lowercased() == "null" || result.lowercased() == "nil" {
                    // Model returned literal "null" — treat as error
#if DEBUG
                    DebugLog.shared.record(
                        kind: .conversation,
                        conversationId: conversationId,
                        actor: "System",
                        content: "⚠️ \(agent.name) returned literal 'null' on attempt \(attempt + 1)"
                    )
#endif
                    lastError = nil
                    continue
                }
                
                // Valid response received
                relayTurns[turnIndex].agentMessages[messageIndex].isComplete = true

                return relayTurns[turnIndex].agentMessages[messageIndex].text

            } catch is CancellationError {
                // User cancelled — stop immediately
                relayTurns[turnIndex].agentMessages[messageIndex].isComplete = true
                return relayTurns[turnIndex].agentMessages[messageIndex].text
            } catch {
                lastError = error
#if DEBUG
                if error.localizedDescription.contains("Failed to deserialize a Generable type") {
                    DebugLog.shared.record(
                        kind: .narration,
                        conversationId: conversationId,
                        actor: "System",
                        content: "⚠️ Disabling tools for \(agent.name) retry due to tool argument parse failure"
                    )
                }
#endif
                if error.localizedDescription.contains("Failed to deserialize a Generable type") {
                    disableToolsForRetry = true
                }
#if DEBUG
                DebugLog.shared.record(
                    kind: .narration,
                    conversationId: conversationId,
                    actor: "System",
                    content: "⚠️ \(agent.name) error on attempt \(attempt + 1): \(error.localizedDescription)"
                )
#endif
                // Will retry on next iteration
                continue
            }
        }

        // All retries exhausted or task cancelled
        let fallback: String
        if Task.isCancelled {
            fallback = relayTurns[turnIndex].agentMessages[messageIndex].text
        } else if let error = lastError {
            fallback = "⚠️ \(agent.name) encountered an error after \(maxRetries + 1) attempts: \(error.localizedDescription)"
        } else {
            fallback = "⚠️ \(agent.name) failed to produce a valid response after \(maxRetries + 1) attempts. The on-device model may be temporarily unavailable — try again in a moment."
        }
        relayTurns[turnIndex].agentMessages[messageIndex].text = fallback
        relayTurns[turnIndex].agentMessages[messageIndex].isComplete = true
        return fallback
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
    private func buildTools(forAgent agent: AgentConfig, eligibleRevisionTargets: [String]) -> [any Tool] {
        var tools: [any Tool] = []

        guard agent.canRequestRevisions, !eligibleRevisionTargets.isEmpty else {
            return tools
        }

        // Revision tool — lets agents request help from each other
        // Passes `callingAgentName` so the tool can reject self-revisions.
        tools.append(RequestRevisionTool(
            agents: agents,
            store: revisionStore,
            conversationId: conversationId,
            callingAgentName: agent.name,
            eligibleTargetNames: eligibleRevisionTargets
        ))

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
        agentName: String,
        previousAgentName: String,
        previousOutput: String,
        userMessage: String
    ) -> String {
        if previousAgentName == "User" {
            return """
                [You are: \(agentName)]

                [User Request]:
                \(userMessage)
                """
        } else {
            return """
                [You are: \(agentName)]

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
