// enactod. Single header facade. Public API lives here; `src/` is the
// implementation (package enactod_impl). Import this package and never
// touch the underlying actod runtime or impl package directly. Unless you want to.
package enact

import "core:log"
import vmem "core:mem/virtual"
import "core:net"
import "core:time"
import "pkgs/actod/src/actod"
import impl "src"

// Boot the actor runtime and install enactod's node scoped infrastructure:
// curl global init, the Ollama tracker, and the ingress + proxy actors used
// for cross node messaging. Children listed in `opts.actor_config.children`
// are spawned after the framework actors.
NODE_INIT :: proc(name: string, opts: System_Config) {
	impl.NODE_INIT(name, opts)
}

// Tear down the runtime. Stops workers, drains mailboxes, destroys actor
// arenas. Does not unload Ollama models; call `unload_ollama_models` first
// if you want that.
SHUTDOWN_NODE :: proc() {
	actod.SHUTDOWN_NODE()
}

// Block the current thread until SIGINT / SIGTERM, then call SHUTDOWN_NODE.
// Typical end of `main` for long running programs.
await_signal :: proc() {
	actod.await_signal()
}

// The name passed to NODE_INIT.
get_local_node_name :: proc() -> string {
	return actod.get_local_node_name()
}

// PID of the root node actor. Parent of every spawn that doesn't specify one.
get_local_node_pid :: proc() -> PID {
	return actod.get_local_node_pid()
}

// -----------------------------------------------------------------------------
// Text values. See docs/07_text-store.md.
// -----------------------------------------------------------------------------

// Value type that either wraps an owned string or holds an (offset, len)
// handle into an agent arena. Within an agent subtree, handle backed Text
// travels as a small struct instead of deep copying the bytes per hop.
Text :: impl.Text

// (offset, len) into an agent arena. Used inside Text.
String_Handle :: impl.String_Handle

// Opaque arena handle. Obtain via `get_agent_arena_ptr` and pass to `text()`
// to produce handle backed Text. Treat as an opaque value; do not dereference.
Arena :: ^vmem.Arena

// Get agent text arena name or PID.
// N.B. Only local agents
get_agent_arena_ptr :: proc {
	get_agent_arena_ptr_by_name,
	get_agent_arena_ptr_by_pid,
}

get_agent_arena_ptr_by_name :: proc(agent_name: string) -> Arena {
	return impl.get_agent_arena_ptr_by_name(agent_name)
}

get_agent_arena_ptr_by_pid :: proc(pid: PID) -> Arena {
	return impl.get_agent_arena_ptr_by_pid(pid)
}

// Wrap a string as a Text. With `arena = nil` (default) the result is string
// backed and owns its bytes. With a non nil `arena` (from
// `get_agent_arena_ptr`) the bytes are copied into the arena and the Text
// carries a handle instead, so subsequent message sends inside the subtree
// skip the per hop byte copy.
text :: proc(s: string, arena: Arena = nil) -> Text {
	return impl.text(s, arena)
}

// Read the bytes behind a Text. Valid for the duration of the current
// handler; call `persist_text` if you need to keep them longer.
resolve :: proc(t: Text) -> string {
	return impl.resolve(t)
}

// Clone a Text onto `allocator` so it survives its source arena's reset.
// Always returns a string backed Text.
persist_text :: proc(t: Text, allocator := context.allocator) -> Text {
	return impl.persist_text(t, allocator)
}

// Free a string backed Text. No op for handle backed (the arena owns it).
free_text :: proc(t: Text) {
	impl.free_text(t)
}

// -----------------------------------------------------------------------------
// Providers, models, routing
// -----------------------------------------------------------------------------

// An LLM endpoint: base URL, API key, wire format, extra headers. Wire
// serialisable (plain strings only), so it can travel inside `Set_Route`.
Provider_Config :: impl.Provider_Config

// Wire format: ANTHROPIC, OPENAI_COMPAT, OLLAMA, GEMINI.
API_Format :: impl.API_Format

// Enum of well known model identifiers. Use raw strings for anything not
// listed (for example Ollama model tags).
Model :: impl.Model

// `union{Model, string}`. Accepted by LLM_Config.model and agent_set_route.
Model_ID :: impl.Model_ID

// Build a Provider_Config. `headers` is flattened into a pre formatted
// `extra_headers` string at construction time; the map is not retained.
make_provider :: proc(
	name: string,
	base_url: string,
	api_key: string = "",
	format: API_Format = .OPENAI_COMPAT,
	headers: map[string]string = nil,
) -> Provider_Config {
	return impl.make_provider(name, base_url, api_key, format, headers)
}

// Reserved. Provider_Config carries no owned memory after make_provider.
destroy_provider :: proc(provider: ^Provider_Config) {
	impl.destroy_provider(provider)
}

// Wire name for a Model enum value (what gets sent to the provider).
model_string :: proc(model: Model) -> string {
	return impl.model_string(model)
}

// Provider + model + sampling knobs bundled. Carried inside Agent_Config
// and Set_Route. Construct via the preset helpers (`anthropic`, `openai`,
// `gemini`, `ollama`, `openai_compat`) or populate the struct directly for
// custom endpoints.
LLM_Config :: impl.LLM_Config

// Default base URLs used by the preset constructors. Override via each
// preset's `base_url` parameter.
DEFAULT_ANTHROPIC_URL :: impl.DEFAULT_ANTHROPIC_URL
DEFAULT_OPENAI_URL :: impl.DEFAULT_OPENAI_URL
DEFAULT_GEMINI_URL :: impl.DEFAULT_GEMINI_URL
DEFAULT_OLLAMA_URL :: impl.DEFAULT_OLLAMA_URL
DEFAULT_ANTHROPIC_TIMEOUT :: impl.DEFAULT_ANTHROPIC_TIMEOUT
DEFAULT_OPENAI_TIMEOUT :: impl.DEFAULT_OPENAI_TIMEOUT
DEFAULT_GEMINI_TIMEOUT :: impl.DEFAULT_GEMINI_TIMEOUT
DEFAULT_OLLAMA_TIMEOUT :: impl.DEFAULT_OLLAMA_TIMEOUT

