package gemini

import "../../../pkgs/ojson"
import c "../../core"
import "core:fmt"
import "core:strings"

build_url :: proc(base_url: string, model: string, stream: bool) -> string {
	if stream {
		return fmt.tprintf("%s/v1beta/models/%s:streamGenerateContent?alt=sse", base_url, model)
	}
	return fmt.tprintf("%s/v1beta/models/%s:generateContent", base_url, model)
}

build_auth :: proc(api_key: string) -> string {
	return fmt.tprintf("x-goog-api-key: %s", api_key)
}

build_extra_headers :: proc(_: ^strings.Builder) {}

// nil → omit thinkingConfig (model default; 2.5 Pro/Flash think by default).
// 0   → disable thinking (valid on Flash/Flash-Lite).
// -1  → dynamic budget (Pro), request thought summaries.
// >0  → fixed budget, request thought summaries.
build_thinking_config :: proc(
	thinking_budget: Maybe(int),
	allocator := context.temp_allocator,
) -> string {
	budget, enabled := thinking_budget.?
	if !enabled {
		return ""
	}
	include_thoughts := budget != 0
	return fmt.aprintf(
		`{{"includeThoughts":%v,"thinkingBudget":%d}}`,
		include_thoughts,
		budget,
		allocator = allocator,
	)
}

to_request :: proc(
	entries: []c.Chat_Entry,
	tools: []c.Tool_Def,
	temperature: f32,
	max_tokens: int,
	thinking_budget: Maybe(int),
	allocator := context.temp_allocator,
) -> Gemini_Request {
	req := Gemini_Request {
		generation_config = Gemini_Generation_Config {
			temperature = temperature,
			max_output_tokens = max_tokens,
			thinking_config = build_thinking_config(thinking_budget, allocator),
		},
	}

	for entry in entries {
		content_s := c.resolve(entry.content)
		if entry.role == .SYSTEM && len(content_s) > 0 {
			sys_parts := make([]Gemini_Part, 1, allocator)
			sys_parts[0] = Gemini_Part {
				text = content_s,
			}
			req.system_instruction = {
				parts = sys_parts,
			}
			break
		}
	}

	contents: [dynamic]Gemini_Content
	contents.allocator = allocator

	i := 0
	for i < len(entries) {
		entry := entries[i]
		if entry.role == .SYSTEM {
			i += 1
			continue
		}

		if entry.role == .TOOL {
			group_end := i
			for group_end < len(entries) && entries[group_end].role == .TOOL {
				group_end += 1
			}
			parts := make([]Gemini_Part, group_end - i, allocator)
			for k in i ..< group_end {
				parts[k - i] = Gemini_Part {
					function_response = {
						name = c.resolve(entries[k].tool_call_id),
						response = {result = c.resolve(entries[k].content)},
					},
				}
			}
			append(&contents, Gemini_Content{role = "user", parts = parts})
			i = group_end
			continue
		}

		content_s := c.resolve(entry.content)

		if entry.role == .ASSISTANT && len(entry.tool_calls) > 0 {
			count := len(entry.tool_calls)
			if len(content_s) > 0 {count += 1}
			parts := make([]Gemini_Part, count, allocator)
			idx := 0
			if len(content_s) > 0 {
				parts[idx] = Gemini_Part {
					text = content_s,
				}
				idx += 1
			}
			for tc in entry.tool_calls {
				args := c.resolve(tc.arguments)
				if len(args) == 0 {
					args = "{}"
				}
				parts[idx] = Gemini_Part {
					function_call = {name = c.resolve(tc.name), args = args},
				}
				idx += 1
			}
			append(&contents, Gemini_Content{role = "model", parts = parts})
			i += 1
			continue
		}

		role := entry.role == .ASSISTANT ? "model" : "user"
		parts := make([]Gemini_Part, 1, allocator)
		parts[0] = Gemini_Part {
			text = content_s,
		}
		append(&contents, Gemini_Content{role = role, parts = parts})
		i += 1
	}

	req.contents = contents[:]

	if len(tools) > 0 {
		decls := make([]Gemini_Tool_Declaration, len(tools), allocator)
		for tool, idx in tools {
			schema := tool.input_schema
			if len(schema) == 0 {
				schema = `{"type":"object","properties":{}}`
			}
			decls[idx] = Gemini_Tool_Declaration {
				name        = tool.name,
				description = tool.description,
				parameters  = schema,
			}
		}
		wire_tools := make([]Gemini_Tool, 1, allocator)
		wire_tools[0] = Gemini_Tool {
			function_declarations = decls,
		}
		req.tools = wire_tools
	}

	return req
}

