# Session

Sessions are how you talk to an agent. Intended pattern: **one session per agent**. A `Session` is a small value type (not an actor) carrying the target's `agent_name`, optional `node_name`, monotonic `next_id`, cached `^Arena`, and the agent's `PID`.

The first actor to drive an agent **claims** it by PID on its first `Agent_Request`. The claim is permanent; another PID is rejected with `"agent claimed by another actor"`. For isolation, spawn a new agent per caller (gateway pattern).

## Basic usage

`spawn_agent` returns a ready `Session`:

```odin
Client :: struct { session: enact.Session }

client_behaviour := enact.Actor_Behaviour(Client){
    init = proc(d: ^Client) {
        enact.session_send(&d.session, "Hello")
    },
    handle_message = proc(d: ^Client, from: enact.PID, msg: any) {
        if r, ok := msg.(enact.Agent_Response); ok {
            fmt.println(enact.resolve(r.content))
        }
    },
}

session, _ := enact.spawn_agent("demo", demo_cfg)
client := Client{session = session}
```

Use `make_session` when the caller did not spawn the agent (remote targets, gateway handoffs, agents spawned elsewhere):

```odin
remote := enact.make_session("demo", "agent-server")
```

`session_send` uses `enact.get_self_pid()` as the reply address.

## Construction

```odin
enact.spawn_agent(name: string, config: Agent_Config) -> (Session, bool)
enact.make_session(agent_name: string, node_name: string = "") -> Session
```

* `spawn_agent("demo", cfg)` spawns the agent and returns a Session in one step. `sess.pid` is populated, so supervisor spawn closures that must return `(PID, bool)` can read from it.
* `make_session("demo")` attaches to an already spawned local agent (arena and PID looked up, lazy refetch if not spawned yet).
* `make_session("demo", "agent-server")` attaches to a remote agent. Arena cache stays `nil`; the request ships as string backed `Text`. See [Remote Agents](08_remote-agents.md).

## One session per agent (claim invariant)

An agent belongs to its first driver. Subsequent requests from a different PID are rejected with `"agent claimed by another actor"`. The agent can safely reset its transport arena on each new request without worrying about foreign writers.

Multiple `make_session` values pointing at the same agent are fine (they're just values), but only one PID can drive it. For per caller isolation, spawn per caller agents via the gateway pattern.

## Session vs raw Agent_Request

You can skip the session and build a request by hand:

```odin
enact.send_by_name("agent:demo", enact.Agent_Request{
    request_id = my_id,
    caller     = enact.get_self_pid(),
    content    = enact.text("hi"),
})
```

`Session` handles four things the raw form doesn't:

* **Arena injection.** `session_send` writes the payload into the target agent's arena with `text(content, s.agent_arena)`. The `Text` is handle backed and zero copy. The raw form produces string backed `Text` that the agent interns.
* **Monotonic `request_id`.**
* **Reply routing.** `caller = get_self_pid()` is stamped automatically.
* **Target addressing.** Handles both local (`agent:<name>`) and remote (`agent:<name>@<node>`) from one value.

Reach for the raw form in routers, bridges, or gateways that thread an upstream `Agent_Request` through with its original `request_id` and `caller`.

## Sending

```odin
// Reply arrives as Agent_Response in the caller actor.
enact.session_send(s: ^Session, content: string) -> Send_Error

// With prompt cache segments prepended. See Prompt Caching.
enact.session_send_cached(s: ^Session, blocks: ..string) -> Send_Error

// Build the request without sending, e.g. to stamp parent_request_id manually.
enact.session_request(s: ^Session, content: string) -> Agent_Request
```

`Send_Error` is actod's enum (`OK`, `ACTOR_NOT_FOUND`, `RECEIVER_BACKLOGGED`, `MESSAGE_TOO_LARGE`, `SYSTEM_SHUTTING_DOWN`, `NETWORK_ERROR`, `NETWORK_RING_FULL`, `NODE_NOT_FOUND`, `NODE_DISCONNECTED`). A valid send returns `OK` and the response arrives later. See [actod/02_actor.md](https://github.com/Jonathan-Rowles/actod/blob/main/docs/02_actor.md).

## Synchronous request

For non actor callers (setup scripts, blocking `main`), `session_request_sync` spawns a temporary reply actor, blocks on a semaphore, and returns directly:

```odin
result := enact.session_request_sync(&session, "What time is it?", 60 * time.Second)
if result.is_error {
    fmt.println("error:", enact.resolve(result.error_msg))
} else {
    fmt.println(enact.resolve(result.content))
}
```

```odin
Sync_Result :: struct {
    content:   Text,
    is_error:  bool,
    error_msg: Text,
    timed_out: bool,
}
```

**Never call `session_request_sync` from inside `handle_message`.** It blocks the caller's worker thread and the reply never processes. Use `session_send` from actors; use `session_request_sync` only from non actor code.

## Addressing

```odin
enact.session_target_name(s: ^Session) -> string
```

Returns `"agent:<name>"` (local) or `"agent:<name>@<node>"` (remote). Useful for logging and `send_by_name` calls using the same routing string.

---
[< Agent](01_agent.md) | [Tools >](03_tools.md)
