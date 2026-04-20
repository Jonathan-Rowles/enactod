package enactod_impl

import "../pkgs/actod"
import actod_core "../pkgs/actod/src/actod"
import "base:runtime"
import "core:fmt"
import "core:log"
import vmem "core:mem/virtual"

AGENT_ACTOR_TYPE_NAME :: "enact:agent"
AGENT_ACTOR_TYPE: actod.Actor_Type

@(init)
init_agent_actor_type :: proc "contextless" () {
	context = runtime.default_context()
	AGENT_ACTOR_TYPE, _ = actod.register_actor_type(AGENT_ACTOR_TYPE_NAME)
}

get_agent_arena_ptr :: proc {
	get_agent_arena_ptr_by_name,
	get_agent_arena_ptr_by_pid,
}

get_agent_arena_ptr_by_pid :: proc(pid: actod.PID) -> ^vmem.Arena {
	if AGENT_ACTOR_TYPE == actod.ACTOR_TYPE_UNTYPED {
		log.error("operation only available for agents")
	}

	cur := pid
	for cur != 0 {
		if actod.get_pid_actor_type(cur) == AGENT_ACTOR_TYPE {
			return read_agent_arena_from_pid(cur)
		}
		cur = actod_core.get_actor_parent(cur)
	}
	return nil
}

get_agent_arena_ptr_by_name :: proc(agent_name: string) -> ^vmem.Arena {
	if pid, ok := actod.get_actor_pid(fmt.tprintf("agent:%s", agent_name)); ok {
		return get_agent_arena_ptr_by_pid(pid)
	}
	if pid, ok := actod.get_actor_pid(agent_name); ok {
		return get_agent_arena_ptr_by_pid(pid)
	}
	return nil
}

@(private = "file")
read_agent_arena_from_pid :: proc(pid: actod.PID) -> ^vmem.Arena {
	actor_ptr := actod_core.get_actor_ptr(pid)
	if actor_ptr == nil do return nil
	data_offset := offset_of(actod_core.Actor(int), data)
	state_ptr := (cast(^rawptr)(uintptr(actor_ptr) + data_offset))^
	if state_ptr == nil do return nil
	return agent_arena(cast(^Agent_State)state_ptr)
}
