package enactod_impl

import "core:mem"
import "core:strings"

Model_ID :: union {
	Model,
	string,
}

// Note: `enable_rate_limiting` on a route override is ignored for routing —
// the rate limiter is spawned once with the initial config's setting and
// is not toggled by Set_Route. Other fields (provider, model, temperature,
// max_tokens, thinking_budget, cache_mode, timeout) are honoured per turn.
resolve_route :: proc(override: Maybe(LLM_Config), config: ^Agent_Config) -> LLM_Config {
	if r, ok := override.?; ok {
		return r
	}
	return config.llm
}

resolve_model_string :: proc(id: Model_ID) -> string {
	switch m in id {
	case Model:
		return model_string(m)
	case string:
		return m
	}
	return ""
}

persist_llm_config :: proc(llm: LLM_Config, allocator: mem.Allocator) -> LLM_Config {
	out := llm
	out.provider.name = strings.clone(llm.provider.name, allocator)
	out.provider.base_url = strings.clone(llm.provider.base_url, allocator)
	out.provider.api_key = strings.clone(llm.provider.api_key, allocator)
	out.provider.extra_headers = strings.clone(llm.provider.extra_headers, allocator)
	if model_str, is_string := llm.model.(string); is_string {
		out.model = strings.clone(model_str, allocator)
	}
	return out
}
