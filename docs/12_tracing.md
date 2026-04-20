# Tracing

A separate observability stream from `Agent_Event`. `Agent_Event` is lean, aimed at streaming UIs. `Trace_Event` is wide, aimed at span style observability: request framing, per turn token counts, tool durations, rate limit events, errors.

## Sinks

```odin
Trace_Sink :: struct {
    name:    string,
    kind:    Trace_Sink_Kind,
    handler: Trace_Handler,        // set on FUNCTION
    spawn:   Trace_Sink_Spawn_Proc, // set on CUSTOM
}

Trace_Sink_Kind :: enum u8 {
    NONE,       // tracing disabled (zero value)
    FUNCTION,   // framework owned generic actor runs `handler`
    CUSTOM,     // user's spawn proc spawns the backing actor
    EXTERNAL,   // no spawn; events emitted to `name` by address
}
```

Zero value (`Trace_Sink{}`) disables tracing. Set `Agent_Config.trace_sink` only if you want it.

### function_trace_sink

A pure handler wrapped in a framework owned actor.

```odin
otlp_handler :: proc(ev: enact.Trace_Event, allocator: mem.Allocator) {
    // stateless forwarder: export to OTLP, log, append JSONL, etc.
}

cfg.trace_sink = enact.function_trace_sink("otlp", otlp_handler)
```

The handler is stateless. Use `custom_trace_sink` for anything that needs to persist across events.

### custom_trace_sink

User supplied spawn proc wraps whatever state the sink needs (file handles, HTTP clients, buffered flushes).

```odin
my_sink_spawn :: proc(name: string, parent: enact.PID) -> (enact.PID, bool) {
    return enact.spawn_child(name, My_Sink_State{}, my_sink_behaviour)
}

cfg.trace_sink = enact.custom_trace_sink("my-sink", my_sink_spawn)
```

The spawn proc MUST register under the passed `name`.

### external_trace_sink

Sink owned elsewhere. Reference by name:

```odin
cfg.trace_sink = enact.external_trace_sink("otlp@observer-node")
```

### dev_trace_sink (built in)

Stdout plus optional JSONL and per request Markdown digest:

```odin
cfg.trace_sink = enact.dev_trace_sink("trace", {
    stdout     = true,
    color      = true,
    jsonl_path = "./trace.jsonl",
    md_dir     = "./traces",
    verbose    = false,
})
```

Multiple agents sharing the same name share one backing actor; first config wins (subsequent mismatches log a warning). For manual control use `spawn_dev_trace_sink_actor`.

## Trace_Event

```odin
Trace_Event_Kind :: enum u8 {
    REQUEST_START, REQUEST_END,
    LLM_CALL_START, LLM_CALL_DONE,
    TOOL_CALL_START, TOOL_CALL_DONE,
    THINKING_DONE,
    RATE_LIMIT_QUEUED, RATE_LIMIT_RETRYING, RATE_LIMIT_PROCESSING,
    ERROR,
}

Trace_Event :: struct {
    kind:                  Trace_Event_Kind,
    request_id:            Request_ID,
    parent_request_id:     Request_ID,    // set on sub agent turns
    agent_name:            Text,
    turn:                  u16,
    timestamp_ns:          i64,
    duration_ns:           i64,

    call_id:               Text,  // TOOL_CALL_*
    tool_name:             Text,  // TOOL_CALL_*
    model:                 Text,  // LLM_CALL_*
    provider:              Text,  // LLM_CALL_*
    detail:                Text,  // kind dependent

    input_tokens:          u32,
    output_tokens:         u32,
    cache_creation_tokens: u32,
    cache_read_tokens:     u32,
    status_code:           u32,
    is_error:              bool,
    retry_count:           u32,
    retry_delay_ms:        u32,
    queue_depth:           u32,
}
```

One wide struct, per kind field population, sinks switch on `kind`.

## detail semantics

```odin
Trace_Event_Detail_Role :: enum u8 {
    NONE,
    USER_INPUT,      // REQUEST_START
    FINAL_RESPONSE,  // REQUEST_END (success)
    ASSISTANT_REPLY, // LLM_CALL_DONE
    TOOL_ARGS,       // TOOL_CALL_START
    TOOL_RESULT,     // TOOL_CALL_DONE (success)
    THINKING,        // THINKING_DONE
    ERROR_MESSAGE,   // REQUEST_END (is_error), TOOL_CALL_DONE (is_error), ERROR
}

role := enact.trace_event_detail_role(ev)
```

## Spans

Typical sink patterns:

* Buffer events per `request_id` until `REQUEST_END`, then flush as one record (built in `dev_trace_sink` does this for `md_dir`).
* Emit spans on `_DONE` events using `duration_ns`:
  * `LLM_CALL_DONE`: LLM call span (model, provider, tokens, status).
  * `TOOL_CALL_DONE`: tool call span (tool_name, call_id, is_error).
  * `REQUEST_END`: outer request span (total tokens, duration).
* Reconstruct the call tree across sub agents via `parent_request_id`.

## Lifecycle

On the first `spawn_agent` referencing a FUNCTION / CUSTOM sink, the sink actor is lazy spawned as a sibling under the agent's parent, so it outlives any one agent and can be shared across agents with the same sink name. Emissions route by name, so the sink can restart independently.

## Text lifetime

The agent persists every `Text` on `Trace_Event` to scratch before sending. actod deep copies the strings into the sink's message pool; they are valid for the handler's duration. A sink that buffers past the handler MUST clone again. Use `persist_text` field by field, or follow `persist_trace_event` in `dev_trace_sink.odin`. See [actod/02_actor.md](https://github.com/Jonathan-Rowles/actod/blob/main/docs/02_actor.md).

---
[< Ollama](11_ollama.md) | [Message Types >](13_message-types.md)
