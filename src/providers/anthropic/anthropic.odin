package anthropic

import "../../../pkgs/ojson"
import c "../../core"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:strings"

build_url :: proc(base_url: string) -> string {
	return fmt.tprintf("%s/v1/messages", base_url)
}

build_auth :: proc(api_key: string) -> string {
	return fmt.tprintf("x-api-key: %s", api_key)
}

build_extra_headers :: proc(sb: ^strings.Builder) {
	strings.write_string(sb, "anthropic-version: 2023-06-01")
}

apply_rolling_cache_breakpoint :: proc(msgs: []Anthropic_Message) {
	if len(msgs) == 0 {
		return
	}
	last := &msgs[len(msgs) - 1]
	if len(last.content) == 0 {
		return
	}
	for j := len(last.content) - 1; j >= 0; j -= 1 {
		switch &v in last.content[j] {
		case Anthropic_Text_Block:
			v.cache_control = {
				type = "ephemeral",
			}
			return
		case Anthropic_Tool_Use_Block:
			v.cache_control = {
				type = "ephemeral",
			}
			return
		case Anthropic_Tool_Result_Block:
			v.cache_control = {
				type = "ephemeral",
			}
			return
		case Anthropic_Thinking_Block:
		}
	}
}

to_request :: proc(
	entries: []c.Chat_Entry,
	tools: []c.Tool_Def,
	model: string,
	caps: c.Capabilities,
	temperature: f32,
	max_tokens: int,
	thinking_budget: Maybe(int),
	stream: bool,
	cache_mode: c.Cache_Mode,
	allocator := context.temp_allocator,
) -> Anthropic_Request {
	req := Anthropic_Request {
		model      = model,
		max_tokens = max_tokens,
		stream     = stream,
	}

	thinking_enabled := false
	if budget, set := thinking_budget.?;
	   set && caps.supports_thinking && budget >= caps.min_thinking_budget {
		req.thinking = {
			type          = "enabled",
			budget_tokens = budget,
		}
		thinking_enabled = true
	}

	if caps.supports_temperature && !thinking_enabled {
		req.temperature = fmt.aprintf("%f", temperature, allocator = allocator)
	}

	cache_enabled := cache_mode != .NONE && caps.supports_cache

	for entry in entries {
		content_s := c.resolve(entry.content)
		if entry.role == .SYSTEM && len(content_s) > 0 {
			block := Anthropic_Text_Block {
				text = content_s,
			}
			if cache_enabled {
				block.cache_control = {
					type = "ephemeral",
				}
			}
			sys := make([]Anthropic_Text_Block, 1, allocator)
			sys[0] = block
			req.system = sys
			break
		}
	}

	msgs: [dynamic]Anthropic_Message
	msgs.allocator = allocator

	i := 0
	user_cache_breakpoint_used := false
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
			blocks := make([]Anthropic_Content_Block, group_end - i, allocator)
			for k in i ..< group_end {
				blocks[k - i] = Anthropic_Tool_Result_Block {
					tool_use_id = c.resolve(entries[k].tool_call_id),
					content     = c.resolve(entries[k].content),
				}
			}
			append(&msgs, Anthropic_Message{role = "user", content = blocks})
			i = group_end
			continue
		}

		content_s := c.resolve(entry.content)
		thinking_s := c.resolve(entry.thinking)
		signature_s := c.resolve(entry.signature)
		origin_s := c.resolve(entry.origin_model)
		origin_matches := len(origin_s) == 0 || origin_s == model
		emit_thinking := thinking_enabled && len(thinking_s) > 0 && origin_matches

		if entry.role == .ASSISTANT && len(entry.tool_calls) > 0 {
			count := len(entry.tool_calls)
			if emit_thinking {count += 1}
			if len(content_s) > 0 {count += 1}
			blocks := make([]Anthropic_Content_Block, count, allocator)
			idx := 0
			if emit_thinking {
				blocks[idx] = Anthropic_Thinking_Block {
					thinking  = thinking_s,
					signature = signature_s,
				}
				idx += 1
			}
			if len(content_s) > 0 {
				blocks[idx] = Anthropic_Text_Block {
					text = content_s,
				}
				idx += 1
			}
			for tc in entry.tool_calls {
				args := c.resolve(tc.arguments)
				if len(args) == 0 {
					args = "{}"
				}
				blocks[idx] = Anthropic_Tool_Use_Block {
					id    = c.resolve(tc.id),
					name  = c.resolve(tc.name),
					input = args,
				}
				idx += 1
			}
			append(&msgs, Anthropic_Message{role = "assistant", content = blocks})
			i += 1
			continue
		}

		if entry.role == .USER && len(entry.cache_blocks) > 0 {
			blocks := make([]Anthropic_Content_Block, len(entry.cache_blocks), allocator)
			last := len(entry.cache_blocks) - 1
			apply_cache_control := cache_enabled && !user_cache_breakpoint_used
			for cb, idx in entry.cache_blocks {
				block := Anthropic_Text_Block {
					text = c.resolve(cb),
				}
				if idx == last && apply_cache_control {
					block.cache_control = {
						type = "ephemeral",
					}
				}
				blocks[idx] = block
			}
			append(&msgs, Anthropic_Message{role = "user", content = blocks})
			if apply_cache_control {
				user_cache_breakpoint_used = true
			}
			i += 1
			continue
		}

		role := entry.role == .ASSISTANT ? "assistant" : "user"
		if entry.role == .ASSISTANT && emit_thinking {
			blocks := make([]Anthropic_Content_Block, 2, allocator)
			blocks[0] = Anthropic_Thinking_Block {
				thinking  = thinking_s,
				signature = signature_s,
			}
			blocks[1] = Anthropic_Text_Block {
				text = content_s,
			}
			append(&msgs, Anthropic_Message{role = role, content = blocks})
		} else {
			blocks := make([]Anthropic_Content_Block, 1, allocator)
			blocks[0] = Anthropic_Text_Block {
				text = content_s,
			}
			append(&msgs, Anthropic_Message{role = role, content = blocks})
		}
		i += 1
	}

	req.messages = msgs[:]

	if cache_enabled {
		apply_rolling_cache_breakpoint(msgs[:])
	}

	wire_tools := make([]Anthropic_Tool, len(tools), allocator)
	for tool, idx in tools {
		schema := tool.input_schema
		if len(schema) == 0 {
			schema = `{"type":"object","properties":{}}`
		}
		wire_tools[idx] = Anthropic_Tool {
			name         = tool.name,
			description  = tool.description,
			input_schema = schema,
		}
		if cache_enabled && idx == len(tools) - 1 {
			wire_tools[idx].cache_control = {
				type = "ephemeral",
			}
		}
	}
	req.tools = wire_tools

	return req
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

	resp, _ := unmarshal_anthropic_response(reader)

	result: c.Parsed_Response
	result.finish_reason = c.text(resp.stop_reason, arena)

	thinking_parts: [dynamic]string
	thinking_parts.allocator = context.temp_allocator

	text_parts: [dynamic]string
	text_parts.allocator = context.temp_allocator

	tool_calls: [dynamic]c.Parsed_Tool_Call
	tool_calls.allocator = context.temp_allocator

	for block in resp.content {
		switch v in block {
		case Anthropic_Thinking_Block:
			if len(v.thinking) > 0 {
				append(&thinking_parts, v.thinking)
			}
			if len(v.signature) > 0 {
				result.thinking_signature = c.text(v.signature, arena)
			}
		case Anthropic_Text_Block:
			if len(v.text) > 0 {
				append(&text_parts, v.text)
			}
		case Anthropic_Tool_Use_Block:
			args := v.input
			if len(args) == 0 {
				args = "{}"
			}
			append(
				&tool_calls,
				c.Parsed_Tool_Call {
					id = c.text(v.id, arena),
					name = c.text(v.name, arena),
					arguments = c.text(args, arena),
				},
			)
		case Anthropic_Tool_Result_Block:
		}
	}

	if len(thinking_parts) > 0 {
		if len(thinking_parts) == 1 {
			result.thinking = c.text(thinking_parts[0], arena)
		} else {
			joined := strings.join(thinking_parts[:], "\n", context.temp_allocator)
			result.thinking = c.text(joined, arena)
		}
	}

	if len(text_parts) > 0 {
		if len(text_parts) == 1 {
			result.content = c.text(text_parts[0], arena)
		} else {
			joined := strings.join(text_parts[:], "\n", context.temp_allocator)
			result.content = c.text(joined, arena)
		}
	}

	if len(tool_calls) > 0 {
		result.tool_calls = make([]c.Parsed_Tool_Call, len(tool_calls))
		copy(result.tool_calls, tool_calls[:])
	}

	result.usage.input_tokens = resp.usage.input_tokens
	result.usage.output_tokens = resp.usage.output_tokens
	result.usage.cache_creation_input_tokens = resp.usage.cache_creation_input_tokens
	result.usage.cache_read_input_tokens = resp.usage.cache_read_input_tokens
	return result
}

