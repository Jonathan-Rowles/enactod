package enactod_impl

import "../pkgs/actod"
import "../pkgs/ojson"
import "core:fmt"
import "core:hash"
import "core:log"
import vmem "core:mem/virtual"
import "core:strings"
import "core:time"
import "wire"

Agent_Phase :: enum {
	IDLE,
	AWAITING_LLM,
	AWAITING_STREAM,
	AWAITING_TOOLS,
	AWAITING_COMPACT,
}

Stream_Tool_Accum :: struct {
	id:    Text,
	name:  Text,
	input: strings.Builder,
}

Agent_State :: struct {
	config:                      Agent_Config,
	agent_name:                  string,
	phase:                       Agent_Phase,
	current_req:                 Request_ID,
	parent_request_id:           Request_ID,
	caller_pid:                  actod.PID,
	claimed_by:                  actod.PID,
	turn:                        int,
	messages:                    [dynamic]Chat_Entry,
	pending_tools:               int,
	tool_results:                [dynamic]Tool_Result_Msg,
	reader:                      ojson.Reader,
	writer:                      ojson.Writer,
	tool_names:                  [dynamic]string,
	compiled_schemas:            []Compiled_Schema,
	route_override:              Maybe(LLM_Config),
	current_format:              API_Format,
	stream_thinking:             strings.Builder,
	stream_text:                 strings.Builder,
	stream_signature:            strings.Builder,
	stream_tools:                [dynamic]Stream_Tool_Accum,
	llm_timer_id:                u32,
	tool_timer_id:               u32,
	total_input_tokens:          int,
	total_output_tokens:         int,
	total_cache_creation_tokens: int,
	total_cache_read_tokens:     int,
	request_start_time:          time.Time,
	llm_turn_start_time:         time.Time,
	current_model_text:          Text,
	current_provider_text:       Text,
	current_status_code:         u32,
	tool_starts:                 map[string]time.Time,
	cache_mode_warning_emitted:  bool,
	arena:                       vmem.Arena,
	inherited_arena:             ^vmem.Arena,
	peak_bytes_used:             uint,
	compact_caller:              actod.PID,
	compact_request_id:          Request_ID,
	compact_snapshot_len:        int,
}

agent_arena :: proc "contextless" (data: ^Agent_State) -> ^vmem.Arena {
	if data.inherited_arena != nil {
		return data.inherited_arena
	}
	return &data.arena
}

agent_behaviour :: actod.Actor_Behaviour(Agent_State) {
	init           = agent_init,
	handle_message = agent_handle_message,
	terminate      = agent_terminate,
}

agent_init :: proc(data: ^Agent_State) {
	if data.inherited_arena == nil {
		if !arena_init(&data.arena) {
			log.errorf("agent:%s failed to init arena", data.agent_name)
		}
	}
	arena := agent_arena(data)

	ojson.init_reader(&data.reader)
	data.writer = ojson.init_writer()
	data.messages = make([dynamic]Chat_Entry)
	data.tool_results = make([dynamic]Tool_Result_Msg)
	data.tool_names = make([dynamic]string)
	data.stream_thinking = strings.builder_make()
	data.stream_text = strings.builder_make()
	data.stream_signature = strings.builder_make()
	data.stream_tools = make([dynamic]Stream_Tool_Accum)
	data.tool_starts = make(map[string]time.Time)

	if data.config.validate_tool_args && len(data.config.tools) > 0 {
		data.compiled_schemas = make([]Compiled_Schema, len(data.config.tools))
	}
	for tool, i in data.config.tools {
		append(&data.tool_names, tool.def.name)
		if data.config.validate_tool_args {
			data.compiled_schemas[i] = compile_schema(tool.def.input_schema)
		}
	}

	for i in 0 ..< data.config.worker_count {
		worker_name := fmt.tprintf("llm:%s:%d", data.agent_name, i)
		_, ok := actod.spawn_child(
			worker_name,
			LLM_Worker_State{arena = arena},
			llm_worker_behaviour,
			actod.make_actor_config(use_dedicated_os_thread = true),
		)
		if !ok {
			log.errorf("agent:%s failed to spawn worker %s", data.agent_name, worker_name)
		}
	}

	limiter_name := fmt.tprintf("ratelim:%s", data.agent_name)
	limiter_state := Rate_Limiter_State {
		worker_name  = strings.clone(fmt.tprintf("llm:%s:0", data.agent_name)),
		worker_count = data.config.worker_count,
		agent_name   = strings.clone(data.agent_name),
		enabled      = data.config.llm.enable_rate_limiting,
		arena        = arena,
	}
	if _, ok := actod.spawn_child(limiter_name, limiter_state, rate_limiter_behaviour); !ok {
		log.errorf("agent:%s failed to spawn rate limiter", data.agent_name)
	}

	ensure_trace_sink_spawned(data.config.trace_sink, data.agent_name)
}

agent_terminate :: proc(data: ^Agent_State) {
	free_chat_entries(&data.messages)
	delete(data.messages)
	if data.inherited_arena == nil {
		arena_destroy(&data.arena)
	}
}

agent_handle_message :: proc(data: ^Agent_State, from: actod.PID, content: any) {
	switch msg in content {
	case Agent_Request:
		handle_agent_request(data, from, msg)
	case LLM_Result:
		handle_llm_result(data, msg)
	case LLM_Stream_Chunk:
		handle_stream_chunk(data, msg)
	case Tool_Result_Msg:
		handle_tool_result(data, msg)
	case Agent_Event:
		if data.config.forward_events && data.caller_pid != 0 {
			send(data.caller_pid, msg)
		}
	case Rate_Limit_Event:
		handle_rate_limit_event(data, msg)
	case actod.Timer_Tick:
		handle_timer(data, msg)
	case Set_Route:
		data.route_override = persist_llm_config(msg.llm, context.allocator)
		log.infof(
			"agent:%s route override set: provider=%s model=%s",
			data.agent_name,
			msg.llm.provider.name,
			resolve_model_string(msg.llm.model),
		)
	case Clear_Route:
		data.route_override = nil
		log.infof("agent:%s route override cleared", data.agent_name)
	case Reset_Conversation:
		handle_reset_conversation(data, from, msg)
	case Cancel_Turn:
		handle_cancel_turn(data, from, msg)
	case Compact_History:
		handle_compact_history(data, from, msg)
	case Arena_Status_Query:
		handle_arena_status_query(data, msg)
	case History_Query:
		handle_history_query(data, msg)
	case Load_History:
		handle_load_history(data, msg)
	}
}

