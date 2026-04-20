#+build !freestanding
#+feature dynamic-literals
package enactod_impl

import "core:strings"
import "core:testing"

@(test)
test_make_provider_trims_trailing_slash :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p := make_provider("x", "https://api.example.com/", "", .OPENAI_COMPAT)
	testing.expect_value(t, p.base_url, "https://api.example.com")
}

@(test)
test_make_provider_flattens_single_header :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p := make_provider(
		"groq",
		"https://api.groq.com",
		"key",
		.OPENAI_COMPAT,
		map[string]string{"X-Tenant" = "demo"},
	)
	testing.expect_value(t, p.extra_headers, "X-Tenant: demo")
}

@(test)
test_build_chat_url_per_format :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	anthropic := make_provider("a", "https://api.anthropic.com", "", .ANTHROPIC)
	testing.expect_value(t, build_chat_url(&anthropic), "https://api.anthropic.com/v1/messages")

	openai := make_provider("o", "https://api.openai.com", "", .OPENAI_COMPAT)
	testing.expect_value(t, build_chat_url(&openai), "https://api.openai.com/chat/completions")

	ollama := make_provider("l", "http://localhost:11434", "", .OLLAMA)
	testing.expect_value(t, build_chat_url(&ollama), "http://localhost:11434/api/chat")
}

@(test)
test_build_chat_url_gemini_streaming_vs_not :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	g := make_provider("g", "https://generativelanguage.googleapis.com", "", .GEMINI)
	non_stream := build_chat_url(&g, "gemini-2.5-flash", false)
	stream := build_chat_url(&g, "gemini-2.5-flash", true)
	testing.expect(t, strings.contains(non_stream, ":generateContent"))
	testing.expect(t, !strings.contains(non_stream, ":streamGenerateContent"))
	testing.expect(t, strings.contains(stream, ":streamGenerateContent?alt=sse"))
	testing.expect(t, strings.contains(stream, "gemini-2.5-flash"))
}

@(test)
test_build_auth_empty_key_returns_empty :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p := make_provider("x", "https://a", "", .OPENAI_COMPAT)
	testing.expect_value(t, build_auth_header(&p), "")
}

@(test)
test_build_auth_per_format_shape :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	anthropic := make_provider("a", "https://a", "sk_ant", .ANTHROPIC)
	testing.expect_value(t, build_auth_header(&anthropic), "x-api-key: sk_ant")

	openai := make_provider("o", "https://a", "sk-oai", .OPENAI_COMPAT)
	testing.expect_value(t, build_auth_header(&openai), "Authorization: Bearer sk-oai")

	gemini := make_provider("g", "https://a", "key", .GEMINI)
	testing.expect_value(t, build_auth_header(&gemini), "x-goog-api-key: key")

	ollama := make_provider("l", "http://localhost", "ignored", .OLLAMA)
	testing.expect_value(t, build_auth_header(&ollama), "")
}

@(test)
test_build_extra_headers_anthropic_includes_api_version :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p := make_provider("a", "https://a", "", .ANTHROPIC)
	h := build_extra_headers(&p)
	testing.expect(t, strings.contains(h, "anthropic-version: 2023-06-01"))
}

@(test)
test_build_extra_headers_appends_user_headers :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p := make_provider("a", "https://a", "", .ANTHROPIC, map[string]string{"X-Custom" = "hello"})
	h := build_extra_headers(&p)
	testing.expect(t, strings.contains(h, "anthropic-version: 2023-06-01"))
	testing.expect(t, strings.contains(h, "X-Custom: hello"))
}

@(test)
test_build_extra_headers_openai_and_user_only :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p := make_provider("o", "https://a", "", .OPENAI_COMPAT, map[string]string{"X-Req" = "1"})
	h := build_extra_headers(&p)
	testing.expect_value(t, h, "X-Req: 1")
}

