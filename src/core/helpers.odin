package core

import "../../pkgs/ojson"
import "core:strings"

role_string :: proc(role: Chat_Role) -> string {
	switch role {
	case .SYSTEM:
		return "system"
	case .USER:
		return "user"
	case .ASSISTANT:
		return "assistant"
	case .TOOL:
		return "tool"
	}
	return "user"
}

extract_error_msg :: proc(reader: ^ojson.Reader) -> string {
	msg, err := ojson.read_string(reader, "error.message")
	if err == .OK && len(msg) > 0 do return msg
	msg, err = ojson.read_string(reader, "error")
	if err == .OK do return msg
	return ""
}

make_provider :: proc(
	name: string,
	base_url: string,
	api_key: string = "",
	format: API_Format = .OPENAI_COMPAT,
	headers: map[string]string = nil,
) -> Provider_Config {
	url := strings.trim_right(base_url, "/")
	extra_headers: string
	if len(headers) > 0 {
		sb := strings.builder_make(context.temp_allocator)
		first := true
		for k, v in headers {
			if !first {
				strings.write_byte(&sb, '\n')
			}
			first = false
			strings.write_string(&sb, k)
			strings.write_string(&sb, ": ")
			strings.write_string(&sb, v)
		}
		extra_headers = strings.clone(strings.to_string(sb))
	}
	return Provider_Config {
		name = name,
		base_url = url,
		api_key = api_key,
		format = format,
		extra_headers = extra_headers,
	}
}
