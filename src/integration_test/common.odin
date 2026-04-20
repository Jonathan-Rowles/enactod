package integration_test

import "core:fmt"
import "core:strings"
import "core:testing"

check :: proc(t: ^testing.T, ok: bool, desc: string, detail: string = "") {
	if ok {
		fmt.printf("  PASS  %s\n", desc)
	} else {
		fmt.printf("  FAIL  %s :: %s\n", desc, detail)
		testing.expect(t, false, desc)
	}
}

find_header_end :: proc(buf: []byte) -> int {
	if len(buf) < 4 {
		return -1
	}
	for i in 0 ..= len(buf) - 4 {
		if buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' && buf[i + 3] == '\n' {
			return i + 4
		}
	}
	return -1
}

parse_content_length :: proc(headers: []byte) -> int {
	s := string(headers)
	needle := "content-length:"
	lower := strings.to_lower(s, context.temp_allocator)
	idx := strings.index(lower, needle)
	if idx < 0 {
		return 0
	}
	rest := strings.trim_space(s[idx + len(needle):])
	eol := strings.index_byte(rest, '\r')
	if eol < 0 {
		eol = len(rest)
	}
	val := strings.trim_space(rest[:eol])
	n := 0
	for c in val {
		if c < '0' || c > '9' {
			break
		}
		n = n * 10 + int(c - '0')
	}
	return n
}
