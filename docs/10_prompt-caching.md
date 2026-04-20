# Prompt Caching

Prompt caching lets the provider skip re reading prefixes it has already seen. Set `cache_mode` on the `LLM_Config`, send cache blocks with `session_send_cached`.

Providers cache differently:

| Provider  | How                                              | What you do                                    |
|-----------|--------------------------------------------------|------------------------------------------------|
| Anthropic | Explicit per block `cache_control: ephemeral`    | `cache_mode = .EPHEMERAL`, `session_send_cached` |
| Gemini    | Implicit. Same prefix re seen caches automatically | Reuse the prefix. `cache_read_tokens` surfaces the hit |
| OpenAI    | Automatic server side on sufficiently long prompts | Nothing to opt into. Usage surfaces via `cache_read_tokens` |
| Ollama    | No remote cache (local model)                    | n/a                                            |

## Anthropic: explicit cache blocks

`cache_mode` is only exposed on the `anthropic` preset:

```odin
cfg := enact.make_agent_config(
    llm = enact.anthropic(key, .Claude_Sonnet_4_5, cache_mode = .EPHEMERAL),
)
```

```odin
Cache_Mode :: enum u8 {
    NONE,
    EPHEMERAL,  // short lived prompt cache (Anthropic: cache_control = ephemeral)
}
```

Unsupported combinations pass through silently, not as an error.

## Sending cache blocks

```odin
enact.session_send_cached(s: ^Session, blocks: ..string) -> Send_Error
enact.MAX_CACHE_BLOCKS :: 4
```

Up to `MAX_CACHE_BLOCKS` (4) segments. Extras dropped with a warning. Empty strings ignored. Blocks are prepended to the user message in order.

```odin
enact.session_send_cached(
    &session,
    long_system_reference_doc,   // large, stable
    tenant_context,              // medium, per tenant stable
    current_conversation_turn,   // the actual query
)
```

Typical layout:

1. Stable reusable prefix (codebase reference, style guide, persona).
2. Medium term context (tenant config, recent memory).
3. Turn specific content.

Earlier blocks get the longest cache lifetime; ordering matters.

## Why 4 slots, not a slice

actod forbids dynamic arrays in messages. `Agent_Request` declares four named `Text` fields (`cache_block_1..4`). The variadic API hides the constraint; extras are dropped rather than silently reordered.

## Gemini: implicit caching

Gemini caches automatically. Send the same long prefix on back to back calls; the provider serves the cached bytes and reports via `cachedContentTokenCount`. enactod surfaces this as `Agent_Response.cache_read_input_tokens` (and `cache_read_tokens` on `Trace_Event`). No `cache_mode`, no `session_send_cached`.

```odin
cfg := enact.make_agent_config(
    llm = enact.gemini(google_key, .Gemini_2_5_Flash),
)

// Turn 1: establishes the prefix. cache_read_input_tokens = 0.
enact.session_send(&session, fmt.tprintf("%s\n\n%s", BIG_BRIEFING, "Summarise the risk."))

// Turn 2+: same prefix → cache_read_input_tokens > 0.
enact.session_send(&session, fmt.tprintf("%s\n\n%s", BIG_BRIEFING, "Propose mitigations."))
```

Caveats:

* Gemini's implicit cache has a minimum prefix size. Very short prompts won't trigger.
* Cache lifetime is provider controlled; no explicit TTL knob.
* `cache_mode` isn't exposed on `gemini` / `openai` / `ollama` presets. If you construct `LLM_Config` directly with `.EPHEMERAL` on a non Anthropic provider, it's a silent no op; a one time warning logs on the first turn. The pass through lets route swaps work without errors.

## Text store and caching

Cache blocks are `Text` values. Within the agent subtree they travel as handles; a multi kilobyte block costs the same per hop as a one byte response field. On `Agent_Response` the arena resets; the next request rebuilds cache blocks from fresh `text(...)` calls. The provider's own cache is unaffected by arena resets.

---
[< Sub agents](09_sub-agents.md) | [Ollama >](11_ollama.md)