// Anthropic preset. Exposes thinking_budget (min 1024 when set) and
// cache_mode because only Anthropic honours explicit cache_control blocks.
// enable_rate_limiting defaults true — Anthropic is the only provider
// where the rate limiter does real work (header parsing + queue gating).
anthropic :: proc(
	api_key: string,
	model: Model_ID,
	temperature: f32 = impl.DEFAULT_TEMPERATURE,
	max_tokens: int = impl.DEFAULT_MAX_TOKENS,
	thinking_budget: Maybe(int) = nil,
	cache_mode: Cache_Mode = .NONE,
	timeout: time.Duration = impl.DEFAULT_ANTHROPIC_TIMEOUT,
	enable_rate_limiting: bool = true,
	base_url: string = impl.DEFAULT_ANTHROPIC_URL,
	headers: map[string]string = nil,
) -> LLM_Config {
	return impl.anthropic(
		api_key,
		model,
		temperature,
		max_tokens,
		thinking_budget,
		cache_mode,
		timeout,
		enable_rate_limiting,
		base_url,
		headers,
	)
}

// OpenAI preset. Caching is server-side automatic and thinking is
// model-internal, so neither is exposed — set them via a raw LLM_Config
// if you need to.
openai :: proc(
	api_key: string,
	model: Model_ID,
	temperature: f32 = impl.DEFAULT_TEMPERATURE,
	max_tokens: int = impl.DEFAULT_MAX_TOKENS,
	timeout: time.Duration = impl.DEFAULT_OPENAI_TIMEOUT,
	enable_rate_limiting: bool = true,
	base_url: string = impl.DEFAULT_OPENAI_URL,
	headers: map[string]string = nil,
) -> LLM_Config {
	return impl.openai(
		api_key,
		model,
		temperature,
		max_tokens,
		timeout,
		enable_rate_limiting,
		base_url,
		headers,
	)
}

// Gemini preset. thinking_budget semantics: nil = off, -1 = dynamic,
// 0 = off, >0 = fixed. Implicit caching is handled server-side.
gemini :: proc(
	api_key: string,
	model: Model_ID,
	temperature: f32 = impl.DEFAULT_TEMPERATURE,
	max_tokens: int = impl.DEFAULT_MAX_TOKENS,
	thinking_budget: Maybe(int) = nil,
	timeout: time.Duration = impl.DEFAULT_GEMINI_TIMEOUT,
	enable_rate_limiting: bool = true,
	base_url: string = impl.DEFAULT_GEMINI_URL,
	headers: map[string]string = nil,
) -> LLM_Config {
	return impl.gemini(
		api_key,
		model,
		temperature,
		max_tokens,
		thinking_budget,
		timeout,
		enable_rate_limiting,
		base_url,
		headers,
	)
}

// Ollama preset. Model is a raw tag string (e.g. "llama3.1:8b") because the
// Model enum doesn't list Ollama tags. No API key needed. Rate limiting
// defaults off — local inference has no provider limits to honour.
ollama :: proc(
	model: string,
	base_url: string = impl.DEFAULT_OLLAMA_URL,
	temperature: f32 = impl.DEFAULT_TEMPERATURE,
	max_tokens: int = impl.DEFAULT_MAX_TOKENS,
	thinking_budget: Maybe(int) = nil,
	timeout: time.Duration = impl.DEFAULT_OLLAMA_TIMEOUT,
	enable_rate_limiting: bool = false,
	headers: map[string]string = nil,
) -> LLM_Config {
	return impl.ollama(
		model,
		base_url,
		temperature,
		max_tokens,
		thinking_budget,
		timeout,
		enable_rate_limiting,
		headers,
	)
}

// OpenAI-wire-compatible endpoints (Groq, Together, Fireworks, vLLM,
// LM Studio, OpenRouter). Pass the display name + base_url explicitly.
openai_compat :: proc(
	name: string,
	base_url: string,
	api_key: string,
	model: Model_ID,
	temperature: f32 = impl.DEFAULT_TEMPERATURE,
	max_tokens: int = impl.DEFAULT_MAX_TOKENS,
	timeout: time.Duration = impl.DEFAULT_OPENAI_TIMEOUT,
	enable_rate_limiting: bool = true,
	headers: map[string]string = nil,
) -> LLM_Config {
	return impl.openai_compat(
		name,
		base_url,
		api_key,
		model,
		temperature,
		max_tokens,
		timeout,
		enable_rate_limiting,
		headers,
	)
}

// Message: override the agent's route. Takes effect on the next turn; the
// in flight call finishes on the old route. Persists until Clear_Route.
Set_Route :: impl.Set_Route

// Message: drop a Set_Route override. Routing reverts to the config time
// provider + model.
Clear_Route :: impl.Clear_Route

// Push a runtime route override. Wins over the agent's config time route.
// Takes effect on the next turn. The whole LLM_Config is swapped —
// provider, model, sampling, timeout — so `Set_Route` from `anthropic(...)`
// to `ollama(...)` automatically picks up Ollama's longer timeout.
// `enable_rate_limiting` on the override is ignored; the rate limiter
// is spawned once at agent init and not toggled by Set_Route.
agent_set_route :: proc(
	agent_name: string,
	llm: LLM_Config,
	node_name: string = "",
) -> Send_Error {
	return impl.agent_set_route(agent_name, llm, node_name)
}

// Remove a Set_Route override. Routing reverts to the config time route.
agent_clear_route :: proc(agent_name: string, node_name: string = "") -> Send_Error {
	return impl.agent_clear_route(agent_name, node_name)
}

// -----------------------------------------------------------------------------
// Agents
// -----------------------------------------------------------------------------

// Per agent configuration. Built via make_agent_config; passed to spawn_agent.
Agent_Config :: impl.Agent_Config

// Prompt cache mode: NONE or EPHEMERAL (provider agnostic hint). Unsupported
// provider combinations pass through silently.
Cache_Mode :: impl.Cache_Mode

// Build an Agent_Config.
//
//   make_agent_config(llm = anthropic(key, .Claude_Sonnet_4_5), tools = ts)
//
// Minimum required: `llm` (built via a preset — `anthropic`, `openai`,
// `gemini`, `ollama`, `openai_compat` — or a raw LLM_Config for custom
// endpoints). Everything else has a default. For dynamic routing across
// providers/models, spawn a router actor and have it push Set_Route
// messages; see `agent_set_route`.
make_agent_config :: proc(
	llm: LLM_Config,
	system_prompt: string = "",
	tools: []Tool = nil,
	children: [dynamic]SPAWN = nil,
	worker_count: int = impl.DEFAULT_WORKER_COUNT,
	max_turns: int = impl.DEFAULT_MAX_TURNS,
	max_tool_calls_per_turn: int = impl.DEFAULT_MAX_TOOL_CALLS_PER_TURN,
	tool_timeout: time.Duration = impl.DEFAULT_TOOL_TIMEOUT,
	stream: bool = false,
	forward_events: bool = false,
	forward_thinking: bool = true,
	tool_continuation: string = "",
	validate_tool_args: bool = true,
	trace_sink: Trace_Sink = {},
	accumulate_history: bool = true,
	restart_policy: Restart_Policy = .PERMANENT,
) -> Agent_Config {
	return impl.make_agent_config(
		llm,
		system_prompt,
		tools,
		children,
		worker_count,
		max_turns,
		max_tool_calls_per_turn,
		tool_timeout,
		stream,
		forward_events,
		forward_thinking,
		tool_continuation,
		validate_tool_args,
		trace_sink,
		accumulate_history,
		restart_policy,
	)
}