handle_arena_status_query :: proc(data: ^Agent_State, msg: Arena_Status_Query) {
	arena := agent_arena(data)
	send(
		msg.caller,
		Arena_Status {
			request_id = msg.request_id,
			arena_id = uintptr(arena),
			bytes_used = arena_bytes_used(arena),
			bytes_reserved = arena_bytes_reserved(arena),
			peak_bytes_used = data.peak_bytes_used,
			owns_arena = data.inherited_arena == nil,
			message_count = len(data.messages),
		},
	)
}

handle_history_query :: proc(data: ^Agent_State, msg: History_Query) {
	n := len(data.messages)
	idx := msg.index
	if idx < 0 {
		idx = n + idx
	}
	if idx < 0 || idx >= n {
		send(msg.caller, History_Entry_Msg{request_id = msg.request_id, index = msg.index})
		return
	}
	entry := data.messages[idx]
	arena := agent_arena(data)
	send(
		msg.caller,
		History_Entry_Msg {
			request_id = msg.request_id,
			index = msg.index,
			found = true,
			role = entry.role,
			content = intern(entry.content, arena),
			tool_call_id = intern(entry.tool_call_id, arena),
		},
	)
}

handle_load_history :: proc(data: ^Agent_State, msg: Load_History) {
	if data.phase != .IDLE {
		send(
			msg.caller,
			Load_History_Result {
				request_id = msg.request_id,
				is_error   = true,
				error_msg  = text("agent is busy", agent_arena(data)),
			},
		)
		return
	}

	json_str := resolve(msg.messages_json)
	if len(json_str) == 0 {
		send(msg.caller, Load_History_Result{request_id = msg.request_id})
		return
	}

	if perr := ojson.parse(&data.reader, transmute([]byte)json_str); perr != .OK {
		send(
			msg.caller,
			Load_History_Result {
				request_id = msg.request_id,
				is_error   = true,
				error_msg  = text("invalid JSON", agent_arena(data)),
			},
		)
		return
	}

	payload, perr := wire.unmarshal_history_payload(&data.reader)
	if perr != .OK && perr != .Key_Not_Found {
		send(
			msg.caller,
			Load_History_Result {
				request_id = msg.request_id,
				is_error   = true,
				error_msg  = text("invalid history payload", agent_arena(data)),
			},
		)
		return
	}

	for entry, i in payload.messages {
		if entry.role != "user" && entry.role != "assistant" {
			send(
				msg.caller,
				Load_History_Result {
					request_id = msg.request_id,
					is_error   = true,
					error_msg = text(
						fmt.tprintf("unknown role %q at messages[%d]", entry.role, i),
						agent_arena(data),
					),
				},
			)
			return
		}
	}

	if len(data.messages) == 0 && len(data.config.system_prompt) > 0 {
		append_system_entry(&data.messages, data.config.system_prompt)
	}

	for entry in payload.messages {
		switch entry.role {
		case "user":
			append_user_entry(&data.messages, entry.content)
		case "assistant":
			append_assistant_entry(&data.messages, text(entry.content,
          agent_arena(data)))
		}
	}

	send(
		msg.caller,
		Load_History_Result{request_id = msg.request_id, loaded = len(payload.messages)},
	)
}

handle_reset_conversation :: proc(data: ^Agent_State, from: actod.PID, msg: Reset_Conversation) {
	if data.phase != .IDLE {
		log.warnf(
			"agent:%s rejected Reset_Conversation %d — busy (phase=%v)",
			data.agent_name,
			msg.request_id,
			data.phase,
		)
		return
	}
	log.infof("agent:%s resetting conversation (%d turns)", data.agent_name, len(data.messages))
	free_chat_entries(&data.messages)
}

handle_cancel_turn :: proc(data: ^Agent_State, from: actod.PID, msg: Cancel_Turn) {
	if data.phase == .IDLE {
		return
	}
	if data.phase == .AWAITING_COMPACT {
		return
	}
	if msg.request_id != data.current_req {
		return
	}

	if data.llm_timer_id != 0 {
		actod.cancel_timer(data.llm_timer_id)
		data.llm_timer_id = 0
	}
	if data.tool_timer_id != 0 {
		actod.cancel_timer(data.tool_timer_id)
		data.tool_timer_id = 0
	}

	log.infof("agent:%s request %d cancelled by caller", data.agent_name, msg.request_id)

	arena := agent_arena(data)
	err_text := text("(cancelled)", arena)
	result := Agent_Response {
		request_id                  = data.current_req,
		is_error                    = true,
		error_msg                   = err_text,
		input_tokens                = data.total_input_tokens,
		output_tokens               = data.total_output_tokens,
		cache_creation_input_tokens = data.total_cache_creation_tokens,
		cache_read_input_tokens     = data.total_cache_read_tokens,
	}
	agent_track_peak(data)
	send(data.caller_pid, result)
	emit_request_end(data, err_text, true)
	reset_agent(data)
}

COMPACT_DEFAULT_INSTRUCTION ::
	"Summarise the conversation so far into a single dense paragraph. " +
	"Capture decisions made, important facts established, open questions, and the user's intent. " +
	"Omit small talk and tool-call mechanics. Write in the third person from the assistant's perspective."

