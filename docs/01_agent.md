# Agent

Every interaction goes through an agent. The agent is a supervised actor owning a worker pool, a rate limiter, tool actors, and a chat history. A request drives a turn loop (ask the LLM, run tool calls, feed results back, repeat) until the model produces a final response or the turn budget runs out.

## Spawning

```odin
import enact "enactod"

cfg := enact.make_agent_config(
    system_prompt = "You are a helpful assistant.",
    llm           = enact.gemini(google_api_key, .Gemini_2_5_Flash),
    tools         = tools,
)
session, ok := enact.spawn_agent("demo", cfg)
```

`spawn_agent` returns a ready [`Session`](02_session.md), the client value you use to drive the agent. `session.pid` is the agent's actor PID.

Presets: `enact.anthropic`, `enact.openai`, `enact.gemini`, `enact.ollama`, plus `enact.openai_compat` for OpenAI wire compatible endpoints (Groq, Together, Fireworks, vLLM, LM Studio, OpenRouter). See [Providers and Routing](04_providers-routing.md).

`spawn_agent` registers `agent:demo`, spawns `worker_count` LLM workers (default 2) on dedicated OS threads, spawns `ratelim:demo`, lazy spawns PERSISTENT tool actors on first call, and spawns any `children` in the config.

Co spawn with other actors via `make_children`. Spawn closures return `(PID, bool)`, so read the PID off the session:

```odin
spawn_demo :: proc(_: string, _: enact.PID) -> (enact.PID, bool) {
    sess, ok := enact.spawn_agent("demo", cfg)
    return sess.pid, ok
}

enact.NODE_INIT("app", enact.make_node_config(
    actor_config = enact.make_actor_config(
        children = enact.make_children(spawn_demo, spawn_client),
    ),
))
```

## Actor tree

```
agent:<name>
├── llm:<name>:0            worker 0 (dedicated OS thread)
├── llm:<name>:1            worker 1
├── ratelim:<name>          rate limiter / dispatcher
├── tool:<name>:<tool>      PERSISTENT / SUB_AGENT (lazy spawned)
├── ephemeral:<name>:<id>   EPHEMERAL (one per call, self terminates)
└── <config.children>       extra siblings you declared
```

The agent never addresses workers directly. It sends `LLM_Call` to `ratelim:<name>`, which fans out across workers (round robin when rate limiting is off, queue gated when on). See [Rate Limiting](06_rate-limiting.md).

## Configuration

```odin
enact.make_agent_config(
    llm                           = enact.anthropic(key, .Claude_Sonnet_4_5),  // required
    system_prompt                 = "",
    tools                         = tools,
    children                      = nil,
    worker_count                  = 2,
    max_turns                     = 10,
    max_tool_calls_per_turn       = 20,
    tool_timeout                  = 30 * time.Second,
    stream                        = false,
    forward_events                = false,
    forward_thinking              = true,
    tool_continuation             = "",
    validate_tool_args            = true,
    accumulate_history            = true,
    auto_compact_threshold_tokens = 0,  // 0 = disabled
    trace_sink                    = {},
)
```

### What lives on LLM_Config (not Agent_Config)

`provider`, `model`, `temperature`, `max_tokens`, `thinking_budget`, `cache_mode`, `timeout`, `enable_rate_limiting` live on `LLM_Config` because they are per endpoint and travel as a unit through `Set_Route`. Each preset exposes only the knobs its provider honours (`enact.openai()` has no `cache_mode` because OpenAI caches server side). Override sampling through the preset:

```odin
llm = enact.anthropic(
    key,
    .Claude_Opus_4,
    temperature     = 0.2,
    max_tokens      = 16_000,
    thinking_budget = 10_000,
    cache_mode      = .EPHEMERAL,
)
```

For unusual combos, construct `LLM_Config` directly. See [Providers and Routing](04_providers-routing.md).

## Dispatch phases

```
IDLE ──session_send──> AWAITING_LLM ──LLM_Result──> {final | tool calls}
                             │
                             ↓ (stream = true)
                       AWAITING_STREAM ──chunk stream──> finalize
                             │
                             ↓ (tool calls)
                       AWAITING_TOOLS ──all results──> AWAITING_LLM ...
                             │
                             ↓ (no more calls, or max_turns)
                            IDLE (Agent_Response sent)
```

`llm.timeout` covers `AWAITING_LLM` and `AWAITING_STREAM`; `tool_timeout` covers `AWAITING_TOOLS`. Timeout produces `Agent_Response{is_error = true}` and returns to `IDLE`. Because `llm.timeout` lives on `LLM_Config`, a `Set_Route` that swaps providers also swaps the timeout (e.g. `anthropic` 120s → `ollama` 300s).

## Single request, single driver

An agent services one request in flight. A second `session_send` while non idle is rejected with `error_msg = text("agent is busy")`.

An agent is also **claimed by its first driver**. The PID of the first `Agent_Request` becomes the permanent owner; requests from other PIDs are rejected with `error_msg = text("agent claimed by another actor")`. The claim lets the agent cheaply reset its transport arena per request: provably one external writer.

For concurrency, spawn more agents (one per caller, gateway pattern). For fan out inside one conversation, use [sub agent pools](09_sub-agents.md).

## Turn limit

`max_turns` bounds the LLM → tools → LLM loop. When hit, the agent returns a truncated response containing the last assistant text prefixed with `[truncated at turn limit N]`. On the penultimate turn the agent injects a final turn user message telling the model to wrap up.

`max_tool_calls_per_turn` caps per turn tool dispatches. Excess calls are reported to the model as errors.

## Auto compact

Set `auto_compact_threshold_tokens > 0` to have the agent automatically compact its history when an LLM call's `input_tokens` reaches the threshold. After the current request completes the agent transitions straight to `AWAITING_COMPACT`, runs one extra LLM call to summarise the conversation, and replaces the chat history with the summary. New requests during the compact window are rejected with `agent is busy`.

`0` disables auto compact. Manual compact via `compact_history(...)` is always available.

## Destroying

```odin
enact.destroy_agent("demo")
```

Terminates `agent:<name>` and every child. The agent's arena is freed.

---
[< Getting Started](00_getting-started.md) | [Session >](02_session.md)