parse_response :: proc(reader: ^ojson.Reader, body: string) -> c.Parsed_Response {
	perr := ojson.parse(reader, transmute([]byte)body)
	if perr != .OK {
		return c.Parsed_Response{error_msg = c.text("failed to parse response JSON")}
	}
	if err_msg := c.extract_error_msg(reader); len(err_msg) > 0 {
		return c.Parsed_Response{error_msg = c.text(err_msg)}
	}

	resp, _ := unmarshal_gemini_response(reader)

	result: c.Parsed_Response
	if len(resp.candidates) == 0 {
		return c.Parsed_Response{error_msg = c.text("missing candidates in response")}
	}
	candidate := resp.candidates[0]

	// Defensive re-read — gen-ojson may drop finishReason when the nested
	// content parse returns Key_Not_Found from a missing optional Part field.
	finish_reason_str := candidate.finish_reason
	if len(finish_reason_str) == 0 {
		finish_reason_str, _ = ojson.read_string(reader, "candidates.0.finishReason")
	}

	switch finish_reason_str {
	case "STOP":
		result.finish_reason = c.text("end_turn")
	case "MAX_TOKENS":
		result.finish_reason = c.text("max_tokens")
	case:
		result.finish_reason = c.text(finish_reason_str)
	}

	text_parts: [dynamic]string
	text_parts.allocator = context.temp_allocator

	thinking_parts: [dynamic]string
	thinking_parts.allocator = context.temp_allocator

	tool_calls: [dynamic]c.Parsed_Tool_Call
	tool_calls.allocator = context.temp_allocator

	for part in candidate.content.parts {
		if len(part.text) > 0 {
			if part.thought {
				append(&thinking_parts, part.text)
			} else {
				append(&text_parts, part.text)
			}
			continue
		}
		if len(part.function_call.name) > 0 {
			name_text := c.text(part.function_call.name)
			args := part.function_call.args
			if len(args) == 0 {
				args = "{}"
			}
			append(
				&tool_calls,
				c.Parsed_Tool_Call{id = name_text, name = name_text, arguments = c.text(args)},
			)
		}
	}

	if len(text_parts) > 0 {
		if len(text_parts) == 1 {
			result.content = c.text(text_parts[0])
		} else {
			joined := strings.join(text_parts[:], "\n", context.temp_allocator)
			result.content = c.text(joined)
		}
	}

	if len(thinking_parts) > 0 {
		if len(thinking_parts) == 1 {
			result.thinking = c.text(thinking_parts[0])
		} else {
			joined := strings.join(thinking_parts[:], "\n", context.temp_allocator)
			result.thinking = c.text(joined)
		}
	}

	if len(tool_calls) > 0 {
		result.tool_calls = make([]c.Parsed_Tool_Call, len(tool_calls))
		copy(result.tool_calls, tool_calls[:])
	}

	// Gemini reports prompt tokens inclusive of cached. We surface the
	// cached slice via cache_read_input_tokens so agents can attribute
	// hits without double-counting input.
	result.usage.input_tokens = resp.usage_metadata.prompt_token_count
	result.usage.cache_read_input_tokens = resp.usage_metadata.cached_content_token_count
	// Thinking tokens are output-side on Gemini — fold into output so
	// totals match what the API bills.
	result.usage.output_tokens =
		resp.usage_metadata.candidates_token_count + resp.usage_metadata.thoughts_token_count
	return result
}