handle_compact_history :: proc(data: ^Agent_State, from: actod.PID, msg: Compact_History) {
	if data.phase != .IDLE {
		log.warnf(
			"agent:%s rejected Compact_History %d — busy (phase=%v)",
			data.agent_name,
			msg.request_id,
			data.phase,
		)
		result := Compact_Result {
			request_id = msg.request_id,
			is_error   = true,
			error_msg  = text("agent is busy", agent_arena(data)),
		}
		send(from, result)
		return
	}

	if len(data.messages) == 0 {
		log.infof("agent:%s Compact_History no-op (empty history)", data.agent_name)
		send(from, Compact_Result{request_id = msg.request_id, old_turns = 0})
		return
	}

	data.compact_caller = from
	data.compact_request_id = msg.request_id
	data.compact_snapshot_len = len(data.messages)

	instruction := msg.instruction
	if len(instruction) == 0 {
		instruction = COMPACT_DEFAULT_INSTRUCTION
	}

	append_user_entry(&data.messages, instruction)

	data.phase = .AWAITING_COMPACT
	dispatch_compact_call(data)
}

dispatch_compact_call :: proc(data: ^Agent_State) {
	route := resolve_route(data.route_override, &data.config)
	if len(route.provider.base_url) == 0 {
		compact_fail(data, "no provider configured")
		return
	}

	data.current_format = route.provider.format
	model_str := resolve_model_string(route.model)

	ojson.writer_reset(&data.writer)
	build_request_json(
		&data.writer,
		data.messages[:],
		nil,
		model_str,
		route.temperature,
		route.max_tokens,
		route.provider.format,
		nil,
		false,
		.NONE,
	)

	payload := ojson.writer_string(&data.writer)
	url := build_chat_url(&route.provider, model_str, false)
	arena := agent_arena(data)

	call := LLM_Call {
		request_id    = data.compact_request_id,
		caller        = actod.get_self_pid(),
		payload       = text(payload, arena),
		url           = text(url, arena),
		auth_header   = text(build_auth_header(&route.provider), arena),
		extra_headers = text(build_extra_headers(&route.provider), arena),
		timeout       = route.timeout,
		stream        = false,
		format        = route.provider.format,
	}
	target := fmt.tprintf("ratelim:%s", data.agent_name)
	send_err := actod.send_message_name(target, call)
	if send_err != .OK {
		compact_fail(data, "failed to reach LLM worker")
	}
}

compact_fail :: proc(data: ^Agent_State, reason: string) {
	log.errorf("agent:%s compact failed: %s", data.agent_name, reason)
	for len(data.messages) > data.compact_snapshot_len {
		idx := len(data.messages) - 1
		entry := data.messages[idx]
		free_text(entry.content)
		free_text(entry.tool_call_id)
		free_text(entry.thinking)
		free_text(entry.signature)
		pop(&data.messages)
	}
	send(
		data.compact_caller,
		Compact_Result {
			request_id = data.compact_request_id,
			is_error = true,
			error_msg = text(reason, agent_arena(data)),
		},
	)
	data.compact_caller = 0
	data.compact_request_id = 0
	data.compact_snapshot_len = 0
	data.phase = .IDLE
}

finalize_compact :: proc(data: ^Agent_State, summary: Text) {
	old_turns := data.compact_snapshot_len
	summary_s := resolve(summary)
	free_chat_entries(&data.messages)

	append_user_entry(&data.messages, fmt.tprintf("[conversation summary]\n%s", summary_s))

	result := Compact_Result {
		request_id = data.compact_request_id,
		summary    = intern(summary, agent_arena(data)),
		old_turns  = old_turns,
	}
	caller := data.compact_caller
	data.compact_caller = 0
	data.compact_request_id = 0
	data.compact_snapshot_len = 0
	data.phase = .IDLE
	send(caller, result)
}

handle_rate_limit_event :: proc(data: ^Agent_State, msg: Rate_Limit_Event) {
	kind: Trace_Event_Kind
	switch msg.kind {
	case .QUEUED:
		kind = .RATE_LIMIT_QUEUED
	case .RETRYING:
		kind = .RATE_LIMIT_RETRYING
	case .PROCESSING:
		kind = .RATE_LIMIT_PROCESSING
	}
	ev := Trace_Event {
		kind           = kind,
		queue_depth    = msg.queue_depth,
		retry_count    = msg.retry_count,
		retry_delay_ms = msg.retry_delay,
	}
	emit_trace(data, ev)
}

handle_agent_request :: proc(data: ^Agent_State, from: actod.PID, msg: Agent_Request) {
	if data.claimed_by != 0 && data.claimed_by != from {
		log.warnf(
			"agent:%s rejected request %d — already claimed by another actor",
			data.agent_name,
			msg.request_id,
		)
		result := Agent_Response {
			request_id = msg.request_id,
			is_error   = true,
			error_msg  = text("agent claimed by another actor", agent_arena(data)),
		}
		send(from, result)
		return
	}

	if data.phase != .IDLE {
		log.warnf(
			"agent:%s rejected request %d — busy (phase=%v)",
			data.agent_name,
			msg.request_id,
			data.phase,
		)
		result := Agent_Response {
			request_id = msg.request_id,
			is_error   = true,
			error_msg  = text("agent is busy", agent_arena(data)),
		}
		send(from, result)
		return
	}

	data.claimed_by = from

	log.infof("agent:%s request %d started", data.agent_name, msg.request_id)

	data.phase = .AWAITING_LLM
	data.current_req = msg.request_id
	data.parent_request_id = msg.parent_request_id
	data.caller_pid = from
	data.turn = 0
	data.request_start_time = time.now()
	clear(&data.tool_results)

	if !data.config.accumulate_history {
		free_chat_entries(&data.messages)
		if len(data.config.system_prompt) > 0 {
			append_system_entry(&data.messages, data.config.system_prompt)
		}
	} else if len(data.messages) == 0 && len(data.config.system_prompt) > 0 {
		append_system_entry(&data.messages, data.config.system_prompt)
	}

	emit_trace(data, Trace_Event{kind = .REQUEST_START, detail = msg.content})

	cache_blocks := collect_cache_blocks(msg)
	if len(cache_blocks) > 0 {
		append_user_entry_cached(&data.messages, cache_blocks)
	} else {
		append_user_entry(&data.messages, resolve(msg.content))
	}

	dispatch_llm_call(data)
}

