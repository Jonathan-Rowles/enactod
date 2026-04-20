# Rate Limiting

Every agent dispatches LLM calls through a rate limiter actor named `ratelim:<agent>`. The rate limiter is **always in the path**. When disabled it becomes a pass through round robin router; the agent addresses one name regardless of policy.

## Enabling

`enable_rate_limiting` lives on `LLM_Config`. Defaults: **true** for Anthropic, OpenAI, Gemini, openai_compat; **false** for Ollama (local inference has no provider limits).

```odin
llm = enact.anthropic(key, .Claude_Sonnet_4_5)         // on
llm = enact.ollama("llama3.1:8b")                       // off
llm = enact.openai(key, .GPT_4_1_Mini, enable_rate_limiting = false)
```

* **enabled**: parses provider rate limit headers, queues when near limits, auto retries 429s with exponential backoff (honours `retry-after`), caps concurrent in flight.
* **disabled**: pass through round robin, no queue, no retry, no header parsing. For absolute minimum latency or external rate limiting.

`enable_rate_limiting` is **spawn time only**. The rate limiter is spawned once at agent init and is not toggled by `Set_Route`. To change enforcement at runtime, destroy and respawn the agent.

## Behaviour (enabled)

On each `LLM_Call`:

1. If there's capacity (remaining requests and tokens, under `max_in_flight`), forward to a worker.
2. Else queue, notify caller with `Rate_Limit_Event{kind = .QUEUED}`, schedule a timer to re check.

On each `LLM_Result`:

* Parse headers (`anthropic-ratelimit-requests-remaining`, etc.) into current limit state.
* On 429 or 529, re queue with `kind = .RETRYING`, honouring `retry-after` or exponential backoff (2s, 4s). Give up after two retries (three attempts).
* On success, forward to original caller and drain any queued requests that fit.

Streaming calls hold the pending entry alive past `LLM_Result` until the final `.DONE` / `.ERROR` chunk, so all chunks route through the same caller.

## Observability

```odin
Rate_Limiter_Query  :: struct { request_id: Request_ID, caller: PID }
Rate_Limiter_Status :: struct {
    request_id:         Request_ID,
    requests_limit:     u32,
    requests_remaining: u32,
    tokens_limit:       u32,
    tokens_remaining:   u32,
    queue_depth:        u32,
    in_flight:          u32,
}

enact.send_by_name(fmt.tprintf("ratelim:%s", agent_name),
    enact.Rate_Limiter_Query{request_id = 1, caller = enact.get_self_pid()})
```

Per request events go to the original caller:

```odin
Rate_Limit_Event_Kind :: enum u8 { QUEUED, RETRYING, PROCESSING }

Rate_Limit_Event :: struct {
    request_id:  Request_ID,
    kind:        Rate_Limit_Event_Kind,
    queue_depth: u32,
    retry_count: u32,
    retry_delay: u32, // milliseconds
}
```

The agent also emits corresponding `Trace_Event` entries (`.RATE_LIMIT_QUEUED`, etc.). See [Tracing](12_tracing.md).

## Header parsing

| Provider  | Parsing                                                             | 429 retry                               |
|-----------|---------------------------------------------------------------------|------------------------------------------|
| Anthropic | `anthropic-ratelimit-{requests,tokens}-{limit,remaining}`, `anthropic-ratelimit-tokens-reset` (RFC 3339), `retry-after` | honours `retry-after`, else exponential |
| Gemini    | pass through                                                        | honours `retry-after`, else exponential |
| OpenAI    | pass through                                                        | honours `retry-after`, else exponential |
| Ollama    | n/a                                                                 | n/a                                      |

For providers without header parsing, `requests_remaining` / `tokens_remaining` stay at initial values; the limiter never blocks on their behalf, but 429s are still caught and retried. To add parsing for a new provider, extend `rate_limiter_parse_limits` in `src/rate_limiter.odin`. Alternatively, set `enable_rate_limiting = false` and wrap externally.

---
[< Streaming and Events](05_streaming-events.md) | [Text Store >](07_text-store.md)
