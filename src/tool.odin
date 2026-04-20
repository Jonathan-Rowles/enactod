package enactod_impl

import "../pkgs/actod"
import "core:mem"

Tool_Proc :: proc(arguments: string, allocator: mem.Allocator) -> (result: string, is_error: bool)
Tool_Spawn_Proc :: proc(name: string, parent: actod.PID) -> (actod.PID, bool)

Sub_Agent_Spec :: struct {
	config:       ^Agent_Config,
	pool_size:    int,
	context_file: string,
}

Tool :: struct {
	def:       Tool_Def,
	lifecycle: Tool_Lifecycle,
	impl:      Tool_Proc,
	spawn:     Tool_Spawn_Proc,
	sub_agent: Sub_Agent_Spec,
}

function_tool :: proc(def: Tool_Def, impl: Tool_Proc) -> Tool {
	return Tool{def = def, lifecycle = .INLINE, impl = impl}
}

ephemeral_tool :: proc(def: Tool_Def, impl: Tool_Proc) -> Tool {
	return Tool{def = def, lifecycle = .EPHEMERAL, impl = impl}
}

persistent_tool :: proc(def: Tool_Def, impl: Tool_Proc) -> Tool {
	return Tool{def = def, lifecycle = .PERSISTENT, impl = impl}
}

persistent_tool_actor :: proc(def: Tool_Def, spawn: Tool_Spawn_Proc) -> Tool {
	return Tool{def = def, lifecycle = .PERSISTENT, spawn = spawn}
}

sub_agent_tool :: proc(
	def: Tool_Def,
	config: ^Agent_Config,
	pool_size: int = 1,
	context_file: string = "",
) -> Tool {
	return Tool {
		def = def,
		lifecycle = .SUB_AGENT,
		sub_agent = Sub_Agent_Spec {
			config = config,
			pool_size = pool_size,
			context_file = context_file,
		},
	}
}
