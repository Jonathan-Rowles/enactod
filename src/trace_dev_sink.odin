package enactod_impl

import "../pkgs/actod"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"

Dev_Trace_Config :: struct {
	stdout:     bool,
	color:      bool,
	jsonl_path: string,
	md_dir:     string,
	verbose:    bool,
}

Dev_Trace_Request_Buffer :: struct {
	events: [dynamic]Trace_Event,
	start:  time.Time,
}

Dev_Trace_State :: struct {
	config:        Dev_Trace_Config,
	jsonl_handle:  ^os.File,
	open_requests: map[Request_ID]Dev_Trace_Request_Buffer,
}

dev_trace_sink_behaviour :: actod.Actor_Behaviour(Dev_Trace_State) {
	init           = dev_trace_sink_init,
	handle_message = dev_trace_sink_handle_message,
	terminate      = dev_trace_sink_terminate,
}

dev_trace_sink_init :: proc(data: ^Dev_Trace_State) {
	data.open_requests = make(map[Request_ID]Dev_Trace_Request_Buffer)
	if len(data.config.jsonl_path) > 0 {
		handle, err := os.open(
			data.config.jsonl_path,
			os.O_WRONLY | os.O_CREATE | os.O_APPEND,
			os.perm_number(0o644),
		)
		if err == os.ERROR_NONE {
			data.jsonl_handle = handle
		} else {
			log.errorf("dev_trace_sink: failed to open %s: %v", data.config.jsonl_path, err)
		}
	}
	if len(data.config.md_dir) > 0 && !os.exists(data.config.md_dir) {
		if err := os.make_directory(data.config.md_dir); err != os.ERROR_NONE {
			log.warnf("dev_trace_sink: make_directory %s: %v", data.config.md_dir, err)
		}
	}
}

dev_trace_sink_terminate :: proc(data: ^Dev_Trace_State) {
	if data.jsonl_handle != nil {
		os.close(data.jsonl_handle)
		data.jsonl_handle = nil
	}
}

dev_trace_sink_handle_message :: proc(data: ^Dev_Trace_State, from: actod.PID, content: any) {
	switch msg in content {
	case Trace_Event:
		dev_trace_handle_event(data, msg)
	}
}

dev_trace_handle_event :: proc(data: ^Dev_Trace_State, ev: Trace_Event) {
	if ev.kind == .REQUEST_START && len(data.config.md_dir) > 0 {
		data.open_requests[ev.request_id] = Dev_Trace_Request_Buffer {
			events = make([dynamic]Trace_Event),
			start = time.Time{_nsec = ev.timestamp_ns},
		}
	}

	if data.config.stdout {
		dev_trace_print_stdout(data, ev)
	}
	if data.jsonl_handle != nil {
		dev_trace_append_jsonl(data, ev)
	}
	if len(data.config.md_dir) > 0 {
		if buf, ok := &data.open_requests[ev.request_id]; ok {
			append(&buf.events, persist_trace_event(ev))
		}
	}

	if ev.kind == .REQUEST_END && len(data.config.md_dir) > 0 {
		if buf, ok := &data.open_requests[ev.request_id]; ok {
			dev_trace_flush_md(data, ev.request_id, buf^)
			delete(buf.events)
			delete_key(&data.open_requests, ev.request_id)
		}
	}
}

