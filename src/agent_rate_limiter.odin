package enactod_impl

import "../pkgs/actod"
import "core:fmt"
import "core:log"
import vmem "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "core:time"

Rate_Limit_State :: struct {
	requests_limit:     u32,
	requests_remaining: u32,
	tokens_limit:       u32,
	tokens_remaining:   u32,
	reset_time:         i64,
}

Queued_Request :: struct {
	call:            LLM_Call,
	original_caller: actod.PID,
	retry_count:     u32,
}

Pending_Call :: struct {
	caller:      actod.PID,
	call:        LLM_Call,
	result_sent: bool,
	retry_count: u32, // carried across 429/529 retries so the 3-retry cap fires
}

Rate_Limiter_State :: struct {
	worker_name:    string,
	worker_count:   int,
	agent_name:     string,
	next_worker:    int,
	limit_state:    Rate_Limit_State,
	queue:          [dynamic]Queued_Request,
	in_flight:      u32,
	max_in_flight:  u32,
	pending_calls:  map[Request_ID]Pending_Call,
	queue_timer_id: u32,
	enabled:        bool,
	arena:          ^vmem.Arena,
}

rate_limiter_behaviour :: actod.Actor_Behaviour(Rate_Limiter_State) {
	init           = rate_limiter_init,
	handle_message = rate_limiter_handle_message,
}

rate_limiter_init :: proc(data: ^Rate_Limiter_State) {
	data.queue = make([dynamic]Queued_Request)
	data.pending_calls = make(map[Request_ID]Pending_Call)
	data.max_in_flight = 10
}

rate_limiter_handle_message :: proc(data: ^Rate_Limiter_State, from: actod.PID, content: any) {
	switch msg in content {
	case LLM_Call:
		rate_limiter_handle_call(data, msg)
	case LLM_Result:
		rate_limiter_handle_result(data, msg)
	case LLM_Stream_Chunk:
		rate_limiter_handle_stream_chunk(data, msg)
	case Rate_Limiter_Query:
		rate_limiter_handle_query(data, msg)
	case actod.Timer_Tick:
		if msg.id == data.queue_timer_id {
			rate_limiter_process_queue(data)
		}
	}
}

rate_limiter_handle_call :: proc(data: ^Rate_Limiter_State, call: LLM_Call) {
	original_caller := call.caller
	if !data.enabled {
		rate_limiter_forward_to_worker(data, call, original_caller, 0)
		return
	}
	can_send := rate_limiter_can_send_now(data)
	log.debugf(
		"Rate limiter: can_send=%v, in_flight=%d/%d, req_rem=%d, tok_rem=%d, reset=%d",
		can_send,
		data.in_flight,
		data.max_in_flight,
		data.limit_state.requests_remaining,
		data.limit_state.tokens_remaining,
		data.limit_state.reset_time,
	)
	if can_send {
		log.debugf("Rate limiter: forwarding to worker %s", data.worker_name)
		rate_limiter_forward_to_worker(data, call, original_caller, 0)
	} else {
		log.warnf("Rate limiter: queuing request (queue depth: %d)", len(data.queue) + 1)
		append(
			&data.queue,
			Queued_Request{call = call, original_caller = original_caller, retry_count = 0},
		)
		actod.send_message(
			original_caller,
			Rate_Limit_Event {
				request_id = call.request_id,
				kind = .QUEUED,
				queue_depth = u32(len(data.queue)),
			},
		)
		if len(data.queue) == 1 {
			data.queue_timer_id, _ = actod.set_timer(100 * time.Millisecond, false)
		}
	}
}

