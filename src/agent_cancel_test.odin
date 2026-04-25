#+build !freestanding
package enactod_impl

import "../pkgs/actod"
import "../pkgs/actod/test_harness/sim"
import "core:strings"
import "core:testing"

@(private = "file")
park_in_awaiting_llm :: proc(s: ^sim.Sim, observer_pid: actod.PID, current_req: Request_ID) {
	a := sim.get_state(s, "agent:demo", Agent_State)
	a.phase = .AWAITING_LLM
	a.current_req = current_req
	a.caller_pid = observer_pid
	a.claimed_by = observer_pid
}

@(test)
test_sim_cancel_turn_returns_to_idle :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := sim.create()
	defer sim.destroy(&s)

	agent_pid, observer_pid, _ := spin_up_agent(&s, basic_sim_agent_cfg())
	park_in_awaiting_llm(&s, observer_pid, 1)

	sim.send_from(&s, agent_pid, observer_pid, Cancel_Turn{request_id = 1, caller = observer_pid})
	sim.run_until_idle(&s)

	obs := sim.get_state(&s, "observer", Observer_State)
	testing.expect(t, obs.got_response, "observer should receive Agent_Response after cancel")
	testing.expect_value(t, obs.last_response.is_error, true)
	testing.expect(
		t,
		strings.contains(resolve(obs.last_response.error_msg), "cancelled"),
		"error_msg should contain 'cancelled'",
	)

	a := sim.get_state(&s, "agent:demo", Agent_State)
	testing.expect_value(t, a.phase, Agent_Phase.IDLE)
	testing.expect_value(t, a.current_req, Request_ID(0))
	testing.expect_value(t, a.pending_tools, 0)
}

@(test)
test_sim_cancel_turn_idle_is_noop :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := sim.create()
	defer sim.destroy(&s)

	agent_pid, observer_pid, _ := spin_up_agent(&s, basic_sim_agent_cfg())

	sim.send_from(&s, agent_pid, observer_pid, Cancel_Turn{request_id = 99, caller = observer_pid})
	sim.run_until_idle(&s)

	obs := sim.get_state(&s, "observer", Observer_State)
	testing.expect(t, !obs.got_response, "no Agent_Response should be sent for stale cancel")

	a := sim.get_state(&s, "agent:demo", Agent_State)
	testing.expect_value(t, a.phase, Agent_Phase.IDLE)
}

@(test)
test_sim_cancel_turn_stale_id_is_noop :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := sim.create()
	defer sim.destroy(&s)

	agent_pid, observer_pid, _ := spin_up_agent(&s, basic_sim_agent_cfg())
	park_in_awaiting_llm(&s, observer_pid, 7)

	sim.send_from(
		&s,
		agent_pid,
		observer_pid,
		Cancel_Turn{request_id = 999, caller = observer_pid},
	)
	sim.run_until_idle(&s)

	obs := sim.get_state(&s, "observer", Observer_State)
	testing.expect(t, !obs.got_response, "no response should be sent for stale-id cancel")

	a := sim.get_state(&s, "agent:demo", Agent_State)
	testing.expect_value(t, a.phase, Agent_Phase.AWAITING_LLM)
	testing.expect_value(t, a.current_req, Request_ID(7))
}
