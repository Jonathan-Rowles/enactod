package enactod_impl

Build_LLM_Proc :: #type proc(api_key: string, model: Model_ID, base_url: string) -> LLM_Config

Provider_Descriptor :: struct {
	name:            string,
	format:          API_Format,
	default_url:     string,
	env_var:         string, // suggested convention; "" means no auth needed
	api_key_default: string, // literal key used when api_key+env_var are both empty (LM Studio)
	build:           Build_LLM_Proc,
}

@(private = "file")
build_anthropic_default :: proc(api_key: string, model: Model_ID, base_url: string) -> LLM_Config {
	return anthropic(api_key = api_key, model = model, base_url = base_url)
}

@(private = "file")
build_openai_default :: proc(api_key: string, model: Model_ID, base_url: string) -> LLM_Config {
	return openai(api_key = api_key, model = model, base_url = base_url)
}

@(private = "file")
build_gemini_default :: proc(api_key: string, model: Model_ID, base_url: string) -> LLM_Config {
	return gemini(api_key = api_key, model = model, base_url = base_url)
}

@(private = "file")
build_ollama_default :: proc(_: string, model: Model_ID, base_url: string) -> LLM_Config {
	return ollama(model = resolve_model_string(model), base_url = base_url)
}

@(private = "file")
build_groq_default :: proc(api_key: string, model: Model_ID, base_url: string) -> LLM_Config {
	return groq(api_key = api_key, model = model, base_url = base_url)
}

@(private = "file")
build_openrouter_default :: proc(
	api_key: string,
	model: Model_ID,
	base_url: string,
) -> LLM_Config {
	return openrouter(api_key = api_key, model = model, base_url = base_url)
}

@(private = "file")
build_together_default :: proc(api_key: string, model: Model_ID, base_url: string) -> LLM_Config {
	return together(api_key = api_key, model = model, base_url = base_url)
}

@(private = "file")
build_fireworks_default :: proc(api_key: string, model: Model_ID, base_url: string) -> LLM_Config {
	return fireworks(api_key = api_key, model = model, base_url = base_url)
}

@(private = "file")
build_lmstudio_default :: proc(_: string, model: Model_ID, base_url: string) -> LLM_Config {
	return lmstudio(model = model, base_url = base_url)
}

KNOWN_PROVIDERS := [?]Provider_Descriptor {
	{
		name = "anthropic",
		format = .ANTHROPIC,
		default_url = DEFAULT_ANTHROPIC_URL,
		env_var = "ANTHROPIC_API_KEY",
		build = build_anthropic_default,
	},
	{
		name = "openai",
		format = .OPENAI_COMPAT,
		default_url = DEFAULT_OPENAI_URL,
		env_var = "OPENAI_API_KEY",
		build = build_openai_default,
	},
	{
		name = "gemini",
		format = .GEMINI,
		default_url = DEFAULT_GEMINI_URL,
		env_var = "GOOGLE_API_KEY",
		build = build_gemini_default,
	},
	{
		name = "ollama",
		format = .OLLAMA,
		default_url = DEFAULT_OLLAMA_URL,
		env_var = "",
		build = build_ollama_default,
	},
	{
		name = "groq",
		format = .OPENAI_COMPAT,
		default_url = DEFAULT_GROQ_URL,
		env_var = "GROQ_API_KEY",
		build = build_groq_default,
	},
	{
		name = "openrouter",
		format = .OPENAI_COMPAT,
		default_url = DEFAULT_OPENROUTER_URL,
		env_var = "OPENROUTER_API_KEY",
		build = build_openrouter_default,
	},
	{
		name = "together",
		format = .OPENAI_COMPAT,
		default_url = DEFAULT_TOGETHER_URL,
		env_var = "TOGETHER_API_KEY",
		build = build_together_default,
	},
	{
		name = "fireworks",
		format = .OPENAI_COMPAT,
		default_url = DEFAULT_FIREWORKS_URL,
		env_var = "FIREWORKS_API_KEY",
		build = build_fireworks_default,
	},
	{
		name = "lmstudio",
		format = .OPENAI_COMPAT,
		default_url = DEFAULT_LMSTUDIO_URL,
		env_var = "",
		api_key_default = "lm-studio",
		build = build_lmstudio_default,
	},
}

list_known_providers :: proc() -> []Provider_Descriptor {
	return KNOWN_PROVIDERS[:]
}

find_provider_descriptor :: proc(name: string) -> (^Provider_Descriptor, bool) {
	for &desc in KNOWN_PROVIDERS {
		if desc.name == name {
			return &desc, true
		}
	}
	return nil, false
}

build_llm :: proc(
	name: string,
	api_key: string,
	model: Model_ID,
	base_url: string = "",
) -> (
	LLM_Config,
	bool,
) {
	desc, found := find_provider_descriptor(name)
	if !found {
		return {}, false
	}
	url := base_url if len(base_url) > 0 else desc.default_url
	return desc.build(api_key, model, url), true
}

build_provider :: proc(
	name: string,
	api_key: string = "",
	base_url: string = "",
) -> (
	Provider_Config,
	bool,
) {
	desc, found := find_provider_descriptor(name)
	if !found {
		return {}, false
	}
	url := base_url if len(base_url) > 0 else desc.default_url
	key := api_key
	if len(key) == 0 {
		key = desc.api_key_default
	}
	return make_provider(desc.name, url, key, desc.format), true
}