Stream :: struct {
	input_tokens:      int,
	output_tokens:     int,
	cache_read_tokens: int,
}

process_sse :: proc(
	s: ^Stream,
	reader: ^ojson.Reader,
	event: c.SSE_Event,
	request_id: c.Request_ID,
	chunks: ^[dynamic]c.LLM_Stream_Chunk,
) {
	data := event.data
	if len(data) == 0 {
		return
	}

	err := ojson.parse(reader, transmute([]byte)data)
	if err != .OK {
		return
	}

	if ojson.exists(reader, "error.message") {
		api_err, _ := ojson.read_string(reader, "error.message")
		append(
			chunks,
			c.LLM_Stream_Chunk{request_id = request_id, kind = .ERROR, content = c.text(api_err)},
		)
		return
	}

	parts, parts_err := ojson.array_elements(reader, "candidates.0.content.parts")
	if parts_err == .OK {
		for elem in parts {
			fn_name, fn_err := ojson.read_string_elem(reader, elem, "functionCall.name")
			if fn_err == .OK && len(fn_name) > 0 {
				raw_args, raw_err := ojson.read_raw_elem(reader, elem, "functionCall.args")
				if raw_err != .OK {
					raw_args = "{}"
				}
				append(
					chunks,
					c.LLM_Stream_Chunk {
						request_id = request_id,
						kind = .TOOL_START,
						name = c.text(fn_name),
						content = c.text(fn_name),
					},
				)
				append(
					chunks,
					c.LLM_Stream_Chunk {
						request_id = request_id,
						kind = .TOOL_INPUT_DELTA,
						content = c.text(raw_args),
					},
				)
				continue
			}

			text_val, text_err := ojson.read_string_elem(reader, elem, "text")
			if text_err == .OK && len(text_val) > 0 {
				is_thought, thought_err := ojson.read_bool_elem(reader, elem, "thought")
				if thought_err == .OK && is_thought {
					append(
						chunks,
						c.LLM_Stream_Chunk {
							request_id = request_id,
							kind = .THINKING_DELTA,
							content = c.text(text_val),
						},
					)
				} else {
					append(
						chunks,
						c.LLM_Stream_Chunk {
							request_id = request_id,
							kind = .TEXT_DELTA,
							content = c.text(text_val),
						},
					)
				}
			}
		}
	}

	// Gemini may split usageMetadata into a chunk separate from the one
	// carrying finishReason, and cached/thoughts counts often land only
	// on that tail chunk. Accumulate whenever the field is present so
	// the DONE chunk always uses the latest values.
	if ojson.exists(reader, "usageMetadata") {
		in_tok, in_err := ojson.read_int(reader, "usageMetadata.promptTokenCount")
		out_tok, out_err := ojson.read_int(reader, "usageMetadata.candidatesTokenCount")
		thoughts_tok, _ := ojson.read_int(reader, "usageMetadata.thoughtsTokenCount")
		cached_tok, _ := ojson.read_int(reader, "usageMetadata.cachedContentTokenCount")
		if in_err == .OK {s.input_tokens = in_tok}
		if out_err == .OK {s.output_tokens = out_tok + thoughts_tok}
		if cached_tok > 0 {s.cache_read_tokens = cached_tok}
	}

	finish_reason, finish_err := ojson.read_string(reader, "candidates.0.finishReason")
	if finish_err == .OK && len(finish_reason) > 0 {
		usage_str := fmt.tprintf(
			"%d,%d,0,%d",
			s.input_tokens,
			s.output_tokens,
			s.cache_read_tokens,
		)

		stop := "end_turn"
		if finish_reason == "MAX_TOKENS" {
			stop = "max_tokens"
		}

		append(
			chunks,
			c.LLM_Stream_Chunk {
				request_id = request_id,
				kind = .DONE,
				name = c.text(usage_str),
				content = c.text(stop),
			},
		)
	}
}

marshal_request :: proc(w: ^ojson.Writer, req: Gemini_Request) {
	marshal_gemini_request(w, req)
}