handle_llm_result :: proc(data: ^Agent_State, msg: LLM_Result) {
	err_msg := resolve(msg.error_msg)

	if data.phase == .AWAITING_COMPACT && msg.request_id == data.compact_request_id {
		if len(err_msg) > 0 {
			compact_fail(data, err_msg)
			return
		}
		if msg.status_code < 200 || msg.status_code >= 300 {
			compact_fail(data, fmt.tprintf("HTTP %d: %s", msg.status_code, resolve(msg.body)))
			return
		}
		parsed := parse_llm_response(
			&data.reader,
			resolve(msg.body),
			data.current_format,
			agent_arena(data),
		)
		parsed_err := resolve(parsed.error_msg)
		if len(parsed_err) > 0 {
			compact_fail(data, parsed_err)
			return
		}
		finalize_compact(data, parsed.content)
		return
	}

	if msg.request_id == data.current_req {
		data.current_status_code = msg.status_code
	}

	if data.phase == .AWAITING_STREAM && msg.request_id == data.current_req {
		if len(err_msg) > 0 {
			if data.llm_timer_id != 0 {
				actod.cancel_timer(data.llm_timer_id)
				data.llm_timer_id = 0
			}
			send_error_response(data, err_msg)
		}
		return
	}


	if data.phase != .AWAITING_LLM || msg.request_id != data.current_req {
		return
	}

	if data.llm_timer_id != 0 {
		actod.cancel_timer(data.llm_timer_id)
		data.llm_timer_id = 0
	}

	if len(err_msg) > 0 {
		send_error_response(data, err_msg)
		return
	}

	if msg.status_code < 200 || msg.status_code >= 300 {
		send_error_response(data, fmt.tprintf("HTTP %d: %s", msg.status_code, resolve(msg.body)))
		return
	}

	parsed := parse_llm_response(
		&data.reader,
		resolve(msg.body),
		data.current_format,
		agent_arena(data),
	)

	parsed_err_s := resolve(parsed.error_msg)
	if len(parsed_err_s) > 0 {
		send_error_response(data, parsed_err_s)
		return
	}

	process_parsed_response(data, parsed)
}

collect_cache_blocks :: proc(msg: Agent_Request) -> []Text {
	candidates := [MAX_CACHE_BLOCKS]Text {
		msg.cache_block_1,
		msg.cache_block_2,
		msg.cache_block_3,
		msg.cache_block_4,
	}
	count := 0
	for c in candidates {
		if len(resolve(c)) > 0 {count += 1}
	}
	if count == 0 {return nil}
	out := make([]Text, count)
	idx := 0
	for c in candidates {
		if len(resolve(c)) > 0 {
			out[idx] = c
			idx += 1
		}
	}
	return out
}

hash_tool_call :: proc(name: string, args: string) -> u64 {
	h := hash.fnv64a(transmute([]byte)name)
	h = hash.fnv64a(transmute([]byte)args, h)
	return h
}

find_tool :: proc(config: ^Agent_Config, name: string) -> (Tool, int, bool) {
	for tool, i in config.tools {
		if tool.def.name == name {
			return tool, i, true
		}
	}
	return {}, -1, false
}

append_tool_error :: proc(data: ^Agent_State, call_id: Text, tool_name: Text, msg: string) {
	append(
		&data.tool_results,
		Tool_Result_Msg {
			request_id = data.current_req,
			call_id = call_id,
			tool_name = tool_name,
			result = text(msg, agent_arena(data)),
			is_error = true,
		},
	)
	data.pending_tools -= 1
}

is_degenerate_output :: proc(content: string) -> bool {
	if len(content) < 200 {
		return false
	}
	sample_len := min(40, len(content) / 4)
	if sample_len < 10 {
		return false
	}
	sample := content[:sample_len]
	count := 0
	for i := 0; i <= len(content) - sample_len; i += sample_len {
		if content[i:][:sample_len] == sample {
			count += 1
		}
	}
	return count >= 4
}

