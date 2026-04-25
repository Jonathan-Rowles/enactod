package enactod_impl

import "../pkgs/actod"
import "core:time"

Agent_Config :: struct {
	llm:                     LLM_Config,
	system_prompt:           string,
	tools:                   []Tool,
	children:                [dynamic]actod.SPAWN,
	worker_count:            int,
	max_turns:               int,
	max_tool_calls_per_turn: int,
	tool_timeout:            time.Duration,
	stream:                  bool,
	forward_events:          bool,
	forward_thinking:        bool,
	tool_continuation:       string,
	validate_tool_args:      bool,
	trace_sink:              Trace_Sink,
	accumulate_history:      bool,
	restart_policy:          actod.Restart_Policy,
}

DEFAULT_WORKER_COUNT :: 2
DEFAULT_MAX_TURNS :: 10
DEFAULT_MAX_TOOL_CALLS_PER_TURN :: 20
DEFAULT_TOOL_TIMEOUT :: 30 * time.Second
DEFAULT_TEMPERATURE :: 0.7
DEFAULT_MAX_TOKENS :: 4096

make_agent_config :: proc(
	llm: LLM_Config,
	system_prompt: string = "",
	tools: []Tool = nil,
	children: [dynamic]actod.SPAWN = nil,
	worker_count: int = DEFAULT_WORKER_COUNT,
	max_turns: int = DEFAULT_MAX_TURNS,
	max_tool_calls_per_turn: int = DEFAULT_MAX_TOOL_CALLS_PER_TURN,
	tool_timeout: time.Duration = DEFAULT_TOOL_TIMEOUT,
	stream: bool = false,
	forward_events: bool = false,
	forward_thinking: bool = true,
	tool_continuation: string = "",
	validate_tool_args: bool = true,
	trace_sink: Trace_Sink = {},
	accumulate_history: bool = true,
	restart_policy: actod.Restart_Policy = .PERMANENT,
) -> Agent_Config {
	return Agent_Config {
		llm = llm,
		system_prompt = system_prompt,
		tools = tools,
		children = children,
		worker_count = worker_count,
		max_turns = max_turns,
		max_tool_calls_per_turn = max_tool_calls_per_turn,
		tool_timeout = tool_timeout,
		stream = stream,
		forward_events = forward_events,
		forward_thinking = forward_thinking,
		tool_continuation = tool_continuation,
		validate_tool_args = validate_tool_args,
		trace_sink = trace_sink,
		accumulate_history = accumulate_history,
		restart_policy = restart_policy,
	}
}
