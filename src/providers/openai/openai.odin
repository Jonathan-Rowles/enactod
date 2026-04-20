package openai

import "../../../pkgs/ojson"
import c "../../core"
import "core:fmt"
import "core:mem"
import "core:strings"

build_url :: proc(base_url: string) -> string {
	return fmt.tprintf("%s/chat/completions", base_url)
}

build_auth :: proc(api_key: string) -> string {
	return fmt.tprintf("Authorization: Bearer %s", api_key)
}

build_extra_headers :: proc(_: ^strings.Builder) {}

to_request :: proc(
	entries: []c.Chat_Entry,
	tools: []c.Tool_Def,
	model: string,
	temperature: f32,
	max_tokens: int,
	stream: bool,
	allocator := context.temp_allocator,
) -> OpenAI_Request {
	messages := make([]OpenAI_Message, len(entries), allocator)
	for entry, i in entries {
		messages[i] = to_message(entry, allocator)
	}

	wire_tools := make([]OpenAI_Tool_Def, len(tools), allocator)
	for tool, i in tools {
		wire_tools[i] = to_tool(tool)
	}

	return OpenAI_Request {
		model = model,
		temperature = temperature,
		max_tokens = max_tokens,
		stream = stream,
		messages = messages,
		tools = wire_tools,
	}
}

@(private)
to_message :: proc(entry: c.Chat_Entry, allocator: mem.Allocator) -> OpenAI_Message {
	msg := OpenAI_Message {
		role    = c.role_string(entry.role),
		content = c.resolve(entry.content),
	}
	if entry.role == .TOOL {
		tool_id_s := c.resolve(entry.tool_call_id)
		if len(tool_id_s) > 0 {
			msg.tool_call_id = tool_id_s
		}
	}
	if entry.role == .ASSISTANT && len(entry.tool_calls) > 0 {
		calls := make([]OpenAI_Tool_Call, len(entry.tool_calls), allocator)
		for tc, i in entry.tool_calls {
			calls[i] = OpenAI_Tool_Call {
				id = c.resolve(tc.id),
				type = "function",
				function = {name = c.resolve(tc.name), arguments = c.resolve(tc.arguments)},
			}
		}
		msg.tool_calls = calls
	}
	return msg
}

to_tool :: proc(tool: c.Tool_Def) -> OpenAI_Tool_Def {
	schema := tool.input_schema
	if len(schema) == 0 {
		schema = `{"type":"object","properties":{}}`
	}
	return OpenAI_Tool_Def {
		type = "function",
		function = {name = tool.name, description = tool.description, parameters = schema},
	}
}

parse_response :: proc(reader: ^ojson.Reader, body: string) -> c.Parsed_Response {
	perr := ojson.parse(reader, transmute([]byte)body)
	if perr != .OK {
		return c.Parsed_Response{error_msg = c.text("failed to parse response JSON")}
	}
	if err_msg := c.extract_error_msg(reader); len(err_msg) > 0 {
		return c.Parsed_Response{error_msg = c.text(err_msg)}
	}

	result: c.Parsed_Response
	// Read usage BEFORE unmarshal: the generator's short-circuit on
	// Key_Not_Found leaves the reader in a state where some siblings
	// become unreadable.
	result.usage.input_tokens, _ = ojson.read_int(reader, "usage.prompt_tokens")
	result.usage.output_tokens, _ = ojson.read_int(reader, "usage.completion_tokens")

	resp, _ := unmarshal_open_ai_response(reader)

	if len(resp.choices) > 0 {
		choice := resp.choices[0]
		result.finish_reason = c.text(choice.finish_reason)
		result.content = c.text(choice.message.content)
		if len(choice.message.tool_calls) > 0 {
			calls := make([]c.Parsed_Tool_Call, len(choice.message.tool_calls))
			for tc, i in choice.message.tool_calls {
				calls[i] = c.Parsed_Tool_Call {
					id        = c.text(tc.id),
					name      = c.text(tc.function.name),
					arguments = c.text(tc.function.arguments),
				}
			}
			result.tool_calls = calls
		}
	}

	return result
}

Stream :: struct {}

process_sse :: proc(
	_: ^Stream,
	reader: ^ojson.Reader,
	event: c.SSE_Event,
	request_id: c.Request_ID,
) -> (
	c.LLM_Stream_Chunk,
	bool,
) {
	data := event.data
	if len(data) == 0 {
		return {}, false
	}

	if strings.trim_space(data) == "[DONE]" {
		return c.LLM_Stream_Chunk{request_id = request_id, kind = .DONE, content = c.text("stop")},
			true
	}

	err := ojson.parse(reader, transmute([]byte)data)
	if err != .OK {
		return {}, false
	}

	fn_name, fn_ok := ojson.read_string(reader, "choices.0.delta.tool_calls.0.function.name")
	if fn_ok == .OK && len(fn_name) > 0 {
		tool_id, _ := ojson.read_string(reader, "choices.0.delta.tool_calls.0.id")
		return c.LLM_Stream_Chunk {
				request_id = request_id,
				kind = .TOOL_START,
				name = c.text(fn_name),
				content = c.text(tool_id),
			},
			true
	}

	fn_args, args_ok := ojson.read_string(
		reader,
		"choices.0.delta.tool_calls.0.function.arguments",
	)
	if args_ok == .OK && len(fn_args) > 0 {
		return c.LLM_Stream_Chunk {
				request_id = request_id,
				kind = .TOOL_INPUT_DELTA,
				content = c.text(fn_args),
			},
			true
	}

	if !ojson.is_null(reader, "choices.0.finish_reason") {
		reason, _ := ojson.read_string(reader, "choices.0.finish_reason")
		if len(reason) > 0 {
			return c.LLM_Stream_Chunk {
					request_id = request_id,
					kind = .DONE,
					content = c.text(reason),
				},
				true
		}
	}

	if !ojson.is_null(reader, "choices.0.delta.content") {
		delta_content, _ := ojson.read_string(reader, "choices.0.delta.content")
		if len(delta_content) > 0 {
			return c.LLM_Stream_Chunk {
					request_id = request_id,
					kind = .TEXT_DELTA,
					content = c.text(delta_content),
				},
				true
		}
	}

	return {}, false
}

marshal_request :: proc(w: ^ojson.Writer, req: OpenAI_Request) {
	marshal_open_ai_request(w, req)
}