process_parsed_response :: proc(data: ^Agent_State, parsed: Parsed_Response) {
	data.total_input_tokens += parsed.usage.input_tokens
	data.total_output_tokens += parsed.usage.output_tokens
	data.total_cache_creation_tokens += parsed.usage.cache_creation_input_tokens
	data.total_cache_read_tokens += parsed.usage.cache_read_input_tokens

	content_s := resolve(parsed.content)
	thinking_s := resolve(parsed.thinking)
	finish_s := resolve(parsed.finish_reason)

	if is_degenerate_output(content_s) {
		log.warnf("agent:%s detected degenerate repetitive output, aborting", data.agent_name)
		send_error_response(data, "model produced degenerate repetitive output")
		return
	}

	if len(thinking_s) > 0 {
		log.infof("agent:%s thinking: %d chars", data.agent_name, len(thinking_s))
		emit_event(data, .THINKING_DONE, detail = parsed.thinking)
		emit_trace(data, Trace_Event{kind = .THINKING_DONE, detail = parsed.thinking})
	}

	log.infof(
		"agent:%s turn %d: text=%d chars, tools=%d, reason=%s",
		data.agent_name,
		data.turn,
		len(content_s),
		len(parsed.tool_calls),
		finish_s,
	)
	emit_event(data, .LLM_CALL_DONE, detail = parsed.content)
	emit_trace(
		data,
		Trace_Event {
			kind = .LLM_CALL_DONE,
			model = data.current_model_text,
			provider = data.current_provider_text,
			detail = parsed.content,
			input_tokens = u32(parsed.usage.input_tokens),
			output_tokens = u32(parsed.usage.output_tokens),
			cache_creation_tokens = u32(parsed.usage.cache_creation_input_tokens),
			cache_read_tokens = u32(parsed.usage.cache_read_input_tokens),
			status_code = data.current_status_code,
			duration_ns = i64(time.diff(data.llm_turn_start_time, time.now())),
		},
	)

	if len(parsed.tool_calls) > 0 {
		max_tc := data.config.max_tool_calls_per_turn
		if max_tc <= 0 {
			max_tc = DEFAULT_MAX_TOOL_CALLS_PER_TURN
		}

		capped := len(parsed.tool_calls) > max_tc
		if capped {
			log.warnf(
				"agent:%s capping tool calls from %d to %d",
				data.agent_name,
				len(parsed.tool_calls),
				max_tc,
			)
		}

		append_assistant_entry(
			&data.messages,
			parsed.content,
			parsed.tool_calls,
			parsed.thinking,
			parsed.thinking_signature,
		)

		data.pending_tools = len(parsed.tool_calls)
		clear(&data.tool_results)
		data.turn += 1

		if capped {
			for i := max_tc; i < len(parsed.tool_calls); i += 1 {
				tc := parsed.tool_calls[i]
				append_tool_error(
					data,
					tc.id,
					tc.name,
					fmt.tprintf(
						"skipped: too many tool calls (%d requested, max %d per turn)",
						len(parsed.tool_calls),
						max_tc,
					),
				)
			}
		}

		dispatch_count := min(len(parsed.tool_calls), max_tc)
		names_sb := strings.builder_make(context.temp_allocator)
		for tc, i in parsed.tool_calls[:dispatch_count] {
			if i > 0 {strings.write_string(&names_sb, ", ")}
			strings.write_string(&names_sb, resolve(tc.name))
		}
		log.infof(
			"agent:%s dispatching %d tool call(s): %s",
			data.agent_name,
			dispatch_count,
			strings.to_string(names_sb),
		)
		seen_calls: map[u64]bool
		seen_calls.allocator = context.temp_allocator
		for tc in parsed.tool_calls[:dispatch_count] {
			tc_name_s := resolve(tc.name)
			tc_args_s := resolve(tc.arguments)
			tc_id_s := resolve(tc.id)
			call_hash := hash_tool_call(tc_name_s, tc_args_s)
			if call_hash in seen_calls {
				log.warnf("agent:%s dedup skipped %s", data.agent_name, tc_name_s)
				append_tool_error(
					data,
					tc.id,
					tc.name,
					"skipped: duplicate tool call in same batch",
				)
				continue
			}
			seen_calls[call_hash] = true

			tool, tool_idx, found := find_tool(&data.config, tc_name_s)

			if !found {
				append_tool_error(
					data,
					tc.id,
					tc.name,
					fmt.tprintf("tool '%s' not found", tc_name_s),
				)
				continue
			}

			if data.config.validate_tool_args &&
			   tool_idx < len(data.compiled_schemas) &&
			   data.compiled_schemas[tool_idx].valid {
				validate_input := tc_args_s
				if len(validate_input) == 0 {
					validate_input = "{}"
				}
				if ojson.parse(&data.reader, transmute([]byte)validate_input) != .OK {
					append_tool_error(
						data,
						tc.id,
						tc.name,
						fmt.tprintf("tool '%s': arguments are not valid JSON", tc_name_s),
					)
					continue
				}
				schema_root := ojson.root_element(&data.reader)
				schema_errors, schema_ok := validate_args(
					&data.reader,
					schema_root,
					&data.compiled_schemas[tool_idx],
				)
				if !schema_ok {
					append_tool_error(data, tc.id, tc.name, format_schema_errors(schema_errors))
					continue
				}
			}

			emit_event(data, .TOOL_CALL_START, subject = tc.name, detail = tc.arguments)
			call_id_key := strings.clone(tc_id_s)
			data.tool_starts[call_id_key] = time.now()
			emit_trace(
				data,
				Trace_Event {
					kind = .TOOL_CALL_START,
					call_id = tc.id,
					tool_name = tc.name,
					detail = tc.arguments,
				},
			)
			tool_msg := Tool_Call_Msg {
				request_id = data.current_req,
				call_id    = tc.id,
				tool_name  = tc.name,
				arguments  = tc.arguments,
			}

			switch tool.lifecycle {
			case .INLINE:
				if tool.impl == nil {
					append_tool_error(
						data,
						tc.id,
						tc.name,
						fmt.tprintf("tool '%s' has no impl", tc_name_s),
					)
					continue
				}
				output, is_error := tool.impl(tc_args_s, context.temp_allocator)
				output_text := text(output, agent_arena(data))
				append(
					&data.tool_results,
					Tool_Result_Msg {
						request_id = data.current_req,
						call_id = tc.id,
						tool_name = tc.name,
						result = output_text,
						is_error = is_error,
					},
				)
				emit_event(data, .TOOL_CALL_DONE, subject = tc.name, detail = output_text)
				emit_tool_done_trace(data, tc.id, tc.name, output_text, is_error)
				data.pending_tools -= 1

			case .EPHEMERAL:
				eph_name := fmt.tprintf("ephemeral:%s:%s", data.agent_name, tc_id_s)
				if !spawn_tool_actor(eph_name, tool, agent_arena(data), ephemeral = true) {
					log.errorf("Failed to spawn ephemeral tool for '%s'", tc_name_s)
					err_text := text(
						fmt.tprintf("failed to spawn ephemeral tool '%s'", tc_name_s),
						agent_arena(data),
					)
					emit_tool_done_trace(data, tc.id, tc.name, err_text, true)
					append_tool_error(
						data,
						tc.id,
						tc.name,
						fmt.tprintf("failed to spawn ephemeral tool '%s'", tc_name_s),
					)
					continue
				}
				actod.send_message_name(eph_name, tool_msg)

			case .PERSISTENT, .SUB_AGENT:
				tool_actor_name := fmt.tprintf("tool:%s:%s", data.agent_name, tc_name_s)
				if _, exists := actod.get_actor_pid(tool_actor_name); !exists {
					if !spawn_tool_actor(
						tool_actor_name,
						tool,
						agent_arena(data),
						ephemeral = false,
					) {
						log.errorf("Failed to spawn tool '%s'", tc_name_s)
						err_text := text(
							fmt.tprintf("failed to spawn tool '%s'", tc_name_s),
							agent_arena(data),
						)
						emit_tool_done_trace(data, tc.id, tc.name, err_text, true)
						append_tool_error(
							data,
							tc.id,
							tc.name,
							fmt.tprintf("failed to spawn tool '%s'", tc_name_s),
						)
						continue
					}
				}
				if send_err := actod.send_message_name(tool_actor_name, tool_msg);
				   send_err != .OK {
					log.errorf("Failed to send to tool '%s': %v", tc_name_s, send_err)
					err_text := text(
						fmt.tprintf("tool '%s' unavailable", tc_name_s),
						agent_arena(data),
					)
					emit_tool_done_trace(data, tc.id, tc.name, err_text, true)
					append_tool_error(
						data,
						tc.id,
						tc.name,
						fmt.tprintf("tool '%s' unavailable", tc_name_s),
					)
				}
			}
		}

		if data.pending_tools > 0 {
			data.phase = .AWAITING_TOOLS
			data.tool_timer_id, _ = actod.set_timer(data.config.tool_timeout, false)
		} else {
			finalize_tool_results(data)
		}
	} else {
		append_assistant_entry(
			&data.messages,
			parsed.content,
			thinking = parsed.thinking,
			signature = parsed.thinking_signature,
		)
		send_success_response(data, parsed.content)
	}
}

