#+build !freestanding
package enactod_impl

import "../pkgs/actod"
import th "../pkgs/actod/test_harness"
import "core:testing"

@(private = "file")
make_proxy :: proc() -> th.Test_Harness(Proxy_State) {
	return th.create(
		Proxy_State{remote_actor = "remote-target", remote_node = "peer-node"},
		proxy_behaviour,
	)
}

@(test)
test_proxy_forward_delivers_to_local_target :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_proxy()
	defer th.destroy(&h)

	local_target_pid := actod.PID(500)
	th.register_pid(&h, "agent:local-target", local_target_pid)

	th.send(
		&h,
		Proxy_Forward {
			target = "agent:local-target",
			payload = Agent_Request{request_id = 3, content = text("hello")},
		},
	)

	msg := th.expect_sent_to(&h, t, local_target_pid, Agent_Request)
	testing.expect_value(t, msg.request_id, Request_ID(3))
	testing.expect_value(t, resolve(msg.content), "hello")
}

@(test)
test_build_proxy_reply_envelope_shape :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	env := build_proxy_reply_envelope(
		"remote-target",
		"local-actor",
		"this-node",
		Agent_Response{request_id = 5, content = text("world")},
	)
	testing.expect_value(t, env.target_name, "remote-target")
	testing.expect_value(t, env.from_actor, "local-actor")
	testing.expect_value(t, env.from_node, "this-node")
	if payload, ok := env.payload.(Agent_Response); ok {
		testing.expect_value(t, payload.request_id, Request_ID(5))
		testing.expect_value(t, resolve(payload.content), "world")
	} else {
		testing.fail(t)
	}
}
