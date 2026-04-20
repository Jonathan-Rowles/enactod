#+build !freestanding
package enactod_impl

import "../pkgs/actod"
import th "../pkgs/actod/test_harness"
import "core:testing"

@(private = "file")
make_ingress :: proc() -> th.Test_Harness(Ingress_State) {
	return th.create(Ingress_State{}, ingress_behaviour)
}

@(private = "file")
make_envelope :: proc(from_actor, from_node, target: string) -> Remote_Envelope {
	return Remote_Envelope {
		target_name = target,
		from_actor = from_actor,
		from_node = from_node,
		payload = Agent_Response{content = text("hi")},
	}
}

@(test)
test_ingress_first_envelope_spawns_proxy_and_forwards :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_ingress()
	defer th.destroy(&h)
	th.init(&h)

	th.send(&h, make_envelope("client-actor", "client-node", "agent:demo"))

	spawn := th.expect_spawned(&h, t, Proxy_State)
	testing.expect_value(t, spawn.name, "enact_proxy:client-actor@client-node")

	fwd := th.expect_sent_to(&h, t, actod.PID(101), Proxy_Forward)
	testing.expect_value(t, fwd.target, "agent:demo")
	if payload, ok := fwd.payload.(Agent_Response); ok {
		testing.expect_value(t, resolve(payload.content), "hi")
	} else {
		testing.fail(t)
	}
}

@(test)
test_ingress_reuses_proxy_for_same_peer :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_ingress()
	defer th.destroy(&h)
	th.init(&h)

	th.send(&h, make_envelope("actor-a", "node-x", "agent:one"))
	th.expect_spawned(&h, t, Proxy_State)
	th.expect_sent_to(&h, t, actod.PID(101), Proxy_Forward)

	th.send(&h, make_envelope("actor-a", "node-x", "agent:two"))
	fwd := th.expect_sent_to(&h, t, actod.PID(101), Proxy_Forward)
	testing.expect_value(t, fwd.target, "agent:two")

	_, _, found := th.find_sent(&h, Proxy_Forward)
	testing.expect(t, !found)
}

@(test)
test_ingress_different_peers_get_different_proxies :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_ingress()
	defer th.destroy(&h)
	th.init(&h)

	th.send(&h, make_envelope("actor-a", "node-1", "agent:demo"))
	s1 := th.expect_spawned(&h, t, Proxy_State)
	th.expect_sent_to(&h, t, actod.PID(101), Proxy_Forward)

	th.send(&h, make_envelope("actor-b", "node-2", "agent:demo"))
	s2 := th.expect_spawned(&h, t, Proxy_State)
	testing.expect(t, s1.name != s2.name)
	th.expect_sent_to(&h, t, actod.PID(102), Proxy_Forward)
}

@(test)
test_ingress_forward_preserves_payload_variant :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_ingress()
	defer th.destroy(&h)
	th.init(&h)

	env := Remote_Envelope {
		target_name = "agent:demo",
		from_actor = "client",
		from_node = "node-x",
		payload = Tool_Call_Msg {
			request_id = 7,
			call_id = text("c1"),
			tool_name = text("search"),
			arguments = text(`{"q":"x"}`),
		},
	}
	th.send(&h, env)
	th.expect_spawned(&h, t, Proxy_State)
	fwd := th.expect_sent_to(&h, t, actod.PID(101), Proxy_Forward)
	if tc, ok := fwd.payload.(Tool_Call_Msg); ok {
		testing.expect_value(t, tc.request_id, Request_ID(7))
		testing.expect_value(t, resolve(tc.call_id), "c1")
		testing.expect_value(t, resolve(tc.tool_name), "search")
	} else {
		testing.fail(t)
	}
}
