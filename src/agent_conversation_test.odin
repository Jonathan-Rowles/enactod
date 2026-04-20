#+build !freestanding
package enactod_impl

import "../pkgs/ojson"
import "core:strings"
import "core:testing"

@(test)
test_append_user_entry_cached_preserves_blocks :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	blocks := []Text{text("system-prefix"), text("docs"), text("query")}
	append_user_entry_cached(&entries, blocks)
	testing.expect_value(t, len(entries), 1)
	testing.expect_value(t, entries[0].role, Chat_Role.USER)
	testing.expect_value(t, len(entries[0].cache_blocks), 3)
	testing.expect_value(t, resolve(entries[0].cache_blocks[0]), "system-prefix")
	testing.expect_value(t, resolve(entries[0].cache_blocks[2]), "query")
}

@(test)
test_append_assistant_entry_with_tool_calls :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	calls := []Parsed_Tool_Call {
		{id = text("call_1"), name = text("get_time"), arguments = text(`{}`)},
		{id = text("call_2"), name = text("search"), arguments = text(`{"q":"x"}`)},
	}
	append_assistant_entry(&entries, text("one moment"), calls)
	testing.expect_value(t, len(entries), 1)
	testing.expect_value(t, entries[0].role, Chat_Role.ASSISTANT)
	testing.expect_value(t, resolve(entries[0].content), "one moment")
	testing.expect_value(t, len(entries[0].tool_calls), 2)
	testing.expect_value(t, resolve(entries[0].tool_calls[0].name), "get_time")
	testing.expect_value(t, resolve(entries[0].tool_calls[1].arguments), `{"q":"x"}`)
}

@(test)
test_free_chat_entries_clears :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_system_entry(&entries, "sys")
	append_user_entry(&entries, "hi")
	append_assistant_entry(
		&entries,
		text("hello"),
		[]Parsed_Tool_Call{{id = text("x"), name = text("y"), arguments = text("{}")}},
	)
	free_chat_entries(&entries)
	testing.expect_value(t, len(entries), 0)
}

@(private = "file")
build :: proc(entries: []Chat_Entry, tools: []Tool_Def, format: API_Format) -> string {
	w := ojson.init_writer(8192, context.temp_allocator)
	build_request_json(&w, entries, tools, "gpt-test", 0.7, 1024, format)
	return ojson.writer_string(&w)
}

@(private = "file")
build_anthropic :: proc(
	entries: []Chat_Entry,
	cache_mode: Cache_Mode = .NONE,
	thinking_budget: Maybe(int) = nil,
) -> string {
	w := ojson.init_writer(8192, context.temp_allocator)
	build_request_json(
		&w,
		entries,
		nil,
		"claude-test",
		0.7,
		1024,
		.ANTHROPIC,
		thinking_budget,
		false,
		cache_mode,
	)
	return ojson.writer_string(&w)
}

@(test)
test_build_openai_has_messages_and_model :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_system_entry(&entries, "You are helpful.")
	append_user_entry(&entries, "Hi")

	json := build(entries[:], nil, .OPENAI_COMPAT)
	testing.expect(t, strings.contains(json, `"model":"gpt-test"`))
	testing.expect(t, strings.contains(json, `"role":"system"`))
	testing.expect(t, strings.contains(json, `"content":"You are helpful."`))
	testing.expect(t, strings.contains(json, `"role":"user"`))
	testing.expect(t, strings.contains(json, `"content":"Hi"`))
	testing.expect(t, strings.contains(json, `"max_tokens":1024`))
}

@(test)
test_build_openai_includes_tools :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_user_entry(&entries, "what time?")
	tools := []Tool_Def {
		{
			name = "get_time",
			description = "current time",
			input_schema = `{"type":"object","properties":{}}`,
		},
	}
	json := build(entries[:], tools, .OPENAI_COMPAT)
	testing.expect(t, strings.contains(json, `"name":"get_time"`))
	testing.expect(t, strings.contains(json, `"description":"current time"`))
	testing.expect(t, strings.contains(json, `"type":"function"`))
}

@(test)
test_build_anthropic_system_is_separate_field :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_system_entry(&entries, "helpful assistant")
	append_user_entry(&entries, "hi")

	json := build_anthropic(entries[:])
	testing.expect(t, strings.contains(json, `"system":`))
	testing.expect(t, strings.contains(json, `"text":"helpful assistant"`))
	testing.expect(t, !strings.contains(json, `"role":"system"`))
}

@(test)
test_build_anthropic_cache_mode_ephemeral_adds_cache_control :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_system_entry(&entries, "big system prompt")
	append_user_entry(&entries, "hi")

	json := build_anthropic(entries[:], cache_mode = .EPHEMERAL)
	testing.expect(t, strings.contains(json, `"cache_control":{"type":"ephemeral"}`))
}

@(test)
test_build_anthropic_no_cache_mode_no_cache_control :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_system_entry(&entries, "s")
	append_user_entry(&entries, "u")
	json := build_anthropic(entries[:], cache_mode = .NONE)
	testing.expect(t, !strings.contains(json, "cache_control"))
}

@(test)
test_build_anthropic_thinking_budget_enables_thinking_block :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_user_entry(&entries, "hard problem")
	json := build_anthropic(entries[:], thinking_budget = 4096)
	testing.expect(t, strings.contains(json, `"thinking":{"type":"enabled","budget_tokens":4096}`))
}

@(test)
test_build_ollama_sets_model_and_num_ctx :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_user_entry(&entries, "hi")
	w := ojson.init_writer(8192, context.temp_allocator)
	build_request_json(&w, entries[:], nil, "llama3", 0.5, 1024, .OLLAMA)
	json := ojson.writer_string(&w)
	testing.expect(t, strings.contains(json, `"model":"llama3"`))
	testing.expect(t, strings.contains(json, `"num_ctx":32768`))
}

@(test)
test_build_gemini_uses_contents_with_role :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_user_entry(&entries, "hi")
	w := ojson.init_writer(8192, context.temp_allocator)
	build_request_json(&w, entries[:], nil, "gemini-test", 0.5, 512, .GEMINI)
	json := ojson.writer_string(&w)
	testing.expect(t, strings.contains(json, `"contents":`))
	testing.expect(t, strings.contains(json, `"role":"user"`))
	testing.expect(t, strings.contains(json, `"text":"hi"`))
	testing.expect(t, strings.contains(json, `"maxOutputTokens":512`))
}

@(test)
test_build_request_json_escapes_quotes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_user_entry(&entries, `he said "hi"`)
	json := build(entries[:], nil, .OPENAI_COMPAT)
	testing.expect(t, strings.contains(json, `"content":"he said \"hi\""`))
}
