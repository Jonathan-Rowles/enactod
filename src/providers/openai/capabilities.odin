package openai

import c "../../core"
import "core:strings"

capabilities :: proc(model: string) -> c.Capabilities {
	caps := c.Capabilities {
		supports_temperature = true,
		supports_top_p       = true,
		supports_tools       = true,
		supports_streaming   = true,
		max_output_tokens    = 4096,
	}

	switch {
	case strings.has_prefix(model, "o1"),
	     strings.has_prefix(model, "o3"),
	     strings.has_prefix(model, "o4"):
		caps.supports_temperature = false
		caps.supports_top_p = false
		caps.context_window = 200_000
		caps.max_output_tokens = 100_000
	case strings.has_prefix(model, "gpt-4.1"):
		caps.context_window = 1_000_000
		caps.max_output_tokens = 32_000
	case strings.has_prefix(model, "gpt-4o"):
		caps.context_window = 128_000
		caps.max_output_tokens = 16_000
	case strings.has_prefix(model, "gpt-4"):
		caps.context_window = 128_000
	case strings.has_prefix(model, "gpt-3.5"):
		caps.context_window = 16_000
	}

	return caps
}
