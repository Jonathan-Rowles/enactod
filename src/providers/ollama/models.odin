package ollama

import "../../../pkgs/ojson"
import c "../../core"
import "core:fmt"
import "core:strings"

models_url :: proc(base_url: string) -> string {
	return fmt.tprintf("%s/api/tags", base_url)
}

show_url :: proc(base_url: string) -> string {
	return fmt.tprintf("%s/api/show", base_url)
}

show_request_body :: proc(model_id: string, allocator := context.temp_allocator) -> string {
	return fmt.aprintf(`{{"model":"%s"}}`, model_id, allocator = allocator)
}

parse_show_capabilities :: proc(body: []byte, base: c.Capabilities) -> (c.Capabilities, bool) {
	reader: ojson.Reader
	ojson.init_reader(&reader)

	if ojson.parse(&reader, body) != .OK {
		return base, false
	}
	if msg := c.extract_error_msg(&reader); len(msg) > 0 {
		return base, false
	}

	items, err := ojson.array_elements(&reader, "capabilities")
	if err != .OK {
		return base, true
	}

	out := base
	out.supports_tools = false
	out.supports_thinking = false

	for item in items {
		name, str_err := ojson.read_string_value(&reader, item)
		if str_err != .OK {
			continue
		}
		switch name {
		case "tools":
			out.supports_tools = true
		case "thinking":
			out.supports_thinking = true
		}
	}
	return out, true
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

	out := make([]c.Model_Info, len(elems), allocator)
	for elem, i in elems {
		id, _ := ojson.read_string_elem(&reader, elem, "name")
		caps := capabilities(id)

		out[i] = c.Model_Info {
			id             = strings.clone(id, allocator),
			display_name   = strings.clone(id, allocator),
			provider_name  = strings.clone(provider_name, allocator),
			context_window = caps.context_window,
			capabilities   = caps,
		}
	}
	return out, true
}
