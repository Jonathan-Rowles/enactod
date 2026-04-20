package core

import "core:strings"

SSE_Event :: struct {
	event_type: string,
	data:       string,
}

SSE_Parser :: struct {
	buf:      [dynamic]byte,
	events:   [dynamic]SSE_Event,
	consumed: int,
}

init_sse_parser :: proc(p: ^SSE_Parser) {
	p.buf = make([dynamic]byte, 0, 4096)
	p.events = make([dynamic]SSE_Event)
}

destroy_sse_parser :: proc(p: ^SSE_Parser) {
	delete(p.buf)
	delete(p.events)
}

reset_sse_parser :: proc(p: ^SSE_Parser) {
	clear(&p.buf)
	clear(&p.events)
	p.consumed = 0
}

sse_feed :: proc(p: ^SSE_Parser, data: []byte) -> []SSE_Event {
	clear(&p.events)

	if p.consumed > 0 {
		remaining := len(p.buf) - p.consumed
		if remaining > 0 {
			copy(p.buf[:remaining], p.buf[p.consumed:])
		}
		resize(&p.buf, remaining)
		p.consumed = 0
	}

	for b in data {
		if b != '\r' {
			append(&p.buf, b)
		}
	}

	scan_pos := 0
	for {
		buf_str := string(p.buf[scan_pos:])
		boundary := strings.index(buf_str, "\n\n")
		if boundary < 0 {
			break
		}

		event_str := buf_str[:boundary]
		scan_pos += boundary + 2

		event := parse_sse_event(event_str)
		if len(event.data) > 0 || len(event.event_type) > 0 {
			append(&p.events, event)
		}
	}
	p.consumed = scan_pos

	return p.events[:]
}

@(private)
parse_sse_event :: proc(raw: string) -> SSE_Event {
	event: SSE_Event
	remaining := raw
	for len(remaining) > 0 {
		nl := strings.index_byte(remaining, '\n')
		line: string
		if nl < 0 {
			line = remaining
			remaining = ""
		} else {
			line = remaining[:nl]
			remaining = remaining[nl + 1:]
		}

		if strings.has_prefix(line, "event:") {
			event.event_type = strings.trim_left_space(line[len("event:"):])
		} else if strings.has_prefix(line, "data:") {
			d := strings.trim_left_space(line[len("data:"):])
			if len(event.data) > 0 {
				event.data = strings.concatenate({event.data, "\n", d}, context.temp_allocator)
			} else {
				event.data = d
			}
		}
	}
	return event
}
