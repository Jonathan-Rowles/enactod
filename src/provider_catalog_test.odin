#+build !freestanding
package enactod_impl

import "core:testing"

@(test)
test_known_providers_includes_all_nine :: proc(t: ^testing.T) {
	names := [?]string {
		"anthropic",
		"openai",
		"gemini",
		"ollama",
		"groq",
		"openrouter",
		"together",
		"fireworks",
		"lmstudio",
	}
	list := list_known_providers()
	testing.expect_value(t, len(list), len(names))

	seen: map[string]bool
	seen.allocator = context.temp_allocator
	for desc in list {
		seen[desc.name] = true
	}
	for n in names {
		testing.expect(t, seen[n], n)
	}
}

@(test)
test_find_provider_descriptor_anthropic :: proc(t: ^testing.T) {
	desc, ok := find_provider_descriptor("anthropic")
	testing.expect(t, ok)
	testing.expect_value(t, desc.name, "anthropic")
	testing.expect_value(t, desc.format, API_Format.ANTHROPIC)
	testing.expect_value(t, desc.env_var, "ANTHROPIC_API_KEY")
	testing.expect_value(t, desc.default_url, DEFAULT_ANTHROPIC_URL)
}

@(test)
test_find_provider_descriptor_unknown :: proc(t: ^testing.T) {
	_, ok := find_provider_descriptor("not-a-provider")
	testing.expect(t, !ok)
}

@(test)
test_find_provider_descriptor_lmstudio_no_env :: proc(t: ^testing.T) {
	desc, ok := find_provider_descriptor("lmstudio")
	testing.expect(t, ok)
	testing.expect_value(t, desc.env_var, "")
	testing.expect_value(t, desc.format, API_Format.OPENAI_COMPAT)
}

@(test)
test_find_provider_descriptor_ollama_no_env :: proc(t: ^testing.T) {
	desc, ok := find_provider_descriptor("ollama")
	testing.expect(t, ok)
	testing.expect_value(t, desc.env_var, "")
	testing.expect_value(t, desc.format, API_Format.OLLAMA)
}

@(test)
test_build_llm_groq_uses_default_url :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	cfg, ok := build_llm("groq", "gsk_test", "llama-3.3-70b")
	testing.expect(t, ok)
	testing.expect_value(t, cfg.provider.name, "groq")
	testing.expect_value(t, cfg.provider.format, API_Format.OPENAI_COMPAT)
	testing.expect_value(t, cfg.provider.api_key, "gsk_test")
	testing.expect_value(t, cfg.provider.base_url, DEFAULT_GROQ_URL)
}

@(test)
test_build_llm_anthropic_overrides_url :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	cfg, ok := build_llm(
		"anthropic",
		"sk_test",
		"claude-sonnet-4-5-20250929",
		"https://anthropic.internal",
	)
	testing.expect(t, ok)
	testing.expect_value(t, cfg.provider.format, API_Format.ANTHROPIC)
	testing.expect_value(t, cfg.provider.base_url, "https://anthropic.internal")
}

@(test)
test_build_llm_lmstudio_ignores_api_key :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	cfg, ok := build_llm("lmstudio", "anything", "local-model")
	testing.expect(t, ok)
	testing.expect_value(t, cfg.provider.name, "lmstudio")
	testing.expect_value(t, cfg.provider.api_key, "lm-studio")
}

@(test)
test_build_llm_ollama_no_key :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	cfg, ok := build_llm("ollama", "", "llama3:latest")
	testing.expect(t, ok)
	testing.expect_value(t, cfg.provider.format, API_Format.OLLAMA)
	testing.expect_value(t, cfg.provider.api_key, "")
}

@(test)
test_build_llm_unknown_returns_false :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	_, ok := build_llm("nope", "key", "model")
	testing.expect(t, !ok)
}

@(test)
test_build_provider_lmstudio_default_key :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	prov, ok := build_provider("lmstudio")
	testing.expect(t, ok)
	testing.expect_value(t, prov.name, "lmstudio")
	testing.expect_value(t, prov.format, API_Format.OPENAI_COMPAT)
	testing.expect_value(t, prov.api_key, "lm-studio")
	testing.expect_value(t, prov.base_url, DEFAULT_LMSTUDIO_URL)
}

@(test)
test_build_provider_anthropic_explicit_key :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	prov, ok := build_provider("anthropic", "sk_ant", "")
	testing.expect(t, ok)
	testing.expect_value(t, prov.api_key, "sk_ant")
	testing.expect_value(t, prov.base_url, DEFAULT_ANTHROPIC_URL)
	testing.expect_value(t, prov.format, API_Format.ANTHROPIC)
}

@(test)
test_build_provider_unknown_returns_false :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	_, ok := build_provider("nope", "key", "")
	testing.expect(t, !ok)
}
