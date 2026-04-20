// Reference OTLP (OpenTelemetry Protocol) trace exporter.
//
// Demonstrates how a production trace sink maps enactod's Trace_Event to
// OTel-compatible spans with gen_ai.* attributes. This example writes one
// OTLP JSON file per request to ./otlp/<agent>-<req>.json — swap
// write_entire_file for a POST to http://localhost:4318/v1/traces to ship
// to a real collector (Jaeger, Grafana Tempo, Honeycomb, Langfuse, etc.).
//
// Span hierarchy:
//   agent.request  (root, from REQUEST_START/END)
//   ├── gen_ai.chat      (per LLM turn, from LLM_CALL_START/DONE)
//   └── tool.call        (per tool invocation, from TOOL_CALL_START/DONE)
//
// Sub-agent calls nest naturally: the inner agent's REQUEST_START carries
// parent_request_id, which this sink uses to stamp parent_span_id.
package main

import enact "../.."
import "../../pkgs/ojson"
import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

Span_ID :: [8]u8
Trace_ID :: [16]u8

OTLP_Span :: struct {
	name:           string,
	trace_id:       Trace_ID,
	span_id:        Span_ID,
	parent_span_id: Span_ID,
	start_ns:       i64,
	end_ns:         i64,
	attrs:          [dynamic]OTLP_Attr,
	is_error:       bool,
	error_msg:      string,
}

OTLP_Attr :: struct {
	key:   string,
	value: string, // all serialised as stringValue for simplicity
}

Request_State :: struct {
	trace_id:       Trace_ID,
	root_span:      Span_ID,
	open_llm_idx:   Maybe(int), // nil == none open; value == index into spans
	open_tools:     map[string]int, // call_id -> span index in `spans`
	spans:          [dynamic]OTLP_Span,
	parent_request: enact.Request_ID,
}

OTLP_Sink_State :: struct {
	// Map child request_id -> parent's trace_id so sub-agents join the parent trace.
	parent_traces: map[enact.Request_ID]Trace_ID,
	parent_roots:  map[enact.Request_ID]Span_ID,
	open:          map[enact.Request_ID]Request_State,
}

otlp_sink_behaviour :: enact.Actor_Behaviour(OTLP_Sink_State) {
	init           = otlp_sink_init,
	handle_message = otlp_sink_handle,
}

otlp_sink_init :: proc(data: ^OTLP_Sink_State) {
	data.parent_traces = make(map[enact.Request_ID]Trace_ID)
	data.parent_roots = make(map[enact.Request_ID]Span_ID)
	data.open = make(map[enact.Request_ID]Request_State)
	os.make_directory("./otlp")
}

