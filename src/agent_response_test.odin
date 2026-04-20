#+build !freestanding
package enactod_impl

import "../pkgs/ojson"
import "core:testing"
import "providers/openai"

@(private = "file")
parse :: proc(body: string, format: API_Format) -> Parsed_Response {
	r: ojson.Reader
	ojson.init_reader(&r, max(len(body) * 4, 4096), context.temp_allocator)
	defer ojson.destroy_reader(&r)
	return parse_llm_response(&r, body, format)
}

@(test)
test_openai_parse_plain_text :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := `{"id":"chatcmpl-1","choices":[{"index":0,"message":{"role":"assistant","content":"Hello!"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}`
	resp := parse(body, .OPENAI_COMPAT)
	testing.expect_value(t, resolve(resp.content), "Hello!")
	testing.expect_value(t, resolve(resp.finish_reason), "stop")
	testing.expect_value(t, resolve(resp.error_msg), "")
	testing.expect_value(t, len(resp.tool_calls), 0)
	testing.expect_value(t, resp.usage.input_tokens, 10)
	testing.expect_value(t, resp.usage.output_tokens, 5)
}

@(test)
test_openai_parse_tool_call :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := `{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_time","arguments":"{\"tz\":\"UTC\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":20,"completion_tokens":10}}`
	resp := parse(body, .OPENAI_COMPAT)
	testing.expect_value(t, resolve(resp.finish_reason), "tool_calls")
	testing.expect_value(t, len(resp.tool_calls), 1)
	testing.expect_value(t, resolve(resp.tool_calls[0].id), "call_1")
	testing.expect_value(t, resolve(resp.tool_calls[0].name), "get_time")
	testing.expect_value(t, resolve(resp.tool_calls[0].arguments), `{"tz":"UTC"}`)
}

@(test)
test_openai_parse_error_body :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := `{"error":{"message":"invalid api key","type":"invalid_request_error"}}`
	resp := parse(body, .OPENAI_COMPAT)
	testing.expect_value(t, resolve(resp.error_msg), "invalid api key")
}

@(test)
test_openai_parse_malformed_json :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	resp := parse(`not json at all`, .OPENAI_COMPAT)
	testing.expect_value(t, resolve(resp.error_msg), "failed to parse response JSON")
}

@(test)
test_anthropic_parse_plain_text :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := `{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"Hi"}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":3}}`
	resp := parse(body, .ANTHROPIC)
	testing.expect_value(t, resolve(resp.content), "Hi")
	testing.expect_value(t, resolve(resp.finish_reason), "end_turn")
	testing.expect_value(t, resp.usage.input_tokens, 10)
	testing.expect_value(t, resp.usage.output_tokens, 3)
}

@(test)
test_anthropic_parse_thinking_and_tool_use :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := `{"content":[{"type":"thinking","thinking":"Let me think","signature":"sig_1"},{"type":"text","text":"Here is my answer"},{"type":"tool_use","id":"tool_1","name":"search","input":{"q":"x"}}],"stop_reason":"tool_use","usage":{"input_tokens":20,"output_tokens":15,"cache_creation_input_tokens":5,"cache_read_input_tokens":3}}`
	resp := parse(body, .ANTHROPIC)
	testing.expect_value(t, resolve(resp.content), "Here is my answer")
	testing.expect_value(t, resolve(resp.thinking), "Let me think")
	testing.expect_value(t, resolve(resp.thinking_signature), "sig_1")
	testing.expect_value(t, resolve(resp.finish_reason), "tool_use")
	testing.expect_value(t, len(resp.tool_calls), 1)
	testing.expect_value(t, resolve(resp.tool_calls[0].id), "tool_1")
	testing.expect_value(t, resolve(resp.tool_calls[0].name), "search")
	testing.expect_value(t, resp.usage.cache_creation_input_tokens, 5)
	testing.expect_value(t, resp.usage.cache_read_input_tokens, 3)
}

@(test)
test_anthropic_parse_multiple_text_blocks_joined :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := `{"content":[{"type":"text","text":"one"},{"type":"text","text":"two"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}`
	resp := parse(body, .ANTHROPIC)
	testing.expect_value(t, resolve(resp.content), "one\ntwo")
}

@(test)
test_anthropic_parse_empty_tool_input_defaults_to_object :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := `{"content":[{"type":"tool_use","id":"t1","name":"noop","input":{}}],"stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1}}`
	resp := parse(body, .ANTHROPIC)
	testing.expect_value(t, len(resp.tool_calls), 1)
	testing.expect_value(t, resolve(resp.tool_calls[0].arguments), "{}")
}

@(test)
test_anthropic_parse_error_body :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := `{"error":{"type":"invalid_request_error","message":"missing credentials"}}`
	resp := parse(body, .ANTHROPIC)
	testing.expect_value(t, resolve(resp.error_msg), "missing credentials")
}