// Spawn `agent:<name>` with its worker pool, rate limiter, tool actors, and
// any `children` listed on the config. Returns a Session ready to drive the
// agent — one session per agent is the intended pattern. The first actor to
// call session_send (or build an Agent_Request) claims the agent; subsequent
// callers from a different PID are rejected. For supervisor/bootstrap spawn
// closures that must return a PID, read `session.pid` off the returned value
// (or call `agent_pid(session)`).
// Arena lifecycle: the agent does NOT reset its own transport arena on
// response. Each `session_send` resets the arena before writing the new
// turn's content. Keep anything the caller needs across turns in the
// caller's own actor state — `Agent_Response` Text is self-contained and
// survives the next `session_send`.
spawn_agent :: proc(name: string, config: Agent_Config) -> (Session, bool) {
	return impl.spawn_agent(name, config)
}

// PID of the agent addressed by this session. Resolved at `make_session` or
// `spawn_agent`. Zero if the session targets a remote node or an agent that
// hadn't spawned yet.
agent_pid :: proc(s: Session) -> PID {
	return impl.agent_pid(s)
}

// Terminate the agent and every child (workers, rate limiter, tool actors).
// The agent's arena is destroyed.
destroy_agent :: proc(name: string) -> bool {
	return impl.destroy_agent(name)
}

// Return `"agent:<name>"` (the registered actor name for a spawned agent).
agent_actor_name :: proc(agent_name: string) -> string {
	return impl.agent_actor_name(agent_name)
}

// -----------------------------------------------------------------------------
// Sessions
// -----------------------------------------------------------------------------

// Client side value type for talking to an agent. Not an actor. Carries the
// target's agent name, an optional node name, and a monotonic request id.
Session :: impl.Session

// Monotonic id stamped on every Agent_Request. Unique per session.
Request_ID :: impl.Request_ID

// Return type of session_request_sync. `content` / `error_msg` are heap
// allocated and owned by the caller.
Sync_Result :: impl.Sync_Result

// Maximum cache blocks per request (4). actod's wire format forbids dynamic
// arrays in messages; extra blocks are dropped with a warning.
MAX_CACHE_BLOCKS :: impl.MAX_CACHE_BLOCKS

// Attach to an already-spawned agent. Use this when the caller did not
// spawn the agent: remote targets, gateway handoffs, or agents spawned
// elsewhere in a supervision tree. For local spawn-and-drive in one step,
// prefer `spawn_agent` (returns a ready Session).
make_session :: proc(agent_name: string, node_name: string = "") -> Session {
	return impl.make_session(agent_name, node_name)
}

// Release resources owned by a Session. For remote sessions this frees the
// local receive arena and unregisters it from the ingress. Safe to call on a
// zero-valued or local-only Session (no-op). Call from the owner actor's
// terminate path (or wherever the session's lifetime ends).
session_destroy :: proc(s: ^Session) {
	impl.session_destroy(s)
}

// Fire and forget send. The reply arrives as Agent_Response in the calling
// actor's mailbox. Caller PID is captured via `get_self_pid()`.
// Resets the target agent's transport arena before writing the new content.
// Anything the caller wants to keep across turns must already live in the
// caller's own state; Agent_Response Text is self-contained so prior
// responses survive unaffected.
session_send :: proc(s: ^Session, content: string) -> Send_Error {
	return impl.session_send(s, content)
}

// Send a request with one or more prompt cache segments prepended to the
// conversation. Up to MAX_CACHE_BLOCKS blocks accepted; extras dropped with
// a warning. See docs/10_prompt-caching.md.
session_send_cached :: proc(s: ^Session, blocks: ..string) -> Send_Error {
	return impl.session_send_cached(s, ..blocks)
}

// Build an Agent_Request without sending. For callers that need to stamp
// `parent_request_id` manually before dispatching.
session_request :: proc(s: ^Session, content: string) -> Agent_Request {
	return impl.session_request(s, content)
}

// Send `content` and block the caller until a reply arrives or `timeout`
// elapses. MUST NOT be called from inside an actor's handle_message (would
// deadlock the worker).
session_request_sync :: proc(
	s: ^Session,
	content: string,
	timeout: time.Duration = 60 * time.Second,
) -> Sync_Result {
	return impl.session_request_sync(s, content, timeout)
}

// Return `"agent:<name>"` or `"agent:<name>@<node>"` (for logging or for
// send_by_name calls that want the same routing string).
session_target_name :: proc(s: ^Session) -> string {
	return impl.session_target_name(s)
}

// Ask the agent to drop its chat history. Addressed by agent name so any
// actor (admin / supervisor) can issue a reset. Rejected when the agent is
// non idle; retry when it's back in IDLE.
reset_conversation :: proc(
	agent_name: string,
	node_name: string = "",
	request_id: Request_ID = 0,
) -> Send_Error {
	return impl.reset_conversation(agent_name, node_name, request_id)
}

// Abort the agent's in-flight turn. The agent emits an error
// Agent_Response{is_error=true, error_msg="(cancelled)"} and returns
// to IDLE. `request_id` must match the in-flight turn; stale or
// non-matching cancels are silently ignored.
cancel_turn :: proc(
	agent_name: string,
	request_id: Request_ID,
	node_name: string = "",
) -> Send_Error {
	return impl.cancel_turn(agent_name, request_id, node_name)
}

// Ask the agent to summarise its history via one dedicated LLM call and
// collapse it into a single entry. The caller receives a Compact_Result
// stamped with `request_id` for correlation.
compact_history :: proc(
	agent_name: string,
	instruction: string = "",
	node_name: string = "",
	request_id: Request_ID = 0,
) -> Send_Error {
	return impl.compact_history(agent_name, instruction, node_name, request_id)
}

