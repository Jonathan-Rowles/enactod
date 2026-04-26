#+build !freestanding
#+feature dynamic-literals
package enactod_impl

import "core:testing"

@(test)
test_anthropic_preset_sets_format_and_defaults :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	llm := anthropic("sk_ant", Model.Claude_Sonnet_4_5)
	testing.expect_value(t, llm.provider.name, "anthropic")
	testing.expect_value(t, llm.provider.base_url, "https://api.anthropic.com")
	testing.expect_value(t, llm.provider.api_key, "sk_ant")
	testing.expect_value(t, llm.provider.format, API_Format.ANTHROPIC)
	testing.expect_value(t, resolve_model_string(llm.model), "claude-sonnet-4-5-20250929")
	testing.expect_value(t, llm.temperature, f32(DEFAULT_TEMPERATURE))
	testing.expect_value(t, llm.max_tokens, DEFAULT_MAX_TOKENS)
	testing.expect_value(t, llm.cache_mode, Cache_Mode.NONE)
	_, has_thinking := llm.thinking_budget.?
	testing.expect(t, !has_thinking)
}

@(test)
test_anthropic_preset_overrides_carry_through :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	llm := anthropic(
		"k",
		Model.Claude_Opus_4,
		temperature = 0.2,
		max_tokens = 8192,
		thinking_budget = 2048,
		cache_mode = .EPHEMERAL,
	)
	testing.expect_value(t, llm.temperature, f32(0.2))
	testing.expect_value(t, llm.max_tokens, 8192)
	testing.expect_value(t, llm.cache_mode, Cache_Mode.EPHEMERAL)
	budget, has := llm.thinking_budget.?
	testing.expect(t, has)
	testing.expect_value(t, budget, 2048)
}

@(test)
test_openai_preset_sets_openai_compat_format :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	llm := openai("sk-oai", Model.GPT_4_1)
	testing.expect_value(t, llm.provider.name, "openai")
	testing.expect_value(t, llm.provider.base_url, "https://api.openai.com/v1")
	testing.expect_value(t, llm.provider.format, API_Format.OPENAI_COMPAT)
	testing.expect_value(t, resolve_model_string(llm.model), "gpt-4.1")
	_, has_thinking := llm.thinking_budget.?
	testing.expect(t, !has_thinking)
	testing.expect_value(t, llm.cache_mode, Cache_Mode.NONE)
}

@(test)
test_gemini_preset_sets_gemini_format_and_thinking :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	llm := gemini("key", Model.Gemini_2_5_Pro, thinking_budget = -1)
	testing.expect_value(t, llm.provider.name, "gemini")
	testing.expect_value(t, llm.provider.format, API_Format.GEMINI)
	testing.expect_value(t, resolve_model_string(llm.model), "gemini-2.5-pro")
	budget, has := llm.thinking_budget.?
	testing.expect(t, has)
	testing.expect_value(t, budget, -1)
}

@(test)
test_ollama_preset_no_key_and_raw_model :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	llm := ollama("llama3.1:8b")
	testing.expect_value(t, llm.provider.name, "ollama")
	testing.expect_value(t, llm.provider.base_url, "http://localhost:11434")
	testing.expect_value(t, llm.provider.api_key, "")
	testing.expect_value(t, llm.provider.format, API_Format.OLLAMA)
	testing.expect_value(t, resolve_model_string(llm.model), "llama3.1:8b")
}

@(test)
test_openai_compat_escape_hatch :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	llm := openai_compat("groq", "https://api.groq.com/openai/v1", "gsk_key", "llama-3.3-70b")
	testing.expect_value(t, llm.provider.name, "groq")
	testing.expect_value(t, llm.provider.base_url, "https://api.groq.com/openai/v1")
	testing.expect_value(t, llm.provider.api_key, "gsk_key")
	testing.expect_value(t, llm.provider.format, API_Format.OPENAI_COMPAT)
	testing.expect_value(t, resolve_model_string(llm.model), "llama-3.3-70b")
}

@(test)
test_preset_base_url_override :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	llm := anthropic("k", Model.Claude_Haiku_4_5, base_url = "https://anthropic.internal/")
	testing.expect_value(t, llm.provider.base_url, "https://anthropic.internal")
}

@(test)
test_preset_headers_flatten :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	llm := openai("k", Model.GPT_4_1_Mini, headers = map[string]string{"X-Tenant" = "demo"})
	testing.expect_value(t, llm.provider.extra_headers, "X-Tenant: demo")
}

@(test)
test_groq_preset :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	llm := groq("gsk_key", "llama-3.3-70b-versatile")
	testing.expect_value(t, llm.provider.name, "groq")
	testing.expect_value(t, llm.provider.base_url, "https://api.groq.com/openai/v1")
	testing.expect_value(t, llm.provider.format, API_Format.OPENAI_COMPAT)
	testing.expect_value(t, llm.provider.api_key, "gsk_key")
}

@(test)
test_openrouter_preset_app_attribution :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	llm := openrouter(
		"or_key",
		"meta-llama/llama-3.1-405b-instruct",
		app_name = "MyApp",
		referer = "https://my.app",
	)
	testing.expect_value(t, llm.provider.name, "openrouter")
	testing.expect_value(t, llm.provider.base_url, "https://openrouter.ai/api/v1")
	testing.expect_value(t, llm.provider.format, API_Format.OPENAI_COMPAT)
	testing.expect(
		t,
		llm.provider.extra_headers != "",
		"app_name + referer should populate headers",
	)
}

@(test)
test_together_preset :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	llm := together("tgt_key", "Qwen/Qwen2.5-Coder-32B-Instruct")
	testing.expect_value(t, llm.provider.name, "together")
	testing.expect_value(t, llm.provider.base_url, "https://api.together.xyz/v1")
	testing.expect_value(t, llm.provider.format, API_Format.OPENAI_COMPAT)
}

@(test)
test_fireworks_preset :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	llm := fireworks("fw_key", "accounts/fireworks/models/llama-v3p3-70b-instruct")
	testing.expect_value(t, llm.provider.name, "fireworks")
	testing.expect_value(t, llm.provider.base_url, "https://api.fireworks.ai/inference/v1")
	testing.expect_value(t, llm.provider.format, API_Format.OPENAI_COMPAT)
}

@(test)
test_lmstudio_preset_local_no_real_key :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	llm := lmstudio("local-model")
	testing.expect_value(t, llm.provider.name, "lmstudio")
	testing.expect_value(t, llm.provider.base_url, "http://localhost:1234/v1")
	testing.expect_value(t, llm.provider.format, API_Format.OPENAI_COMPAT)
	testing.expect_value(t, llm.provider.api_key, "lm-studio")
	testing.expect_value(t, llm.enable_rate_limiting, false)
}

@(test)
test_vllm_preset_passthrough :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	llm := vllm("http://gpu-host:8000/v1", "Qwen/Qwen2.5-72B-Instruct")
	testing.expect_value(t, llm.provider.name, "vllm")
	testing.expect_value(t, llm.provider.base_url, "http://gpu-host:8000/v1")
	testing.expect_value(t, llm.provider.format, API_Format.OPENAI_COMPAT)
	testing.expect_value(t, llm.enable_rate_limiting, false)
}
