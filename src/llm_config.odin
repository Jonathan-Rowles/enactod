package enactod_impl

import "core:time"

DEFAULT_ANTHROPIC_URL :: "https://api.anthropic.com"
DEFAULT_OPENAI_URL :: "https://api.openai.com/v1"
DEFAULT_GEMINI_URL :: "https://generativelanguage.googleapis.com"
DEFAULT_OLLAMA_URL :: "http://localhost:11434"
DEFAULT_GROQ_URL :: "https://api.groq.com/openai/v1"
DEFAULT_OPENROUTER_URL :: "https://openrouter.ai/api/v1"
DEFAULT_TOGETHER_URL :: "https://api.together.xyz/v1"
DEFAULT_FIREWORKS_URL :: "https://api.fireworks.ai/inference/v1"
DEFAULT_LMSTUDIO_URL :: "http://localhost:1234/v1"

DEFAULT_ANTHROPIC_TIMEOUT :: 120 * time.Second
DEFAULT_OPENAI_TIMEOUT :: 60 * time.Second
DEFAULT_GEMINI_TIMEOUT :: 60 * time.Second
DEFAULT_OLLAMA_TIMEOUT :: 300 * time.Second

LLM_Config :: struct {
	provider:             Provider_Config,
	model:                Model_ID,
	temperature:          f32,
	max_tokens:           int,
	thinking_budget:      Maybe(int),
	cache_mode:           Cache_Mode,
	timeout:              time.Duration,
	enable_rate_limiting: bool,
}

anthropic :: proc(
	api_key: string,
	model: Model_ID,
	temperature: f32 = DEFAULT_TEMPERATURE,
	max_tokens: int = DEFAULT_MAX_TOKENS,
	thinking_budget: Maybe(int) = nil,
	cache_mode: Cache_Mode = .NONE,
	timeout: time.Duration = DEFAULT_ANTHROPIC_TIMEOUT,
	enable_rate_limiting: bool = true,
	base_url: string = DEFAULT_ANTHROPIC_URL,
	headers: map[string]string = nil,
) -> LLM_Config {
	return LLM_Config {
		provider = make_provider("anthropic", base_url, api_key, .ANTHROPIC, headers),
		model = model,
		temperature = temperature,
		max_tokens = max_tokens,
		thinking_budget = thinking_budget,
		cache_mode = cache_mode,
		timeout = timeout,
		enable_rate_limiting = enable_rate_limiting,
	}
}

openai :: proc(
	api_key: string,
	model: Model_ID,
	temperature: f32 = DEFAULT_TEMPERATURE,
	max_tokens: int = DEFAULT_MAX_TOKENS,
	timeout: time.Duration = DEFAULT_OPENAI_TIMEOUT,
	enable_rate_limiting: bool = true,
	base_url: string = DEFAULT_OPENAI_URL,
	headers: map[string]string = nil,
) -> LLM_Config {
	return LLM_Config {
		provider = make_provider("openai", base_url, api_key, .OPENAI_COMPAT, headers),
		model = model,
		temperature = temperature,
		max_tokens = max_tokens,
		timeout = timeout,
		enable_rate_limiting = enable_rate_limiting,
	}
}

gemini :: proc(
	api_key: string,
	model: Model_ID,
	temperature: f32 = DEFAULT_TEMPERATURE,
	max_tokens: int = DEFAULT_MAX_TOKENS,
	thinking_budget: Maybe(int) = nil,
	timeout: time.Duration = DEFAULT_GEMINI_TIMEOUT,
	enable_rate_limiting: bool = true,
	base_url: string = DEFAULT_GEMINI_URL,
	headers: map[string]string = nil,
) -> LLM_Config {
	return LLM_Config {
		provider = make_provider("gemini", base_url, api_key, .GEMINI, headers),
		model = model,
		temperature = temperature,
		max_tokens = max_tokens,
		thinking_budget = thinking_budget,
		timeout = timeout,
		enable_rate_limiting = enable_rate_limiting,
	}
}

ollama :: proc(
	model: string,
	base_url: string = DEFAULT_OLLAMA_URL,
	temperature: f32 = DEFAULT_TEMPERATURE,
	max_tokens: int = DEFAULT_MAX_TOKENS,
	thinking_budget: Maybe(int) = nil,
	timeout: time.Duration = DEFAULT_OLLAMA_TIMEOUT,
	enable_rate_limiting: bool = false,
	headers: map[string]string = nil,
) -> LLM_Config {
	return LLM_Config {
		provider = make_provider("ollama", base_url, "", .OLLAMA, headers),
		model = model,
		temperature = temperature,
		max_tokens = max_tokens,
		thinking_budget = thinking_budget,
		timeout = timeout,
		enable_rate_limiting = enable_rate_limiting,
	}
}