@(test)
test_ollama_parse_plain_text :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := `{"model":"llama3","message":{"role":"assistant","content":"Hello from Ollama"},"done":true,"done_reason":"stop","prompt_eval_count":8,"eval_count":5}`
	resp := parse(body, .OLLAMA)
	testing.expect_value(t, resolve(resp.content), "Hello from Ollama")
	testing.expect_value(t, resolve(resp.finish_reason), "stop")
	testing.expect_value(t, resp.usage.input_tokens, 8)
	testing.expect_value(t, resp.usage.output_tokens, 5)
}

@(test)
test_ollama_parse_thinking :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := `{"message":{"role":"assistant","content":"answer","thinking":"planning..."},"done":true,"done_reason":"stop","prompt_eval_count":1,"eval_count":1}`
	resp := parse(body, .OLLAMA)
	testing.expect_value(t, resolve(resp.thinking), "planning...")
	testing.expect_value(t, resolve(resp.content), "answer")
}

@(test)
test_ollama_parse_tool_call :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := `{"message":{"role":"assistant","content":"","tool_calls":[{"id":"tc1","function":{"name":"search","arguments":{"q":"x"}}}]},"done":true,"done_reason":"stop","prompt_eval_count":2,"eval_count":2}`
	resp := parse(body, .OLLAMA)
	testing.expect_value(t, len(resp.tool_calls), 1)
	testing.expect_value(t, resolve(resp.tool_calls[0].id), "tc1")
	testing.expect_value(t, resolve(resp.tool_calls[0].name), "search")
}

@(test)
test_gemini_parse_plain_text :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := `{"candidates":[{"content":{"parts":[{"text":"Hello from Gemini"}]},"finishReason":"STOP"}]}`
	resp := parse(body, .GEMINI)
	testing.expect_value(t, resolve(resp.content), "Hello from Gemini")
	testing.expect_value(t, resolve(resp.finish_reason), "end_turn")
}

@(test)
test_gemini_parse_max_tokens_finish_reason_mapping :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := `{"candidates":[{"content":{"parts":[{"text":"truncated"}]},"finishReason":"MAX_TOKENS"}]}`
	resp := parse(body, .GEMINI)
	testing.expect_value(t, resolve(resp.finish_reason), "max_tokens")
}

@(test)
test_gemini_parse_thinking_part :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := `{"candidates":[{"content":{"parts":[{"text":"reasoning...","thought":true},{"text":"final answer"}]},"finishReason":"STOP"}]}`
	resp := parse(body, .GEMINI)
	testing.expect_value(t, resolve(resp.thinking), "reasoning...")
	testing.expect_value(t, resolve(resp.content), "final answer")
}

@(test)
test_gemini_parse_function_call :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := `{"candidates":[{"content":{"parts":[{"functionCall":{"name":"search","args":{"q":"x"}}}]},"finishReason":"STOP"}]}`
	resp := parse(body, .GEMINI)
	testing.expect_value(t, len(resp.tool_calls), 1)
	testing.expect_value(t, resolve(resp.tool_calls[0].name), "search")
}

@(test)
test_gemini_parse_missing_candidates_errors :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := `{"candidates":[]}`
	resp := parse(body, .GEMINI)
	testing.expect_value(t, resolve(resp.error_msg), "missing candidates in response")
}

@(test)
test_extract_error_msg_prefers_nested_message :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	r: ojson.Reader
	ojson.init_reader(&r, 4096, context.temp_allocator)
	defer ojson.destroy_reader(&r)
	body := `{"error":{"message":"deep","type":"x"}}`
	testing.expect_value(t, ojson.parse(&r, transmute([]byte)body), ojson.Error.OK)
	testing.expect_value(t, extract_error_msg(&r), "deep")
}

@(test)
test_extract_error_msg_falls_back_to_top_level :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	r: ojson.Reader
	ojson.init_reader(&r, 4096, context.temp_allocator)
	defer ojson.destroy_reader(&r)
	body := `{"error":"just a string"}`
	testing.expect_value(t, ojson.parse(&r, transmute([]byte)body), ojson.Error.OK)
	testing.expect_value(t, extract_error_msg(&r), "just a string")
}

@(test)
test_extract_error_msg_returns_empty_when_no_error :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	r: ojson.Reader
	ojson.init_reader(&r, 4096, context.temp_allocator)
	defer ojson.destroy_reader(&r)
	testing.expect_value(t, ojson.parse(&r, transmute([]byte)string(`{}`)), ojson.Error.OK)
	testing.expect_value(t, extract_error_msg(&r), "")
}

@(test)
test_KNOWN_BUG_gen_ojson_short_circuits_siblings :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	r: ojson.Reader
	ojson.init_reader(&r, 8192, context.temp_allocator)
	defer ojson.destroy_reader(&r)
	body := `{"choices":[{"index":0,"message":{"role":"assistant","content":"Hi"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}`
	testing.expect_value(t, ojson.parse(&r, transmute([]byte)body), ojson.Error.OK)
	resp, _ := openai.unmarshal_open_ai_response(&r)
	testing.expect_value(t, resp.usage.prompt_tokens, 0)
	testing.expect_value(t, resp.usage.completion_tokens, 0)
}
