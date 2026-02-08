# Agent Relay Mode 🏃‍♂️⚡

> *"The intelligence is there — it just needs the right tools."*

Agent Relay Mode stretches tiny on-device LLMs beyond their vanilla capabilities by orchestrating a **relay race of specialized agents**. Each agent focuses on one small piece of the problem, then hands off to the next — like a team of experts collaborating in a group chat.

---

## Architecture Overview

```
User Message
    │
    ▼
┌─────────┐     ┌─────────┐     ┌─────────┐
│  Aria    │ ──▶ │  Cody   │ ──▶ │  Rexa   │
│ Architect│     │  Coder  │     │ Reviewer │
│  🏗️     │     │  💻     │     │  🔍     │
└─────────┘     └─────────┘     └─────────┘
    Plan     ──▶   Implement  ──▶   Review
```

Each agent:
1. Gets its **own system prompt** (personality + role)
2. Receives the **full conversation context** (user message + all previous agent outputs in this turn)
3. Produces a response that is **handed off** to the next agent
4. Has its **own `LanguageModelSession`** — no shared state between agents

---

## File Structure

| File | Purpose |
|------|---------|
| `AgentConfiguration.json` | **The single source of truth** for agent definitions. Add, remove, reorder agents here. |
| `AgentManager.swift` | Loads JSON config, orchestrates the relay pipeline, manages state. |
| `AgentRelayView.swift` | Group-chat-style UI for the relay. Includes `RelayTurnView`, `AgentBubbleView`, `TypingIndicatorView`. |
| `SettingsView.swift` | Toggle for Agent Mode + agent roster preview. |
| `ContentView.swift` | Switches between normal chat and `AgentRelayView` based on the setting. |
| `MessageView.swift` | Existing single-chat message UI (unchanged). |

---

## How It Works

### 1. Configuration (`AgentConfiguration.json`)

Agents are defined as a JSON array. Each agent has:

```json
{
    "id": "unique_string",
    "name": "Display Name",
    "emoji": "🎨",
    "color": "#HEX_COLOR",
    "systemPrompt": "You are [Name], the [Role]. Your job is to...",
    "order": 0
}
```

- **`order`** determines the relay sequence (0 goes first, 1 goes second, etc.)
- **`systemPrompt`** is the agent's personality — this is what makes each agent specialized
- **`color`** is used for the agent's chat bubble accent
- You can have **any number of agents** — the system dynamically adapts

### 2. The Relay Pipeline (`AgentManager`)

When the user sends a message:

1. `AgentManager.startRelay()` creates a new `RelayTurn`
2. For each agent (in `order` sequence):
   - A fresh `LanguageModelSession` is created with the agent's `systemPrompt`
   - The agent receives: conversation history + user message + all prior agent outputs this turn
   - The response streams in real-time (or waits for full completion)
   - Once complete, the next agent begins
3. The pipeline supports **cancellation** at any point

### 3. Context Building

Each agent sees an accumulating context:

```
[History from previous turns]
[User]: Current user message
[Agent 1 Name]: Agent 1's response
[Agent 2 Name]: Agent 2's response
...
```

This means later agents can reference, critique, or build upon earlier agents' work.

### 4. UI (`AgentRelayView`)

The UI is styled like a **group chat**:
- User messages appear as blue bubbles on the right
- Agent messages appear on the left with:
  - Colored emoji avatar + name tag
  - Tinted bubble matching the agent's color
  - "thinking..." animation while generating
  - "handed off" arrows between agents
- A welcome header shows all agents with overlapping avatars

---

## Modifying Agents

### Add a New Agent

Add a new object to `AgentConfiguration.json`:

```json
{
    "id": "tester",
    "name": "Tess",
    "emoji": "🧪",
    "color": "#9B59B6",
    "systemPrompt": "You are Tess, the Tester. Write unit tests for the code provided by the previous agent...",
    "order": 3
}
```

That's it. The system picks it up automatically.

### Remove an Agent

Delete its entry from the JSON array.

### Reorder Agents

Change the `order` values. Agents are sorted by `order` ascending.

### Change Agent Behavior

Edit the `systemPrompt`. This is the most impactful lever — a well-crafted prompt makes the agent much more effective at its role.

---

## Design Principles

1. **Stretch, don't overload** — Each agent gets a focused task so the small on-device model can excel at one thing at a time
2. **Relay, not committee** — Sequential handoff, not parallel consensus. Each agent builds on the last.
3. **Transparent** — The user sees every agent's contribution in the group chat. No hidden reasoning.
4. **Modular** — Agents are pure configuration. No code changes needed to add/remove/reorder.
5. **Cute** — It should feel like hanging out in a group chat with helpful AI friends, not operating an enterprise pipeline.

---

## Future Ideas

- [ ] **Conditional routing** — Let agents decide which agent goes next (not just sequential)
- [ ] **Agent-to-agent feedback loops** — If the reviewer finds issues, loop back to the coder
- [ ] **User can @ mention a specific agent** — Skip the relay and talk directly to one agent
- [ ] **Agent memory** — Persist agent-specific context across conversations
- [ ] **Custom agent editor in-app** — Edit agents from the UI instead of just JSON
- [ ] **Agent performance metrics** — Track which agents contribute most to good outcomes
- [ ] **Parallel agents** — Some steps could run in parallel (e.g., testing + documentation)
- [ ] **Tool use** — Let agents call functions (file I/O, web search, etc.)

---

## Settings Integration

- **Agent Mode toggle** in Settings → Mode section
- When ON: system prompt field hides, agent roster shows
- When OFF: normal single-chat mode, system prompt returns
- Temperature and streaming settings apply to all agents
- Toggling resets the current conversation

---

*Built with Apple Intelligence on-device models via the Foundation Models framework.*
