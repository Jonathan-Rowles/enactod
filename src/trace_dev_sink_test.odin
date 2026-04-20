#+build !freestanding
package enactod_impl

import th "../pkgs/actod/test_harness"
import "core:testing"

@(private = "file")
make_sink :: proc(md_dir: string = "") -> th.Test_Harness(Dev_Trace_State) {
	return th.create(
		Dev_Trace_State{config = Dev_Trace_Config{md_dir = md_dir}},
		dev_trace_sink_behaviour,
	)
}

@(test)
test_persist_trace_event_clones_all_text_fields :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	ev := Trace_Event {
		kind       = .LLM_CALL_DONE,
		request_id = 7,
		agent_name = text("demo"),
		call_id    = text("call_1"),
		tool_name  = text("search"),
		model      = text("gpt-4o-mini"),
		provider   = text("openai"),
		detail     = text("assistant said hi"),
	}
	p := persist_trace_event(ev)
	testing.expect_value(t, resolve(p.agent_name), "demo")
	testing.expect_value(t, resolve(p.call_id), "call_1")
	testing.expect_value(t, resolve(p.tool_name), "search")
	testing.expect_value(t, resolve(p.model), "gpt-4o-mini")
	testing.expect_value(t, resolve(p.provider), "openai")
	testing.expect_value(t, resolve(p.detail), "assistant said hi")
	testing.expect_value(t, p.kind, Trace_Event_Kind.LLM_CALL_DONE)
	got_req: u64 = u64(p.request_id)
	want_req: u64 = 7
	testing.expect_value(t, got_req, want_req)
}

@(test)
test_sink_begins_buffer_on_request_start :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_sink(md_dir = "/tmp/enactod-trace-dir-does-not-need-to-exist")
	defer th.destroy(&h)

	th.init(&h)
	th.send(&h, Trace_Event{kind = .REQUEST_START, request_id = 1, detail = text("hi")})

	s := th.get_state(&h)
	testing.expect_value(t, len(s.open_requests), 1)
	buf, ok := s.open_requests[1]
	testing.expect(t, ok)
	testing.expect_value(t, len(buf.events), 1)
}

@(test)
test_sink_buffers_intermediate_events :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_sink(md_dir = "/tmp")
	defer th.destroy(&h)
	th.init(&h)

	th.send(&h, Trace_Event{kind = .REQUEST_START, request_id = 1, detail = text("q")})
	th.send(&h, Trace_Event{kind = .LLM_CALL_START, request_id = 1})
	th.send(&h, Trace_Event{kind = .LLM_CALL_DONE, request_id = 1, detail = text("a")})

	s := th.get_state(&h)
	buf, ok := s.open_requests[1]
	testing.expect(t, ok)
	testing.expect_value(t, len(buf.events), 3)
}

@(test)
test_sink_drops_events_for_unknown_request :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_sink(md_dir = "/tmp")
	defer th.destroy(&h)
	th.init(&h)

	th.send(&h, Trace_Event{kind = .LLM_CALL_DONE, request_id = 99})
	s := th.get_state(&h)
	testing.expect_value(t, len(s.open_requests), 0)
}