@(test)
test_resolve_route_uses_config_when_no_override :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	cfg := Agent_Config {
		llm = openai_compat("o", "https://a", "", Model.GPT_4_1_Mini),
	}
	r := resolve_route(nil, &cfg)
	testing.expect_value(t, r.provider.name, "o")
	testing.expect_value(t, resolve_model_string(r.model), "gpt-4.1-mini")
}

@(test)
test_resolve_route_override_wins :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	cfg := Agent_Config {
		llm = openai_compat("cfg-prov", "https://a", "", Model.GPT_4_1_Mini),
	}
	override := anthropic("", Model.Claude_Sonnet_4_5, base_url = "https://b")
	override.provider.name = "override-prov"
	r := resolve_route(override, &cfg)
	testing.expect_value(t, r.provider.name, "override-prov")
	testing.expect_value(t, r.provider.format, API_Format.ANTHROPIC)
	testing.expect_value(t, resolve_model_string(r.model), "claude-sonnet-4-5-20250929")
}

@(test)
test_resolve_model_string_enum :: proc(t: ^testing.T) {
	id: Model_ID = Model.Claude_Haiku_4_5
	testing.expect_value(t, resolve_model_string(id), "claude-haiku-4-5-20251001")
}

@(test)
test_resolve_model_string_raw_string :: proc(t: ^testing.T) {
	id: Model_ID = "llama3.1:70b-instruct-q4_K_M"
	testing.expect_value(t, resolve_model_string(id), "llama3.1:70b-instruct-q4_K_M")
}

@(private = "file")
make_limiter :: proc() -> Rate_Limiter_State {
	return Rate_Limiter_State{}
}

@(test)
test_rate_limiter_parses_anthropic_request_headers :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := make_limiter()
	headers :=
		"anthropic-ratelimit-requests-limit:50\n" +
		"anthropic-ratelimit-requests-remaining:42\n" +
		"anthropic-ratelimit-tokens-limit:40000\n" +
		"anthropic-ratelimit-tokens-remaining:35000"
	rate_limiter_parse_limits(&s, headers)
	testing.expect_value(t, s.limit_state.requests_limit, u32(50))
	testing.expect_value(t, s.limit_state.requests_remaining, u32(42))
	testing.expect_value(t, s.limit_state.tokens_limit, u32(40000))
	testing.expect_value(t, s.limit_state.tokens_remaining, u32(35000))
}

@(test)
test_rate_limiter_tokens_reset_rfc3339_parsed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := make_limiter()
	rate_limiter_parse_limits(&s, "anthropic-ratelimit-tokens-reset:2026-04-19T10:20:30Z")
	testing.expect(t, s.limit_state.reset_time > 0)
}

@(test)
test_rate_limiter_missing_headers_are_tolerated :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := make_limiter()
	rate_limiter_parse_limits(&s, "")
	testing.expect_value(t, s.limit_state.requests_limit, u32(0))
	rate_limiter_parse_limits(&s, "x-custom:ignored")
	testing.expect_value(t, s.limit_state.requests_limit, u32(0))
}

@(test)
test_rate_limiter_retry_after_integer_seconds :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	d := rate_limiter_parse_retry_after("retry-after:7")
	testing.expect(t, d > 0)
	testing.expect_value(t, i64(d / 1e9), i64(7))
}

@(test)
test_rate_limiter_retry_after_case_insensitive_key :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	d := rate_limiter_parse_retry_after("Retry-After:3")
	testing.expect(t, d > 0)
}

@(test)
test_rate_limiter_retry_after_absent_returns_zero :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	d := rate_limiter_parse_retry_after("")
	testing.expect_value(t, i64(d), i64(0))
	d = rate_limiter_parse_retry_after("x:1\ny:2")
	testing.expect_value(t, i64(d), i64(0))
}

@(test)
test_is_retryable_status :: proc(t: ^testing.T) {
	testing.expect(t, is_retryable_status(429))
	testing.expect(t, is_retryable_status(529))
	testing.expect(t, is_retryable_status(503))
	testing.expect(t, !is_retryable_status(200))
	testing.expect(t, !is_retryable_status(400))
	testing.expect(t, !is_retryable_status(500))
}
