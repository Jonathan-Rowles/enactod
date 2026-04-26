#+build !freestanding
package enactod_impl

import "core:testing"
import "providers/anthropic"
import "providers/gemini"
import "providers/ollama"
import "providers/openai"

@(test)
test_anthropic_parse_models_basic :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := transmute([]byte)string(
		`{
			"data": [
				{"id": "claude-opus-4-7-20251115", "display_name": "Claude Opus 4.7", "type": "model"},
				{"id": "claude-sonnet-4-5-20250929", "display_name": "Claude Sonnet 4.5", "type": "model"}
			],
			"has_more": false
		}`,
	)
	list, ok := anthropic.parse_models(body, "anthropic")
	testing.expect(t, ok, "parse must succeed")
	testing.expect_value(t, len(list), 2)
	testing.expect_value(t, list[0].id, "claude-opus-4-7-20251115")
	testing.expect_value(t, list[0].display_name, "Claude Opus 4.7")
	testing.expect_value(t, list[0].provider_name, "anthropic")
	testing.expect(t, !list[0].capabilities.supports_temperature, "opus 4.7 capabilities applied")
	testing.expect(t, list[1].capabilities.supports_temperature, "sonnet 4.5 capabilities applied")
}

@(test)
test_openai_parse_models_basic :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := transmute([]byte)string(
		`{
			"object": "list",
			"data": [
				{"id": "gpt-4o", "object": "model", "created": 1715367049, "owned_by": "system"},
				{"id": "o3-mini", "object": "model", "created": 1726531200, "owned_by": "system"}
			]
		}`,
	)
	list, ok := openai.parse_models(body, "openai")
	testing.expect(t, ok, "parse must succeed")
	testing.expect_value(t, len(list), 2)
	testing.expect_value(t, list[0].id, "gpt-4o")
	testing.expect(t, list[0].capabilities.supports_temperature, "gpt-4o supports temperature")
	testing.expect_value(t, list[0].created_unix, 1715367049)
	testing.expect_value(t, list[1].id, "o3-mini")
	testing.expect(t, !list[1].capabilities.supports_temperature, "o3-mini drops temperature")
}

@(test)
test_gemini_parse_models_strips_prefix_and_overlays_limits :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := transmute([]byte)string(
		`{
			"models": [
				{
					"name": "models/gemini-2.5-pro",
					"version": "001",
					"displayName": "Gemini 2.5 Pro",
					"inputTokenLimit": 2000000,
					"outputTokenLimit": 70000,
					"supportedGenerationMethods": ["generateContent"]
				}
			]
		}`,
	)
	list, ok := gemini.parse_models(body, "gemini")
	testing.expect(t, ok, "parse must succeed")
	testing.expect_value(t, len(list), 1)
	testing.expect_value(t, list[0].id, "gemini-2.5-pro")
	testing.expect_value(t, list[0].display_name, "Gemini 2.5 Pro")
	testing.expect_value(t, list[0].context_window, 2000000)
	testing.expect_value(t, list[0].capabilities.context_window, 2000000)
	testing.expect_value(t, list[0].capabilities.max_output_tokens, 70000)
	testing.expect(t, list[0].capabilities.supports_thinking, "2.5 pro supports thinking")
}

@(test)
test_ollama_parse_models_basic :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := transmute([]byte)string(
		`{
			"models": [
				{"name": "llama3:latest", "size": 4661211808},
				{"name": "qwen2.5-coder:14b", "size": 9000000000}
			]
		}`,
	)
	list, ok := ollama.parse_models(body, "ollama")
	testing.expect(t, ok, "parse must succeed")
	testing.expect_value(t, len(list), 2)
	testing.expect_value(t, list[0].id, "llama3:latest")
	testing.expect_value(t, list[0].provider_name, "ollama")
}

@(test)
test_models_url_anthropic :: proc(t: ^testing.T) {
	url := anthropic.models_url("https://api.anthropic.com")
	testing.expect_value(t, url, "https://api.anthropic.com/v1/models?limit=1000")
}

@(test)
test_models_url_openai :: proc(t: ^testing.T) {
	url := openai.models_url("https://api.openai.com/v1")
	testing.expect_value(t, url, "https://api.openai.com/v1/models")
}

@(test)
test_models_url_gemini_with_key :: proc(t: ^testing.T) {
	url := gemini.models_url("https://generativelanguage.googleapis.com", "abc")
	testing.expect_value(
		t,
		url,
		"https://generativelanguage.googleapis.com/v1beta/models?key=abc&pageSize=1000",
	)
}