rate_limiter_handle_result :: proc(data: ^Rate_Limiter_State, result: LLM_Result) {
	data.in_flight -= 1
	log.debugf(
		"Rate limiter: received result, status=%d, in_flight now %d",
		result.status_code,
		data.in_flight,
	)

	if data.enabled {
		rate_limiter_parse_limits(data, resolve(result.headers))
		log.debugf(
			"Rate limiter: after parsing headers - req_rem=%d, tok_rem=%d",
			data.limit_state.requests_remaining,
			data.limit_state.tokens_remaining,
		)
	}

	pending, found := data.pending_calls[result.request_id]
	if !found {
		log.debugf(
			"Received result for unknown request_id=%v (likely streaming call already cleaned up)",
			result.request_id,
		)
		if data.enabled {rate_limiter_process_queue(data)}
		return
	}
	log.debugf("Rate limiter: forwarding result to original caller")

	if data.enabled && is_retryable_status(result.status_code) {
		retry_after := rate_limiter_parse_retry_after(resolve(result.headers))
		log.warnf(
			"Retryable %d for request %v, retry_after: %v",
			result.status_code,
			result.request_id,
			retry_after,
		)

		retry_count := pending.retry_count + 1

		if retry_count < 3 {
			delay := retry_after > 0 ? retry_after : time.Duration(1 << retry_count) * time.Second
			log.infof(
				"Re-queueing request %v for retry #%d after %v",
				result.request_id,
				retry_count,
				delay,
			)

			queued := Queued_Request {
				call            = pending.call,
				original_caller = pending.caller,
				retry_count     = retry_count,
			}
			log.debugf(
				"Rate limiter: queuing retry, payload len=%d",
				len(resolve(queued.call.payload)),
			)
			append(&data.queue, queued)
			actod.send_message(
				pending.caller,
				Rate_Limit_Event {
					request_id = result.request_id,
					kind = .RETRYING,
					queue_depth = u32(len(data.queue)),
					retry_count = retry_count,
					retry_delay = u32(delay / time.Millisecond),
				},
			)
			data.queue_timer_id, _ = actod.set_timer(delay, false)
			return
		} else {
			log.warnf(
				"Max retries exceeded for request %v, returning error to caller",
				result.request_id,
			)
			delete_key(&data.pending_calls, result.request_id)
			log.debugf(
				"Rate limiter: removed request_id=%v from pending (max retries), pending count=%d",
				result.request_id,
				len(data.pending_calls),
			)
		}
	} else {
		if pending.call.stream {
			updated := pending
			updated.result_sent = true
			data.pending_calls[result.request_id] = updated
			log.debugf(
				"Rate limiter: marked streaming request_id=%v as done, waiting for DONE chunk",
				result.request_id,
			)
		} else {
			delete_key(&data.pending_calls, result.request_id)
			log.debugf(
				"Rate limiter: removed request_id=%v from pending (success), pending count=%d",
				result.request_id,
				len(data.pending_calls),
			)
		}
	}

	actod.send_message(pending.caller, result)
	if data.enabled {rate_limiter_process_queue(data)}
}

rate_limiter_handle_stream_chunk :: proc(data: ^Rate_Limiter_State, chunk: LLM_Stream_Chunk) {
	pending, found := data.pending_calls[chunk.request_id]
	if !found {
		log.warnf("Received stream chunk for unknown request_id: %v", chunk.request_id)
		return
	}
	actod.send_message(pending.caller, chunk)

	if chunk.kind == .DONE || chunk.kind == .ERROR {
		delete_key(&data.pending_calls, chunk.request_id)
		log.debugf(
			"Rate limiter: cleaned up streaming request_id=%v (received %v), pending count=%d",
			chunk.request_id,
			chunk.kind,
			len(data.pending_calls),
		)
	}
}

rate_limiter_handle_query :: proc(data: ^Rate_Limiter_State, query: Rate_Limiter_Query) {
	status := Rate_Limiter_Status {
		request_id         = query.request_id,
		requests_limit     = data.limit_state.requests_limit,
		requests_remaining = data.limit_state.requests_remaining,
		tokens_limit       = data.limit_state.tokens_limit,
		tokens_remaining   = data.limit_state.tokens_remaining,
		queue_depth        = u32(len(data.queue)),
		in_flight          = data.in_flight,
	}
	actod.send_message(query.caller, status)
}

rate_limiter_can_send_now :: proc(data: ^Rate_Limiter_State) -> bool {
	if data.in_flight >= data.max_in_flight {
		return false
	}

	if data.limit_state.requests_remaining > 0 && data.limit_state.tokens_remaining > 0 {
		return true
	}

	now := time.now()
	now_unix := time.time_to_unix(now)
	if now_unix > data.limit_state.reset_time {
		return true
	}

	return false
}

