//
//  AgentRelayView.swift
//  Apple Intelligence Chat
//
//  Created by Pallav Agarwal on 2/7/26.
//

import SwiftUI
import FoundationModels

/// The main agent relay chat view — a group chat with AI agents
struct AgentRelayView: View {
    @State private var agentManager = AgentManager()
    @State private var inputText = ""
    @State private var model = SystemLanguageModel.default
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    @AppStorage("useStreaming") private var useStreaming = AppSettings.useStreaming
    @AppStorage("temperature") private var temperature = AppSettings.temperature

    var body: some View {
        ZStack {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        // Welcome header
                        agentWelcomeHeader
                            .padding(.bottom, 12)

                        // Relay turns
                        ForEach(agentManager.relayTurns) { turn in
                            RelayTurnView(turn: turn, currentAgentIndex: agentManager.currentAgentIndex)
                                .id(turn.id)
                        }
                    }
                    .padding()
                    .padding(.bottom, 90)
                }
                .onChange(of: agentManager.relayTurns.last?.agentMessages.last?.text) {
                    if let lastTurn = agentManager.relayTurns.last {
                        withAnimation {
                            proxy.scrollTo(lastTurn.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Input field
            VStack {
                Spacer()
                agentInputField
                    .padding(20)
            }
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Welcome Header

    private var agentWelcomeHeader: some View {
        VStack(spacing: 8) {
            // Agent avatars in a row
            HStack(spacing: -8) {
                ForEach(agentManager.agents) { agent in
                    Text(agent.emoji)
                        .font(.title)
                        .frame(width: 44, height: 44)
                        .background(agent.swiftUIColor.opacity(0.2))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                }
            }

            Text("Agent Relay")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Your team of \(agentManager.agents.count) agents will collaborate on your request")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 16)
    }

    // MARK: - Input Field

    private var agentInputField: some View {
        ZStack {
            TextField("Describe what you need…", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .frame(minHeight: 22)
                .disabled(agentManager.isRunning)
                .onSubmit {
                    if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        handleSendOrStop()
                    }
                }
                .padding(16)

            HStack {
                Spacer()
                Button(action: handleSendOrStop) {
                    Image(systemName: agentManager.isRunning ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(isSendDisabled ? Color.gray.opacity(0.6) : .primary)
                }
                .disabled(isSendDisabled)
                .animation(.easeInOut(duration: 0.2), value: agentManager.isRunning)
                .glassEffect(.regular.interactive())
                .padding(.trailing, 8)
            }
        }
        .glassEffect(.regular.interactive())
    }

    private var isSendDisabled: Bool {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !agentManager.isRunning
    }

    // MARK: - Actions

    private func handleSendOrStop() {
        if agentManager.isRunning {
            agentManager.stopRelay()
        } else {
            guard model.isAvailable else {
                errorMessage = "The language model is not available."
                showErrorAlert = true
                return
            }
            let message = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return }
            inputText = ""
            agentManager.startRelay(
                userMessage: message,
                temperature: temperature,
                useStreaming: useStreaming
            )
        }
    }

    func resetConversation() {
        agentManager.reset()
    }
}

// MARK: - Relay Turn View

/// Displays one user message followed by each agent's response
struct RelayTurnView: View {
    let turn: RelayTurn
    let currentAgentIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // User bubble
            HStack {
                Spacer()
                Text(turn.userMessage)
                    .padding(12)
                    .foregroundColor(.white)
                    .background(.blue)
                    .clipShape(.rect(cornerRadius: 18))
                    .glassEffect(in: .rect(cornerRadius: 18))
            }
            .padding(.vertical, 6)

            // Relay arrow
            HStack {
                Spacer()
                relayIndicator
                Spacer()
            }
            .padding(.vertical, 4)

            // Agent messages
            ForEach(Array(turn.agentMessages.enumerated()), id: \.element.id) { index, agentMsg in
                AgentBubbleView(
                    agentMessage: agentMsg,
                    isActive: currentAgentIndex == index && !agentMsg.isComplete,
                    showRelayArrow: index < turn.agentMessages.count - 1 && agentMsg.isComplete
                )
            }
        }
        .padding(.vertical, 8)
    }

    private var relayIndicator: some View {
        VStack(spacing: 2) {
            Image(systemName: "arrow.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("relay started")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
    }
}

// MARK: - Agent Bubble View

/// A single agent's chat bubble styled like a group chat
struct AgentBubbleView: View {
    let agentMessage: AgentMessage
    let isActive: Bool
    let showRelayArrow: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Agent name tag
            HStack(spacing: 6) {
                Text(agentMessage.agentConfig.emoji)
                    .font(.body)
                Text(agentMessage.agentConfig.name)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(agentMessage.agentConfig.swiftUIColor)

                if isActive {
                    TypingIndicatorView()
                }
            }

            // Message content
            if agentMessage.text.isEmpty && isActive {
                PulsingDotView()
                    .frame(width: 60, height: 25)
                    .padding(.leading, 4)
            } else if !agentMessage.text.isEmpty {
                MarkdownText(agentMessage.text)
                    .padding(12)
                    .background(agentMessage.agentConfig.swiftUIColor.opacity(0.08))
                    .clipShape(.rect(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(agentMessage.agentConfig.swiftUIColor.opacity(0.15), lineWidth: 1)
                    )
            }

            // Relay handoff arrow
            if showRelayArrow {
                HStack {
                    Spacer()
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(agentMessage.agentConfig.swiftUIColor.opacity(0.5))
                        Text("handed off")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.3), value: agentMessage.text)
    }
}

// MARK: - Typing Indicator

/// Cute little "typing…" animation next to agent name
struct TypingIndicatorView: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 2) {
            Text("thinking")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(0..<3) { i in
                Circle()
                    .frame(width: 4, height: 4)
                    .foregroundStyle(.tertiary)
                    .scaleEffect(isAnimating ? 1.0 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15),
                        value: isAnimating
                    )
            }
        }
        .onAppear { isAnimating = true }
    }
}
