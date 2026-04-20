package enactod_impl

import "../pkgs/actod"
import "core:fmt"
import "core:log"
import "core:strings"

DEFAULT_INGRESS_PAGE_SIZE :: 16 * 1024 * 1024

Ingress_State :: struct {
	proxies: map[string]actod.PID,
}

ingress_behaviour :: actod.Actor_Behaviour(Ingress_State) {
	init           = ingress_init,
	handle_message = ingress_handle_message,
}

ingress_init :: proc(data: ^Ingress_State) {
	data.proxies = make(map[string]actod.PID)
}

ingress_handle_message :: proc(data: ^Ingress_State, from: actod.PID, content: any) {
	switch &msg in content {
	case Remote_Envelope:
		proxy_pid := ingress_get_or_spawn_proxy(data, msg.from_actor, msg.from_node)
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
	d: ^Ingress_State,
	actor_name: string,
	node_name: string,
) -> actod.PID {
	lookup_key := fmt.tprintf("%s@%s", actor_name, node_name)
	if pid, ok := d.proxies[lookup_key]; ok {
		return pid
	}
	proxy_actor_name := fmt.tprintf("enact_proxy:%s@%s", actor_name, node_name)
	state := Proxy_State {
		remote_actor = strings.clone(actor_name),
		remote_node  = strings.clone(node_name),
	}
	pid, ok := actod.spawn_child(proxy_actor_name, state, proxy_behaviour)
	if !ok {
		return 0
	}
	d.proxies[strings.clone(lookup_key)] = pid
	return pid
}
