# Agent Relay Mode 🏃‍♂️⚡🔧

> *"The intelligence is there — it just needs the right tools."*

Agent Relay Mode stretches tiny on-device LLMs beyond their vanilla capabilities by orchestrating a **relay race of specialized agents**. Each agent focuses on one small piece of the problem, then hands off to the next — like a team of experts collaborating in a group chat. Agents can even **call tools** and **request revisions from each other**.

---

## Architecture Overview

```
User Message
    │
    ▼
┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐
│ Andrea  │ ──▶ │  Barb   │ ──▶ │ Carmen  │ ──▶ │ Reinie  │
│ Architect│     │ Builder │     │  Coder  │     │ Reviewer │
│  📋     │     │  🧱     │     │  💻     │     │  🔍     │
└─────────┘     └─────────┘     └─────────┘     └─────────┘
    Plan     ──▶ Framework  ──▶   Fill In   ──▶   Review
                                     │
                              🔧 tool call:
                          "request_revision"
                                     │
                                     ▼
                               ┌─────────┐
                               │  Cody   │  ← revision loop
                               │  Coder  │
                               │  💻     │
                               └─────────┘
                                  Fix it
```

Each agent:
1. Gets its **own system prompt** (personality + role)
2. Receives **only the user request + the previous agent's output** (minimal context — no full conversation dump)
3. Gets a **brand-new `LanguageModelSession`** every time — no session reuse, no context rot
4. Has access to **tools** (like requesting revisions) via the Foundation Models `Tool` protocol
5. Produces a response that is **handed off** to the next agent

---

## File Structure

| File | Purpose |
|------|---------|
| `AgentConfiguration.json` | **The single source of truth** for agent definitions. Add, remove, reorder agents here. |
| `AgentManager.swift` | Loads JSON config, orchestrates the relay pipeline, manages state, defines tools, handles revision loops. |
| `AgentRelayView.swift` | Group-chat-style UI for the relay. Includes `RelayTurnView`, `AgentBubbleView`, `TypingIndicatorView`. Shows revision annotations. |
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
   - A **brand-new** `LanguageModelSession` is created with the agent's `systemPrompt` and the current set of tools
   - The agent receives a **focused prompt**: only the original user request + the previous agent's output
   - The response streams in real-time (or waits for full completion)
   - After generation, the manager checks for pending revision requests
   - If a revision was requested → a fresh session is spun up for the target agent with the revision context
   - Once complete (with or without revision), the next agent begins
3. The pipeline supports **cancellation** at any point
4. Revision loops are capped at **3 per turn** to prevent infinite cycles

### 3. Context Strategy: No Context Rot

**Old approach (removed):** Every agent got the full accumulating conversation — user message + all previous agent outputs + history from prior turns. This caused "context rot" where later agents got confused by too much information.

**New approach:** Each agent only sees:

```
[User Request]:
The original user message

[Previous Agent — AgentName]:
Only the immediately previous agent's output
```

- The **first agent** gets just the user request (Andrea plans)
- **Barb** turns the plan into a code framework (skeletons only)
- **Carmen** fills in the framework with working code
- **Reinie** reviews the code
- **Subsequent agents** always get the user request + what the agent right before them said
- **Revision agents** get a focused revision context: what was asked, their original output, and the requester's output
- **No full conversation dumps.** Each session is fresh. No context bleeds between agents.

This keeps each agent focused and prevents the 4,096-token context window from filling up with irrelevant prior turns.

### 4. Tool Calling

Agents have access to tools via the Foundation Models `Tool` protocol. Tools are passed to `LanguageModelSession(instructions:tools:)` and the framework handles invocation automatically during generation.

#### How Tool Calling Works

1. Tools are defined as structs conforming to `Tool` from FoundationModels
2. Each tool has an `Arguments` struct (Codable, with `@Guide` annotations for the model)
3. The framework describes available tools to the model automatically
4. When the model decides to use a tool, the framework calls `call(arguments:)` and feeds the result back
5. After generation completes, the `AgentManager` checks for any side effects (like revision requests)

#### Built-in Tool: `RequestRevisionTool`

Allows any agent to request a revision from any other agent:

```swift
struct RequestRevisionTool: Tool {
    struct Arguments: Codable {
        @Guide(description: "The name of the agent to ask for a revision.")
        var targetAgentName: String

        @Guide(description: "What needs to be revised or reconsidered.")
        var revisionRequest: String
    }

    func call(arguments: Arguments) async throws -> ToolOutput {
        // Records the request in a shared RevisionRequestStore (actor)
        // AgentManager checks this store after each agent finishes
    }
}
```

**Example flow:** Rexa the Reviewer calls `RequestRevisionTool` with `targetAgentName: "Cody"` and `revisionRequest: "The function is missing error handling for nil inputs."` → After Rexa finishes, the manager spins up a fresh Cody session with the revision context → Cody produces an updated response → the relay continues.

#### Communication via `RevisionRequestStore`

The tool and manager communicate through a shared `actor`:

```swift
actor RevisionRequestStore {
    func set(targetAgentName: String, revisionRequest: String)
    func consume() -> (targetAgentName: String, revisionRequest: String)?
}
```

The tool writes to it; the manager reads and clears it after each agent.

### 5. Adding New Tools

All tools are registered in `AgentManager.buildTools()`. To add a new tool:

