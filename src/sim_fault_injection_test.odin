#+build !freestanding
package enactod_impl

import "../pkgs/actod/test_harness/sim"
import "core:strings"
import "core:testing"

@(test)
test_sim_drop_llm_result_triggers_timeout :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	context.logger.lowest_level = .Fatal
	s := sim.create()
	defer sim.destroy(&s)

	cfg := basic_sim_agent_cfg()
	agent_pid, observer_pid, rl := spin_up_agent(&s, cfg)

	sim.add_fault(
		&s,
		sim.Fault_Rule {
			match = sim.Fault_Match{to_name = "agent:demo", msg_type = typeid_of(LLM_Result)},
			action = .Drop,
			remaining = -1,
		},
	)

	fake_ratelim_enqueue_result(
		rl,
		`{"choices":[{"message":{"role":"assistant","content":"would never arrive"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}`,
	)

	sim.send_from(&s, agent_pid, observer_pid, Agent_Request{request_id = 1, content = text("hi")})

	sim.run_until_idle(&s)

	obs := sim.get_state(&s, "observer", Observer_State)
	testing.expect(t, !obs.got_response, "before timeout, observer should have no response")

	agent_cfg_timeout := cfg.llm.timeout
	sim.advance_time(&s, agent_cfg_timeout + agent_cfg_timeout / 2)
	sim.run_until_idle(&s)

	obs2 := sim.get_state(&s, "observer", Observer_State)
	testing.expect(t, obs2.got_response, "after timeout, observer should see error response")
	testing.expect_value(t, obs2.last_response.is_error, true)
	testing.expect(
		t,
		strings.contains(resolve(obs2.last_response.error_msg), "timed out"),
		"error message should mention timeout",
	)
}

@(test)
test_sim_delayed_llm_result_still_delivers :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := sim.create()
	defer sim.destroy(&s)

	cfg := basic_sim_agent_cfg()
	agent_pid, observer_pid, rl := spin_up_agent(&s, cfg)

	sim.add_fault(
		&s,
		sim.Fault_Rule {
			match = sim.Fault_Match{to_name = "agent:demo", msg_type = typeid_of(LLM_Result)},
			action = .Delay,
			remaining = 1,
			delay_steps = 2,
		},
	)

	fake_ratelim_enqueue_result(
		rl,
		`{"choices":[{"message":{"role":"assistant","content":"eventually"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}`,
	)

	sim.send_from(&s, agent_pid, observer_pid, Agent_Request{request_id = 1, content = text("hi")})
	for i in 0 ..< 10 {
		if !sim.step(&s) && sim.delayed_count(&s) == 0 {
			break
		}
		_ = i
	}

	obs := sim.get_state(&s, "observer", Observer_State)
	testing.expect(t, obs.got_response, "delayed result should eventually arrive")
	testing.expect_value(t, resolve(obs.last_response.content), "eventually")
	testing.expect_value(t, obs.last_response.is_error, false)
}
