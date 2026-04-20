#+build !freestanding
package enactod_impl

import "core:testing"

@(test)
test_sse_single_event :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p: SSE_Parser
	init_sse_parser(&p)
	defer destroy_sse_parser(&p)

	events := sse_feed(&p, transmute([]byte)string("data: hello\n\n"))
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0].data, "hello")
	testing.expect_value(t, events[0].event_type, "")
}

@(test)
test_sse_event_with_type :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p: SSE_Parser
	init_sse_parser(&p)
	defer destroy_sse_parser(&p)

	events := sse_feed(&p, transmute([]byte)string("event: message_start\ndata: {\"x\":1}\n\n"))
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0].event_type, "message_start")
	testing.expect_value(t, events[0].data, `{"x":1}`)
}

@(test)
test_sse_multiple_events_single_feed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p: SSE_Parser
	init_sse_parser(&p)
	defer destroy_sse_parser(&p)

	events := sse_feed(&p, transmute([]byte)string("data: one\n\ndata: two\n\ndata: three\n\n"))
	testing.expect_value(t, len(events), 3)
	testing.expect_value(t, events[0].data, "one")
	testing.expect_value(t, events[1].data, "two")
	testing.expect_value(t, events[2].data, "three")
}

@(test)
test_sse_event_split_across_chunks :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p: SSE_Parser
	init_sse_parser(&p)
	defer destroy_sse_parser(&p)

	ev1 := sse_feed(&p, transmute([]byte)string("event: delta\ndata: hel"))
	testing.expect_value(t, len(ev1), 0)

	ev2 := sse_feed(&p, transmute([]byte)string("lo\n\n"))
	testing.expect_value(t, len(ev2), 1)
	testing.expect_value(t, ev2[0].event_type, "delta")
	testing.expect_value(t, ev2[0].data, "hello")
}

@(test)
test_sse_strips_carriage_returns :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p: SSE_Parser
	init_sse_parser(&p)
	defer destroy_sse_parser(&p)

	events := sse_feed(&p, transmute([]byte)string("data: hi\r\n\r\n"))
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0].data, "hi")
}

@(test)
test_sse_multi_line_data_joined_with_newline :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p: SSE_Parser
	init_sse_parser(&p)
	defer destroy_sse_parser(&p)

	events := sse_feed(&p, transmute([]byte)string("data: line1\ndata: line2\n\n"))
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0].data, "line1\nline2")
}

@(test)
test_sse_empty_event_skipped :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p: SSE_Parser
	init_sse_parser(&p)
	defer destroy_sse_parser(&p)

	events := sse_feed(&p, transmute([]byte)string("\n\n"))
	testing.expect_value(t, len(events), 0)
}

@(test)
test_sse_buffer_compacts_after_consumed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p: SSE_Parser
	init_sse_parser(&p)
	defer destroy_sse_parser(&p)

	sse_feed(&p, transmute([]byte)string("data: one\n\n"))
	events := sse_feed(&p, transmute([]byte)string("data: two\n\n"))
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0].data, "two")
	testing.expect_value(t, p.consumed, len(p.buf))
}

@(test)
test_sse_reset_clears_everything :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p: SSE_Parser
	init_sse_parser(&p)
	defer destroy_sse_parser(&p)

	sse_feed(&p, transmute([]byte)string("data: hi\n\n"))
	reset_sse_parser(&p)
	testing.expect_value(t, len(p.buf), 0)
	testing.expect_value(t, len(p.events), 0)
	testing.expect_value(t, p.consumed, 0)
}
