package gemini

import "../../../pkgs/ojson"
import c "../../core"
import "core:fmt"
import "core:strings"

models_url :: proc(base_url: string, api_key: string) -> string {
	if len(api_key) > 0 {
		return fmt.tprintf("%s/v1beta/models?key=%s&pageSize=1000", base_url, api_key)
	}
	return fmt.tprintf("%s/v1beta/models?pageSize=1000", base_url)
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

	elems, err := ojson.array_elements(&reader, "models")
	if err != .OK {
		return nil, false
	}

	out := make([dynamic]c.Model_Info, 0, len(elems), allocator)
	for elem in elems {
		raw_name, _ := ojson.read_string_elem(&reader, elem, "name")
		id := raw_name
		if strings.has_prefix(id, "models/") {
			id = id[len("models/"):]
		}
		display, _ := ojson.read_string_elem(&reader, elem, "displayName")
		input_limit, _ := ojson.read_int_elem(&reader, elem, "inputTokenLimit")
		output_limit, _ := ojson.read_int_elem(&reader, elem, "outputTokenLimit")

		caps := capabilities(id)
		if input_limit > 0 {
			caps.context_window = input_limit
		}
		if output_limit > 0 {
			caps.max_output_tokens = output_limit
		}

		append(
			&out,
			c.Model_Info {
				id = strings.clone(id, allocator),
				display_name = strings.clone(display, allocator),
				provider_name = strings.clone(provider_name, allocator),
				context_window = caps.context_window,
				capabilities = caps,
			},
		)
	}
	return out[:], true
}