otlp_sink_handle :: proc(data: ^OTLP_Sink_State, from: enact.PID, msg: any) {
	ev, ok := msg.(enact.Trace_Event)
	if !ok {
		return
	}

	#partial switch ev.kind {
	case .REQUEST_START:
		req := Request_State{}
		req.open_tools = make(map[string]int)
		req.spans = make([dynamic]OTLP_Span)
		req.parent_request = ev.parent_request_id

		if ev.parent_request_id != 0 {
			if pt, pok := data.parent_traces[ev.parent_request_id]; pok {
				req.trace_id = pt
			} else {
				rand_bytes(req.trace_id[:])
			}
		} else {
			rand_bytes(req.trace_id[:])
		}
		rand_bytes(req.root_span[:])

		parent_span: Span_ID
		if ev.parent_request_id != 0 {
			parent_span = data.parent_roots[ev.parent_request_id]
		}

		root := OTLP_Span {
			name           = "agent.request",
			trace_id       = req.trace_id,
			span_id        = req.root_span,
			parent_span_id = parent_span,
			start_ns       = ev.timestamp_ns,
			attrs          = make([dynamic]OTLP_Attr),
		}
		append(
			&root.attrs,
			OTLP_Attr{"agent.name", strings.clone(enact.resolve(ev.agent_name))},
			OTLP_Attr{"agent.request_id", fmt.aprintf("%d", ev.request_id)},
		)
		if input := enact.resolve(ev.detail); len(input) > 0 {
			append(&root.attrs, OTLP_Attr{"agent.user_input", strings.clone(input)})
		}
		append(&req.spans, root)

		data.parent_traces[ev.request_id] = req.trace_id
		data.parent_roots[ev.request_id] = req.root_span
		data.open[ev.request_id] = req

	case .LLM_CALL_START:
		req, rok := &data.open[ev.request_id]
		if !rok {
			return
		}
		span_id: Span_ID
		rand_bytes(span_id[:])
		span := OTLP_Span {
			name           = "gen_ai.chat",
			trace_id       = req.trace_id,
			span_id        = span_id,
			parent_span_id = req.root_span,
			start_ns       = ev.timestamp_ns,
			attrs          = make([dynamic]OTLP_Attr),
		}
		append(
			&span.attrs,
			OTLP_Attr{"gen_ai.system", strings.clone(enact.resolve(ev.provider))},
			OTLP_Attr{"gen_ai.request.model", strings.clone(enact.resolve(ev.model))},
			OTLP_Attr{"gen_ai.turn", fmt.aprintf("%d", ev.turn)},
		)
		append(&req.spans, span)
		req.open_llm_idx = len(req.spans) - 1

	case .LLM_CALL_DONE:
		req, rok := &data.open[ev.request_id]
		if !rok {
			return
		}
		idx, open := req.open_llm_idx.?
		if !open {
			return
		}
		s := &req.spans[idx]
		s.end_ns = ev.timestamp_ns
		append(
			&s.attrs,
			OTLP_Attr{"gen_ai.usage.input_tokens", fmt.aprintf("%d", ev.input_tokens)},
			OTLP_Attr{"gen_ai.usage.output_tokens", fmt.aprintf("%d", ev.output_tokens)},
			OTLP_Attr{"http.status_code", fmt.aprintf("%d", ev.status_code)},
		)
		req.open_llm_idx = nil

	case .TOOL_CALL_START:
		req, rok := &data.open[ev.request_id]
		if !rok {
			return
		}
		span_id: Span_ID
		rand_bytes(span_id[:])
		span := OTLP_Span {
			name           = "tool.call",
			trace_id       = req.trace_id,
			span_id        = span_id,
			parent_span_id = req.root_span,
			start_ns       = ev.timestamp_ns,
			attrs          = make([dynamic]OTLP_Attr),
		}
		append(
			&span.attrs,
			OTLP_Attr{"tool.name", strings.clone(enact.resolve(ev.tool_name))},
			OTLP_Attr{"tool.call_id", strings.clone(enact.resolve(ev.call_id))},
		)
		if args := enact.resolve(ev.detail); len(args) > 0 {
			append(&span.attrs, OTLP_Attr{"tool.arguments", strings.clone(args)})
		}
		append(&req.spans, span)
		req.open_tools[strings.clone(enact.resolve(ev.call_id))] = len(req.spans) - 1

	case .TOOL_CALL_DONE:
		req, rok := &data.open[ev.request_id]
		if !rok {
			return
		}
		call_id_s := enact.resolve(ev.call_id)
		idx, tok := req.open_tools[call_id_s]
		if !tok {
			return
		}
		s := &req.spans[idx]
		s.end_ns = ev.timestamp_ns
		s.is_error = ev.is_error
		if ev.is_error {
			s.error_msg = strings.clone(enact.resolve(ev.detail))
		}
		delete_key(&req.open_tools, call_id_s)

	case .REQUEST_END:
		req, rok := &data.open[ev.request_id]
		if !rok {
			return
		}
		root := &req.spans[0]
		root.end_ns = ev.timestamp_ns
		root.is_error = ev.is_error
		if ev.is_error {
			root.error_msg = strings.clone(enact.resolve(ev.detail))
		}
		append(
			&root.attrs,
			OTLP_Attr{"gen_ai.usage.input_tokens", fmt.aprintf("%d", ev.input_tokens)},
			OTLP_Attr{"gen_ai.usage.output_tokens", fmt.aprintf("%d", ev.output_tokens)},
		)

		flush_trace(enact.resolve(ev.agent_name), ev.request_id, req^)

		for k in req.open_tools {
			delete(k)
		}
		delete(req.open_tools)
		delete(req.spans)
		delete_key(&data.open, ev.request_id)
		delete_key(&data.parent_traces, ev.request_id)
		delete_key(&data.parent_roots, ev.request_id)
	}
}

