package core

NDJSON_Parser :: struct {
	buf:      [dynamic]byte,
	lines:    [dynamic]string,
	consumed: int,
}

init_ndjson_parser :: proc(p: ^NDJSON_Parser) {
	p.buf = make([dynamic]byte, 0, 4096)
	p.lines = make([dynamic]string)
}

destroy_ndjson_parser :: proc(p: ^NDJSON_Parser) {
	delete(p.buf)
	delete(p.lines)
}

reset_ndjson_parser :: proc(p: ^NDJSON_Parser) {
	clear(&p.buf)
	clear(&p.lines)
	p.consumed = 0
}

ndjson_feed :: proc(p: ^NDJSON_Parser, data: []byte) -> []string {
	clear(&p.lines)

	if p.consumed > 0 {
		remaining := len(p.buf) - p.consumed
		if remaining > 0 {
			copy(p.buf[:remaining], p.buf[p.consumed:])
		}
		resize(&p.buf, remaining)
		p.consumed = 0
	}

	append(&p.buf, ..data)

	scan_pos := 0
	for i in 0 ..< len(p.buf) {
		if p.buf[i] == '\n' {
			line := string(p.buf[scan_pos:i])
			if len(line) > 0 && line[0] == '{' {
				append(&p.lines, line)
			}
			scan_pos = i + 1
		}
	}
	p.consumed = scan_pos

	return p.lines[:]
}