@(private = "file")
dev_trace_print_stdout :: proc(data: ^Dev_Trace_State, ev: Trace_Event) {
	ts := time.Time {
		_nsec = ev.timestamp_ns,
	}
	h, m, s := time.clock(ts)
	ms := (ev.timestamp_ns / 1_000_000) % 1000

	color_on, color_off: string
	if data.config.color {
		color_on = dev_trace_color_for(ev.kind)
		color_off = "\x1b[0m"
	}

	kind_str := dev_trace_kind_string(ev.kind)
	agent := resolve(ev.agent_name)

	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&sb,
		"%s[%02d:%02d:%02d.%03d]%s %sagent:%s req=%d%s",
		color_on,
		h,
		m,
		s,
		ms,
		color_off,
		color_on,
		agent,
		ev.request_id,
		color_off,
	)
	if ev.turn > 0 ||
	   ev.kind == .LLM_CALL_START ||
	   ev.kind == .LLM_CALL_DONE ||
	   ev.kind == .TOOL_CALL_START ||
	   ev.kind == .TOOL_CALL_DONE {
		fmt.sbprintf(&sb, " turn=%d", ev.turn)
	}
	fmt.sbprintf(&sb, " %s%-21s%s", color_on, kind_str, color_off)

	#partial switch ev.kind {
	case .LLM_CALL_START:
		fmt.sbprintf(&sb, " model=%s provider=%s", resolve(ev.model), resolve(ev.provider))
	case .LLM_CALL_DONE:
		fmt.sbprintf(
			&sb,
			" tokens=%d/%d dur=%dms status=%d",
			ev.input_tokens,
			ev.output_tokens,
			ev.duration_ns / 1_000_000,
			ev.status_code,
		)
		if ev.cache_read_tokens > 0 || ev.cache_creation_tokens > 0 {
			fmt.sbprintf(
				&sb,
				" cache_r=%d cache_c=%d",
				ev.cache_read_tokens,
				ev.cache_creation_tokens,
			)
		}
	case .TOOL_CALL_START:
		fmt.sbprintf(&sb, " tool=%s call=%s", resolve(ev.tool_name), resolve(ev.call_id))
		if data.config.verbose {
			fmt.sbprintf(&sb, " args=%s", resolve(ev.detail))
		}
	case .TOOL_CALL_DONE:
		fmt.sbprintf(&sb, " tool=%s dur=%dms", resolve(ev.tool_name), ev.duration_ns / 1_000_000)
		if ev.is_error {
			fmt.sbprint(&sb, " ERR")
		}
		if data.config.verbose {
			fmt.sbprintf(&sb, " result=%s", truncate(resolve(ev.detail), 200))
		}
	case .THINKING_DONE:
		fmt.sbprintf(&sb, " chars=%d", len(resolve(ev.detail)))
	case .REQUEST_END:
		fmt.sbprintf(
			&sb,
			" tokens=%d/%d dur=%dms",
			ev.input_tokens,
			ev.output_tokens,
			ev.duration_ns / 1_000_000,
		)
		if ev.is_error {
			fmt.sbprint(&sb, " ERR")
		}
	case .RATE_LIMIT_QUEUED, .RATE_LIMIT_RETRYING, .RATE_LIMIT_PROCESSING:
		fmt.sbprintf(&sb, " queue=%d", ev.queue_depth)
		if ev.retry_count > 0 {
			fmt.sbprintf(&sb, " retry=%d delay=%dms", ev.retry_count, ev.retry_delay_ms)
		}
	}

	fmt.sbprint(&sb, "\n")
	os.write_string(os.stdout, strings.to_string(sb))
}

