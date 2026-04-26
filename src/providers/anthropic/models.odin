package anthropic

import "../../../pkgs/ojson"
import c "../../core"
import "core:fmt"
import "core:strings"

models_url :: proc(base_url: string) -> string {
	return fmt.tprintf("%s/v1/models?limit=1000", base_url)
}

parse_models :: proc(
	body: []byte,
	provider_name: string,
	allocator := context.allocator,
) -> (
	[]c.Model_Info,
	bool,
) {
	reader: ojson.Reader
	ojson.init_reader(&reader)

	if ojson.parse(&reader, body) != .OK {
		return nil, false
	}
	if msg := c.extract_error_msg(&reader); len(msg) > 0 {
		return nil, false
	}

	elems, err := ojson.array_elements(&reader, "data")
	if err != .OK {
		return nil, false
	}

	out := make([]c.Model_Info, len(elems), allocator)
	for elem, i in elems {
		id, _ := ojson.read_string_elem(&reader, elem, "id")
		display, _ := ojson.read_string_elem(&reader, elem, "display_name")

		caps := capabilities(id)
		out[i] = c.Model_Info {
			id             = strings.clone(id, allocator),
			display_name   = strings.clone(display, allocator),
			provider_name  = strings.clone(provider_name, allocator),
			context_window = caps.context_window,
			capabilities   = caps,
		}
	}
	return out, true
}