handle_tool_result :: proc(data: ^Agent_State, msg: Tool_Result_Msg) {
	if data.phase != .AWAITING_TOOLS || msg.request_id != data.current_req {
		return
	}

	emit_event(data, .TOOL_CALL_DONE, subject = msg.tool_name, detail = msg.result)
	emit_tool_done_trace(data, msg.call_id, msg.tool_name, msg.result, msg.is_error)
	arena := agent_arena(data)
	append(
		&data.tool_results,
		Tool_Result_Msg {
			request_id = msg.request_id,
			call_id = intern(msg.call_id, arena),
			tool_name = intern(msg.tool_name, arena),
			result = intern(msg.result, arena),
			is_error = msg.is_error,
		},
	)
	data.pending_tools -= 1

	if data.pending_tools <= 0 {
		if data.tool_timer_id != 0 {
			actod.cancel_timer(data.tool_timer_id)
			data.tool_timer_id = 0
		}
		finalize_tool_results(data)
	}
}

finalize_tool_results :: proc(data: ^Agent_State) {
	for tr in data.tool_results {
		resolved := resolve(tr.result)
		content: Text
		if tr.is_error {
			content = text(fmt.tprintf("Error: %s", resolved), agent_arena(data))
		} else {
			content = tr.result
		}
		append_tool_result_entry(&data.messages, tr.call_id, content)
	}
	clear(&data.tool_results)

	if data.turn >= data.config.max_turns {
		send_truncated_response(data)
		return
	}

	if data.turn >= data.config.max_turns - 1 {
		append_user_entry(
			&data.messages,
			"FINAL TURN — turn limit reached. Stop calling tools. Reply with a brief summary of what you completed, what's left, and any blockers. No tool calls.",
		)
	} else if len(data.config.tool_continuation) > 0 {
		append_user_entry(&data.messages, data.config.tool_continuation)
	}

	data.phase = .AWAITING_LLM
	dispatch_llm_call(data)
}

send_truncated_response :: proc(data: ^Agent_State) {
	log.warnf(
		"agent:%s request %d hit max_turns=%d, returning partial result",
		data.agent_name,
		data.current_req,
		data.config.max_turns,
	)

	partial: string
	for i := len(data.messages) - 1; i >= 0; i -= 1 {
		entry := data.messages[i]
		partial_s := resolve(entry.content)
		if entry.role == .ASSISTANT && len(partial_s) > 0 {
			partial = partial_s
			break
		}
	}

	body: string
	if len(partial) > 0 {
		body = fmt.tprintf("[truncated at turn limit %d]\n%s", data.config.max_turns, partial)
	} else {
		body = fmt.tprintf(
			"[truncated at turn limit %d — no assistant reply produced before cap]",
			data.config.max_turns,
		)
	}

	body_text := text(body, agent_arena(data))
	result := Agent_Response {
		request_id                  = data.current_req,
		content                     = body_text,
		is_error                    = false,
		input_tokens                = data.total_input_tokens,
		output_tokens               = data.total_output_tokens,
		cache_creation_input_tokens = data.total_cache_creation_tokens,
		cache_read_input_tokens     = data.total_cache_read_tokens,
	}
	agent_track_peak(data)
	send(data.caller_pid, result)
	emit_request_end(data, body_text, false)
	reset_agent(data)
}


handle_timer :: proc(data: ^Agent_State, msg: actod.Timer_Tick) {
	if msg.id == data.llm_timer_id {
		if data.phase == .AWAITING_LLM || data.phase == .AWAITING_STREAM {
			send_error_response(data, "LLM request timed out")
		}
	} else if msg.id == data.tool_timer_id {
		if data.phase == .AWAITING_TOOLS {
			send_error_response(data, "tool execution timed out")
		}
	}
}

