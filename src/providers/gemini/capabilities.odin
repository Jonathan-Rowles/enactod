package gemini

import c "../../core"
import "core:strings"

capabilities :: proc(model: string) -> c.Capabilities {
	caps := c.Capabilities {
		supports_temperature = true,
		supports_top_p       = true,
		supports_tools       = true,
		supports_streaming   = true,
		max_output_tokens    = 8192,
	}

	switch {
	case strings.has_prefix(model, "gemini-2.5-pro"):
		caps.supports_thinking = true
		caps.min_thinking_budget = -1
		caps.max_thinking_budget = 32_000
		caps.context_window = 1_000_000
		caps.max_output_tokens = 64_000
	case strings.has_prefix(model, "gemini-2.5-flash-lite"):
		caps.supports_thinking = true
		caps.min_thinking_budget = 0
		caps.max_thinking_budget = 24_000
		caps.context_window = 1_000_000
		caps.max_output_tokens = 64_000
	case strings.has_prefix(model, "gemini-2.5-flash"):
		caps.supports_thinking = true
		caps.min_thinking_budget = 0
		caps.max_thinking_budget = 24_000
		caps.context_window = 1_000_000
		caps.max_output_tokens = 64_000
	case strings.has_prefix(model, "gemini-2.0"):
		caps.context_window = 1_000_000
	case strings.has_prefix(model, "gemini-1.5"):
		caps.context_window = 2_000_000
	}

	return caps
}
