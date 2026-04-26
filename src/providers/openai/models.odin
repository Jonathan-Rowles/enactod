package openai

import "../../../pkgs/ojson"
import c "../../core"
import "core:fmt"
import "core:strings"

models_url :: proc(base_url: string) -> string {
	return fmt.tprintf("%s/models", base_url)
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
		created, _ := ojson.read_int_elem(&reader, elem, "created")

		caps := capabilities(id)
		overlay_supported_parameters(&reader, elem, &caps)
		if ctx_len, ctx_err := ojson.read_int_elem(&reader, elem, "context_length");
		   ctx_err == .OK && ctx_len > 0 {
			caps.context_window = ctx_len
		}

		display := id
		if name, name_err := ojson.read_string_elem(&reader, elem, "name");
		   name_err == .OK && len(name) > 0 {
			display = name
		}

		out[i] = c.Model_Info {
			id             = strings.clone(id, allocator),
			display_name   = strings.clone(display, allocator),
			provider_name  = strings.clone(provider_name, allocator),
			context_window = caps.context_window,
			capabilities   = caps,
			created_unix   = i64(created),
		}
	}
	return out, true
}

@(private)
overlay_supported_parameters :: proc(
	reader: ^ojson.Reader,
	elem: ojson.Element,
	caps: ^c.Capabilities,
) {
	parent, perr := ojson.obj_element_from(reader, elem, "supported_parameters")
	if perr != .OK {
		return
	}
	items, err := ojson.array_elements_from(reader, parent)
	if err != .OK {
		return
	}

	caps.supports_temperature = false
	caps.supports_top_p = false
	caps.supports_tools = false
	caps.supports_thinking = false

	for item in items {
		name, str_err := ojson.read_string_value(reader, item)
		if str_err != .OK {
			continue
		}
		switch name {
		case "temperature":
			caps.supports_temperature = true
		case "top_p":
			caps.supports_top_p = true
		case "tools", "tool_choice":
			caps.supports_tools = true
		case "reasoning", "include_reasoning", "thinking":
			caps.supports_thinking = true
		}
	}
}
