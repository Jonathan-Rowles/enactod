package enactod_impl

import "core"
import "core:strings"
import "providers/anthropic"
import "providers/gemini"
import "providers/ollama"
import "providers/openai"

Stream_Decoder :: union {
	anthropic.Stream,
	openai.Stream,
	ollama.Stream,
	gemini.Stream,
}

reset_decoder :: proc(d: ^Stream_Decoder, format: API_Format) {
	switch format {
	case .ANTHROPIC:
		d^ = anthropic.Stream{}
	case .OPENAI_COMPAT:
		d^ = openai.Stream{}
	case .OLLAMA:
		d^ = ollama.Stream{}
	case .GEMINI:
		d^ = gemini.Stream{}
	}
}

build_chat_url :: proc(
	provider: ^core.Provider_Config,
	model: string = "",
	stream: bool = false,
) -> string {
	switch provider.format {
	case .ANTHROPIC:
		return anthropic.build_url(provider.base_url)
	case .OPENAI_COMPAT:
		return openai.build_url(provider.base_url)
	case .OLLAMA:
		return ollama.build_url(provider.base_url)
	case .GEMINI:
		return gemini.build_url(provider.base_url, model, stream)
	}
	return openai.build_url(provider.base_url)
}

build_auth_header :: proc(provider: ^core.Provider_Config) -> string {
	if len(provider.api_key) == 0 {
		return ""
	}
	switch provider.format {
	case .ANTHROPIC:
		return anthropic.build_auth(provider.api_key)
	case .OPENAI_COMPAT:
		return openai.build_auth(provider.api_key)
	case .OLLAMA:
		return ollama.build_auth(provider.api_key)
	case .GEMINI:
		return gemini.build_auth(provider.api_key)
	}
	return openai.build_auth(provider.api_key)
}

build_extra_headers :: proc(provider: ^core.Provider_Config) -> string {
	sb := strings.builder_make(context.temp_allocator)
	switch provider.format {
	case .ANTHROPIC:
		anthropic.build_extra_headers(&sb)
	case .OPENAI_COMPAT:
		openai.build_extra_headers(&sb)
	case .OLLAMA:
		ollama.build_extra_headers(&sb)
	case .GEMINI:
		gemini.build_extra_headers(&sb)
	}
	if len(provider.extra_headers) > 0 {
		if strings.builder_len(sb) > 0 {
			strings.write_byte(&sb, '\n')
		}
		strings.write_string(&sb, provider.extra_headers)
	}
	return strings.to_string(sb)
}

destroy_provider :: proc(provider: ^core.Provider_Config) {}
