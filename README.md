# enactod

[![CI](https://github.com/Jonathan-Rowles/enactod/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Jonathan-Rowles/enactod/actions/workflows/ci.yml)

**Actor based LLM agents for the [Odin programming language](https://odin-lang.org/).**

enactod is an LLM agent framework built on [actod](https://github.com/Jonathan-Rowles/actod). Agents, tools, rate limiters, sub agent pools, and trace sinks are all actors. They compose by name, are supervised by actod, and run local or distributed without changing calling code.

## Why actors for agentic work?

A real agent juggles long lived conversational state, parallel tool calls, sub agent fan out, provider rate limits shared across many agents, cross node inference, and a messy failure story (timeouts, 429s, crashed tools, malformed outputs). Writing that with futures, mutexes, and channels means reinventing supervision, message routing, and addressing by hand. Actors give you the primitives for free:

* **Isolation and supervision.** Agent, tool, and sub agent crashes stay local. `restart_policy` declares intent up front, so you don't reanswer "catch here or let it propagate?" at every call site.
* **Location transparency.** Sub agents, tools, rate limiters, and trace sinks can live in the same process, on a different worker thread, or on a different node, without changing calling code.
* **Natural concurrency.** Parallel tool calls, sub agent pools, N in flight requests across many agents. The agent actor owns its own phase and correlates replies by caller PID, no lock on "is the agent idle?".

enactod uses the actor model as the composition primitive. The full actod runtime (supervision, registry, pub/sub, timers, networking) is re exported through `enact` when you need it.

## Install

```bash
git clone --recurse-submodules https://github.com/Jonathan-Rowles/enactod
```

## What's included

| Feature | Docs |
|---|---|
| Agent | [01 agent](docs/01_agent.md) |
| Session | [02 session](docs/02_session.md) |
| Tools | [03 tools](docs/03_tools.md) |
| Providers and routing | [04 providers and routing](docs/04_providers-routing.md) |
| Streaming events | [05 streaming events](docs/05_streaming-events.md) |
| Rate limiting | [06 rate limiting](docs/06_rate-limiting.md) |
| Text store | [07 text store](docs/07_text-store.md) |
| Remote agents | [08 remote agents](docs/08_remote-agents.md), example [`example/chat`](example/chat) |
| Sub agents | [09 sub agents](docs/09_sub-agents.md) |
| Prompt caching | [10 prompt caching](docs/10_prompt-caching.md) |
| Ollama | [11 ollama](docs/11_ollama.md) |
| Tracing | [12 tracing](docs/12_tracing.md), example [`example/trace_otlp`](example/trace_otlp/main.odin) |
| Message types | [13 message types](docs/13_message-types.md) |

## Minimal application

```odin
import enact "enactod"

Client :: struct { session: enact.Session }

client_behaviour := enact.Actor_Behaviour(Client) {
    init = proc(d: ^Client) { enact.session_send(&d.session, "Hello") },
    handle_message = proc(d: ^Client, from: enact.PID, msg: any) {
        if r, ok := msg.(enact.Agent_Response); ok {
            fmt.println(enact.resolve(r.content))
            enact.self_terminate()
        }
    },
}

spawn_client :: proc(_: string, _: enact.PID) -> (enact.PID, bool) {
    return enact.spawn_child("client",
        Client{session = enact.make_session("demo")}, client_behaviour)
}

spawn_demo_agent :: proc(_: string, _: enact.PID) -> (enact.PID, bool) {
    sess, ok := enact.spawn_agent("demo", demo_config)
    return sess.pid, ok
}

main :: proc() {
    demo_config = enact.make_agent_config(
        system_prompt = "You are a helpful assistant.",
        llm           = enact.anthropic(api_key, .Claude_Sonnet_4_5),
    )
    enact.NODE_INIT("my-app", enact.make_node_config(
        actor_config = enact.make_actor_config(
            children = enact.make_children(spawn_demo_agent, spawn_client),
        ),
    ))
    enact.await_signal()
}
```

Walkthrough: [docs/00_getting-started.md](docs/00_getting-started.md).

## UI as a blocking child

For a TUI, CLI, or game loop that owns the main thread, pass the UI spawn as `blocking_child` instead of calling `await_signal`. `NODE_INIT` runs the UI spawn on the calling thread and returns when that actor terminates. Main then calls `SHUTDOWN_NODE` explicitly.

```odin
main :: proc() {
    agents, ui, log_level := agent.setup()
    enact.NODE_INIT("coderson", enact.make_node_config(
        actor_config = enact.make_actor_config(
            children = agents,
            logging  = enact.make_log_config(level = log_level),
        ),
        blocking_child = ui,
    ))
    enact.SHUTDOWN_NODE()
}
```

Shutdown sequence:

1. User triggers exit inside the UI (quit command, EOF, window close).
2. An inner actor detects the exit and calls `enact.terminate_actor(ui_pid, .SHUTDOWN)`. Common pattern: a stdin reader spawned as a dedicated OS thread child of the UI.
3. The UI actor's loop returns, `NODE_INIT` returns on main.
4. Main calls `SHUTDOWN_NODE()` to drain the worker pool, destroy actor arenas, and free curl.

Do not call `await_signal()` in this pattern. Working example: [`example/chat/cli`](example/chat/cli/main.odin).

## Multi user server (gateway pattern)

One agent per connected user, spawned on demand by a gateway actor. Client asks to open a session, gets back an agent name, talks to that agent for the rest of the connection, and asks the gateway to tear it down on close.

```odin
gateway_handle_message :: proc(d: ^Gateway_State, from: enact.PID, content: any) {
    switch msg in content {
    case enact.Session_Create:
        d.next_id += 1
        name := strings.clone(fmt.tprintf("session-%d", d.next_id))
        enact.spawn_agent(name, d.config)
        enact.send(from, enact.Session_Created{agent_name = name})
    case enact.Session_Destroy:
        enact.destroy_agent(msg.agent_name)
    }
}
```

Each session gets its own chat history, worker pool, rate limiter, and tool actors. One user's conversation doesn't touch another's state.

Working example: [`example/chat`](example/chat). [`server`](example/chat/server/main.odin) runs the gateway, [`cli`](example/chat/cli/main.odin) is a remote client. Run two CLI instances against one server to see two live sessions. Transport agnostic: swap the TCP connection for a WebSocket, SSE, or long poll edge actor and nothing else changes. See [docs/08_remote-agents.md](docs/08_remote-agents.md).

## Facade

`import enact "enactod"` is all you need. [`enactod.odin`](enactod.odin) holds the full public surface: agents, sessions, tools, providers, messages, tracing, plus the actod runtime re exported (`spawn`, `send`, `set_timer`, `subscribe_type`, etc.). `src/` is implementation.

## Memory model

Three allocators:

* **Per agent arena.** Transport bytes between actors in one agent subtree: LLM payloads, tool arguments, tool results, stream chunks, event text. Created at `spawn_agent`, reset at the start of each user `session_send` before the new turn's content is written. Sub agents inherit the parent's arena and never reset.
* **Actor arena.** Per actor working memory that dies with the actor: parser buffers, stream accumulators, chat history (owned strings, survive arena reset). Managed by actod.
* **Heap.** User owned configuration (`Agent_Config`, `Provider_Config`, `Tool_Def`, static prompts). Program lifetime.

If a string flows through a message, use `Text`. Spawn time infrastructure goes in the actor arena. Compile time config stays where the user put it. See [docs/07_text-store.md](docs/07_text-store.md).

## Configuration

```odin
enact.make_agent_config(
    llm                     = enact.anthropic(key, .Claude_Sonnet_4_5),  // required
    system_prompt           = "...",
    tools                   = tools,
    children                = nil,
    worker_count            = 2,
    max_turns               = 10,
    max_tool_calls_per_turn = 20,
    tool_timeout            = 30 * time.Second,
    stream                  = false,
    forward_events          = false,
    forward_thinking        = true,
    tool_continuation       = "",
    validate_tool_args      = true,
    accumulate_history      = true,
    trace_sink              = {},
)
```

`llm` is the only required argument. It bundles provider, model, sampling (temperature, max_tokens, thinking_budget, cache_mode), timeout, and rate limit policy, built via a preset (`anthropic` / `openai` / `gemini` / `ollama` / `openai_compat`) or a raw `LLM_Config`. Dynamic routing: send `Set_Route{llm}` from a router actor. See [docs/04_providers-routing.md](docs/04_providers-routing.md).

## TODO

* Eval harness against stub or live providers.
* MCP tool wrapping.
* Per turn token usage events (currently only final `Agent_Response` carries totals).
* Vertex and Bedrock provider wrappers.
* Shared `ratelim:<provider>` actor. Sub agent pools and multi agent setups currently race independent limiters toward the same provider's 429.
* Peer budget actor (`max_tokens_total`, `max_wallclock`, cost).
* `parent_request_id: Request_ID` on `Agent_Event` (8 bytes) for sub agent tree correlation.
