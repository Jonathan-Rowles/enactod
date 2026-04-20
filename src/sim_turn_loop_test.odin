#+build !freestanding
package enactod_impl

import "../pkgs/actod/test_harness/sim"
import "core:testing"

@(test)
test_sim_turn_loop_text_response :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := sim.create()
	defer sim.destroy(&s)

	agent_pid, observer_pid, rl := spin_up_agent(&s, basic_sim_agent_cfg())

	fake_ratelim_enqueue_result(
		rl,
		`{"choices":[{"message":{"role":"assistant","content":"hello from sim"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":3}}`,
	)

	sim.send_from(
		&s,
		agent_pid,
		observer_pid,
		Agent_Request{request_id = 1, content = text("hi there")},
	)
	sim.run_until_idle(&s)

	obs := sim.get_state(&s, "observer", Observer_State)
	testing.expect(t, obs.got_response, "observer should receive Agent_Response")
	testing.expect_value(t, resolve(obs.last_response.content), "hello from sim")
	testing.expect_value(t, obs.last_response.is_error, false)
	testing.expect_value(t, obs.last_response.input_tokens, 5)
	testing.expect_value(t, obs.last_response.output_tokens, 3)

	agent := sim.get_state(&s, "agent:demo", Agent_State)
	testing.expect_value(t, agent.phase, Agent_Phase.IDLE)

	testing.expect_value(t, len(rl.received_calls), 1)
	testing.expect_value(t, rl.received_calls[0].format, API_Format.OPENAI_COMPAT)
}