@(private = "file")
dev_trace_append_jsonl :: proc(data: ^Dev_Trace_State, ev: Trace_Event) {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprint(&sb, "{")
	fmt.sbprintf(&sb, `"kind":"%s"`, dev_trace_kind_string(ev.kind))
	fmt.sbprintf(&sb, `,"request_id":%d`, ev.request_id)
	if ev.parent_request_id != 0 {
		fmt.sbprintf(&sb, `,"parent_request_id":%d`, ev.parent_request_id)
	}
	dev_trace_json_string(&sb, "agent_name", resolve(ev.agent_name))
	fmt.sbprintf(&sb, `,"turn":%d`, ev.turn)
	fmt.sbprintf(&sb, `,"timestamp_ns":%d`, ev.timestamp_ns)
	if ev.duration_ns > 0 {
		fmt.sbprintf(&sb, `,"duration_ns":%d`, ev.duration_ns)
	}
	if call_id_s := resolve(ev.call_id); len(call_id_s) > 0 {
		dev_trace_json_string(&sb, "call_id", call_id_s)
	}
	if tool_name_s := resolve(ev.tool_name); len(tool_name_s) > 0 {
		dev_trace_json_string(&sb, "tool_name", tool_name_s)
	}
	if model_s := resolve(ev.model); len(model_s) > 0 {
		dev_trace_json_string(&sb, "model", model_s)
	}
	if provider_s := resolve(ev.provider); len(provider_s) > 0 {
		dev_trace_json_string(&sb, "provider", provider_s)
	}
	if detail_s := resolve(ev.detail); len(detail_s) > 0 {
		dev_trace_json_string(&sb, "detail", detail_s)
	}
	if ev.input_tokens > 0 {fmt.sbprintf(&sb, `,"input_tokens":%d`, ev.input_tokens)}
	if ev.output_tokens > 0 {fmt.sbprintf(&sb, `,"output_tokens":%d`, ev.output_tokens)}
	if ev.cache_creation_tokens > 0 {
		fmt.sbprintf(&sb, `,"cache_creation_tokens":%d`, ev.cache_creation_tokens)
	}
	if ev.cache_read_tokens > 0 {
		fmt.sbprintf(&sb, `,"cache_read_tokens":%d`, ev.cache_read_tokens)
	}
	if ev.status_code > 0 {fmt.sbprintf(&sb, `,"status_code":%d`, ev.status_code)}
	if ev.is_error {fmt.sbprint(&sb, `,"is_error":true`)}
	if ev.retry_count > 0 {fmt.sbprintf(&sb, `,"retry_count":%d`, ev.retry_count)}
	if ev.retry_delay_ms > 0 {fmt.sbprintf(&sb, `,"retry_delay_ms":%d`, ev.retry_delay_ms)}
	if ev.queue_depth > 0 {fmt.sbprintf(&sb, `,"queue_depth":%d`, ev.queue_depth)}
	fmt.sbprint(&sb, "}\n")

	line := strings.to_string(sb)
	if _, err := os.write_string(data.jsonl_handle, line); err != os.ERROR_NONE {
		log.errorf("dev_trace_sink: jsonl write failed: %v", err)
	}
}