@(test)
test_models_url_ollama :: proc(t: ^testing.T) {
	url := ollama.models_url("http://localhost:11434")
	testing.expect_value(t, url, "http://localhost:11434/api/tags")
}

@(test)
test_anthropic_parse_models_handles_error_payload :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := transmute([]byte)string(
		`{"error": {"type": "authentication_error", "message": "invalid x-api-key"}}`,
	)
	list, ok := anthropic.parse_models(body, "anthropic")
	testing.expect(t, !ok, "API error returns ok=false")
	testing.expect_value(t, len(list), 0)
}

@(test)
test_openai_parser_overlays_openrouter_supported_parameters :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := transmute([]byte)string(
		`{
			"data": [
				{
					"id": "anthropic/claude-3-5-sonnet",
					"name": "Anthropic: Claude 3.5 Sonnet",
					"context_length": 200000,
					"supported_parameters": ["max_tokens", "temperature", "top_p", "tools", "reasoning"]
				},
				{
					"id": "openai/o3-mini",
					"name": "OpenAI: o3 Mini",
					"context_length": 200000,
					"supported_parameters": ["max_tokens", "tools", "reasoning"]
				}
			]
		}`,
	)
	list, ok := openai.parse_models(body, "openrouter")
	testing.expect(t, ok)
	testing.expect_value(t, len(list), 2)

	testing.expect(t, list[0].capabilities.supports_temperature, "claude has temperature")
	testing.expect(t, list[0].capabilities.supports_top_p, "claude has top_p")
	testing.expect(t, list[0].capabilities.supports_tools, "claude has tools")
	testing.expect(t, list[0].capabilities.supports_thinking, "claude has reasoning")
	testing.expect_value(t, list[0].context_window, 200000)
	testing.expect_value(t, list[0].display_name, "Anthropic: Claude 3.5 Sonnet")

	testing.expect(t, !list[1].capabilities.supports_temperature, "o3-mini drops temperature")
	testing.expect(t, !list[1].capabilities.supports_top_p, "o3-mini drops top_p")
	testing.expect(t, list[1].capabilities.supports_tools, "o3-mini has tools")
	testing.expect(t, list[1].capabilities.supports_thinking, "o3-mini has reasoning")
}

@(test)
test_openai_parser_no_overlay_when_supported_parameters_absent :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := transmute([]byte)string(
		`{
			"data": [
				{"id": "gpt-4o", "object": "model", "created": 1715367049}
			]
		}`,
	)
	list, ok := openai.parse_models(body, "openai")
	testing.expect(t, ok)
	testing.expect(
		t,
		list[0].capabilities.supports_temperature,
		"prefix-match keeps gpt-4o defaults",
	)
}

@(test)
test_ollama_parse_show_capabilities_overlay :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := transmute([]byte)string(`{
			"capabilities": ["completion", "tools", "thinking"]
		}`)
	base := ollama.capabilities("llama3")
	overlaid, ok := ollama.parse_show_capabilities(body, base)
	testing.expect(t, ok)
	testing.expect(t, overlaid.supports_tools, "tools enabled by API")
	testing.expect(t, overlaid.supports_thinking, "thinking enabled by API")
}

@(test)
test_ollama_parse_show_capabilities_disables_when_absent_from_array :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := transmute([]byte)string(`{
			"capabilities": ["completion"]
		}`)
	base := ollama.capabilities("some-model")
	testing.expect(t, base.supports_tools, "default base has tools on")
	testing.expect(t, base.supports_thinking, "default base has thinking on")

	overlaid, ok := ollama.parse_show_capabilities(body, base)
	testing.expect(t, ok)
	testing.expect(t, !overlaid.supports_tools, "tools removed because absent from API list")
	testing.expect(t, !overlaid.supports_thinking, "thinking removed because absent from API list")
}

@(test)
test_ollama_parse_show_capabilities_missing_field_returns_base :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := transmute([]byte)string(`{"modelfile": "...", "details": {"family": "llama"}}`)
	base := ollama.capabilities("llama3")
	overlaid, ok := ollama.parse_show_capabilities(body, base)
	testing.expect(t, ok, "missing capabilities array is not an error")
	testing.expect_value(t, overlaid.supports_tools, base.supports_tools)
	testing.expect_value(t, overlaid.supports_thinking, base.supports_thinking)
}
