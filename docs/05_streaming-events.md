# Streaming and Events

When `stream = true` and `forward_events = true`, the agent emits `Agent_Event` to the caller as the LLM response arrives. The shape is flat, so it survives actor to actor and node to node transport verbatim.

## Enabling

```odin
cfg := enact.make_agent_config(
    llm              = enact.anthropic(key, .Claude_Sonnet_4_5),
    stream           = true,   // ask the provider for a streaming response
    forward_events   = true,   // relay chunks to the caller
    forward_thinking = true,   // default; false suppresses THINKING_* events
)
```

`stream` controls the provider request. `forward_events` controls whether the agent pushes per chunk events. You can stream internally without forwarding.

## Normalised across providers

Every provider has a different streaming wire format:

| Provider  | Wire format                                   |
|-----------|-----------------------------------------------|
| Anthropic | SSE (`text/event-stream`, event+data pairs)   |
| OpenAI    | SSE, one `data:` chunk per delta              |
| Gemini    | SSE via `streamGenerateContent?alt=sse`       |
| Ollama    | NDJSON, one JSON object per line              |

enactod normalises all four into the same `Agent_Event` stream. Receiving actor code doesn't branch on provider.

## Agent_Event

```odin
Event_Kind :: enum u8 {
    LLM_CALL_START, LLM_CALL_DONE,
    TOOL_CALL_START, TOOL_CALL_DONE,
    THINKING_DONE, THINKING_DELTA,
    TEXT_DELTA,
}

Agent_Event :: struct {
    request_id: Request_ID,
    kind:       Event_Kind,
    subject:    Text,   // tool name, worker target, etc.
    detail:     Text,   // delta bytes, full text, arguments, result
}
```

| Kind              | subject                   | detail                       |
|-------------------|---------------------------|------------------------------|
| LLM_CALL_START    | dispatch target (ratelim) | model name                   |
| LLM_CALL_DONE     |                           | full assistant text          |
| TOOL_CALL_START   | tool name                 | arguments (raw JSON)         |
| TOOL_CALL_DONE    | tool name                 | tool result                  |
| TEXT_DELTA        |                           | delta bytes                  |
| THINKING_DELTA    |                           | delta bytes                  |
| THINKING_DONE     |                           | full thinking text           |

## Consuming

```odin
handle_message = proc(d: ^Client, from: enact.PID, msg: any) {
    switch m in msg {
    case enact.Agent_Event:
        switch m.kind {
        case .TEXT_DELTA:
            fmt.printf("%s", enact.resolve(m.detail))
        case .THINKING_DELTA:
            fmt.printf("\x1b[2m%s\x1b[0m", enact.resolve(m.detail))
        case .TOOL_CALL_START:
            fmt.printfln("\n[tool] %s(%s)",
                enact.resolve(m.subject), enact.resolve(m.detail))
        case .TOOL_CALL_DONE:
            fmt.printfln("[done] %s → %s",
                enact.resolve(m.subject), enact.resolve(m.detail))
        case .LLM_CALL_START, .LLM_CALL_DONE, .THINKING_DONE:
        }
    case enact.Agent_Response:
        // final response with token usage
    }
}
```

`Agent_Response` still arrives at the end of a streamed request, carrying the final assembled content and token totals.

## Flat shape

`kind` + two `Text` fields is deliberate:

* **Wire safe.** actod forbids nested unions, maps, and dynamic arrays in messages.
* **Text store friendly.** `subject` and `detail` travel as 8 byte handles within an agent subtree; per event overhead is constant.
* **One registration.** `register_message_type(Agent_Event)` once for every kind.

## Backpressure

Streaming dispatches every chunk through the sender's mailbox. If the consumer is slow and the mailbox fills, actod returns `RECEIVER_BACKLOGGED` and the chunk is dropped. No credit window backpressure yet. Raise consumer `message_batch` / mailbox size, or consume every delta cheaply and buffer later.

---
[< Providers and Routing](04_providers-routing.md) | [Rate Limiting >](06_rate-limiting.md)