dispatch_llm_call :: proc(data: ^Agent_State) {
	route := resolve_route(data.route_override, &data.config)
	if len(route.provider.base_url) == 0 {
		send_error_response(data, "no provider configured")
		return
	}

	data.current_format = route.provider.format

	if route.cache_mode != .NONE &&
	   route.provider.format != .ANTHROPIC &&
	   !data.cache_mode_warning_emitted {
		log.warnf(
			"agent:%s cache_mode=%v is a no-op on %v provider — only .ANTHROPIC honours cache_control blocks. (Gemini caches implicitly; OpenAI caches server-side; Ollama is local.) Set cache_mode=.NONE to silence this.",
			data.agent_name,
			route.cache_mode,
			route.provider.format,
		)
		data.cache_mode_warning_emitted = true
	}

	if route.provider.format == .OLLAMA {
		actod.send_message_name(
			OLLAMA_TRACKER_ACTOR_NAME,
			Ollama_Model_Seen {
				base_url = route.provider.base_url,
				model = resolve_model_string(route.model),
			},
		)
	}

	model_str := resolve_model_string(route.model)

	tool_defs: [dynamic]Tool_Def
	defer delete(tool_defs)
	for reg in data.config.tools {
		append(&tool_defs, reg.def)
	}

	ojson.writer_reset(&data.writer)
	build_request_json(
		&data.writer,
		data.messages[:],
		tool_defs[:],
		model_str,
		route.temperature,
		route.max_tokens,
		route.provider.format,
		route.thinking_budget,
		data.config.stream,
		route.cache_mode,
	)

	payload := ojson.writer_string(&data.writer)
	url := build_chat_url(&route.provider, model_str, data.config.stream)
	arena := agent_arena(data)

	call := LLM_Call {
		request_id    = data.current_req,
		caller        = actod.get_self_pid(),
		payload       = text(payload, arena),
		url           = text(url, arena),
		auth_header   = text(build_auth_header(&route.provider), arena),
		extra_headers = text(build_extra_headers(&route.provider), arena),
		timeout       = route.timeout,
		stream        = data.config.stream,
		format        = route.provider.format,
	}

	target_name := fmt.tprintf("ratelim:%s", data.agent_name)

	log.infof(
		"agent:%s dispatching LLM call to %s (model=%s, stream=%v)",
		data.agent_name,
		target_name,
		model_str,
		data.config.stream,
	)
	model_text := text(model_str, arena)
	provider_text := text(route.provider.name, arena)
	data.llm_turn_start_time = time.now()
	data.current_model_text = model_text
	data.current_provider_text = provider_text
	emit_event(data, .LLM_CALL_START, subject = text(target_name, arena), detail = model_text)
	emit_trace(
		data,
		Trace_Event{kind = .LLM_CALL_START, model = model_text, provider = provider_text},
	)

	send_err := actod.send_message_name(target_name, call)
	if send_err != .OK {
		log.errorf("Failed to send LLM_Call to %s: %v", target_name, send_err)
		send_error_response(data, "failed to reach LLM worker")
		return
	}

	if data.config.stream {
		data.phase = .AWAITING_STREAM
		reset_stream_accumulators(data)
	}

	data.llm_timer_id, _ = actod.set_timer(route.timeout, false)
}

handle_stream_chunk :: proc(data: ^Agent_State, chunk: LLM_Stream_Chunk) {
	if data.phase != .AWAITING_STREAM || chunk.request_id != data.current_req {
		return
	}

	chunk_content := resolve(chunk.content)
	chunk_name := resolve(chunk.name)

	switch chunk.kind {
	case .THINKING_DELTA:
		if chunk_name == "signature" {
			strings.write_string(&data.stream_signature, chunk_content)
		} else {
			strings.write_string(&data.stream_thinking, chunk_content)
			emit_event(data, .THINKING_DELTA, detail = chunk.content)
		}
	case .TEXT_DELTA:
		strings.write_string(&data.stream_text, chunk_content)
		emit_event(data, .TEXT_DELTA, detail = chunk.content)
	case .TOOL_START:
		arena := agent_arena(data)
		append(
			&data.stream_tools,
			Stream_Tool_Accum {
				id = intern(chunk.content, arena),
				name = intern(chunk.name, arena),
				input = strings.builder_make(),
			},
		)
	case .TOOL_INPUT_DELTA:
		if len(data.stream_tools) > 0 {
			strings.write_string(
				&data.stream_tools[len(data.stream_tools) - 1].input,
				chunk_content,
			)
		}
	case .DONE:
		if data.llm_timer_id != 0 {
			actod.cancel_timer(data.llm_timer_id)
			data.llm_timer_id = 0
		}
		finalize_stream(data, chunk_content, chunk_name)
	case .ERROR:
		if data.llm_timer_id != 0 {
			actod.cancel_timer(data.llm_timer_id)
			data.llm_timer_id = 0
		}
		send_error_response(data, chunk_content)
	}
}

reset_stream_accumulators :: proc(data: ^Agent_State) {
	strings.builder_reset(&data.stream_thinking)
	strings.builder_reset(&data.stream_text)
	strings.builder_reset(&data.stream_signature)
	for &tool in data.stream_tools {
		strings.builder_destroy(&tool.input)
	}
	clear(&data.stream_tools)
}

parse_stream_usage :: proc(usage_str: string) -> (int, int, int, int) {
	parts: [4]int
	idx := 0
	cur := 0
	parsed_any := false
	for c in usage_str {
		if c == ',' {
			if idx < 4 {
				parts[idx] = cur
			}
			idx += 1
			cur = 0
			parsed_any = false
			continue
		}
		if c >= '0' && c <= '9' {
			cur = cur * 10 + int(c - '0')
			parsed_any = true
		}
	}
	if parsed_any && idx < 4 {
		parts[idx] = cur
	}
	return parts[0], parts[1], parts[2], parts[3]
}

finalize_stream :: proc(data: ^Agent_State, stop_reason: string, usage_str: string = "") {
	log.infof("agent:%s stream done (reason=%s)", data.agent_name, stop_reason)
	thinking_s := strings.to_string(data.stream_thinking)
	text_s := strings.to_string(data.stream_text)
	signature_s := strings.to_string(data.stream_signature)

	tool_calls: [dynamic]Parsed_Tool_Call
	tool_calls.allocator = context.temp_allocator
	for &tool in data.stream_tools {
		append(
			&tool_calls,
			Parsed_Tool_Call {
				id = tool.id,
				name = tool.name,
				arguments = text(strings.to_string(tool.input), agent_arena(data)),
			},
		)
	}

	stream_input, stream_output, stream_cache_create, stream_cache_read := parse_stream_usage(
		usage_str,
	)
	arena := agent_arena(data)
	parsed := Parsed_Response {
		content = text(text_s, arena),
		finish_reason = text(stop_reason, arena),
		thinking = text(thinking_s, arena),
		thinking_signature = text(signature_s, arena),
		usage = Usage_Info {
			input_tokens = stream_input,
			output_tokens = stream_output,
			cache_creation_input_tokens = stream_cache_create,
			cache_read_input_tokens = stream_cache_read,
		},
	}
	if len(tool_calls) > 0 {
		parsed.tool_calls = make([]Parsed_Tool_Call, len(tool_calls))
		copy(parsed.tool_calls, tool_calls[:])
	}

	data.phase = .AWAITING_LLM
	process_parsed_response(data, parsed)
}

