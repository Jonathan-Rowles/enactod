package enactod_impl

import "../pkgs/actod"
import "core:fmt"
import "core:log"
import vmem "core:mem/virtual"
import "core:strings"
import "vendor:curl"

spawn_agent :: proc(name: string, config: Agent_Config) -> (Session, bool) {
	behaviour := agent_behaviour
	behaviour.actor_type = AGENT_ACTOR_TYPE
	agent_name := fmt.tprintf("agent:%s", name)
	state := Agent_State {
		config     = config,
		agent_name = strings.clone(name),
	}
	_, ok := actod.spawn_child(
		agent_name,
		state,
		behaviour,
		actod.make_actor_config(children = config.children),
	)
	if !ok {
		log.errorf("Failed to spawn agent '%s'", name)
		return Session{}, false
	}
	return make_session(name), true
}

spawn_sub_agent :: proc(
	name: string,
	config: Agent_Config,
	parent_arena: ^vmem.Arena,
) -> (
	actod.PID,
	bool,
) {
	behaviour := agent_behaviour
	behaviour.actor_type = AGENT_ACTOR_TYPE
	agent_name := fmt.tprintf("agent:%s", name)
	state := Agent_State {
		config          = config,
		agent_name      = strings.clone(name),
		inherited_arena = parent_arena,
	}
	pid, ok := actod.spawn_child(
		agent_name,
		state,
		behaviour,
		actod.make_actor_config(children = config.children),
	)
	if !ok {
		log.errorf("Failed to spawn sub-agent '%s'", name)
		return 0, false
	}
	return pid, true
}

destroy_agent :: proc(name: string) -> bool {
	agent_name := fmt.tprintf("agent:%s", name)
	pid, ok := actod.get_actor_pid(agent_name)
	if !ok {
		log.errorf("destroy_agent: agent '%s' not found", agent_name)
		return false
	}
	return actod.terminate_actor(pid, .SHUTDOWN)
}

@(fini)
cleanup_curl :: proc "contextless" () {
	curl.global_cleanup()
}