@(private = "file")
dev_trace_flush_md :: proc(
	data: ^Dev_Trace_State,
	request_id: Request_ID,
	buf: Dev_Trace_Request_Buffer,
) {
	if len(buf.events) == 0 {
		return
	}
	agent := resolve(buf.events[0].agent_name)
	path := fmt.tprintf("%s/%s-%d.md", data.config.md_dir, agent, request_id)

	sb := strings.builder_make(context.temp_allocator)
	end_ev := buf.events[len(buf.events) - 1]

	fmt.sbprintf(&sb, "# Request %d — agent:%s\n\n", request_id, agent)
	if end_ev.parent_request_id != 0 {
		fmt.sbprintf(&sb, "**Parent request:** %d  \n", end_ev.parent_request_id)
	} else {
		fmt.sbprint(&sb, "**Parent request:** (top-level)  \n")
	}
	if start_ev := buf.events[0]; start_ev.kind == .REQUEST_START {
		if q := resolve(start_ev.detail); len(q) > 0 {
			fmt.sbprintf(&sb, "**User input:**\n\n```\n%s\n```\n\n", q)
		}
	}
	fmt.sbprintf(&sb, "**Duration:** %dms  \n", end_ev.duration_ns / 1_000_000)
	fmt.sbprintf(
		&sb,
		"**Tokens:** input=%d output=%d cache_creation=%d cache_read=%d  \n",
		end_ev.input_tokens,
		end_ev.output_tokens,
		end_ev.cache_creation_tokens,
		end_ev.cache_read_tokens,
	)
	if end_ev.is_error {
		fmt.sbprintf(&sb, "**Status:** ERROR — %s\n\n", resolve(end_ev.detail))
	} else {
		fmt.sbprint(&sb, "**Status:** success\n\n")
	}

	fmt.sbprint(&sb, "## Events\n\n")
	for ev in buf.events {
		fmt.sbprintf(&sb, "### %s — turn %d\n\n", dev_trace_kind_string(ev.kind), ev.turn)
		#partial switch ev.kind {
		case .LLM_CALL_START:
			fmt.sbprintf(
				&sb,
				"- **Model:** %s\n- **Provider:** %s\n\n",
				resolve(ev.model),
				resolve(ev.provider),
			)
		case .LLM_CALL_DONE:
			fmt.sbprintf(
				&sb,
				"- **Duration:** %dms\n- **Tokens:** in=%d out=%d\n- **Status:** %d\n\n",
				ev.duration_ns / 1_000_000,
				ev.input_tokens,
				ev.output_tokens,
				ev.status_code,
			)
			if detail_s := resolve(ev.detail); len(detail_s) > 0 {
				fmt.sbprintf(&sb, "```\n%s\n```\n\n", detail_s)
			}
		case .TOOL_CALL_START:
			fmt.sbprintf(
				&sb,
				"- **Tool:** %s\n- **Call ID:** %s\n- **Args:** `%s`\n\n",
				resolve(ev.tool_name),
				resolve(ev.call_id),
				resolve(ev.detail),
			)
		case .TOOL_CALL_DONE:
			fmt.sbprintf(
				&sb,
				"- **Tool:** %s\n- **Duration:** %dms\n- **Error:** %v\n",
				resolve(ev.tool_name),
				ev.duration_ns / 1_000_000,
				ev.is_error,
			)
			if detail_s := resolve(ev.detail); len(detail_s) > 0 {
				fmt.sbprintf(&sb, "\n```\n%s\n```\n\n", detail_s)
			}
		case .THINKING_DONE:
			if detail_s := resolve(ev.detail); len(detail_s) > 0 {
				fmt.sbprintf(&sb, "```\n%s\n```\n\n", detail_s)
			}
		case .RATE_LIMIT_QUEUED, .RATE_LIMIT_RETRYING, .RATE_LIMIT_PROCESSING:
			fmt.sbprintf(
				&sb,
				"- **Queue depth:** %d\n- **Retry:** %d (delay %dms)\n\n",
				ev.queue_depth,
				ev.retry_count,
				ev.retry_delay_ms,
			)
		case .REQUEST_START:
			fmt.sbprint(&sb, "\n")
		case .REQUEST_END:
			fmt.sbprint(&sb, "\n")
		case:
			fmt.sbprint(&sb, "\n")
		}
	}

	if err := os.write_entire_file(path, transmute([]byte)strings.to_string(sb));
	   err != os.ERROR_NONE {
		log.errorf("dev_trace_sink: failed to write %s: %v", path, err)
	}
}

persist_trace_event :: proc(ev: Trace_Event) -> Trace_Event {
	out := ev
	out.agent_name = persist_text(ev.agent_name)
	out.call_id = persist_text(ev.call_id)
	out.tool_name = persist_text(ev.tool_name)
	out.model = persist_text(ev.model)
	out.provider = persist_text(ev.provider)
	out.detail = persist_text(ev.detail)
	return out
}

