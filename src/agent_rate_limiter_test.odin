#+build !freestanding
package enactod_impl

import "../pkgs/actod"
import th "../pkgs/actod/test_harness"
import "core:testing"

@(private = "file")
make_limiter_harness :: proc(
	enabled: bool,
	worker_count: int,
) -> th.Test_Harness(Rate_Limiter_State) {
	h := th.create(
		Rate_Limiter_State {
			worker_name = "llm:test-agent:0",
			worker_count = worker_count,
			agent_name = "test-agent",
			enabled = enabled,
		},
		rate_limiter_behaviour,
	)
	th.init(&h)
	return h
}

@(private = "file")
make_call :: proc(id: Request_ID, caller: actod.PID, stream: bool = false) -> LLM_Call {
	return LLM_Call {
		request_id = id,
		caller = caller,
		payload = text(`{"body":"x"}`),
		url = text("https://api/x"),
		auth_header = text("auth: x"),
		stream = stream,
	}
}

@(test)
test_ratelim_passthrough_forwards_single_worker :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_limiter_harness(enabled = false, worker_count = 1)
	defer th.destroy(&h)

	worker_pid := actod.PID(900)
	th.register_pid(&h, "llm:test-agent:0", worker_pid)

	caller := actod.PID(10)
	th.send(&h, make_call(1, caller))

	fwd := th.expect_sent_to(&h, t, worker_pid, LLM_Call)
	testing.expect_value(t, fwd.request_id, Request_ID(1))
	testing.expect_value(t, fwd.caller, actod.PID(1))
}

@(test)
test_ratelim_passthrough_round_robins_multiple_workers :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_limiter_harness(enabled = false, worker_count = 3)
	defer th.destroy(&h)

	w0 := actod.PID(900)
	w1 := actod.PID(901)
	w2 := actod.PID(902)
	th.register_pid(&h, "llm:test-agent:0", w0)
	th.register_pid(&h, "llm:test-agent:1", w1)
	th.register_pid(&h, "llm:test-agent:2", w2)

	caller := actod.PID(10)
	th.send(&h, make_call(1, caller))
	th.send(&h, make_call(2, caller))
	th.send(&h, make_call(3, caller))
	th.send(&h, make_call(4, caller))

	th.expect_sent_to(&h, t, w0, LLM_Call)
	th.expect_sent_to(&h, t, w1, LLM_Call)
	th.expect_sent_to(&h, t, w2, LLM_Call)
	th.expect_sent_to(&h, t, w0, LLM_Call)
}

@(test)
test_ratelim_enabled_forwards_when_under_cap :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_limiter_harness(enabled = true, worker_count = 1)
	defer th.destroy(&h)

	worker_pid := actod.PID(900)
	th.register_pid(&h, "llm:test-agent:0", worker_pid)

	caller := actod.PID(10)
	th.send(&h, make_call(1, caller))

	th.expect_sent_to(&h, t, worker_pid, LLM_Call)
	s := th.get_state(&h)
	testing.expect_value(t, s.in_flight, u32(1))
	testing.expect_value(t, len(s.pending_calls), 1)
}

@(test)
test_ratelim_query_returns_status_snapshot :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_limiter_harness(enabled = true, worker_count = 1)
	defer th.destroy(&h)

	th.register_pid(&h, "llm:test-agent:0", actod.PID(900))
	caller := actod.PID(50)
	th.send(&h, make_call(1, caller))
	th.expect_sent_to(&h, t, actod.PID(900), LLM_Call)

	th.send(&h, Rate_Limiter_Query{request_id = 99, caller = caller})
	status := th.expect_sent_to(&h, t, caller, Rate_Limiter_Status)
	testing.expect_value(t, status.request_id, Request_ID(99))
	testing.expect_value(t, status.in_flight, u32(1))
	testing.expect_value(t, status.queue_depth, u32(0))
}

