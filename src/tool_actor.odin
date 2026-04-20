package enactod_impl

import "../pkgs/actod"
import "core:fmt"
import "core:log"
import vmem "core:mem/virtual"
import "core:strings"

Tool_Actor_State :: struct {
	execute:   Tool_Proc,
	ephemeral: bool,
	arena:     ^vmem.Arena,
}

tool_actor_behaviour :: actod.Actor_Behaviour(Tool_Actor_State) {
	handle_message = tool_actor_handle_message,
}

tool_actor_handle_message :: proc(data: ^Tool_Actor_State, from: actod.PID, content: any) {
	switch msg in content {
	case Tool_Call_Msg:
		result: Tool_Result_Msg
		if data.execute == nil {
			log.errorf("Tool '%s' has no execute proc", actod.get_self_name())
			result = Tool_Result_Msg {
				request_id = msg.request_id,
				call_id    = intern(msg.call_id, data.arena),
				tool_name  = intern(msg.tool_name, data.arena),
				result     = text("tool has no implementation", data.arena),
				is_error   = true,
			}
		} else {
			output, is_error := data.execute(resolve(msg.arguments), context.temp_allocator)
			result = Tool_Result_Msg {
				request_id = msg.request_id,
				call_id    = intern(msg.call_id, data.arena),
				tool_name  = intern(msg.tool_name, data.arena),
				result     = text(output, data.arena),
				is_error   = is_error,
			}
		}
		actod.send_message(from, result)
		if data.ephemeral {
			actod.self_terminate()
		}
	}
}

spawn_tool_actor :: proc(name: string, tool: Tool, arena: ^vmem.Arena, ephemeral: bool) -> bool {
	switch tool.lifecycle {
	case .INLINE:
		return false
	case .EPHEMERAL, .PERSISTENT:
		if tool.spawn != nil {
			_, ok := tool.spawn(name, actod.get_self_pid())
			return ok
		}
		if tool.impl == nil {
			return false
		}
		state := Tool_Actor_State {
			execute   = tool.impl,
			ephemeral = ephemeral,
			arena     = arena,
		}
		if ephemeral {
			_, ok := actod.spawn_child(
				name,
				state,
				tool_actor_behaviour,
				actod.make_actor_config(restart_policy = .TEMPORARY),
			)
			return ok
		}
		_, ok := actod.spawn_child(name, state, tool_actor_behaviour)
		return ok
	case .SUB_AGENT:
		return spawn_sub_agent_tool_actor(name, tool.def.name, tool.sub_agent, arena)
	}
	return false
}

@(private = "file")
spawn_sub_agent_tool_actor :: proc(
	name: string,
	tool_name: string,
	spec: Sub_Agent_Spec,
	arena: ^vmem.Arena,
) -> bool {
	parent_name := actod.get_self_name()
	agent_short := parent_name
	if idx := strings.last_index_byte(parent_name, ':'); idx >= 0 {
		agent_short = parent_name[idx + 1:]
	}

	if spec.pool_size > 1 {
		base_name := fmt.aprintf("%s-%s", agent_short, tool_name)
		state := Sub_Agent_Pool_State {
			base_name        = base_name,
			sub_agent_config = spec.config,
			pool_size        = spec.pool_size,
			context_file     = spec.context_file,
			arena            = arena,
		}
		_, ok := actod.spawn_child(name, state, sub_agent_pool_behaviour)
		return ok
	}

	sub_agent_name := fmt.aprintf("%s-%s", agent_short, tool_name)
	state := Sub_Agent_Bridge_State {
		sub_agent_name   = sub_agent_name,
		sub_agent_config = spec.config,
		context_file     = spec.context_file,
		arena            = arena,
	}
	_, ok := actod.spawn_child(name, state, sub_agent_bridge_behaviour)
	return ok
}
