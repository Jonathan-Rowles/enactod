package enactod_impl

import "../pkgs/ojson"
import "providers/anthropic"
import "providers/gemini"
import "providers/ollama"
import "providers/openai"

MAX_CACHE_BLOCKS :: 4

build_request_json :: proc(
	w: ^ojson.Writer,
	entries: []Chat_Entry,
	tools: []Tool_Def,
	model: string,
	caps: Capabilities,
	temperature: f32,
	max_tokens: int,
	format: API_Format = .OPENAI_COMPAT,
	thinking_budget: Maybe(int) = nil,
	stream: bool = false,
	cache_mode: Cache_Mode = .NONE,
) {
	ojson.writer_reset(w)
	switch format {
	case .OPENAI_COMPAT:
		req := openai.to_request(entries, tools, model, caps, temperature, max_tokens, stream)
		openai.marshal_request(w, req)
	case .ANTHROPIC:
		req := anthropic.to_request(
			entries,
			tools,
			model,
			caps,
			temperature,
			max_tokens,
			thinking_budget,
			stream,
			cache_mode,
		)
		anthropic.marshal_request(w, req)
	case .OLLAMA:
		req := ollama.to_request(entries, tools, model, caps, temperature, stream, thinking_budget)
		ollama.marshal_request(w, req)
	case .GEMINI:
		req := gemini.to_request(entries, tools, caps, temperature, max_tokens, thinking_budget)
		gemini.marshal_request(w, req)
	}
}
