package anthropic

import c "../../core"
import "core:strings"

capabilities :: proc(model: string) -> c.Capabilities {
	caps := c.Capabilities {
		supports_temperature = true,
		supports_top_p       = true,
		supports_tools       = true,
		supports_streaming   = true,
		supports_cache       = true,
		max_output_tokens    = 8192,
	}

	switch {
	case strings.has_prefix(model, "claude-opus-4-7"):
		caps.supports_temperature = false
		caps.supports_top_p = false
		caps.supports_thinking = true
		caps.min_thinking_budget = 1024
		caps.max_thinking_budget = 32000
		caps.context_window = 1_000_000
		caps.max_output_tokens = 32000
	case strings.has_prefix(model, "claude-sonnet-4-6"):
		caps.supports_thinking = true
		caps.min_thinking_budget = 1024
		caps.max_thinking_budget = 32000
		caps.context_window = 200_000
		caps.max_output_tokens = 64000
	case strings.has_prefix(model, "claude-sonnet-4-5"):
		caps.supports_thinking = true
		caps.min_thinking_budget = 1024
		caps.max_thinking_budget = 32000
		caps.context_window = 200_000
		caps.max_output_tokens = 64000
	case strings.has_prefix(model, "claude-haiku-4-5"):
		caps.supports_thinking = true
		caps.min_thinking_budget = 1024
		caps.max_thinking_budget = 16000
		caps.context_window = 200_000
		caps.max_output_tokens = 32000
	case strings.has_prefix(model, "claude-opus-4-1"), strings.has_prefix(model, "claude-opus-4"):
		caps.supports_thinking = true
		caps.min_thinking_budget = 1024
		caps.max_thinking_budget = 32000
		caps.context_window = 200_000
	case strings.has_prefix(model, "claude-3-7"):
		caps.supports_thinking = true
		caps.min_thinking_budget = 1024
		caps.max_thinking_budget = 16000
		caps.context_window = 200_000
		caps.max_output_tokens = 64000
	case strings.has_prefix(model, "claude-3-5"), strings.has_prefix(model, "claude-3"):
		caps.context_window = 200_000
	}

	return caps
}
