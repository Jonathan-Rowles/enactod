# Remote Agents

Agents and sessions work the same over the wire as locally. Use `make_session(agent, node)` to address a remote agent; the runtime handles routing and reply path without extra API.

## Bootstrap

On both nodes:

```odin
enact.NODE_INIT("my-app", enact.make_node_config(
    network = enact.make_network_config(port = 9100),
    actor_config = enact.make_actor_config(
        children = enact.make_children(spawn_gateway),
    ),
))
```

`NODE_INIT` installs enactod's node infrastructure: curl global init, the Ollama tracker, and the ingress and proxy actors for cross node messaging.

Register the peer node on the client:

```odin
enact.register_node("agent-server",
    net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = 9100},
    .TCP_Custom_Protocol,
)
```

## Cross node session

```odin
session := enact.make_session("demo", "agent-server")
enact.session_send(&session, "Hello from remote")
```

The server hosts `agent:demo`; the client addresses it as `agent:demo@agent-server`. Reply routing goes via a per remote proxy.

## send / send_to rules

```odin
enact.send(pid, msg) -> Send_Error
enact.send_to(actor_name, node_name, msg) -> Send_Error
enact.send_by_name("actor@node", msg) -> Send_Error
```

| Target                  | Path                                             |
|-------------------------|--------------------------------------------------|
| Local PID / name        | actod direct                                     |
| Remote `Remote_Payload` | ingress envelope, Text resolved to strings at sender |
| Remote other message    | actod native cross node                          |

`Remote_Payload` covers messages carrying `Text` fields. Text less controls (`Set_Route`, `Clear_Route`, `Ollama_Model_Seen`, `Session_*`) skip ingress.

**Never call `actod.send_message*` / `actod.send_to` directly from user code** for messages carrying `Text`. They bypass ingress; handle backed `Text` would arrive pointing at an arena on the wrong node. Use `enact.send` / `enact.send_to`.

## Ingress

```
Remote_Envelope ─┐
  (from peer)    │   ingress actor
                 └─> spawn or lookup proxy for (from_actor, from_node)
                     Proxy_Forward{target, payload} ─> target actor
```

The sender resolves every `Text` to string backed before wrapping in `Remote_Envelope` (handles are meaningless on another node). The ingress actor (`enact_ingress`) spawns or looks up a proxy for `(from_actor, from_node)` and sends `Proxy_Forward{target, payload}`.

Reply path:

```
target ─send(from=proxy)─> enact_proxy:caller@caller-node ─envelope─> caller node ingress ─> caller
```

## Gateway pattern: one process, many sessions

One isolated agent per connected user. A single actor owns session lifecycle: clients ask it to open a session, it spawns a fresh agent and replies with the name, and it cleans up on disconnect.

### Server

```odin
Session_Entry :: struct {
    agent_name: string,
    client:     enact.PID,
}

Gateway_State :: struct {
    sessions: [dynamic]Session_Entry,
    next_id:  int,
    config:   enact.Agent_Config,
}

gateway_handle_message :: proc(d: ^Gateway_State, from: enact.PID, content: any) {
    switch msg in content {
    case enact.Session_Create:
        d.next_id += 1
        agent_name := strings.clone(fmt.tprintf("session-%d", d.next_id))
        if _, ok := enact.spawn_agent(agent_name, d.config); !ok {
            delete(agent_name)
            return
        }
        append(&d.sessions, Session_Entry{agent_name = agent_name, client = from})
        enact.send(from, enact.Session_Created{agent_name = agent_name})

    case enact.Session_Destroy:
        for entry, i in d.sessions {
            if entry.agent_name == msg.agent_name {
                enact.destroy_agent(entry.agent_name)
                delete(entry.agent_name)
                unordered_remove(&d.sessions, i)
                break
            }
        }
    }
}
```

The gateway is registered as `"gateway"` and spawned as a child of `NODE_INIT`. Clients address it as `gateway@agent-server`.

### Client

```odin
cli_init :: proc(d: ^CLI_State) {
    enact.send_to("gateway", SERVER_NODE, enact.Session_Create{})
}

cli_handle_message :: proc(d: ^CLI_State, from: enact.PID, content: any) {
    switch msg in content {
    case enact.Session_Created:
        d.agent_name = strings.clone(msg.agent_name)
        d.session    = enact.make_session(d.agent_name, SERVER_NODE)
    case User_Input:
        enact.session_send(&d.session, msg.content)
    case enact.Agent_Event:     /* stream */
    case enact.Agent_Response:  /* final */
    }
}

cli_terminate :: proc(d: ^CLI_State) {
    if len(d.agent_name) > 0 {
        enact.send_to("gateway", SERVER_NODE, enact.Session_Destroy{agent_name = d.agent_name})
    }
}
```

