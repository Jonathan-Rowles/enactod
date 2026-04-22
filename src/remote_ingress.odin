package enactod_impl

import "../pkgs/actod"
import "core:fmt"
import "core:log"
import "core:strings"

DEFAULT_INGRESS_PAGE_SIZE :: 16 * 1024 * 1024

Ingress_State :: struct {}

ingress_behaviour :: actod.Actor_Behaviour(Ingress_State) {
	handle_message = ingress_handle_message,
}

ingress_handle_message :: proc(_: ^Ingress_State, from: actod.PID, content: any) {
	switch &msg in content {
	case Remote_Envelope:
		proxy_pid := ingress_get_or_spawn_proxy(msg.from_actor, msg.from_node, msg.target_name)
		if proxy_pid == 0 {
			log.errorf(
				"enact_ingress: failed to get proxy for '%s@%s'",
				msg.from_actor,
				msg.from_node,
			)
			return
		}
		err := actod.send_message(
			proxy_pid,
			Proxy_Forward{target = msg.target_name, payload = msg.payload},
		)
		if err != .OK {
			log.errorf(
				"enact_ingress: forward to proxy '%s@%s' failed: %v",
				msg.from_actor,
				msg.from_node,
				err,
			)
		}
	}
}

ingress_spawn :: proc(_: string, _: actod.PID) -> (actod.PID, bool) {
	return actod.spawn_child(
		INGRESS_ACTOR_NAME,
		Ingress_State{},
		ingress_behaviour,
		actod.make_actor_config(page_size = DEFAULT_INGRESS_PAGE_SIZE),
	)
}

@(private = "file")
ingress_get_or_spawn_proxy :: proc(
	from_actor, from_node, target_name: string,
) -> actod.PID {
	proxy_actor_name := fmt.tprintf(
		"enact_proxy:%s:%s@%s",
		target_name,
		from_actor,
		from_node,
	)
	if pid, ok := actod.get_actor_pid(proxy_actor_name); ok {
		return pid
	}

	state := Proxy_State {
		remote_actor = strings.clone(from_actor),
		remote_node  = strings.clone(from_node),
	}
	opts := actod.make_actor_config(page_size = DEFAULT_INGRESS_PAGE_SIZE)
	if target_pid, ok := actod.get_actor_pid(target_name); ok {
		pid, spawned := actod.spawn(proxy_actor_name, state, proxy_behaviour, opts, target_pid)
		if spawned do return pid
		return 0
	}
	pid, spawned := actod.spawn_child(proxy_actor_name, state, proxy_behaviour, opts)
	if !spawned do return 0
	return pid
}
