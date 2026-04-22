package enactod_impl

import "../pkgs/ojson"
import vmem "core:mem/virtual"
import "providers/anthropic"
import "providers/gemini"
import "providers/ollama"
import "providers/openai"

parse_llm_response :: proc(
	reader: ^ojson.Reader,
	body: string,
	format: API_Format = .OPENAI_COMPAT,
	arena: ^vmem.Arena = nil,
) -> Parsed_Response {
	switch format {
	case .ANTHROPIC:
		return anthropic.parse_response(reader, body, arena)
	case .OPENAI_COMPAT:
		return openai.parse_response(reader, body, arena)
	case .OLLAMA:
		return ollama.parse_response(reader, body, arena)
	case .GEMINI:
		return gemini.parse_response(reader, body, arena)
	}
	return openai.parse_response(reader, body, arena)
}
