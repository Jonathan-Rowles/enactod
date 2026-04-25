# Text Store

`Text` is a small value that either wraps an ordinary `string` (self contained) or carries an `(offset, len)` handle into an agent owned arena. Within an agent's subtree (workers, rate limiter, tool actors, sub agent bridges, sub agents), handle backed `Text` travels as a small struct, bypassing actod's per hop deep copy. Long LLM payloads and chat history entries stay cheap to route.

Users don't init, reset, or destroy the store. Every top level `spawn_agent` gets its own arena; each user side `session_send` resets it before writing the new turn's content. Sub agents inherit the parent's arena and never reset.

## Shape

```odin
String_Handle :: struct {
    offset: u32,
    len:    u32,
}

Text :: struct {
    s:      string,
    handle: String_Handle,
    arena:  uintptr,     // opaque handle to a ^vmem.Arena
}
```

Handle backed: `arena != 0`, `handle.len > 0`, bytes at `arena.curr_block.base[offset:][:len]`.
String backed: `arena == 0`, `s` owns the bytes.
Empty: zero struct, sentinel for "no value".

`resolve(t)` is self sufficient. It reads bytes from wherever the `Text` points, without the caller knowing which arena.

## User discipline

1. **To read.** `resolve(t)` returns a `string`. Valid for the duration of the handler that received the `Text`.
2. **To keep past your handler.** `persist_text(t, allocator)` always returns a string backed `Text` that owns its bytes. Equivalent to `resolve + strings.clone + re wrap`, but one call.

If you only resolve and use inline, nothing else is required. The framework handles arena lifetime.

## API

```odin
enact.text(s: string) -> Text       // string backed wrapper
enact.resolve(t: Text) -> string    // read bytes
enact.persist_text(t, allocator := context.allocator) -> Text
                                    // always string backed, safe to outlive any arena
enact.free_text(t: Text)            // delete for string backed, no op for handle backed
```

Public `text(s)` always produces string backed `Text`. Framework internal code creates handle backed `Text` via an overload that takes the arena. That API is not exposed to user code.

## Arena lifecycle (framework owned)

* **`spawn_agent`** creates a `vmem.Arena` on agent state.
* **Every actor in the subtree** (workers, rate limiter, tool actors, sub agent bridges) receives a pointer to this arena at spawn time.
* **`session_send`** (and `session_send_cached` / `session_request_sync`) calls `arena_reset` before writing the new turn's content. The 1:1 claim invariant guarantees only one external writer. `Agent_Response` `Text` is string backed, so received responses survive unaffected.
* **`session_send_with_parent`** (internal, sub agent bridges/pools) does NOT reset; the parent's arena is shared and usually mid turn.
* **`send_*_response`** resolves outbound `Text` to string backed (`persist_text`) BEFORE sending. No arena reset at response time.
* **`emit_event` / `emit_trace`** persist outbound `Text`.
* **Sub agents** inherit the parent's arena via `spawn_sub_agent`. They never reset.
* **`agent_terminate`** destroys the arena (top level agents only).

## Reset_Conversation, Compact_History, Load_History

Addressed by agent name (no Session required):

```odin
enact.reset_conversation(agent_name, node_name := "")
enact.compact_history(agent_name, instruction := "", node_name := "")
enact.load_history(agent_name, messages_json, node_name := "")
```

`reset_conversation` clears chat history (keeping the agent and tool actors alive). Ignored while non idle; retry when IDLE.

`compact_history` asks the agent to summarise via one dedicated LLM call (bypassing `max_turns` and tool continuation) and collapses into a single summary entry.

```odin
Compact_Result :: struct {
    request_id: Request_ID,
    summary:    Text,
    old_turns:  int,
    is_error:   bool,
    error_msg:  Text,
}
```

`load_history` seeds the agent's chat history with prior turns from a JSON payload, the canonical "resume a saved conversation" path. The wire shape mirrors OpenAI's request body:

```json
{
  "messages": [
    {"role": "user",      "content": "Hi"},
    {"role": "assistant", "content": "Hello, how can I help?"}
  ]
}
```

Entries are appended if the agent has no messages yet and `Agent_Config.system_prompt` is set, the system prompt is injected at index 0 first. Roles other than `user` / `assistant` are rejected (the framework configures `system` from `Agent_Config.system_prompt`, not the payload). Tool turns and assistant tool calls are not surfaced in v1, this is a resume import, not an exact fidelity round trip.

```odin
Load_History_Result :: struct {
    request_id: Request_ID,
    is_error:   bool,
    error_msg:  Text,
    loaded:     int,
}
```

Validation is all-or-nothing: an unknown role aborts the load before any entries are appended. `loaded` is the count appended on success. Combine with `accumulate_history = true` (the default), `accumulate_history = false` clears history at every request and defeats the seed.

## accumulate_history

`Agent_Config.accumulate_history` (default `true`). Successive requests form one ongoing conversation; history grows across turns. Use `Compact_History` or `Reset_Conversation` to prune.

Set `false` when the caller reconstructs full context externally per turn (e.g. an agent fronted by its own memory service). Each request starts fresh.

## Cross subtree and cross node boundaries

Framework internal sends between the agent and its workers/tools/bridges are handle backed (fast). Outbound sends (`Agent_Response`, `Agent_Event`, `Trace_Event`, `Tool_Result_Msg` replies) all `persist_text` on their Text fields first, so the message is self contained by the time it leaves the subtree.

Cross node sends go further. `resolve_text_fields` converts every `Text` in the message to string backed before wire serialisation. The receiving node's ingress routes the envelope to a per remote proxy, which forwards locally. The target sees string backed `Text` and resolves directly.

## Text in user messages

User defined messages should use `string`, not `Text`. The framework can't auto persist user message `Text` fields at boundaries. `string` is easier: actod deep copies on send, the receiver owns their copy.

If you have a genuine reason to carry `Text` (e.g. forwarding an agent response), call `persist_text` before sending if it might cross out of the originating subtree.

---
[< Rate Limiting](06_rate-limiting.md) | [Remote Agents >](08_remote-agents.md)
