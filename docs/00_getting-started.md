# Getting Started

A minimal enactod application: one agent, one tool, one client. The client asks the agent for the current time, the agent calls `get_time` to answer, and the program exits. Source: [getting_start.odin](getting_start.odin).

## Running

```bash
export ANTHROPIC_API_KEY=...
cd docs
odin run .
```

## Swapping providers

```odin
// Gemini (GOOGLE_API_KEY).
llm = enact.gemini(google_key, .Gemini_2_5_Flash)

// Ollama (local, no key, needs `ollama serve`).
llm = enact.ollama("gemma3:4b")

// OpenAI.
llm = enact.openai(openai_key, .GPT_4_1_Mini)

// OpenAI wire compatible (Groq, Together, Fireworks, vLLM, LM Studio, OpenRouter).
llm = enact.openai_compat("groq", "https://api.groq.com/openai/v1", groq_key, "llama-3.3-70b-versatile")
```

Each preset bakes in the right base URL, timeout, rate limit default, and (for Anthropic) cache and thinking semantics. See [Providers and Routing](04_providers-routing.md).

## What the example shows

* **Spawning an agent.** `spawn_agent("demo", agent_config)` registers a supervised actor named `agent:demo` with its worker pool, rate limiter, and tool actors.
* **Talking via Session.** `make_session("demo")` is a client side value. `session_send` posts an `Agent_Request`; the reply arrives as `Agent_Response` in the caller.
* **Function tools.** `function_tool` runs `Tool_Proc` directly on the agent. Zero spawn, good for pure stateless operations.
* **Supervision.** Agent and client are co spawned as children of the node via `make_children`.
* **Termination.** The client posts to a semaphore on response; `main` returns once `sema_wait` unblocks.

## Next steps

* [Agent](01_agent.md). Lifecycle, configuration, dispatch phases.
* [Session](02_session.md). Request and response, sync helpers, cross node.
* [Tools](03_tools.md). Four tool lifecycles.
* [Providers and Routing](04_providers-routing.md). Anthropic, OpenAI compatible, Ollama, Gemini.
* [Streaming and Events](05_streaming-events.md).
* [Text Store](07_text-store.md).

---
[Agent >](01_agent.md)
