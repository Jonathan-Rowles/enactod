package ollama

import c "../../core"

capabilities :: proc(model: string) -> c.Capabilities {
	return c.Capabilities {
		supports_temperature = true,
		supports_top_p       = true,
		supports_tools       = true,
		supports_streaming   = true,
		supports_thinking    = true,
		min_thinking_budget  = 0,
		max_thinking_budget  = 1,
		context_window       = 32_768,
	}
}