1. **Create a struct conforming to `Tool`** (from FoundationModels):

```swift
struct WebSearchTool: Tool {
    struct Arguments: Codable {
        @Guide(description: "The search query to look up.")
        var query: String
    }

    var description: String {
        "Search the web for information. Use this when you need current data or facts."
    }

    func call(arguments: Arguments) async throws -> ToolOutput {
        let results = await performSearch(query: arguments.query)
        return ToolOutput(results)
    }
}
```

2. **Append it in `buildTools()`**:

```swift
private func buildTools() -> [any Tool] {
    var tools: [any Tool] = []
    tools.append(RequestRevisionTool(agents: agents, store: revisionStore))
    tools.append(WebSearchTool())       // ← new tool
    tools.append(CalculatorTool())      // ← another new tool
    return tools
}
```

That's it. The Foundation Models framework automatically makes the tool available to every agent.

#### Tool Design Guidelines

- **Keep `Arguments` simple.** The on-device model has a small context window — complex argument schemas confuse it.
- **Use `@Guide` annotations** to describe each argument clearly. The model relies on these descriptions.
- **Return useful `ToolOutput`** strings. The model sees the output and incorporates it into its response.
- **Side effects are fine.** Tools can write to actors, files, databases, etc. Just be mindful of thread safety.
- **One tool call per agent per generation** is the practical limit for the on-device model.

### 6. UI (`AgentRelayView`)

The UI is styled like a **group chat**:
- User messages appear as blue bubbles on the right
- Agent messages appear on the left with:
  - Colored emoji avatar + name tag
  - Tinted bubble matching the agent's color
  - "thinking..." animation while generating
  - "handed off" arrows between agents
  - **"(revision requested by X)"** label on revision messages
- A welcome header shows all agents with overlapping avatars
- Revision messages appear inline in the conversation flow

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

That's it. The system picks it up automatically — including tool availability.

### Remove an Agent

Delete its entry from the JSON array.

### Reorder Agents

Change the `order` values. Agents are sorted by `order` ascending.

### Change Agent Behavior

Edit the `systemPrompt`. This is the most impactful lever — a well-crafted prompt makes the agent much more effective at its role.

**Tip for revision-aware agents:** Include something like *"If you find issues with the previous agent's work, use the RequestRevision tool to ask them to fix it"* in the system prompt of reviewer-type agents.

---

## Design Principles

1. **Stretch, don't overload** — Each agent gets a focused task so the small on-device model can excel at one thing at a time
2. **Relay, not committee** — Sequential handoff, not parallel consensus. Each agent builds on the last.
3. **No context rot** — Every agent gets a fresh `LanguageModelSession` with only the information it needs. No accumulated history, no stale context.
4. **Tools, not magic** — Agent capabilities are extended through explicit tools, not prompt hacks. Tools are typed, validated, and easy to add.
5. **Transparent** — The user sees every agent's contribution and every revision in the group chat. No hidden reasoning.
6. **Modular** — Agents are pure configuration, tools are pure code. No coupling between the two.
7. **Cute** — It should feel like hanging out in a group chat with helpful AI friends, not operating an enterprise pipeline.

---

## Key Components

### `RevisionRequestStore` (Actor)

Thread-safe bridge between tool calls and the relay pipeline:

```
Tool.call() ──writes──▶ RevisionRequestStore ──read by──▶ AgentManager
```

### `runAgent()` (Private method)

The workhorse of the pipeline. Creates a fresh session, sends a focused prompt, streams/awaits the response, and returns the final text. Called for both normal relay steps and revision loops.

### `buildFocusedPrompt()` (Private method)

Constructs the minimal prompt for each agent. First agent gets just the user request; subsequent agents get user request + previous agent's output.

### `buildTools()` (Private method — the tool registry)

Single place where all tools are instantiated and collected. This is the **extension point** for adding new capabilities.

---

## Future Ideas

- [x] ~~**Tool use** — Let agents call functions~~ ✅ Implemented via Foundation Models `Tool` protocol
- [x] ~~**Agent-to-agent feedback loops** — If the reviewer finds issues, loop back to the coder~~ ✅ Implemented via `RequestRevisionTool`
- [ ] **More built-in tools** — Web search, file I/O, calculator, code execution
- [ ] **Conditional routing** — Let agents decide which agent goes next (not just sequential)
- [ ] **User can @ mention a specific agent** — Skip the relay and talk directly to one agent
- [ ] **Agent memory** — Persist agent-specific context across conversations
- [ ] **Custom agent editor in-app** — Edit agents from the UI instead of just JSON
- [ ] **Agent performance metrics** — Track which agents contribute most to good outcomes
- [ ] **Parallel agents** — Some steps could run in parallel (e.g., testing + documentation)
- [ ] **Tool permissions** — Let specific tools be available only to specific agents
- [ ] **Multi-revision chains** — Allow revision agents to themselves request further revisions (currently capped at 3 loops)

---

## Settings Integration

- **Agent Mode toggle** in Settings → Mode section
- When ON: system prompt field hides, agent roster shows
- When OFF: normal single-chat mode, system prompt returns
- Temperature and streaming settings apply to all agents
- Toggling resets the current conversation

---

*Built with Apple Intelligence on-device models via the Foundation Models framework. Tools powered by the `Tool` protocol from FoundationModels.*
