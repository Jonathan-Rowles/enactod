package enactod_impl

import "../pkgs/ojson"
import "providers/anthropic"
import "providers/gemini"
import "providers/ollama"
import "providers/openai"

parse_llm_response :: proc(
	reader: ^ojson.Reader,
	body: string,
	format: API_Format = .OPENAI_COMPAT,
) -> Parsed_Response {
	switch format {
	case .ANTHROPIC:
		return anthropic.parse_response(reader, body)
	case .OPENAI_COMPAT:
		return openai.parse_response(reader, body)
	case .OLLAMA:
		return ollama.parse_response(reader, body)
	case .GEMINI:
		return gemini.parse_response(reader, body)
	}
	return openai.parse_response(reader, body)
}
