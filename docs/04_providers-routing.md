# Providers and Routing

Three pieces: `Provider_Config` (endpoint identity, base URL, API key, wire format, headers), `LLM_Config` (provider, model, sampling, timeout, rate limit policy), and `Set_Route` (runtime override that swaps an `LLM_Config` mid conversation). The agent resolves its route every turn.

## Provider presets

```odin
enact.anthropic(api_key, .Claude_Sonnet_4_5)
enact.openai(api_key, .GPT_4_1_Mini)
enact.gemini(api_key, .Gemini_2_5_Flash)
enact.ollama("llama3.1:8b")                                           // no key, defaults to http://localhost:11434
enact.openai_compat("groq", "https://api.groq.com/openai/v1", key, "llama-3.3-70b-versatile")
```

Each returns an `LLM_Config`:

```odin
cfg := enact.make_agent_config(
    llm   = enact.anthropic(key, .Claude_Sonnet_4_5),
    tools = my_tools,
)
```

### Preset knobs

Only knobs the provider honours. Wrong combos (thinking on OpenAI, `cache_mode` on Ollama) are unpresentable through the preset.

| Preset           | Required          | Optional                                                                                | Default timeout |
|------------------|-------------------|-----------------------------------------------------------------------------------------|-----------------|
| `anthropic`      | `api_key`, `model`| `temperature`, `max_tokens`, `thinking_budget` (min 1024), `cache_mode` (`.EPHEMERAL`), `timeout`, `enable_rate_limiting`, `base_url`, `headers` | 120s |
| `openai`         | `api_key`, `model`| `temperature`, `max_tokens`, `timeout`, `enable_rate_limiting`, `base_url`, `headers`   | 60s  |
| `gemini`         | `api_key`, `model`| `temperature`, `max_tokens`, `thinking_budget` (`-1` dynamic, `0` off, `>0` fixed), `timeout`, `enable_rate_limiting`, `base_url`, `headers` | 60s  |
| `ollama`         | `model` (string)  | `temperature`, `max_tokens`, `thinking_budget`, `timeout`, `enable_rate_limiting` (defaults **false**), `base_url`, `headers` | 300s |
| `openai_compat`  | `name`, `base_url`, `api_key`, `model` | `temperature`, `max_tokens`, `timeout`, `enable_rate_limiting`, `headers`  | 60s  |

Rate limiting defaults `true` for everything except Ollama. The rate limiter is **always** in the dispatch path; the flag controls whether it enforces limits or just passes through.

## Raw escape hatch

```odin
provider := enact.make_provider(
    name     = "internal-proxy",
    base_url = "https://proxy.internal/v1",
    api_key  = api_key,
    format   = .OPENAI_COMPAT,
    headers  = map[string]string{"X-Tenant" = "demo"},
)

cfg := enact.make_agent_config(
    llm = enact.LLM_Config{
        provider    = provider,
        model       = "internal-v2",
        temperature = 0.5,
        max_tokens  = 16_000,
        timeout     = 90 * time.Second,
        enable_rate_limiting = true,
    },
)
```

```odin
API_Format :: enum u8 { OPENAI_COMPAT, ANTHROPIC, OLLAMA, GEMINI }
```

`headers` is flattened at construction into a preformatted `extra_headers` string. `Provider_Config` carries only plain strings afterwards, so `LLM_Config` is fully wire serialisable and can travel inside `Set_Route`. See [actod/03_message-registration.md](https://github.com/Jonathan-Rowles/actod/blob/main/docs/03_message-registration.md).

## Model IDs

```odin
Model_ID :: union {
    Model,   // enum, compile time checked
    string,  // raw, provider specific names
}
```

The enum covers well known Claude, GPT, and Gemini lines. Ollama tags go through the `string` branch.

## Default route

```odin
cfg := enact.make_agent_config(
    llm = enact.anthropic(key, .Claude_Sonnet_4_5),
)
```

## Runtime override

```odin
enact.agent_set_route(agent_name, llm, node_name = "") -> Send_Error
enact.agent_clear_route(agent_name, node_name = "")   -> Send_Error
```

`agent_set_route` pushes `Set_Route{llm}` to the agent. Takes effect on the **next** LLM turn; in flight calls finish on the old route. Persists until `Clear_Route`.

The whole `LLM_Config` swaps as a unit: provider, model, sampling, timeout, cache_mode. Switching `anthropic(...)` → `ollama(...)` picks up Ollama's longer timeout as part of the swap.

```odin
enact.agent_set_route("demo", enact.gemini(google_key, .Gemini_2_5_Flash))
enact.agent_set_route("demo", enact.ollama("gemma3:4b"))
enact.agent_clear_route("demo")
```

From another actor, anywhere in the mesh:

```odin
enact.send_to("agent:demo", "node-a", enact.Set_Route{
    llm = enact.gemini(google_key, .Gemini_2_5_Flash_Lite),
})
```

### What doesn't change on route swap

`enable_rate_limiting` on an override is **ignored**. The rate limiter is spawned once at agent init. To change rate limit enforcement at runtime, destroy and respawn the agent.

## Router actor pattern

Dynamic routing (turn based, cost based, failover, per tenant) is an actor pattern, not a callback. Spawn a router, push `Set_Route`.

**Cost aware cross provider routing**:

```odin
Router_State :: struct {
    target:    string,
    cost_used: f64,
    premium:   enact.LLM_Config,   // Anthropic Sonnet
    mid:       enact.LLM_Config,   // Gemini Flash
    cheap:     enact.LLM_Config,   // local Ollama
}

router_behaviour := enact.Actor_Behaviour(Router_State){
    handle_message = proc(d: ^Router_State, from: enact.PID, msg: any) {
        if r, ok := msg.(enact.Agent_Response); ok {
            d.cost_used += cost_of(r.input_tokens, r.output_tokens)
            switch {
            case d.cost_used > HARD_BUDGET: enact.agent_set_route(d.target, d.cheap)
            case d.cost_used > SOFT_BUDGET: enact.agent_set_route(d.target, d.mid)
            }
        }
    },
}
```

**Failover on rate limit pressure**:

```odin
case enact.Rate_Limit_Event:
    if r.kind == .QUEUED && r.queue_depth > FAILOVER_THRESHOLD {
        enact.agent_set_route(d.target, d.mid)
    }
```

The router can live anywhere in the mesh. There is no `Callback_Router` / `Static_Router`. Function pointers don't cross nodes, read external state, and are invisible to observers.

## Resolution

```odin
// Precedence: runtime Set_Route override wins over config.llm.
resolve_route :: proc(override: Maybe(LLM_Config), config: ^Agent_Config) -> LLM_Config
```

Called every LLM turn. Override stored in `route_override: Maybe(LLM_Config)`, set by `Set_Route`, cleared by `Clear_Route`.

---
[< Tools](03_tools.md) | [Streaming and Events >](05_streaming-events.md)
