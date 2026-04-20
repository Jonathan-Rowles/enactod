#+build !freestanding
package enactod_impl

import "core:testing"

@(test)
test_ndjson_single_line :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p: NDJSON_Parser
	init_ndjson_parser(&p)
	defer destroy_ndjson_parser(&p)

	lines := ndjson_feed(&p, transmute([]byte)string(`{"a":1}` + "\n"))
	testing.expect_value(t, len(lines), 1)
	testing.expect_value(t, lines[0], `{"a":1}`)
}

@(test)
test_ndjson_multiple_lines_one_feed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p: NDJSON_Parser
	init_ndjson_parser(&p)
	defer destroy_ndjson_parser(&p)

	lines := ndjson_feed(
		&p,
		transmute([]byte)string(`{"a":1}` + "\n" + `{"b":2}` + "\n" + `{"c":3}` + "\n"),
	)
	testing.expect_value(t, len(lines), 3)
	testing.expect_value(t, lines[0], `{"a":1}`)
	testing.expect_value(t, lines[1], `{"b":2}`)
	testing.expect_value(t, lines[2], `{"c":3}`)
}

@(test)
test_ndjson_partial_tail_preserved_across_feeds :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p: NDJSON_Parser
	init_ndjson_parser(&p)
	defer destroy_ndjson_parser(&p)

	l1 := ndjson_feed(&p, transmute([]byte)string(`{"k":`))
	testing.expect_value(t, len(l1), 0)

	l2 := ndjson_feed(&p, transmute([]byte)string(`"v"}` + "\n" + `{"next":`))
	testing.expect_value(t, len(l2), 1)
	testing.expect_value(t, l2[0], `{"k":"v"}`)

	l3 := ndjson_feed(&p, transmute([]byte)string(`42}` + "\n"))
	testing.expect_value(t, len(l3), 1)
	testing.expect_value(t, l3[0], `{"next":42}`)
}

@(test)
test_ndjson_non_object_lines_dropped :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p: NDJSON_Parser
	init_ndjson_parser(&p)
	defer destroy_ndjson_parser(&p)

	lines := ndjson_feed(
		&p,
		transmute([]byte)string("\n" + "comment line\n" + `{"keep":true}` + "\n"),
	)
	testing.expect_value(t, len(lines), 1)
	testing.expect_value(t, lines[0], `{"keep":true}`)
}

@(test)
test_ndjson_reset_clears_buffer :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p: NDJSON_Parser
	init_ndjson_parser(&p)
	defer destroy_ndjson_parser(&p)

	ndjson_feed(&p, transmute([]byte)string(`{"a":1}` + "\npartial"))
	reset_ndjson_parser(&p)
	testing.expect_value(t, len(p.buf), 0)
	testing.expect_value(t, len(p.lines), 0)
}
