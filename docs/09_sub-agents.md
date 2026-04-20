# Sub agents

A sub agent tool treats another agent as a callable tool of its parent. The parent's tool dispatch hands off to a bridge (one sub agent) or pool (many), which sessions to the sub agent, awaits the reply, and translates it back into a `Tool_Result_Msg`.

## Constructor

```odin
enact.sub_agent_tool(
    def:          Tool_Def,
    config:       ^Agent_Config,
    pool_size:    int    = 1,
    context_file: string = "",
) -> Tool
```

`pool_size == 1` → bridge (single sub agent). `pool_size > 1` → pool (N identical sub agents, fan out).

```odin
// Cheap, fast, parallel sub agents.
research_cfg := enact.make_agent_config(
    system_prompt = "Research one topic in depth. Respond with a 2-3 paragraph summary.",
    llm           = enact.gemini(google_key, .Gemini_2_5_Flash_Lite),
    tools         = research_tools,
)

// Parent: plans and synthesises; delegates legwork to the pool.
parent_cfg := enact.make_agent_config(
    system_prompt = "You coordinate a research team. Plan, delegate, synthesise.",
    llm           = enact.anthropic(anthropic_key, .Claude_Sonnet_4_5),
    tools = []enact.Tool{
        enact.sub_agent_tool(
            {name = "research", description = "Research one topic in depth.",
             input_schema = `{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}`},
            &research_cfg,
            pool_size    = 4,
            context_file = "/etc/codebase.md",
        ),
    },
)
```

Mixing providers between parent and sub agent is free. Each carries its own `LLM_Config`. A pool can even mix models between slots via per slot `Set_Route` at runtime.

## Bridge (pool_size = 1)

Spawns one sub agent lazily on first call, keeps it alive, forwards each invocation via `session_send_with_parent` (stamping the outer request id into the sub agent's `parent_request_id`). The sub agent's `Agent_Response` is translated into a `Tool_Result_Msg`. Events from the sub agent bubble up through the parent's event stream untouched.

```
parent agent           bridge                sub agent
     │ Tool_Call_Msg      │                      │
     ├──────────────────> │ session_send         │
     │                    ├────────────────────> │
     │                    │  Agent_Event         │
     │ <──────────────────┤ <────────────────────┤
     │                    │  Agent_Response      │
     │ Tool_Result_Msg    │ <────────────────────┤
     │ <──────────────────┤                      │
```

Sub agent naming: `<parent-short>-<tool-name>`. For `agent:demo` with a `research` tool, the sub agent registers as `agent:demo-research`. The bridge is `tool:demo:research`.

## Pool (pool_size > 1)

Manages N slot indexed sub agents (`demo-research-0`, `-1`, ...). Slots spawned on first use. Incoming calls fan out across free slots; if all busy, calls queue in an overflow list. Per call reply routing is the same as the bridge.

Use pools for work parallelisable inside one conversation: retrieval across several sources, specialist analysts on one input, a batch of code reviewers. A pool of 4 means the parent can have up to 4 outstanding `research(...)` calls.

## context_file

If set, contents are read on every call and prepended to the query as `<context>...</context>`:

```
<context>
{contents of context_file}
</context>

{query}
```

Useful for codebase level reference, style guides, or tenant specific context that should always be visible to the sub agent without bloating the parent's prompt.

## Query extraction

The bridge / pool parses JSON arguments and uses the `query` field. If absent, the full arguments JSON is used. Define `input_schema` with a `query` property for a clean sub agent view.

## Request correlation

```
Tool_Call_Msg.request_id  = parent's request_id
Tool_Call_Msg.call_id     = model assigned tool call id
              ↓
session_send_with_parent(sub_session, query, parent_request_id = ...)
              ↓
sub agent's Agent_Request.parent_request_id = parent's request_id
              ↓
traces from the sub agent carry parent_request_id
```

A tracing sink can walk `parent_request_id` → `request_id` to rebuild the call tree. See [Tracing](12_tracing.md).

---
[< Remote Agents](08_remote-agents.md) | [Prompt Caching >](10_prompt-caching.md)
