#+build !freestanding
package enactod_impl

import "../pkgs/ojson"
import "core:strings"
import "core:testing"

@(private = "file")
build_for :: proc(
	model: string,
	format: API_Format,
	entries: []Chat_Entry,
	thinking_budget: Maybe(int) = nil,
) -> string {
	w := ojson.init_writer(8192, context.temp_allocator)
	caps := capabilities_for(format, model)
	build_request_json(
		&w,
		entries,
		nil,
		model,
		caps,
		0.7,
		1024,
		format,
		thinking_budget,
		false,
		.NONE,
	)
	return ojson.writer_string(&w)
}

@(test)
test_capabilities_anthropic_opus_47_drops_temperature :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	caps := capabilities_for(.ANTHROPIC, "claude-opus-4-7-20251115")
	testing.expect(t, !caps.supports_temperature, "opus 4.7 must not support temperature")
	testing.expect(t, caps.supports_thinking, "opus 4.7 must support thinking")

	entries: [dynamic]Chat_Entry
	append_user_entry(&entries, "hi")
	json := build_for("claude-opus-4-7-20251115", .ANTHROPIC, entries[:])
	testing.expect(t, !strings.contains(json, `"temperature"`), "no temperature on opus 4.7")
}

@(test)
test_capabilities_anthropic_known_model_keeps_temperature :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_user_entry(&entries, "hi")
	json := build_for("claude-sonnet-4-5-20250929", .ANTHROPIC, entries[:])
	testing.expect(t, strings.contains(json, `"temperature"`), "sonnet 4.5 keeps temperature")
}

@(test)
test_capabilities_anthropic_unknown_model_keeps_temperature :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_user_entry(&entries, "hi")
	json := build_for("claude-test", .ANTHROPIC, entries[:])
	testing.expect(t, strings.contains(json, `"temperature"`), "unknown defaults permissive")
}

@(test)
test_capabilities_anthropic_thinking_block_dropped_when_budget_off :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_user_entry(&entries, "hi")
	append_assistant_entry(&entries, text("answer"), nil, text("internal trace"), text("sig-abc"))
	json := build_for("claude-sonnet-4-5-20250929", .ANTHROPIC, entries[:])
	testing.expect(
		t,
		!strings.contains(json, `"type":"thinking"`),
		"prior thinking dropped when budget unset",
	)
	testing.expect(t, !strings.contains(json, `"signature"`), "no signature replay")
}

@(test)
test_capabilities_anthropic_thinking_block_kept_when_budget_set :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_user_entry(&entries, "hi")
	append_assistant_entry(&entries, text("answer"), nil, text("internal trace"), text("sig-abc"))
	json := build_for("claude-sonnet-4-5-20250929", .ANTHROPIC, entries[:], 4096)
	testing.expect(
		t,
		strings.contains(json, `"type":"thinking"`),
		"thinking block kept when budget set",
	)
}

@(test)
test_capabilities_openai_o3_drops_temperature :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	caps := capabilities_for(.OPENAI_COMPAT, "o3-mini")
	testing.expect(t, !caps.supports_temperature, "o3 must not support temperature")

	entries: [dynamic]Chat_Entry
	append_user_entry(&entries, "hi")
	json := build_for("o3-mini", .OPENAI_COMPAT, entries[:])
	testing.expect(t, !strings.contains(json, `"temperature"`), "no temperature on o3")
}

@(test)
test_capabilities_openai_gpt4_keeps_temperature :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_user_entry(&entries, "hi")
	json := build_for("gpt-4o", .OPENAI_COMPAT, entries[:])
	testing.expect(t, strings.contains(json, `"temperature"`), "gpt-4o keeps temperature")
}

@(test)
test_capabilities_gemini_keeps_temperature :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_user_entry(&entries, "hi")
	json := build_for("gemini-2.5-flash", .GEMINI, entries[:])
	testing.expect(t, strings.contains(json, `"temperature"`), "gemini keeps temperature")
}

@(test)
test_capabilities_ollama_keeps_temperature :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_user_entry(&entries, "hi")
	json := build_for("llama3", .OLLAMA, entries[:])
	testing.expect(t, strings.contains(json, `"temperature"`), "ollama keeps temperature")
}

@(test)
test_capabilities_anthropic_47_thinking_budget_clamps_below_min :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_user_entry(&entries, "hi")
	json := build_for("claude-opus-4-7-20251115", .ANTHROPIC, entries[:], 512)
	testing.expect(
		t,
		!strings.contains(json, `"thinking":`),
		"budget below min_thinking_budget skips thinking",
	)
	testing.expect(
		t,
		!strings.contains(json, `"temperature"`),
		"opus 4.7 still drops temperature even with thinking off",
	)
}

@(test)
test_origin_model_dropped_thinking_when_model_differs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_user_entry(&entries, "hi")
	append_assistant_entry(
		&entries,
		text("answer"),
		nil,
		text("internal trace"),
		text("sig-from-model-a"),
		text("claude-sonnet-4-5-20250929"),
	)
	json := build_for("claude-opus-4-7-20251115", .ANTHROPIC, entries[:], 4096)
	testing.expect(
		t,
		!strings.contains(json, `"type":"thinking"`),
		"thinking dropped when origin_model != current",
	)
	testing.expect(
		t,
		!strings.contains(json, "sig-from-model-a"),
		"signature dropped when origin_model != current",
	)
}

@(test)
test_origin_model_kept_thinking_when_model_matches :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_user_entry(&entries, "hi")
	append_assistant_entry(
		&entries,
		text("answer"),
		nil,
		text("internal trace"),
		text("sig-abc"),
		text("claude-sonnet-4-5-20250929"),
	)
	json := build_for("claude-sonnet-4-5-20250929", .ANTHROPIC, entries[:], 4096)
	testing.expect(t, strings.contains(json, `"type":"thinking"`), "thinking kept on same model")
	testing.expect(t, strings.contains(json, "sig-abc"), "signature kept on same model")
}

@(test)
test_origin_model_unset_keeps_thinking :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_user_entry(&entries, "hi")
	append_assistant_entry(
		&entries,
		text("answer"),
		nil,
		text("internal trace"),
		text("sig-legacy"),
	)
	json := build_for("claude-sonnet-4-5-20250929", .ANTHROPIC, entries[:], 4096)
	testing.expect(
		t,
		strings.contains(json, `"type":"thinking"`),
		"unset origin_model keeps thinking (legacy entries)",
	)
}

@(test)
test_origin_model_dropped_thinking_with_tool_calls_too :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries: [dynamic]Chat_Entry
	append_user_entry(&entries, "look up x")
	calls := []Parsed_Tool_Call {
		{id = text("call_1"), name = text("search"), arguments = text(`{"q":"x"}`)},
	}
	append_assistant_entry(
		&entries,
		text("checking"),
		calls,
		text("plan"),
		text("sig-cross"),
		text("claude-sonnet-4-5-20250929"),
	)
	json := build_for("claude-opus-4-7-20251115", .ANTHROPIC, entries[:], 4096)
	testing.expect(
		t,
		!strings.contains(json, `"type":"thinking"`),
		"thinking dropped on cross-model tool-call entry",
	)
	testing.expect(t, strings.contains(json, `"type":"tool_use"`), "tool_use block preserved")
}