rate_limiter_forward_to_worker :: proc(
	data: ^Rate_Limiter_State,
	call: LLM_Call,
	original_caller: actod.PID,
	retry_count: u32,
) {
	modified_call := call
	modified_call.caller = actod.get_self_pid()

	stored_call := call
	stored_call.payload = intern(call.payload, data.arena)
	stored_call.url = intern(call.url, data.arena)
	stored_call.auth_header = intern(call.auth_header, data.arena)
	stored_call.extra_headers = intern(call.extra_headers, data.arena)

	data.pending_calls[call.request_id] = Pending_Call {
		caller      = original_caller,
		call        = stored_call,
		retry_count = retry_count,
	}
	data.in_flight += 1

	target_worker: string
	if data.worker_count > 1 {
		target_worker = fmt.tprintf("llm:%s:%d", data.agent_name, data.next_worker)
		data.next_worker = (data.next_worker + 1) % data.worker_count
	} else {
		target_worker = data.worker_name
	}

	log.debugf(
		"Rate limiter: tracking request_id=%v, pending count=%d, payload len=%d",
		call.request_id,
		len(data.pending_calls),
		len(resolve(stored_call.payload)),
	)
	actod.send_message_name(target_worker, modified_call)
}

rate_limiter_process_queue :: proc(data: ^Rate_Limiter_State) {
	for len(data.queue) > 0 && rate_limiter_can_send_now(data) {
		req := data.queue[0]
		log.debugf("Rate limiter: dequeuing retry, payload len=%d", len(resolve(req.call.payload)))
		ordered_remove(&data.queue, 0)
		actod.send_message(
			req.original_caller,
			Rate_Limit_Event {
				request_id = req.call.request_id,
				kind = .PROCESSING,
				queue_depth = u32(len(data.queue)),
			},
		)
		rate_limiter_forward_to_worker(data, req.call, req.original_caller, req.retry_count)
	}

	if len(data.queue) > 0 {
		data.queue_timer_id, _ = actod.set_timer(100 * time.Millisecond, false)
	}
}

rate_limiter_parse_limits :: proc(data: ^Rate_Limiter_State, headers_str: string) {
	if len(headers_str) == 0 {
		return
	}

	lines := strings.split(headers_str, "\n")
	defer delete(lines)

	for line in lines {
		if colon_idx := strings.index_byte(line, ':'); colon_idx >= 0 {
			key := line[:colon_idx]
			value := strings.trim_space(line[colon_idx + 1:])

			switch key {
			case "anthropic-ratelimit-requests-limit":
				if val, ok := strconv.parse_u64(value); ok {
					data.limit_state.requests_limit = u32(val)
				}
			case "anthropic-ratelimit-requests-remaining":
				if val, ok := strconv.parse_u64(value); ok {
					data.limit_state.requests_remaining = u32(val)
				}
			case "anthropic-ratelimit-tokens-limit":
				if val, ok := strconv.parse_u64(value); ok {
					data.limit_state.tokens_limit = u32(val)
				}
			case "anthropic-ratelimit-tokens-remaining":
				if val, ok := strconv.parse_u64(value); ok {
					data.limit_state.tokens_remaining = u32(val)
				}
			case "anthropic-ratelimit-tokens-reset":
				parsed_time, consumed := time.rfc3339_to_time_utc(value)
				if consumed > 0 {
					data.limit_state.reset_time = time.time_to_unix(parsed_time)
				}
			}
		}
	}
}

is_retryable_status :: proc(status: u32) -> bool {
	return status == 429 || status == 529 || status == 503
}

rate_limiter_parse_retry_after :: proc(headers_str: string) -> time.Duration {
	if len(headers_str) == 0 {
		return 0
	}

	lines := strings.split(headers_str, "\n")
	defer delete(lines)

	for line in lines {
		if colon_idx := strings.index_byte(line, ':'); colon_idx >= 0 {
			key := line[:colon_idx]
			value := strings.trim_space(line[colon_idx + 1:])

			if strings.equal_fold(key, "retry-after") {
				if seconds, ok := strconv.parse_u64(value); ok {
					return time.Duration(seconds) * time.Second
				}
			}
		}
	}

	return 0
}
