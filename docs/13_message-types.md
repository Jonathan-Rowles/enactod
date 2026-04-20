# Message Types

enactod registers every cross actor message type at startup. Users writing custom tools, sinks, or router actors only need to register their own types.

## Registered at startup

```odin
@(init)
init_enactod_messages :: proc "contextless" () {
    // Agent API
    enact.register_message_type(Agent_Request)
    enact.register_message_type(Agent_Response)
    enact.register_message_type(Agent_Event)

    // LLM dispatch
    enact.register_message_type(LLM_Call)
    enact.register_message_type(LLM_Result)
    enact.register_message_type(LLM_Stream_Chunk)

    // Tools
    enact.register_message_type(Tool_Call_Msg)
    enact.register_message_type(Tool_Result_Msg)

    // Routing
    enact.register_message_type(Set_Route)
    enact.register_message_type(Clear_Route)

    // Conversation management
    enact.register_message_type(Reset_Conversation)
    enact.register_message_type(Compact_History)
    enact.register_message_type(Compact_Result)

    // Arena / history introspection
    enact.register_message_type(Arena_Status_Query)
    enact.register_message_type(Arena_Status)
    enact.register_message_type(History_Query)
    enact.register_message_type(History_Entry_Msg)

    // Ollama
    enact.register_message_type(Ollama_Model_Seen)
    enact.register_message_type(Ollama_Unload_All)

    // Gateway (application emitted, see 08_remote-agents.md)
    enact.register_message_type(Session_Create)
    enact.register_message_type(Session_Created)
    enact.register_message_type(Session_Destroy)

    // Rate limiting
    enact.register_message_type(Rate_Limiter_Query)
    enact.register_message_type(Rate_Limiter_Status)
    enact.register_message_type(Rate_Limit_Event)

    // Tracing
    enact.register_message_type(Trace_Event)

    // Cross node transport
    enact.register_message_type(Remote_Envelope)
    enact.register_message_type(Proxy_Forward)
}
```

## By topic

| Topic                   | Types                                                                 |
|-------------------------|-----------------------------------------------------------------------|
| Agent API               | `Agent_Request`, `Agent_Response`, `Agent_Event`                      |
| LLM dispatch            | `LLM_Call`, `LLM_Result`, `LLM_Stream_Chunk`                          |
| Tools                   | `Tool_Call_Msg`, `Tool_Result_Msg`                                    |
| Routing                 | `Set_Route`, `Clear_Route`                                            |
| Conversation management | `Reset_Conversation`, `Compact_History`, `Compact_Result`             |
| Arena introspection     | `Arena_Status_Query`, `Arena_Status`                                  |
| History introspection   | `History_Query`, `History_Entry_Msg`                                  |
| Ollama                  | `Ollama_Model_Seen`, `Ollama_Unload_All`                              |
| Rate limiting           | `Rate_Limiter_Query`, `Rate_Limiter_Status`, `Rate_Limit_Event`       |
| Tracing                 | `Trace_Event`                                                         |
| Transport               | `Remote_Envelope`, `Proxy_Forward`                                    |

## Remote_Payload

```odin
Remote_Payload :: union {
    Agent_Request, Agent_Response, Agent_Event,
    LLM_Call, LLM_Result, LLM_Stream_Chunk,
    Tool_Call_Msg, Tool_Result_Msg,
    Session_Create, Session_Created, Session_Destroy,
    Rate_Limiter_Query, Rate_Limiter_Status, Rate_Limit_Event,
    Trace_Event,
    Compact_Result, History_Entry_Msg,
}
```

**Invariant**: a type belongs in `Remote_Payload` iff it contains a `Text` field. Text less controls (`Set_Route`, `Clear_Route`, `Ollama_Model_Seen`, `Ollama_Unload_All`) skip the union and travel on actod's native cross node path.

When adding a new `Text` carrying message that crosses nodes, add it to `Remote_Payload`. The generic `resolve_text_fields` in `src/remote.odin` walks the struct recursively, converting handle backed `Text` to string backed before the envelope leaves the sender.

## Registering user types

From `@(init)` in your own package, before `NODE_INIT`:

```odin
Progress_Update :: struct {
    request_id: enact.Request_ID,
    percent:    u8,
    note:       enact.Text,
}

@(init)
register_my_messages :: proc "contextless" () {
    enact.register_message_type(Progress_Update)
}
```

Rules (see [actod/03_message-registration.md](https://github.com/Jonathan-Rowles/actod/blob/main/docs/03_message-registration.md)):

* **Registration is process global.** Register once in `@(init)`.
* **No maps.** actod forbids `map[K]V` fields.
* **No dynamic arrays in cross node messages.** `[dynamic]T` deep copies locally fine but can't serialise across nodes.
* **No pointers to external state.** Fields must be inline valued or `Text` / `string` that can deep copy.
* **Identical struct layout on every node.** Registration is positional; mismatched fields produce silent corruption.

## Wire shape notes

* `Agent_Event` is flat (`kind` + `subject: Text` + `detail: Text`), intentional. See [Streaming and Events](05_streaming-events.md).
* `Trace_Event` is wide (one struct, per kind field population), intentional. See [Tracing](12_tracing.md).
* `Set_Route.llm` is a fully serialisable `LLM_Config` (plain strings, no maps) so routing can flow across nodes without ingress.
* `Agent_Request.cache_block_1..4` are fixed width named slots instead of a slice; actod's wire format can't deep copy dynamic arrays.

---
[< Tracing](12_tracing.md)