flush_trace :: proc(agent_name: string, request_id: enact.Request_ID, req: Request_State) {
	w := ojson.init_writer()
	defer ojson.destroy_writer(&w)

	// { resourceSpans: [ { resource: {...}, scopeSpans: [ { scope, spans: [...] } ] } ] }
	ojson.write_object_start(&w)
	ojson.write_key(&w, "resourceSpans")
	ojson.write_array_start(&w)
	ojson.write_object_start(&w)

	ojson.write_key(&w, "resource")
	ojson.write_object_start(&w)
	ojson.write_key(&w, "attributes")
	ojson.write_array_start(&w)
	write_string_attr(&w, "service.name", "enactod-example")
	ojson.write_array_end(&w)
	ojson.write_object_end(&w)

	ojson.write_key(&w, "scopeSpans")
	ojson.write_array_start(&w)
	ojson.write_object_start(&w)
	ojson.write_key(&w, "scope")
	ojson.write_object_start(&w)
	ojson.write_key(&w, "name")
	ojson.write_string(&w, "enactod")
	ojson.write_object_end(&w)
	ojson.write_key(&w, "spans")
	ojson.write_array_start(&w)
	for _, i in req.spans {
		emit_span(&w, &req.spans[i])
	}
	ojson.write_array_end(&w)
	ojson.write_object_end(&w)
	ojson.write_array_end(&w)

	ojson.write_object_end(&w)
	ojson.write_array_end(&w)
	ojson.write_object_end(&w)

	path := fmt.tprintf("./otlp/%s-%d.json", agent_name, request_id)
	_ = os.write_entire_file(path, transmute([]byte)ojson.writer_string(&w))
	fmt.printfln("[otlp] wrote %s (%d spans)", path, len(req.spans))
}

emit_span :: proc(w: ^ojson.Writer, span: ^OTLP_Span) {
	ojson.write_object_start(w)

	tid := span.trace_id
	sid := span.span_id
	ojson.write_key(w, "traceId")
	ojson.write_string(w, hex_string(tid[:]))
	ojson.write_key(w, "spanId")
	ojson.write_string(w, hex_string(sid[:]))
	if span.parent_span_id != (Span_ID{}) {
		psid := span.parent_span_id
		ojson.write_key(w, "parentSpanId")
		ojson.write_string(w, hex_string(psid[:]))
	}
	ojson.write_key(w, "name")
	ojson.write_string(w, span.name)
	ojson.write_key(w, "kind")
	ojson.write_int(w, 1) // INTERNAL
	ojson.write_key(w, "startTimeUnixNano")
	ojson.write_string(w, fmt.tprintf("%d", span.start_ns)) // OTLP encodes nanos as strings
	ojson.write_key(w, "endTimeUnixNano")
	ojson.write_string(w, fmt.tprintf("%d", span.end_ns))

	ojson.write_key(w, "attributes")
	ojson.write_array_start(w)
	for attr in span.attrs {
		write_string_attr(w, attr.key, attr.value)
	}
	ojson.write_array_end(w)

	if span.is_error {
		ojson.write_key(w, "status")
		ojson.write_object_start(w)
		ojson.write_key(w, "code")
		ojson.write_int(w, 2) // STATUS_CODE_ERROR
		ojson.write_key(w, "message")
		ojson.write_string(w, span.error_msg)
		ojson.write_object_end(w)
	}

	ojson.write_object_end(w)
}

