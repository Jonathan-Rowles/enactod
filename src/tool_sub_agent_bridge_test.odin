#+build !freestanding
package enactod_impl

import "../pkgs/actod"
import th "../pkgs/actod/test_harness"
import "core:testing"

@(private = "file")
make_bridge :: proc() -> th.Test_Harness(Sub_Agent_Bridge_State) {
	return th.create(
		Sub_Agent_Bridge_State{sub_agent_name = "demo-research"},
		sub_agent_bridge_behaviour,
	)
}

@(private = "file")
seed_pending :: proc(
	s: ^Sub_Agent_Bridge_State,
	call_id, tool_name: string,
	req: Request_ID,
	caller: actod.PID,
) {
	s.pending_id = text(call_id)
	s.tool_name = text(tool_name)
	s.request_id = req
	s.caller = caller
	s.sub_agent_pid = actod.pack_pid(actod.Handle{idx = 500})
}

@(test)
test_bridge_agent_response_becomes_tool_result :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	context.logger.lowest_level = .Fatal
	h := make_bridge()
	defer th.destroy(&h)
	th.init(&h)

	caller := actod.pack_pid(actod.Handle{idx = 10})
	seed_pending(th.get_state(&h), "call_1", "research", 42, caller)

	th.send(&h, Agent_Response{request_id = 99, content = text("final"), is_error = false})

	r := th.expect_sent_to(&h, t, caller, Tool_Result_Msg)
	testing.expect_value(t, r.request_id, Request_ID(42))
	testing.expect_value(t, resolve(r.call_id), "call_1")
	testing.expect_value(t, resolve(r.tool_name), "research")
	testing.expect_value(t, resolve(r.result), "final")
	testing.expect_value(t, r.is_error, false)
}

@(test)
test_bridge_agent_response_error_is_wrapped :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	context.logger.lowest_level = .Fatal
	h := make_bridge()
	defer th.destroy(&h)
	th.init(&h)

	caller := actod.pack_pid(actod.Handle{idx = 10})
	seed_pending(th.get_state(&h), "c", "r", 1, caller)

	th.send(&h, Agent_Response{request_id = 1, is_error = true, error_msg = text("boom")})

	r := th.expect_sent_to(&h, t, caller, Tool_Result_Msg)
	testing.expect_value(t, r.is_error, true)
	testing.expect_value(t, resolve(r.result), "sub-agent error: boom")
}

@(test)
test_bridge_agent_event_bubbles_to_caller :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_bridge()
	defer th.destroy(&h)
	th.init(&h)

	caller := actod.pack_pid(actod.Handle{idx = 10})
	seed_pending(th.get_state(&h), "c", "r", 1, caller)

	th.send(&h, Agent_Event{kind = .TEXT_DELTA, detail = text("delta")})
	ev := th.expect_sent_to(&h, t, caller, Agent_Event)
	testing.expect_value(t, ev.kind, Event_Kind.TEXT_DELTA)
	testing.expect_value(t, resolve(ev.detail), "delta")
}