// -----------------------------------------------------------------------------
// Tools
// -----------------------------------------------------------------------------

// Value type describing a tool available to an agent. Built via one of the
// five constructors below.
Tool :: impl.Tool

// INLINE, EPHEMERAL, PERSISTENT, SUB_AGENT.
Tool_Lifecycle :: impl.Tool_Lifecycle

// Tool metadata: name, description, input_schema (raw JSON Schema). Compiled
// once at agent init; validated per call when `validate_tool_args = true`.
Tool_Def :: impl.Tool_Def

// Pure tool body: `(arguments, allocator) -> (result, is_error)`. No globals,
// no shared mutable state, no hidden I/O.
Tool_Proc :: impl.Tool_Proc

// Actor spawn proc for a custom persistent tool. MUST register the spawned
// actor under the `name` argument it receives.
Tool_Spawn_Proc :: impl.Tool_Spawn_Proc

// INLINE tool. Runs on the agent actor itself; zero spawn. Must be pure.
function_tool :: proc(def: Tool_Def, impl_proc: Tool_Proc) -> Tool {
	return impl.function_tool(def, impl_proc)
}

// EPHEMERAL tool. One fresh actor per call, self terminates on return. Good
// for blocking I/O that shouldn't stall the agent.
ephemeral_tool :: proc(def: Tool_Def, impl_proc: Tool_Proc) -> Tool {
	return impl.ephemeral_tool(def, impl_proc)
}

// PERSISTENT tool. Lazy spawned, long lived, backed by the default tool
// actor running `impl_proc`. For stateful behaviour use persistent_tool_actor.
persistent_tool :: proc(def: Tool_Def, impl_proc: Tool_Proc) -> Tool {
	return impl.persistent_tool(def, impl_proc)
}

// PERSISTENT tool with a user supplied actor behaviour. `spawn_proc` MUST
// register the spawned actor under the `name` argument it receives,
// otherwise the agent can't reach it.
persistent_tool_actor :: proc(def: Tool_Def, spawn_proc: Tool_Spawn_Proc) -> Tool {
	return impl.persistent_tool_actor(def, spawn_proc)
}

// SUB_AGENT tool. Delegates to another agent. `pool_size > 1` fans out
// across a pool. `context_file` is read on every call and prepended as
// `<context>...</context>`.
sub_agent_tool :: proc(
	def: Tool_Def,
	config: ^Agent_Config,
	pool_size: int = 1,
	context_file: string = "",
) -> Tool {
	return impl.sub_agent_tool(def, config, pool_size, context_file)
}

// -----------------------------------------------------------------------------
// Messages
// -----------------------------------------------------------------------------

// The request message produced by session_send / session_send_cached.
Agent_Request :: impl.Agent_Request

// The final reply from an agent. Content plus token totals.
Agent_Response :: impl.Agent_Response

// Per chunk streaming event. Flat `kind + subject + detail` shape; see
// docs/05_streaming-events.md for the kind -> field mapping.
Agent_Event :: impl.Agent_Event

// LLM_CALL_START/DONE, TOOL_CALL_START/DONE, THINKING_DONE, THINKING_DELTA,
// TEXT_DELTA.
Event_Kind :: impl.Event_Kind

// Dispatched to a tool actor on every tool call.
Tool_Call_Msg :: impl.Tool_Call_Msg

// Reply from a tool actor back to the agent.
Tool_Result_Msg :: impl.Tool_Result_Msg

// SYSTEM, USER, ASSISTANT, TOOL. Used by History_Entry_Msg.
Chat_Role :: impl.Chat_Role

// Message: drop the agent's chat history.
Reset_Conversation :: impl.Reset_Conversation

// Message: abort the agent's in-flight turn. Matched against the
// current request_id; stale cancels are ignored.
Cancel_Turn :: impl.Cancel_Turn

// Message: ask the agent to compact its history via an LLM summary.
Compact_History :: impl.Compact_History

// Reply to Compact_History. `summary` is the new single entry; `old_turns`
// counts what was replaced.
Compact_Result :: impl.Compact_Result

// Message: query the agent's arena usage.
Arena_Status_Query :: impl.Arena_Status_Query

// Reply to Arena_Status_Query: bytes used / reserved, peak usage.
Arena_Status :: impl.Arena_Status

// Message: fetch a single chat history entry by index (negative counts from
// the end).
History_Query :: impl.History_Query

// Reply to History_Query.
History_Entry_Msg :: impl.History_Entry_Msg

// Message: client asks a gateway actor to open a session. The gateway
// decides what "session" means (typically spawns a per client agent). Not
// emitted by the framework; used by application gateway actors. See
// docs/08_remote-agents.md.
Session_Create :: impl.Session_Create

// Reply to Session_Create. The gateway reports the agent name the client
// should use for subsequent `make_session` / `session_send` calls.
Session_Created :: impl.Session_Created

// Message: client tells the gateway to tear down its session. The gateway
// calls `destroy_agent` on the named agent.
Session_Destroy :: impl.Session_Destroy

// -----------------------------------------------------------------------------
// Rate limiting. See docs/06_rate-limiting.md.
// -----------------------------------------------------------------------------

// Message: ask `ratelim:<agent>` for its current limit state.
Rate_Limiter_Query :: impl.Rate_Limiter_Query

// Reply to Rate_Limiter_Query: request/token limits, queue depth, in flight.
Rate_Limiter_Status :: impl.Rate_Limiter_Status

// Per request event emitted to the original caller.
Rate_Limit_Event :: impl.Rate_Limit_Event

// QUEUED, RETRYING, PROCESSING.
Rate_Limit_Event_Kind :: impl.Rate_Limit_Event_Kind

// -----------------------------------------------------------------------------
// Tracing. See docs/12_tracing.md.
// -----------------------------------------------------------------------------

// Wide observability record. One struct, fields meaningful per kind. Sinks
// switch on `kind`.
Trace_Event :: impl.Trace_Event

// REQUEST_START/END, LLM_CALL_START/DONE, TOOL_CALL_START/DONE,
// THINKING_DONE, RATE_LIMIT_*, ERROR.
Trace_Event_Kind :: impl.Trace_Event_Kind

// Semantic role of `Trace_Event.detail` for a given kind. Useful for
// exporters that need to tag the payload without reimplementing the mapping.
Trace_Event_Detail_Role :: impl.Trace_Event_Detail_Role