emit_event :: proc(data: ^Agent_State, kind: Event_Kind, subject: Text = {}, detail: Text = {}) {
	if !data.config.forward_events || data.caller_pid == 0 {
		return
	}
	if !data.config.forward_thinking {
		#partial switch kind {
		case .THINKING_DELTA, .THINKING_DONE:
			return
		}
	}
	arena := agent_arena(data)
	send(
		data.caller_pid,
		Agent_Event {
			request_id = data.current_req,
			kind = kind,
			agent_name = text(data.agent_name, arena),
			subject = intern(subject, arena),
			detail = intern(detail, arena),
		},
	)
}

emit_trace :: proc(data: ^Agent_State, ev: Trace_Event) {
	if data.config.trace_sink.kind == .NONE {
		return
	}
	arena := agent_arena(data)
	enriched := ev
	enriched.request_id = data.current_req
	enriched.parent_request_id = data.parent_request_id
	enriched.agent_name = text(data.agent_name, arena)
	enriched.turn = u16(data.turn)
	enriched.timestamp_ns = i64(time.time_to_unix_nano(time.now()))
	enriched.call_id = intern(enriched.call_id, arena)
	enriched.tool_name = intern(enriched.tool_name, arena)
	enriched.model = intern(enriched.model, arena)
	enriched.provider = intern(enriched.provider, arena)
	enriched.detail = intern(enriched.detail, arena)
	send_by_name(data.config.trace_sink.name, enriched)
}

emit_tool_done_trace :: proc(
	data: ^Agent_State,
	call_id: Text,
	tool_name: Text,
	result: Text,
	is_error: bool,
) {
	if data.config.trace_sink.kind == .NONE {
		return
	}
	id_s := resolve(call_id)
	duration_ns: i64 = 0
	if start, ok := data.tool_starts[id_s]; ok {
		duration_ns = i64(time.diff(start, time.now()))
		delete_key(&data.tool_starts, id_s)
	}
	emit_trace(
		data,
		Trace_Event {
			kind = .TOOL_CALL_DONE,
			call_id = call_id,
			tool_name = tool_name,
			detail = result,
			is_error = is_error,
			duration_ns = duration_ns,
		},
	)
}

send_success_response :: proc(data: ^Agent_State, content: Text) {
	log.infof(
		"agent:%s request %d completed (%d chars)",
		data.agent_name,
		data.current_req,
		len(resolve(content)),
	)
	arena := agent_arena(data)
	externalized := intern(content, arena)
	result := Agent_Response {
		request_id                  = data.current_req,
		content                     = externalized,
		input_tokens                = data.total_input_tokens,
		output_tokens               = data.total_output_tokens,
		cache_creation_input_tokens = data.total_cache_creation_tokens,
		cache_read_input_tokens     = data.total_cache_read_tokens,
	}
	agent_track_peak(data)
	send(data.caller_pid, result)
	emit_request_end(data, externalized, false)
	reset_agent(data)
}

send_error_response :: proc(data: ^Agent_State, msg: string) {
	log.errorf("agent:%s request %d error: %s", data.agent_name, data.current_req, msg)
	arena := agent_arena(data)
	err_text := text(msg, arena)
	result := Agent_Response {
		request_id                  = data.current_req,
		is_error                    = true,
		error_msg                   = err_text,
		input_tokens                = data.total_input_tokens,
		output_tokens               = data.total_output_tokens,
		cache_creation_input_tokens = data.total_cache_creation_tokens,
		cache_read_input_tokens     = data.total_cache_read_tokens,
	}
	agent_track_peak(data)
	send(data.caller_pid, result)
	emit_request_end(data, err_text, true)
	reset_agent(data)
}

agent_track_peak :: proc(data: ^Agent_State) {
	arena := agent_arena(data)
	used := arena_bytes_used(arena)
	if used > data.peak_bytes_used {
		data.peak_bytes_used = used
	}
}

emit_request_end :: proc(data: ^Agent_State, detail: Text, is_error: bool) {
	emit_trace(
		data,
		Trace_Event {
			kind = .REQUEST_END,
			detail = detail,
			is_error = is_error,
			input_tokens = u32(data.total_input_tokens),
			output_tokens = u32(data.total_output_tokens),
			cache_creation_tokens = u32(data.total_cache_creation_tokens),
			cache_read_tokens = u32(data.total_cache_read_tokens),
			duration_ns = i64(time.diff(data.request_start_time, time.now())),
		},
	)
}

reset_agent :: proc(data: ^Agent_State) {
	caller := data.caller_pid
	data.phase = .IDLE
	data.current_req = 0
	data.parent_request_id = 0
	data.caller_pid = 0
	data.turn = 0
	data.pending_tools = 0
	data.total_input_tokens = 0
	data.total_output_tokens = 0
	data.total_cache_creation_tokens = 0
	data.total_cache_read_tokens = 0
	data.current_status_code = 0
	data.current_model_text = {}
	data.current_provider_text = {}
	for k in data.tool_starts {
		delete(k)
	}
	clear(&data.tool_starts)

	if data.inherited_arena == nil && caller != 0 {
		caller_node := actod.get_node_id(caller)
		if caller_node != 0 && !actod.is_local_pid(caller) {
			arena_reset(&data.arena)
		}
	}
}