@(test)
test_ratelim_429_requeues_and_emits_retrying_event :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	context.logger.lowest_level = .Fatal
	h := make_limiter_harness(enabled = true, worker_count = 1)
	defer th.destroy(&h)

	worker_pid := actod.PID(900)
	th.register_pid(&h, "llm:test-agent:0", worker_pid)

	caller := actod.PID(10)
	th.send(&h, make_call(1, caller))
	th.expect_sent_to(&h, t, worker_pid, LLM_Call)

	th.send(&h, LLM_Result{request_id = 1, status_code = 429, headers = text("retry-after:2")})

	ev := th.expect_sent_to(&h, t, caller, Rate_Limit_Event)
	testing.expect_value(t, ev.kind, Rate_Limit_Event_Kind.RETRYING)
	testing.expect_value(t, ev.retry_count, u32(1))
	testing.expect(t, ev.retry_delay >= 2000)

	s := th.get_state(&h)
	testing.expect_value(t, len(s.queue), 1)
	testing.expect_value(t, s.queue[0].retry_count, u32(1))
}

@(test)
test_ratelim_max_retries_exceeded_forwards_error :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	context.logger.lowest_level = .Fatal
	h := make_limiter_harness(enabled = true, worker_count = 1)
	defer th.destroy(&h)

	worker_pid := actod.PID(900)
	th.register_pid(&h, "llm:test-agent:0", worker_pid)

	caller := actod.PID(10)
	th.send(&h, make_call(1, caller))
	th.expect_sent_to(&h, t, worker_pid, LLM_Call)

	for i in 0 ..< 3 {
		th.send(&h, LLM_Result{request_id = 1, status_code = 429})
		if i < 2 {
			th.expect_sent_to(&h, t, caller, Rate_Limit_Event)
			timer := th.expect_timer(&h, t)
			th.fire_timer(&h, timer.id)
			th.expect_sent_to(&h, t, worker_pid, LLM_Call)
		}
		_ = i
	}

	result := th.expect_sent_to(&h, t, caller, LLM_Result)
	testing.expect_value(t, result.status_code, u32(429))
}

@(test)
test_ratelim_success_removes_pending_and_forwards :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_limiter_harness(enabled = true, worker_count = 1)
	defer th.destroy(&h)

	worker_pid := actod.PID(900)
	th.register_pid(&h, "llm:test-agent:0", worker_pid)

	caller := actod.PID(10)
	th.send(&h, make_call(1, caller))
	th.expect_sent_to(&h, t, worker_pid, LLM_Call)

	th.send(&h, LLM_Result{request_id = 1, status_code = 200, body = text("done")})
	result := th.expect_sent_to(&h, t, caller, LLM_Result)
	testing.expect_value(t, resolve(result.body), "done")

	s := th.get_state(&h)
	testing.expect_value(t, len(s.pending_calls), 0)
	testing.expect_value(t, s.in_flight, u32(0))
}

@(test)
test_ratelim_streaming_pending_survives_until_done_chunk :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_limiter_harness(enabled = true, worker_count = 1)
	defer th.destroy(&h)

	worker_pid := actod.PID(900)
	th.register_pid(&h, "llm:test-agent:0", worker_pid)

	caller := actod.PID(10)
	th.send(&h, make_call(1, caller, stream = true))
	th.expect_sent_to(&h, t, worker_pid, LLM_Call)

	th.send(&h, LLM_Result{request_id = 1, status_code = 200})
	th.expect_sent_to(&h, t, caller, LLM_Result)

	s := th.get_state(&h)
	testing.expect_value(t, len(s.pending_calls), 1)
	pending, ok := s.pending_calls[1]
	testing.expect(t, ok)
	testing.expect_value(t, pending.result_sent, true)

	th.send(&h, LLM_Stream_Chunk{request_id = 1, kind = .TEXT_DELTA, content = text("hi")})
	chunk := th.expect_sent_to(&h, t, caller, LLM_Stream_Chunk)
	testing.expect_value(t, chunk.kind, Stream_Chunk_Kind.TEXT_DELTA)

	th.send(&h, LLM_Stream_Chunk{request_id = 1, kind = .DONE})
	th.expect_sent_to(&h, t, caller, LLM_Stream_Chunk)
	s2 := th.get_state(&h)
	testing.expect_value(t, len(s2.pending_calls), 0)
}
