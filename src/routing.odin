package enactod_impl

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