### Consequences

* **Isolation per session.** Each user's agent has its own chat history, worker pool, rate limiter, tool actors, and transport arena.
* **Independent failure.** An agent crash is local to that session.
* **Independent rate limits.** Each session owns its own `ratelim:<session>`. See TODO in the root README for shared provider level limiter work.
* **Simple shutdown.** `Session_Destroy` triggers `destroy_agent`, which terminates the agent and every child.

### Transport agnostic

Swap "per connection actor" for any connection handler. The shape is:

```
[connection] ──accept──> [per-connection actor] ──Session_Create──> [gateway]
                                                 <──Session_Created── [gateway] ──spawn──> agent:<session-id>
[connection] ──frame ──> [per-connection actor] ──session_send──> agent:<session-id>
[connection] ──close ──> [per-connection actor] ──Session_Destroy──> [gateway]
```

For WebSocket, SSE, or long poll servers, the per connection actor changes; agents and tools don't.

## WebSocket edge actor

Concrete WebSocket example using [ws_odin](https://github.com/Jonathan-Rowles/ws_odin). Library callbacks fire on the I/O thread; translate each event into a message on the actor's mailbox.

### Boundary messages

```odin
Incoming_Frame :: struct { text: string }
WS_Closed      :: struct { code: u16, reason: string }

@(init)
register_ws_messages :: proc "contextless" () {
    enact.register_message_type(Incoming_Frame)
    enact.register_message_type(WS_Closed)
}
```

### Per connection actor

```odin
import "ws"

WS_User :: struct { actor_name: string }

WS_Conn_State :: struct {
    conn:       ^ws.Server_Connection,
    user:       ^WS_User,
    session:    enact.Session,
    agent_name: string,
    ready:      bool,
}

ws_conn_behaviour :: enact.Actor_Behaviour(WS_Conn_State) {
    init = proc(d: ^WS_Conn_State) {
        enact.send_by_name("gateway", enact.Session_Create{})
    },
    handle_message = proc(d: ^WS_Conn_State, from: enact.PID, msg: any) {
        switch m in msg {
        case enact.Session_Created:
            d.agent_name = strings.clone(m.agent_name)
            d.session    = enact.make_session(d.agent_name)
            d.ready      = true
        case Incoming_Frame:
            if d.ready { enact.session_send(&d.session, m.text) }
        case enact.Agent_Event:
            if m.kind == .TEXT_DELTA { ws.server_send_text(d.conn, enact.resolve(m.detail)) }
        case enact.Agent_Response:
            if !m.is_error { ws.server_send_text(d.conn, enact.resolve(m.content)) }
        case WS_Closed:
            if len(d.agent_name) > 0 {
                enact.send_by_name("gateway", enact.Session_Destroy{agent_name = d.agent_name})
            }
            enact.self_terminate()
        }
    },
    terminate = proc(d: ^WS_Conn_State) {
        if d.conn != nil { ws.server_destroy(d.conn) }
        if d.user != nil { delete(d.user.actor_name); free(d.user) }
    },
}
```

### Listener callbacks

```odin
// Callbacks run on ws_odin's I/O thread. Never touch actor state.
ws_callbacks := ws.Server_Callbacks{
    handle_message = proc(c: ^ws.Server_Connection, op: ws.Opcode, data: []byte) {
        user := (^WS_User)(c.user_data)
        enact.send_by_name(user.actor_name,
            Incoming_Frame{text = strings.clone(string(data))})
    },
    on_disconnect = proc(c: ^ws.Server_Connection, code: ws.Close_Code, reason: string) {
        user := (^WS_User)(c.user_data)
        enact.send_by_name(user.actor_name,
            WS_Closed{code = u16(code), reason = strings.clone(reason)})
    },
}
```

### Discipline

* **Callbacks don't touch actor state.** Translate each event into a message and `send_by_name` it.
* **`server_send_text` is thread safe.** ws_odin's send ring is MPSC.
* **Clone strings at the boundary.** Callback `data` points into ws_odin's receive buffer, valid only for the callback.
* **One actor per socket.** On crash or `WS_Closed`, its arena drops and `ws.server_destroy` runs in `terminate`.

Gateway and agents don't know a WebSocket exists. Swap ws_odin for any transport; agent code is unchanged.

---
[< Text Store](07_text-store.md) | [Sub agents >](09_sub-agents.md)