@(private = "file")
dev_trace_kind_string :: proc(kind: Trace_Event_Kind) -> string {
	switch kind {
	case .REQUEST_START:
		return "REQUEST_START"
	case .REQUEST_END:
		return "REQUEST_END"
	case .LLM_CALL_START:
		return "LLM_CALL_START"
	case .LLM_CALL_DONE:
		return "LLM_CALL_DONE"
	case .TOOL_CALL_START:
		return "TOOL_CALL_START"
	case .TOOL_CALL_DONE:
		return "TOOL_CALL_DONE"
	case .THINKING_DONE:
		return "THINKING_DONE"
	case .RATE_LIMIT_QUEUED:
		return "RATE_LIMIT_QUEUED"
	case .RATE_LIMIT_RETRYING:
		return "RATE_LIMIT_RETRYING"
	case .RATE_LIMIT_PROCESSING:
		return "RATE_LIMIT_PROCESSING"
	case .ERROR:
		return "ERROR"
	}
	return "UNKNOWN"
}

@(private = "file")
dev_trace_color_for :: proc(kind: Trace_Event_Kind) -> string {
	#partial switch kind {
	case .REQUEST_START, .REQUEST_END:
		return "\x1b[36m" // cyan
	case .LLM_CALL_START, .LLM_CALL_DONE:
		return "\x1b[32m" // green
	case .TOOL_CALL_START, .TOOL_CALL_DONE:
		return "\x1b[33m" // yellow
	case .THINKING_DONE:
		return "\x1b[35m" // magenta
	case .RATE_LIMIT_QUEUED, .RATE_LIMIT_RETRYING, .RATE_LIMIT_PROCESSING:
		return "\x1b[34m" // blue
	case .ERROR:
		return "\x1b[31m" // red
	}
	return ""
}

@(private = "file")
dev_trace_json_string :: proc(sb: ^strings.Builder, key: string, value: string) {
	fmt.sbprintf(sb, `,"%s":"`, key)
	for r in value {
		switch r {
		case '"':
			fmt.sbprint(sb, `\"`)
		case '\\':
			fmt.sbprint(sb, `\\`)
		case '\n':
			fmt.sbprint(sb, `\n`)
		case '\r':
			fmt.sbprint(sb, `\r`)
		case '\t':
			fmt.sbprint(sb, `\t`)
		case:
			if r < 0x20 {
				fmt.sbprintf(sb, `\u%04x`, r)
			} else {
				fmt.sbprint(sb, r)
			}
		}
	}
	fmt.sbprint(sb, `"`)
}

@(private = "file")
truncate :: proc(s: string, max: int) -> string {
	if len(s) <= max {
		return s
	}
	return fmt.tprintf("%s…(%d more)", s[:max], len(s) - max)
}

dev_trace_sink :: proc(name: string, config: Dev_Trace_Config = {}) -> Trace_Sink {
	cfg := config
	if !cfg.stdout && len(cfg.jsonl_path) == 0 && len(cfg.md_dir) == 0 {
		cfg.stdout = true
	}
	if g_dev_trace_configs == nil {
		g_dev_trace_configs = make(map[string]Dev_Trace_Config)
	}
	if existing, present := g_dev_trace_configs[name]; present && existing != cfg {
		log.warnf(
			"dev_trace_sink: '%s' already registered with different config — keeping first",
			name,
		)
	} else {
		g_dev_trace_configs[name] = cfg
	}
	return custom_trace_sink(name, dev_trace_spawn_proc)
}

@(private = "file")
g_dev_trace_configs: map[string]Dev_Trace_Config

@(private = "file")
dev_trace_spawn_proc :: proc(name: string, parent: actod.PID) -> (actod.PID, bool) {
	cfg := g_dev_trace_configs[name]
	return actod.spawn(
		name,
		Dev_Trace_State{config = cfg},
		dev_trace_sink_behaviour,
		actod.make_actor_config(),
		parent,
	)
}

spawn_dev_trace_sink_actor :: proc(
	name: string,
	config: Dev_Trace_Config = {},
) -> (
	actod.PID,
	bool,
) {
	cfg := config
	if !cfg.stdout && len(cfg.jsonl_path) == 0 && len(cfg.md_dir) == 0 {
		cfg.stdout = true
	}
	return actod.spawn_child(name, Dev_Trace_State{config = cfg}, dev_trace_sink_behaviour)
}