Stream :: struct {
	current_type:          string,
	input_tokens:          int,
	output_tokens:         int,
	cache_creation_tokens: int,
	cache_read_tokens:     int,
}

process_sse :: proc(
	s: ^Stream,
	reader: ^ojson.Reader,
	event: c.SSE_Event,
	request_id: c.Request_ID,
	arena: ^vmem.Arena = nil,
) -> (
	c.LLM_Stream_Chunk,
	bool,
) {
	etype := event.event_type

	if etype == "message_start" {
		err := ojson.parse(reader, transmute([]byte)event.data)
		if err == .OK {
			s.input_tokens, _ = ojson.read_int(reader, "message.usage.input_tokens")
			s.cache_creation_tokens, _ = ojson.read_int(
				reader,
				"message.usage.cache_creation_input_tokens",
			)
			s.cache_read_tokens, _ = ojson.read_int(
				reader,
				"message.usage.cache_read_input_tokens",
			)
		}
		return {}, false
	}

	if etype == "content_block_start" {
		err := ojson.parse(reader, transmute([]byte)event.data)
		if err != .OK {
			return {}, false
		}
		block_type, _ := ojson.read_string(reader, "content_block.type")
		s.current_type = block_type

		if block_type == "tool_use" {
			tool_id, _ := ojson.read_string(reader, "content_block.id")
			tool_name, _ := ojson.read_string(reader, "content_block.name")
			return c.LLM_Stream_Chunk {
					request_id = request_id,
					kind = .TOOL_START,
					name = c.text(tool_name, arena),
					content = c.text(tool_id, arena),
				},
				true
		}
		return {}, false
	}

	if etype == "content_block_delta" {
		err := ojson.parse(reader, transmute([]byte)event.data)
		if err != .OK {
			return {}, false
		}
		delta_type, _ := ojson.read_string(reader, "delta.type")

		switch delta_type {
		case "thinking_delta":
			thinking, _ := ojson.read_string(reader, "delta.thinking")
			return c.LLM_Stream_Chunk {
					request_id = request_id,
					kind = .THINKING_DELTA,
					content = c.text(thinking, arena),
				},
				true
		case "signature_delta":
			sig, _ := ojson.read_string(reader, "delta.signature")
			return c.LLM_Stream_Chunk {
					request_id = request_id,
					kind = .THINKING_DELTA,
					name = c.text("signature", arena),
					content = c.text(sig, arena),
				},
				true
		case "text_delta":
			text_val, _ := ojson.read_string(reader, "delta.text")
			return c.LLM_Stream_Chunk {
					request_id = request_id,
					kind = .TEXT_DELTA,
					content = c.text(text_val, arena),
				},
				true
		case "input_json_delta":
			partial, _ := ojson.read_string(reader, "delta.partial_json")
			return c.LLM_Stream_Chunk {
					request_id = request_id,
					kind = .TOOL_INPUT_DELTA,
					content = c.text(partial, arena),
				},
				true
		}
		return {}, false
	}

	if etype == "message_delta" {
		err := ojson.parse(reader, transmute([]byte)event.data)
		if err != .OK {
			return {}, false
		}
		stop_reason, _ := ojson.read_string(reader, "delta.stop_reason")
		out_tokens, tok_err := ojson.read_int(reader, "usage.output_tokens")
		if tok_err == .OK {
			s.output_tokens = out_tokens
		}
		usage_str := fmt.tprintf(
			"%d,%d,%d,%d",
			s.input_tokens,
			s.output_tokens,
			s.cache_creation_tokens,
			s.cache_read_tokens,
		)
		return c.LLM_Stream_Chunk {
				request_id = request_id,
				kind = .DONE,
				name = c.text(usage_str, arena),
				content = c.text(stop_reason, arena),
			},
			true
	}

	if etype == "error" {
		return c.LLM_Stream_Chunk {
				request_id = request_id,
				kind = .ERROR,
				content = c.text(event.data, arena),
			},
			true
	}

	return {}, false
}

marshal_request :: proc(w: ^ojson.Writer, req: Anthropic_Request) {
	marshal_anthropic_request(w, req)
}