write_string_attr :: proc(w: ^ojson.Writer, key: string, value: string) {
	ojson.write_object_start(w)
	ojson.write_key(w, "key")
	ojson.write_string(w, key)
	ojson.write_key(w, "value")
	ojson.write_object_start(w)
	ojson.write_key(w, "stringValue")
	ojson.write_string(w, value)
	ojson.write_object_end(w)
	ojson.write_object_end(w)
}

hex_string :: proc(bytes: []byte) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for b in bytes {
		fmt.sbprintf(&sb, "%02x", b)
	}
	return strings.to_string(sb)
}

rand_bytes :: proc(out: []byte) {
	for i in 0 ..< len(out) {
		out[i] = u8(rand.uint32())
	}
}

// -----------------------------------------------------------------------------
// Demo wiring
// -----------------------------------------------------------------------------

done: sync.Sema

get_time_tool :: proc(arguments: string, allocator: mem.Allocator) -> (string, bool) {
	now := time.now()
	y, mon, d := time.date(now)
	h, min, s := time.clock(now)
	return fmt.aprintf(
			"%d-%02d-%02d %02d:%02d:%02d",
			y,
			int(mon),
			d,
			h,
			min,
			s,
			allocator = allocator,
		),
		false
}

Client_State :: struct {
	session: enact.Session,
}

client_behaviour :: enact.Actor_Behaviour(Client_State) {
	init = proc(data: ^Client_State) {
		enact.session_send(&data.session, "What time is it? Use the get_time tool.")
	},
	handle_message = proc(data: ^Client_State, from: enact.PID, content: any) {
		if msg, ok := content.(enact.Agent_Response); ok {
			fmt.printfln("\nResponse: %s", enact.resolve(msg.content))
			sync.sema_post(&done)
		}
	},
}

agent_config: enact.Agent_Config

// Lazy-spawned by the agent via custom_trace_sink. Registers the actor
// under the name the framework passes in (must match the sink name on
// Agent_Config.trace_sink).
otlp_sink_spawn :: proc(name: string, parent: enact.PID) -> (enact.PID, bool) {
	return enact.spawn(name, OTLP_Sink_State{}, otlp_sink_behaviour)
}

spawn_agent_demo :: proc(_: string, _: enact.PID) -> (enact.PID, bool) {
	sess, ok := enact.spawn_agent("demo", agent_config)
	return sess.pid, ok
}

spawn_client :: proc(_: string, _: enact.PID) -> (enact.PID, bool) {
	return enact.spawn_child(
		"client",
		Client_State{session = enact.make_session("demo")},
		client_behaviour,
	)
}

main :: proc() {
	api_key := os.get_env_alloc("ANTHROPIC_API_KEY", context.allocator)
	if len(api_key) == 0 {
		fmt.println("Set ANTHROPIC_API_KEY")
		return
	}

	tools := []enact.Tool {
		enact.function_tool(
			enact.Tool_Def {
				name = "get_time",
				description = "Get the current date and time",
				input_schema = `{"type":"object","properties":{}}`,
			},
			get_time_tool,
		),
	}

	agent_config = enact.make_agent_config(
		llm = enact.anthropic(api_key, enact.Model.Claude_Sonnet_4_5),
		tools = tools,
		worker_count = 1,
		trace_sink = enact.custom_trace_sink("otlp", otlp_sink_spawn),
	)

	enact.NODE_INIT(
		"enactod-otlp",
		enact.make_node_config(
			actor_config = enact.make_actor_config(
				children = enact.make_children(spawn_agent_demo, spawn_client),
			),
		),
	)

	sync.sema_wait(&done)
	enact.SHUTDOWN_NODE()
}