// Sink config. Built via one of the four constructors below.
Trace_Sink :: impl.Trace_Sink

// NONE, FUNCTION, CUSTOM, EXTERNAL.
Trace_Sink_Kind :: impl.Trace_Sink_Kind

// `proc(ev, allocator)`. Runs inside the function trace sink's actor.
Trace_Handler :: impl.Trace_Handler

// Actor spawn proc for custom_trace_sink. MUST register under `name`.
Trace_Sink_Spawn_Proc :: impl.Trace_Sink_Spawn_Proc

// Options for dev_trace_sink: stdout, color, jsonl_path, md_dir, verbose.
Dev_Trace_Config :: impl.Dev_Trace_Config

// Return the semantic role of `ev.detail` for the event's kind (e.g.
// USER_INPUT for REQUEST_START, TOOL_ARGS for TOOL_CALL_START). Useful for
// exporters choosing between gen_ai.prompt, gen_ai.completion, tool.arguments.
// NONE if the event doesn't carry detail text.
trace_event_detail_role :: proc "contextless" (ev: Trace_Event) -> Trace_Event_Detail_Role {
	return impl.trace_event_detail_role(ev)
}

// Simplest sink constructor. The handler runs inside a framework owned
// actor; `context.temp_allocator` is available for scratch. Stateless; use
// custom_trace_sink for anything that needs to persist across events.
function_trace_sink :: proc(name: string, handler: Trace_Handler) -> Trace_Sink {
	return impl.function_trace_sink(name, handler)
}

// Full control sink. The spawn proc must register the spawned actor under
// the name it receives. Use for stateful sinks (file handles, HTTP clients,
// buffered flushes).
custom_trace_sink :: proc(name: string, spawn: Trace_Sink_Spawn_Proc) -> Trace_Sink {
	return impl.custom_trace_sink(name, spawn)
}

// No spawn. The agent emits to `name` (supports the `actor@node` cross node
// syntax). The user spawns and owns the sink actor elsewhere.
external_trace_sink :: proc(name: string) -> Trace_Sink {
	return impl.external_trace_sink(name)
}

// Built in sink for development: pretty stdout + optional JSONL + per
// request MD digest. Pass the returned value directly to
// Agent_Config.trace_sink; the agent will lazy spawn the backing actor.
dev_trace_sink :: proc(name: string, config: Dev_Trace_Config = {}) -> Trace_Sink {
	return impl.dev_trace_sink(name, config)
}

// Direct spawn of the dev sink actor, for callers who want manual control
// over where it sits in the supervision tree. Configure the agent with
// external_trace_sink(name) to reference it.
spawn_dev_trace_sink_actor :: proc(name: string, config: Dev_Trace_Config = {}) -> (PID, bool) {
	return impl.spawn_dev_trace_sink_actor(name, config)
}

// -----------------------------------------------------------------------------
// Ollama. See docs/11_ollama.md.
// -----------------------------------------------------------------------------

// Message: unload every tracked Ollama (base_url, model) via `keep_alive = 0`.
Ollama_Unload_All :: impl.Ollama_Unload_All

// Unload every Ollama (base_url, model) the tracker has seen. Optional.
// enactod leaves Ollama models loaded by default so they stay warm for the
// next session; call this to release VRAM / RAM on shutdown or between jobs.
unload_ollama_models :: proc(node_name: string = "") -> Send_Error {
	return impl.unload_ollama_models(node_name)
}

// =============================================================================
// Actor runtime (re-exports from actod)
//
// For deep semantics, see the actod docs:
//   https://github.com/Jonathan-Rowles/actod/blob/main/docs/
// =============================================================================

// -----------------------------------------------------------------------------
// Types
// -----------------------------------------------------------------------------

// 64 bit actor identifier. Compare with `==`.
PID :: actod.PID

// Typed behaviour struct: init, handle_message, terminate, supervisor callbacks.
// See https://github.com/Jonathan-Rowles/actod/blob/main/docs/02_actor.md.
Actor_Behaviour :: actod.Actor_Behaviour

// PID or name reference. Used by Actor_Config.affinity.
Actor_Ref :: actod.Actor_Ref

// 8 bit actor type id. Used for type based pub/sub.
Actor_Type :: actod.Actor_Type

// Lifecycle enum: ALIVE, TERMINATING, TERMINATED.
Actor_State :: actod.Actor_State

// Low level handle used inside actod's PID encoding.
Handle :: actod.Handle

// `proc(name: string, parent: PID) -> (PID, bool)`. The canonical child
// spawn signature.
SPAWN :: actod.SPAWN

// Result of every send: OK, ACTOR_NOT_FOUND, RECEIVER_BACKLOGGED,
// MESSAGE_TOO_LARGE, SYSTEM_SHUTTING_DOWN, NETWORK_ERROR, NETWORK_RING_FULL,
// NODE_NOT_FOUND, NODE_DISCONNECTED.
Send_Error :: actod.Send_Error

// HIGH, NORMAL, LOW. Used with send_high / send_low / set_send_priority.
Message_Priority :: actod.Message_Priority

// NORMAL, SHUTDOWN, CRASHED. Passed to self_terminate / terminate_actor.
Termination_Reason :: actod.Termination_Reason

// `struct{ id: u32 }`. Fires to actors holding a timer.
Timer_Tick :: actod.Timer_Tick

// Handle returned by subscribe_type. Pass to unsubscribe.
Subscription :: actod.Subscription

// Scoped, local only topic. Embed in a domain struct for per entity channels.
// See https://github.com/Jonathan-Rowles/actod/blob/main/docs/07_topic-pubsub.md.
Topic :: actod.Topic

// Handle returned by subscribe_topic.
Topic_Subscription :: actod.Topic_Subscription

// ONE_FOR_ONE, ONE_FOR_ALL, REST_FOR_ONE.
// See https://github.com/Jonathan-Rowles/actod/blob/main/docs/04_supervisor.md.
Supervision_Strategy :: actod.Supervision_Strategy

// PERMANENT, TRANSIENT, TEMPORARY.
Restart_Policy :: actod.Restart_Policy

// Spin strategy for the worker's mailbox wait loop.
SPIN_STRATEGY :: actod.SPIN_STRATEGY

// Top level config returned by make_node_config and passed to NODE_INIT.
System_Config :: actod.System_Config

// Per actor config: mailbox, supervision, affinity, stack size.
Actor_Config :: actod.Actor_Config

