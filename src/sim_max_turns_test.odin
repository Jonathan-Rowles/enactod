#+build !freestanding
package enactod_impl

import "../pkgs/actod/test_harness/sim"
import "core:mem"
import "core:strings"
import "core:testing"

@(private = "file")
noop_impl :: proc(_: string, _: mem.Allocator) -> (string, bool) {
	return "ok", false
}

@(test)
test_sim_max_turns_truncates :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	context.logger.lowest_level = .Fatal
	s := sim.create()
	defer sim.destroy(&s)

	tools := []Tool {
		function_tool(
			Tool_Def {
				name = "loop_tool",
				description = "loops",
				input_schema = `{"type":"object","properties":{}}`,
			},
			noop_impl,
		),
	}
	cfg := make_agent_config(
		llm = openai_compat(
			"stub",
			"http://stub",
			"",
			Model.GPT_4o_Mini,
			enable_rate_limiting = false,
		),
		tools = tools,
		worker_count = 1,
		max_turns = 2,
	)

	agent_pid, observer_pid, rl := spin_up_agent(&s, cfg)

	fake_ratelim_enqueue_result(
		rl,
		`{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"loop_tool","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}`,
	)
	fake_ratelim_enqueue_result(
		rl,
		`{"choices":[{"message":{"role":"assistant","content":"working on it","tool_calls":[{"id":"call_2","type":"function","function":{"name":"loop_tool","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}`,
	)

	sim.send_from(&s, agent_pid, observer_pid, Agent_Request{request_id = 1, content = text("go")})
	sim.run_until_idle(&s)

	obs := sim.get_state(&s, "observer", Observer_State)
	testing.expect(t, obs.got_response)
	content := resolve(obs.last_response.content)
	testing.expect(
		t,
		strings.has_prefix(content, "[truncated at turn limit 2]"),
		"content should be prefixed with truncation marker",
	)
	testing.expect(
		t,
		strings.contains(content, "working on it"),
		"partial should carry last assistant text",
	)
	testing.expect_value(t, len(rl.received_calls), 2)

	agent := sim.get_state(&s, "agent:demo", Agent_State)
	testing.expect_value(t, agent.phase, Agent_Phase.IDLE)
}

@(test)
test_sim_max_turns_nudge_injected_before_cap :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	context.logger.lowest_level = .Fatal
	s := sim.create()
	defer sim.destroy(&s)

	tools := []Tool {
		function_tool(
			Tool_Def {
				name = "loop_tool",
				description = "loops",
				input_schema = `{"type":"object","properties":{}}`,
			},
			noop_impl,
		),
	}
	cfg := make_agent_config(
		llm = openai_compat(
			"stub",
			"http://stub",
			"",
			Model.GPT_4o_Mini,
			enable_rate_limiting = false,
		),
		tools = tools,
		worker_count = 1,
		max_turns = 2,
	)
	agent_pid, observer_pid, rl := spin_up_agent(&s, cfg)

	fake_ratelim_enqueue_result(
		rl,
		`{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"loop_tool","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}`,
	)
	fake_ratelim_enqueue_result(
		rl,
		`{"choices":[{"message":{"role":"assistant","content":"done!"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}`,
	)

	sim.send_from(&s, agent_pid, observer_pid, Agent_Request{request_id = 1, content = text("go")})
	sim.run_until_idle(&s)

	obs := sim.get_state(&s, "observer", Observer_State)
	testing.expect(t, obs.got_response)
	testing.expect_value(t, resolve(obs.last_response.content), "done!")

	testing.expect_value(t, len(rl.received_calls), 2)
	agent := sim.get_state(&s, "agent:demo", Agent_State)
	_ = agent
	second_payload := resolve(rl.received_calls[1].payload)
	testing.expect(
		t,
		strings.contains(second_payload, "FINAL TURN"),
		"second LLM call should include the final-turn nudge in the conversation",
	)
}
