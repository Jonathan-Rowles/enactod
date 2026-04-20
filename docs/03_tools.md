# Tools

Tools are plain `enact.Tool` values. No interfaces, no inheritance. Each tool has a `Tool_Def` (name, description, input schema) plus a lifecycle that decides where the implementation runs. The agent's dispatch is a single four way switch.

## Lifecycles

| Lifecycle    | Where it runs                              | Constructor                                 |
|--------------|--------------------------------------------|---------------------------------------------|
| INLINE       | on the agent actor itself                  | `function_tool`                             |
| EPHEMERAL    | one fresh actor per call, self terminates  | `ephemeral_tool`                            |
| PERSISTENT   | lazy spawned once, long lived              | `persistent_tool` / `persistent_tool_actor` |
| SUB_AGENT    | delegated to another agent                 | `sub_agent_tool`                            |

```odin
tools := []enact.Tool{
    enact.function_tool(
        {name = "get_time", description = "...", input_schema = `{"type":"object","properties":{}}`},
        get_time_impl,
    ),
    enact.ephemeral_tool({name = "fetch_url", ...}, fetch_impl),
    enact.persistent_tool({name = "cache", ...}, cache_impl),
    enact.persistent_tool_actor({name = "notepad", ...}, notepad_spawn),
    enact.sub_agent_tool({name = "research", ...}, &research_config, pool_size = 4),
}
```

Pick by workload:

* **INLINE** for fast, stateless, CPU light operations. Zero spawn overhead.
* **EPHEMERAL** for blocking I/O or anything that takes meaningful wall clock time. Keeps the agent responsive.
* **PERSISTENT** for long lived state (caches, connections) or anything expensive to construct.
* **SUB_AGENT** to delegate to another LLM agent. See [Sub agents](09_sub-agents.md).

## Tool_Def

```odin
Tool_Def :: struct {
    name:         string,
    description:  string,
    input_schema: string, // raw JSON Schema
}
```

The agent compiles every `input_schema` once during `agent_init`. When `validate_tool_args = true` (default), every tool call is validated before dispatch. Invalid arguments return to the model as a tool error with path and reason.

Supported: `object`, `array`, `string`, `number`, `integer`, `boolean`, `null`, `properties`, `required`, `additionalProperties`, `items`, `enum`, `anyOf`.

## Tool_Proc

```odin
Tool_Proc :: proc(arguments: string, allocator: mem.Allocator) -> (result: string, is_error: bool)
```

**Purity contract**: no package globals, no shared mutable state, no hidden I/O. The same proc may run concurrently from different agents, and INLINE impls run on the agent actor itself. Any hidden state races. For state, use `persistent_tool_actor`.

`arguments` is the raw JSON from the model. `allocator` is `context.temp_allocator` inside the calling actor. The returned string is copied into the response `Text` by the agent.

## Custom actor (stateful tools)

```odin
Notepad_State :: struct { notes: [dynamic]string }

notepad_behaviour := enact.Actor_Behaviour(Notepad_State){
    init = proc(d: ^Notepad_State) { d.notes = make([dynamic]string) },
    handle_message = proc(d: ^Notepad_State, from: enact.PID, c: any) {
        if m, ok := c.(enact.Tool_Call_Msg); ok {
            result := notepad_exec(d, enact.resolve(m.arguments))
            enact.send(from, enact.Tool_Result_Msg{
                request_id = m.request_id, call_id = m.call_id,
                tool_name  = m.tool_name,   result  = enact.text(result),
            })
        }
    },
}

notepad_spawn :: proc(name: string, _: enact.PID) -> (enact.PID, bool) {
    return enact.spawn_child(name, Notepad_State{}, notepad_behaviour)
}
```

**Invariant**: the spawn proc MUST register under the passed `name`. The agent addresses tool calls to that exact name. Ignoring `name` silently drops every call.

## Messages

```odin
Tool_Call_Msg :: struct {
    request_id: Request_ID,
    call_id:    Text,
    tool_name:  Text,
    arguments:  Text,
}

Tool_Result_Msg :: struct {
    request_id: Request_ID,
    call_id:    Text,
    tool_name:  Text,
    result:     Text,
    is_error:   bool,
}
```

Tool actors reply to `from` (the sender PID), not by name. The agent correlates results to its in flight request without a registry lookup. Both types are registered for cross node use. See [actod/03_message-registration.md](https://github.com/Jonathan-Rowles/actod/blob/main/docs/03_message-registration.md).

---
[< Session](02_session.md) | [Providers and Routing >](04_providers-routing.md)
