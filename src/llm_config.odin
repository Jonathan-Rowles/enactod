package enactod_impl

import "core:time"

DEFAULT_ANTHROPIC_URL :: "https://api.anthropic.com"
DEFAULT_OPENAI_URL :: "https://api.openai.com/v1"
DEFAULT_GEMINI_URL :: "https://generativelanguage.googleapis.com"
DEFAULT_OLLAMA_URL :: "http://localhost:11434"

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