openai_compat :: proc(
	name: string,
	base_url: string,
	api_key: string,
	model: Model_ID,
	temperature: f32 = DEFAULT_TEMPERATURE,
	max_tokens: int = DEFAULT_MAX_TOKENS,
	timeout: time.Duration = DEFAULT_OPENAI_TIMEOUT,
	enable_rate_limiting: bool = true,
	headers: map[string]string = nil,
) -> LLM_Config {
	return LLM_Config {
		provider = make_provider(name, base_url, api_key, .OPENAI_COMPAT, headers),
		model = model,
		temperature = temperature,
		max_tokens = max_tokens,
		timeout = timeout,
		enable_rate_limiting = enable_rate_limiting,
	}
}

groq :: proc(
	api_key: string,
	model: Model_ID,
	temperature: f32 = DEFAULT_TEMPERATURE,
	max_tokens: int = DEFAULT_MAX_TOKENS,
	timeout: time.Duration = DEFAULT_OPENAI_TIMEOUT,
	enable_rate_limiting: bool = true,
	base_url: string = DEFAULT_GROQ_URL,
	headers: map[string]string = nil,
) -> LLM_Config {
	return openai_compat(
		"groq",
		base_url,
		api_key,
		model,
		temperature,
		max_tokens,
		timeout,
		enable_rate_limiting,
		headers,
	)
}

openrouter :: proc(
	api_key: string,
	model: Model_ID,
	temperature: f32 = DEFAULT_TEMPERATURE,
	max_tokens: int = DEFAULT_MAX_TOKENS,
	timeout: time.Duration = DEFAULT_OPENAI_TIMEOUT,
	enable_rate_limiting: bool = true,
	app_name: string = "",
	referer: string = "",
	base_url: string = DEFAULT_OPENROUTER_URL,
	headers: map[string]string = nil,
) -> LLM_Config {
	merged := headers
	if len(app_name) > 0 || len(referer) > 0 {
		merged = make(map[string]string, context.temp_allocator)
		for k, v in headers {
			merged[k] = v
		}
		if len(app_name) > 0 {
			merged["X-Title"] = app_name
		}
		if len(referer) > 0 {
			merged["HTTP-Referer"] = referer
		}
	}
	return openai_compat(
		"openrouter",
		base_url,
		api_key,
		model,
		temperature,
		max_tokens,
		timeout,
		enable_rate_limiting,
		merged,
	)
}

together :: proc(
	api_key: string,
	model: Model_ID,
	temperature: f32 = DEFAULT_TEMPERATURE,
	max_tokens: int = DEFAULT_MAX_TOKENS,
	timeout: time.Duration = DEFAULT_OPENAI_TIMEOUT,
	enable_rate_limiting: bool = true,
	base_url: string = DEFAULT_TOGETHER_URL,
	headers: map[string]string = nil,
) -> LLM_Config {
	return openai_compat(
		"together",
		base_url,
		api_key,
		model,
		temperature,
		max_tokens,
		timeout,
		enable_rate_limiting,
		headers,
	)
}

fireworks :: proc(
	api_key: string,
	model: Model_ID,
	temperature: f32 = DEFAULT_TEMPERATURE,
	max_tokens: int = DEFAULT_MAX_TOKENS,
	timeout: time.Duration = DEFAULT_OPENAI_TIMEOUT,
	enable_rate_limiting: bool = true,
	base_url: string = DEFAULT_FIREWORKS_URL,
	headers: map[string]string = nil,
) -> LLM_Config {
	return openai_compat(
		"fireworks",
		base_url,
		api_key,
		model,
		temperature,
		max_tokens,
		timeout,
		enable_rate_limiting,
		headers,
	)
}

lmstudio :: proc(
	model: Model_ID,
	temperature: f32 = DEFAULT_TEMPERATURE,
	max_tokens: int = DEFAULT_MAX_TOKENS,
	timeout: time.Duration = DEFAULT_OLLAMA_TIMEOUT,
	enable_rate_limiting: bool = false,
	base_url: string = DEFAULT_LMSTUDIO_URL,
	headers: map[string]string = nil,
) -> LLM_Config {
	return openai_compat(
		"lmstudio",
		base_url,
		"lm-studio",
		model,
		temperature,
		max_tokens,
		timeout,
		enable_rate_limiting,
		headers,
	)
}

vllm :: proc(
	base_url: string,
	model: Model_ID,
	api_key: string = "",
	temperature: f32 = DEFAULT_TEMPERATURE,
	max_tokens: int = DEFAULT_MAX_TOKENS,
	timeout: time.Duration = DEFAULT_OPENAI_TIMEOUT,
	enable_rate_limiting: bool = false,
	headers: map[string]string = nil,
) -> LLM_Config {
	return openai_compat(
		"vllm",
		base_url,
		api_key,
		model,
		temperature,
		max_tokens,
		timeout,
		enable_rate_limiting,
		headers,
	)
}