// Cross node networking: port, auth, heartbeat, reconnect policy.
Network_Config :: actod.Network_Config

// Logging config: level, file/console options, optional custom logger.
Log_Config :: actod.Log_Config

// Custom log sink callback.
Log_Callback :: actod.Log_Callback

// Custom log flush callback.
Log_Flush :: actod.Log_Flush

// core:log level alias.
Log_Level :: log.Level

// core:log options alias.
Log_Options :: log.Options

// 16 bit node id inside a PID.
Node_ID :: actod.Node_ID

// Metadata about a registered peer node.
Node_Info :: actod.Node_Info

// Transport options for register_node (e.g. TCP_Custom_Protocol).
// See https://github.com/Jonathan-Rowles/actod/blob/main/docs/10_network.md.
Transport_Strategy :: actod.Transport_Strategy

// Connection ring sizing for the network layer.
Connection_Ring_Config :: actod.Connection_Ring_Config

// Per actor runtime stats. Emitted by the observer.
Actor_Stats :: actod.Actor_Stats

// Bulk stats payload emitted to stats subscribers.
Stats_Snapshot :: actod.Stats_Snapshot

// Reply to request_actor_stats / request_all_stats.
Stats_Response :: actod.Stats_Response

// Sentinel Actor_Type value for actors with no registered type.
ACTOR_TYPE_UNTYPED :: actod.ACTOR_TYPE_UNTYPED

// -----------------------------------------------------------------------------
// Spawning & lifecycle
// -----------------------------------------------------------------------------

// Top level spawn. Use spawn_child from within an actor.
spawn :: proc(
	name: string,
	data: $T,
	behaviour: Actor_Behaviour(T),
	opts: Actor_Config = actod.SYSTEM_CONFIG.actor_config,
	parent_pid: PID = 0,
) -> (
	PID,
	bool,
) {
	return actod.spawn(name, data, behaviour, opts, parent_pid)
}

// Spawn a child of the calling actor. Must be called from within an actor.
spawn_child :: proc(
	name: string,
	data: $T,
	behaviour: Actor_Behaviour(T),
	opts: Actor_Config = actod.SYSTEM_CONFIG.actor_config,
) -> (
	PID,
	bool,
) {
	return actod.spawn_child(name, data, behaviour, opts)
}

// Spawn via a registered SPAWN proc looked up by name. See
// register_spawn_func.
spawn_by_name :: proc(
	spawn_func_name: string,
	actor_name: string,
	parent_pid: PID = 0,
) -> (
	PID,
	bool,
) {
	return actod.spawn_by_name(spawn_func_name, actor_name, parent_pid)
}

// Ask a peer node to spawn an actor via its registered spawn func. Blocks
// until the remote node replies or `timeout` elapses.
spawn_remote :: proc(
	spawn_func_name: string,
	actor_name: string,
	target_node: string,
	parent_pid: PID = 0,
	timeout: time.Duration = actod.SPAWN_REMOTE_TIMEOUT,
) -> (
	PID,
	bool,
) {
	return actod.spawn_remote(spawn_func_name, actor_name, target_node, parent_pid, timeout)
}

// Terminate a specific actor. Does not cascade to children unless the
// supervisor policy says so.
terminate_actor :: proc(to: PID, reason: Termination_Reason = .SHUTDOWN) -> bool {
	return actod.terminate_actor(to, reason)
}

// Change an actor's registered name. All future by name sends use the new.
rename_actor :: proc(pid: PID, new_name: string) -> bool {
	return actod.rename_actor(pid, new_name)
}

// -----------------------------------------------------------------------------
// Messaging. Single source of truth.
// -----------------------------------------------------------------------------

// Route a message to `to` whether local or remote. For remote targets
// carrying Text fields, the message goes through enactod's ingress path
// (Text resolved to strings on the sender).
send :: proc(to: PID, msg: $T) -> Send_Error {
	return impl.send(to, msg)
}

// Send to a named actor on an explicit node. Empty node_name (or the local
// node) is equivalent to a local by name send.
send_to :: proc(actor_name: string, node_name: string, msg: $T) -> Send_Error {
	return impl.send_to(actor_name, node_name, msg)
}

// Accepts either `"actor"` (local) or `"actor@node"` (remote).
send_by_name :: proc(target: string, msg: $T) -> Send_Error {
	return impl.send_by_name(target, msg)
}

// Send a message to the current actor. Always local.
send_self :: proc(content: $T) -> Send_Error {
	return actod.send_self(content)
}

// Send to the parent actor. Routes through enact.send so a parent created
// via spawn_remote on another node carries its Text fields correctly.
send_message_to_parent :: proc(content: $T) -> bool {
	return impl.send_to_parent(content)
}

// Send to every registered child. Same Text safety contract as
// send_message_to_parent.
send_message_to_children :: proc(content: $T) -> bool {
	return impl.send_to_children(content)
}

// High priority variant of send. Cross node Text routing is preserved.
send_high :: proc(to: PID, content: $T) -> Send_Error {
	return impl.send_high(to, content)
}

// Low priority variant of send. Cross node Text routing is preserved.
send_low :: proc(to: PID, content: $T) -> Send_Error {
	return impl.send_low(to, content)
}

// Set the worker local priority for subsequent sends. Call
// reset_send_priority afterwards. No routing semantics.
set_send_priority :: proc(p: Message_Priority) {
	actod.set_send_priority(p)
}

// Reset the worker local send priority to NORMAL.
reset_send_priority :: proc() {
	actod.reset_send_priority()
}

// Register a message type so actod can deep copy it across mailboxes and the
// network. Call from an `@(init)` proc for each user defined message. See
// https://github.com/Jonathan-Rowles/actod/blob/main/docs/03_message-registration.md.
register_message_type :: proc "contextless" ($T: typeid) {
	actod.register_message_type(T)
}

// -----------------------------------------------------------------------------
// Actor context. Call from within an actor.
// -----------------------------------------------------------------------------

// PID of the calling actor.
get_self_pid :: proc() -> PID {
	return actod.get_self_pid()
}

// Registered name of the calling actor.
get_self_name :: proc() -> string {
	return actod.get_self_name()
}

// PID of the calling actor's parent (0 if none).
get_parent_pid :: proc() -> PID {
	return actod.get_parent_pid()
}

// Terminate the calling actor.
self_terminate :: proc(reason: Termination_Reason = .NORMAL) -> bool {
	return actod.self_terminate(reason)
}

