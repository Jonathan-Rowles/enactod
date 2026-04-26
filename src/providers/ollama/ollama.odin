package ollama

import "../../../pkgs/ojson"
import c "../../core"
import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"

DEFAULT_NUM_CTX :: 32768

build_url :: proc(base_url: string) -> string {
	return fmt.tprintf("%s/api/chat", base_url)
}

build_auth :: proc(_: string) -> string {
	return ""
}

build_extra_headers :: proc(_: ^strings.Builder) {}

to_request :: proc(
	entries: []c.Chat_Entry,
	tools: []c.Tool_Def,
	model: string,
	caps: c.Capabilities,
	temperature: f32,
	stream: bool,
	thinking_budget: Maybe(int),
	num_ctx: int = DEFAULT_NUM_CTX,
	allocator := context.temp_allocator,
) -> Ollama_Request {
	messages := make([]Ollama_Message, len(entries), allocator)
	for entry, i in entries {
		messages[i] = to_message(entry, allocator)
	}

	wire_tools: []Ollama_Tool_Def
	if caps.supports_tools && len(tools) > 0 {
		wire_tools = make([]Ollama_Tool_Def, len(tools), allocator)
		for tool, i in tools {
			wire_tools[i] = to_tool(tool)
		}
	}

	think: string
	if budget, enabled := thinking_budget.?; enabled && caps.supports_thinking {
		think = "true" if budget != 0 else "false"
	}

	ctx := num_ctx
	if ctx <= 0 do ctx = DEFAULT_NUM_CTX

	options := Ollama_Options {
		num_ctx = ctx,
	}
	if caps.supports_temperature {
		options.temperature = fmt.aprintf("%f", temperature, allocator = allocator)
	}

	return Ollama_Request {
		model = model,
		stream = stream,
		think = think,
		messages = messages,
		tools = wire_tools,
		options = options,
	}
}

@(private)
to_message :: proc(entry: c.Chat_Entry, allocator: mem.Allocator) -> Ollama_Message {
	msg := Ollama_Message {
		role    = c.role_string(entry.role),
		content = c.resolve(entry.content),
	}
	if entry.role == .ASSISTANT && len(entry.tool_calls) > 0 {
		calls := make([]Ollama_Tool_Call, len(entry.tool_calls), allocator)
		for tc, i in entry.tool_calls {
			args := c.resolve(tc.arguments)
			if len(args) == 0 {
				args = "{}"
			}
			calls[i] = Ollama_Tool_Call {
				id = c.resolve(tc.id),
				function = {name = c.resolve(tc.name), arguments = args},
			}
		}
		msg.tool_calls = calls
	}
	return msg
}

@(private)
to_tool :: proc(tool: c.Tool_Def) -> Ollama_Tool_Def {
	schema := tool.input_schema
	if len(schema) == 0 {
		schema = `{"type":"object","properties":{}}`
	}
	return Ollama_Tool_Def {
		type = "function",
		function = {name = tool.name, description = tool.description, parameters = schema},
	}
}

parse_response :: proc(
	reader: ^ojson.Reader,
	body: string,
	arena: ^vmem.Arena = nil,
) -> c.Parsed_Response {
	perr := ojson.parse(reader, transmute([]byte)body)
	if perr != .OK {
		return c.Parsed_Response{error_msg = c.text("failed to parse response JSON", arena)}
	}
	if err_msg := c.extract_error_msg(reader); len(err_msg) > 0 {
		return c.Parsed_Response{error_msg = c.text(err_msg, arena)}
	}

	result: c.Parsed_Response
	result.usage.input_tokens, _ = ojson.read_int(reader, "prompt_eval_count")
	result.usage.output_tokens, _ = ojson.read_int(reader, "eval_count")

	resp, _ := unmarshal_ollama_response(reader)
	result.finish_reason = c.text(resp.done_reason, arena)
	result.content = c.text(resp.message.content, arena)
	if len(resp.message.thinking) > 0 {
		result.thinking = c.text(resp.message.thinking, arena)
	}

	if len(resp.message.tool_calls) > 0 {
		calls := make([]c.Parsed_Tool_Call, len(resp.message.tool_calls))
		for tc, i in resp.message.tool_calls {
			args := tc.function.arguments
			if len(args) == 0 {
				args = "{}"
			}
			calls[i] = c.Parsed_Tool_Call {
				id        = c.text(tc.id, arena),
				name      = c.text(tc.function.name, arena),
				arguments = c.text(args, arena),
			}
		}
		result.tool_calls = calls
	}

	return result
}

Stream :: struct {
	input_tokens:  int,
	output_tokens: int,
}

process_ndjson :: proc(
	s: ^Stream,
	reader: ^ojson.Reader,
	line: string,
	request_id: c.Request_ID,
	chunks: ^[dynamic]c.LLM_Stream_Chunk,
	arena: ^vmem.Arena = nil,
) {
	err := ojson.parse(reader, transmute([]byte)line)
	if err != .OK {
		return
	}

	tool_call_elems, tc_err := ojson.array_elements(reader, "message.tool_calls")
	if tc_err == .OK && len(tool_call_elems) > 0 {
		for elem in tool_call_elems {
			tool_name, _ := ojson.read_string_elem(reader, elem, "function.name")
			tool_id, _ := ojson.read_string_elem(reader, elem, "id")
			raw_args, raw_err := ojson.read_raw_elem(reader, elem, "function.arguments")
			if raw_err != .OK {
				raw_args = "{}"
			}
			append(
				chunks,
				c.LLM_Stream_Chunk {
					request_id = request_id,
					kind = .TOOL_START,
					name = c.text(tool_name, arena),
					content = c.text(tool_id, arena),
				},
			)
			append(
				chunks,
				c.LLM_Stream_Chunk {
					request_id = request_id,
					kind = .TOOL_INPUT_DELTA,
					content = c.text(raw_args, arena),
				},
			)
		}
	}

	if !ojson.is_null(reader, "message.thinking") {
		thinking, _ := ojson.read_string(reader, "message.thinking")
		if len(thinking) > 0 {
			append(
				chunks,
				c.LLM_Stream_Chunk {
					request_id = request_id,
					kind = .THINKING_DELTA,
					content = c.text(thinking, arena),
				},
			)
		}
	}

	if !ojson.is_null(reader, "message.content") {
		content, _ := ojson.read_string(reader, "message.content")
		if len(content) > 0 {
			append(
				chunks,
				c.LLM_Stream_Chunk {
					request_id = request_id,
					kind = .TEXT_DELTA,
					content = c.text(content, arena),
				},
			)
		}
	}

	done, done_err := ojson.read_bool(reader, "done")
	if done_err == .OK && done {
		in_tok, _ := ojson.read_int(reader, "prompt_eval_count")
		out_tok, _ := ojson.read_int(reader, "eval_count")
		s.input_tokens = in_tok
		s.output_tokens = out_tok
		usage_str := fmt.tprintf("%d,%d,0,0", in_tok, out_tok)
		append(
			chunks,
			c.LLM_Stream_Chunk {
				request_id = request_id,
				kind = .DONE,
				name = c.text(usage_str, arena),
				content = c.text("stop", arena),
			},
		)
	}
}

marshal_request :: proc(w: ^ojson.Writer, req: Ollama_Request) {
	marshal_ollama_request(w, req)
}
