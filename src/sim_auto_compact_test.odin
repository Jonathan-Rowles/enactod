#+build !freestanding
package enactod_impl

import "../pkgs/actod/test_harness/sim"
import "core:strings"
import "core:testing"

@(test)
test_sim_auto_compact_triggers_after_threshold :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	context.logger.lowest_level = .Fatal
	s := sim.create()
	defer sim.destroy(&s)

	cfg := make_agent_config(
		llm = openai_compat(
			"stub",
			"http://stub",
			"",
			Model.GPT_4o_Mini,
			enable_rate_limiting = false,
		),
		worker_count = 1,
		auto_compact_threshold_tokens = 100,
	)
	agent_pid, observer_pid, rl := spin_up_agent(&s, cfg)

	fake_ratelim_enqueue_result(
		rl,
		`{"choices":[{"message":{"role":"assistant","content":"answer"},"finish_reason":"stop"}],"usage":{"prompt_tokens":150,"completion_tokens":1}}`,
	)
	fake_ratelim_enqueue_result(
		rl,
		`{"choices":[{"message":{"role":"assistant","content":"summary of conversation"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}`,
	)

	sim.send_from(
		&s,
		agent_pid,
		observer_pid,
		Agent_Request{request_id = 1, content = text("hi")},
	)
	sim.run_until_idle(&s)

	obs := sim.get_state(&s, "observer", Observer_State)
	testing.expect(t, obs.got_response)
	testing.expect_value(t, resolve(obs.last_response.content), "answer")

	testing.expect_value(t, len(rl.received_calls), 2)

	agent := sim.get_state(&s, "agent:demo", Agent_State)
	testing.expect_value(t, agent.phase, Agent_Phase.IDLE)
	testing.expect_value(t, len(agent.messages), 1)
	testing.expect(
		t,
		strings.contains(resolve(agent.messages[0].content), "summary of conversation"),
		"history should be replaced by the compact summary",
	)
}

@(test)
test_sim_auto_compact_disabled_when_threshold_zero :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	context.logger.lowest_level = .Fatal
	s := sim.create()
	defer sim.destroy(&s)

	cfg := basic_sim_agent_cfg()
	agent_pid, observer_pid, rl := spin_up_agent(&s, cfg)

	fake_ratelim_enqueue_result(
		rl,
		`{"choices":[{"message":{"role":"assistant","content":"answer"},"finish_reason":"stop"}],"usage":{"prompt_tokens":150,"completion_tokens":1}}`,
	)

	sim.send_from(
		&s,
		agent_pid,
		observer_pid,
		Agent_Request{request_id = 1, content = text("hi")},
	)
	sim.run_until_idle(&s)

	testing.expect_value(t, len(rl.received_calls), 1)

	agent := sim.get_state(&s, "agent:demo", Agent_State)
	testing.expect_value(t, agent.phase, Agent_Phase.IDLE)
}

@(test)
test_sim_auto_compact_below_threshold_no_trigger :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	context.logger.lowest_level = .Fatal
	s := sim.create()
	defer sim.destroy(&s)

	cfg := make_agent_config(
		llm = openai_compat(
			"stub",
			"http://stub",
			"",
			Model.GPT_4o_Mini,
			enable_rate_limiting = false,
		),
		worker_count = 1,
		auto_compact_threshold_tokens = 1000,
	)
	agent_pid, observer_pid, rl := spin_up_agent(&s, cfg)

	fake_ratelim_enqueue_result(
		rl,
		`{"choices":[{"message":{"role":"assistant","content":"answer"},"finish_reason":"stop"}],"usage":{"prompt_tokens":50,"completion_tokens":1}}`,
	)

	sim.send_from(
		&s,
		agent_pid,
		observer_pid,
		Agent_Request{request_id = 1, content = text("hi")},
	)
	sim.run_until_idle(&s)

	testing.expect_value(t, len(rl.received_calls), 1)
}