// Rename the calling actor.
self_rename :: proc(new_name: string) -> bool {
	return actod.self_rename(new_name)
}

// Cooperative yield for pooled actors. Rarely needed; reconsider design if
// you reach for it often.
yield :: proc() {
	actod.yield()
}

// Clock that returns virtual time in tests, real time in production. Use
// instead of `time.now()` inside actor code.
now :: proc() -> time.Time {
	return actod.now()
}

// -----------------------------------------------------------------------------
// Registry / lookup
// -----------------------------------------------------------------------------

// Look up an actor's PID by registered name.
get_actor_pid :: proc(name: string) -> (PID, bool) {
	return actod.get_actor_pid(name)
}

// Registered name for a PID.
get_actor_name :: proc(pid: PID) -> string {
	return actod.get_actor_name(pid)
}

// True if `pid` lives on the local node.
is_local_pid :: proc(pid: PID) -> bool {
	return actod.is_local_pid(pid)
}

// Extract the Node_ID from a PID.
get_node_id :: proc(pid: PID) -> Node_ID {
	return actod.get_node_id(pid)
}

// Extract the Actor_Type from a PID.
get_pid_actor_type :: proc(pid: PID) -> Actor_Type {
	return actod.get_pid_actor_type(pid)
}

// -----------------------------------------------------------------------------
// Timers. See https://github.com/Jonathan-Rowles/actod/blob/main/docs/05_timer.md.
// -----------------------------------------------------------------------------

// Schedule a Timer_Tick after `interval`. Returns the timer id to match on.
// `repeat = true` fires every `interval` until cancelled. Auto cleaned up
// on actor termination.
set_timer :: proc(interval: time.Duration, repeat: bool) -> (u32, Send_Error) {
	return actod.set_timer(interval, repeat)
}

// Cancel a scheduled timer.
cancel_timer :: proc(id: u32) -> Send_Error {
	return actod.cancel_timer(id)
}

// -----------------------------------------------------------------------------
// Supervision. See https://github.com/Jonathan-Rowles/actod/blob/main/docs/04_supervisor.md.
// -----------------------------------------------------------------------------

// List the registered children of `parent`.
get_children :: proc(parent: PID) -> []PID {
	return actod.get_children(parent)
}

// Spawn a new child under `parent` via the given SPAWN proc.
add_child :: proc(parent: PID, child_spawn: SPAWN) -> (PID, bool) {
	return actod.add_child(parent, child_spawn)
}

// Attach an already spawned actor as a child of `parent` (for restarts).
add_child_existing :: proc(parent: PID, existing_child: PID, child_spawn: SPAWN) -> (PID, bool) {
	return actod.add_child_existing(parent, existing_child, child_spawn)
}

// Detach a child from its parent. Does not terminate the child.
remove_child :: proc(parent: PID, child: PID) -> bool {
	return actod.remove_child(parent, child)
}

// -----------------------------------------------------------------------------
// Pub/Sub. Type based (global, cross node) and topic based (local).
// See https://github.com/Jonathan-Rowles/actod/blob/main/docs/06_pubsub.md.
// -----------------------------------------------------------------------------

// Register a user named Actor_Type. Returns the 8 bit id (1 to 255).
register_actor_type :: proc(name: string) -> (Actor_Type, bool) {
	return actod.register_actor_type(name)
}

// Reverse lookup: name for an Actor_Type.
get_actor_type_name :: proc(actor_type: Actor_Type) -> (string, bool) {
	return actod.get_actor_type_name(actor_type)
}

// Subscribe the calling actor to broadcasts for a given Actor_Type.
subscribe_type :: proc(actor_type: Actor_Type) -> (Subscription, bool) {
	return actod.subscribe_type(actor_type)
}

// Remove a type based subscription.
unsubscribe :: proc(sub: Subscription) -> bool {
	return actod.pubsub_unsubscribe(sub)
}

// Broadcast to every subscriber of the caller's Actor_Type.
broadcast :: proc(msg: $T) {
	actod.broadcast(msg)
}

// Count of subscribers for an Actor_Type.
get_subscriber_count :: proc(actor_type: Actor_Type) -> u32 {
	return actod.get_subscriber_count(actor_type)
}

// Subscribe to a scoped Topic (local, up to 64 subscribers).
subscribe_topic :: proc(topic: ^Topic) -> (Topic_Subscription, bool) {
	return actod.subscribe_topic(topic)
}

// Remove a topic subscription.
unsubscribe_topic :: proc(sub: Topic_Subscription) -> bool {
	return actod.unsubscribe_topic(sub)
}

// Publish to every subscriber of a Topic.
publish :: proc(topic: ^Topic, msg: $T) {
	actod.publish(topic, msg)
}

// -----------------------------------------------------------------------------
// Networking. See https://github.com/Jonathan-Rowles/actod/blob/main/docs/10_network.md.
// -----------------------------------------------------------------------------

// Register a peer node. Later sends to `actor@name` route over this link.
register_node :: proc(
	name: string,
	address: net.Endpoint,
	transport: Transport_Strategy,
) -> (
	Node_ID,
	bool,
) {
	return actod.register_node(name, address, transport)
}

// Register a SPAWN proc under a stable name so peers can call spawn_remote.
register_spawn_func :: proc(name: string, func: SPAWN) -> bool {
	return actod.register_spawn_func(name, func)
}

// Metadata for a registered peer.
get_node_info :: proc(node_id: Node_ID) -> (Node_Info, bool) {
	return actod.get_node_info(node_id)
}

// Look up a peer Node_ID by registered name.
get_node_by_name :: proc(name: string) -> (Node_ID, bool) {
	return actod.get_node_by_name(name)
}

// Drop a peer registration.
unregister_node :: proc(node_id: Node_ID) {
	actod.unregister_node(node_id)
}

// -----------------------------------------------------------------------------
// Observer. See https://github.com/Jonathan-Rowles/actod/blob/main/docs/08_observer.md.
// -----------------------------------------------------------------------------

// Start the stats observer. `collection_interval = 0` means manual only.
start_observer :: proc(collection_interval: time.Duration = 0) -> (PID, bool) {
	return actod.start_observer(collection_interval)
}

// Stop the stats observer.
stop_observer :: proc() {
	actod.stop_observer()
}

// Trigger one stats collection pass now.
trigger_stats_collection :: proc() -> bool {
	return actod.trigger_stats_collection()
}

// Subscribe the calling actor to Stats_Snapshot messages.
subscribe_to_stats :: proc() -> (Subscription, bool) {
	return actod.subscribe_to_stats()
}

// Remove a stats subscription.
unsubscribe_from_stats :: proc(sub: Subscription) -> bool {
	return actod.unsubscribe_from_stats(sub)
}

// -----------------------------------------------------------------------------
// Logging. See https://github.com/Jonathan-Rowles/actod/blob/main/docs/09_logging.md.
// -----------------------------------------------------------------------------

// Set the calling actor's log level.
set_log_level :: proc(level: Log_Level) {
	actod.set_log_level(level)
}

// Cheap check before building expensive log messages.
is_log_level_enabled :: proc(level: Log_Level) -> bool {
	return actod.is_log_level_enabled(level)
}

// Fetch the calling actor's current log config.
get_current_log_config :: proc() -> Log_Config {
	return actod.get_current_log_config()
}

// -----------------------------------------------------------------------------
// Configuration builders
// -----------------------------------------------------------------------------

// Build a System_Config for NODE_INIT. All args optional; defaults are the
// actod standard config.
make_node_config :: proc(
	actor_registry_size: int = actod.SYSTEM_CONFIG.actor_registry_size,
	allow_registry_growth: bool = actod.SYSTEM_CONFIG.allow_registry_growth,
	enable_observer: bool = actod.SYSTEM_CONFIG.enable_observer,
	observer_interval: time.Duration = actod.SYSTEM_CONFIG.observer_interval,
	network: Network_Config = actod.SYSTEM_CONFIG.network,
	actor_config: Actor_Config = actod.SYSTEM_CONFIG.actor_config,
	blocking_child: SPAWN = actod.SYSTEM_CONFIG.blocking_child,
	worker_count: int = actod.SYSTEM_CONFIG.worker_count,
	hot_reload_dev: bool = actod.SYSTEM_CONFIG.hot_reload_dev,
	hot_reload_watch_path: string = actod.SYSTEM_CONFIG.hot_reload_watch_path,
) -> System_Config {
	return actod.make_node_config(
		actor_registry_size,
		allow_registry_growth,
		enable_observer,
		observer_interval,
		network,
		actor_config,
		blocking_child,
		worker_count,
		hot_reload_dev,
		hot_reload_watch_path,
	)
}

// Build an Actor_Config for spawn / spawn_child / spawn_agent.
make_actor_config :: proc(
	children: [dynamic]SPAWN = nil,
	spin_strategy: SPIN_STRATEGY = actod.SYSTEM_CONFIG.actor_config.spin_strategy,
	logging: Log_Config = actod.SYSTEM_CONFIG.actor_config.logging,
	message_batch: int = actod.SYSTEM_CONFIG.actor_config.message_batch,
	page_size: int = actod.SYSTEM_CONFIG.actor_config.page_size,
	supervision_strategy: Supervision_Strategy = actod.SYSTEM_CONFIG.actor_config.supervision_strategy,
	restart_policy: Restart_Policy = actod.SYSTEM_CONFIG.actor_config.restart_policy,
	max_restarts: int = actod.SYSTEM_CONFIG.actor_config.max_restarts,
	restart_window: time.Duration = actod.SYSTEM_CONFIG.actor_config.restart_window,
	home_worker: int = actod.SYSTEM_CONFIG.actor_config.home_worker,
	affinity: Actor_Ref = actod.SYSTEM_CONFIG.actor_config.affinity,
	coro_stack_size: int = actod.SYSTEM_CONFIG.actor_config.coro_stack_size,
	use_dedicated_os_thread: bool = actod.SYSTEM_CONFIG.actor_config.use_dedicated_os_thread,
	stack_size_dedicated_os_thread: int = actod.SYSTEM_CONFIG.actor_config.stack_size_dedicated_os_thread,
) -> Actor_Config {
	return actod.make_actor_config(
		children,
		spin_strategy,
		logging,
		message_batch,
		page_size,
		supervision_strategy,
		restart_policy,
		max_restarts,
		restart_window,
		home_worker,
		affinity,
		coro_stack_size,
		use_dedicated_os_thread,
		stack_size_dedicated_os_thread,
	)
}

// Build a Network_Config. `port = 0` disables networking.
make_network_config :: proc(
	auth_password: string = actod.DEFAULT_NETWORK_CONFIG.auth_password,
	port: int = actod.DEFAULT_NETWORK_CONFIG.port,
	heartbeat_interval: time.Duration = actod.DEFAULT_NETWORK_CONFIG.heartbeat_interval,
	heartbeat_timeout: time.Duration = actod.DEFAULT_NETWORK_CONFIG.heartbeat_timeout,
	reconnect_initial_delay: time.Duration = actod.DEFAULT_NETWORK_CONFIG.reconnect_initial_delay,
	reconnect_retry_delay: time.Duration = actod.DEFAULT_NETWORK_CONFIG.reconnect_retry_delay,
	connection_ring: Connection_Ring_Config = actod.DEFAULT_NETWORK_CONFIG.connection_ring,
) -> Network_Config {
	return actod.make_network_config(
		auth_password,
		port,
		heartbeat_interval,
		heartbeat_timeout,
		reconnect_initial_delay,
		reconnect_retry_delay,
		connection_ring,
	)
}

// Build a Log_Config for Actor_Config.logging.
make_log_config :: proc(
	level: Log_Level = actod.SYSTEM_CONFIG.actor_config.logging.level,
	console_opts: Log_Options = actod.SYSTEM_CONFIG.actor_config.logging.console_opts,
	file_opts: Log_Options = actod.SYSTEM_CONFIG.actor_config.logging.file_opts,
	ident: string = actod.SYSTEM_CONFIG.actor_config.logging.ident,
	enable_file: bool = actod.SYSTEM_CONFIG.actor_config.logging.enable_file,
	log_path: string = actod.SYSTEM_CONFIG.actor_config.logging.log_path,
	custom_logger: Log_Callback = actod.SYSTEM_CONFIG.actor_config.logging.custom_logger,
	custom_flush: Log_Flush = actod.SYSTEM_CONFIG.actor_config.logging.custom_flush,
) -> Log_Config {
	return actod.make_log_config(
		level,
		console_opts,
		file_opts,
		ident,
		enable_file,
		log_path,
		custom_logger,
		custom_flush,
	)
}

// Assemble a `[dynamic]SPAWN` from varargs for Actor_Config.children.
make_children :: proc(spawns: ..SPAWN) -> [dynamic]SPAWN {
	return actod.make_children(..spawns)
}
