#+build !freestanding
package enactod_impl

import "../pkgs/actod/test_harness/sim"
import "core:mem"
import "core:testing"

@(private = "file")
get_time_impl :: proc(arguments: string, allocator: mem.Allocator) -> (string, bool) {
	return "2026-04-19 10:00:00", false
}

@(private = "file")
echo_arg_impl :: proc(arguments: string, _: mem.Allocator) -> (string, bool) {
	return arguments, false
}

@(test)
test_sim_inline_tool_round_trip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := sim.create()
	defer sim.destroy(&s)

	tools := []Tool {
		function_tool(
			Tool_Def {
				name = "get_time",
				description = "current time",
				input_schema = `{"type":"object","properties":{}}`,
			},
			get_time_impl,
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
	)

	agent_pid, observer_pid, rl := spin_up_agent(&s, cfg)

	fake_ratelim_enqueue_result(
		rl,
		`{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_time","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}`,
	)
	fake_ratelim_enqueue_result(
		rl,
		`{"choices":[{"message":{"role":"assistant","content":"It is 10am."},"finish_reason":"stop"}],"usage":{"prompt_tokens":20,"completion_tokens":7}}`,
	)

	sim.send_from(
		&s,
		agent_pid,
		observer_pid,
		Agent_Request{request_id = 1, content = text("what time?")},
	)
	sim.run_until_idle(&s)

	obs := sim.get_state(&s, "observer", Observer_State)
	testing.expect(t, obs.got_response)
	testing.expect_value(t, resolve(obs.last_response.content), "It is 10am.")

	testing.expect_value(t, len(rl.received_calls), 2)

	testing.expect_value(t, obs.last_response.input_tokens, 30)
	testing.expect_value(t, obs.last_response.output_tokens, 12)

	agent := sim.get_state(&s, "agent:demo", Agent_State)
	testing.expect_value(t, agent.phase, Agent_Phase.IDLE)
}

@(test)
test_sim_inline_tool_schema_rejects_bad_args :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := sim.create()
	defer sim.destroy(&s)

	tools := []Tool {
		function_tool(
			Tool_Def {
				name = "echo",
				description = "echo",
				input_schema = `{"type":"object","properties":{"msg":{"type":"string"}},"required":["msg"]}`,
			},
			echo_arg_impl,
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
		validate_tool_args = true,
	)

	agent_pid, observer_pid, rl := spin_up_agent(&s, cfg)

	fake_ratelim_enqueue_result(
		rl,
		`{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"echo","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}`,
	)
	fake_ratelim_enqueue_result(
		rl,
		`{"choices":[{"message":{"role":"assistant","content":"sorry"},"finish_reason":"stop"}],"usage":{"prompt_tokens":20,"completion_tokens":2}}`,
	)

	sim.send_from(
		&s,
		agent_pid,
		observer_pid,
		Agent_Request{request_id = 1, content = text("echo?")},
	)
	sim.run_until_idle(&s)

	obs := sim.get_state(&s, "observer", Observer_State)
	testing.expect(t, obs.got_response)
	testing.expect_value(t, resolve(obs.last_response.content), "sorry")
	testing.expect_value(t, len(rl.received_calls), 2)
}

@(test)
test_sim_inline_tool_not_found_reports_error :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := sim.create()
	defer sim.destroy(&s)

	cfg := basic_sim_agent_cfg()
	agent_pid, observer_pid, rl := spin_up_agent(&s, cfg)

	fake_ratelim_enqueue_result(
		rl,
		`{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"x","type":"function","function":{"name":"no_such","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}`,
	)
	fake_ratelim_enqueue_result(
		rl,
		`{"choices":[{"message":{"role":"assistant","content":"bail"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}`,
	)

	sim.send_from(&s, agent_pid, observer_pid, Agent_Request{request_id = 1, content = text("hi")})
	sim.run_until_idle(&s)

	obs := sim.get_state(&s, "observer", Observer_State)
	testing.expect(t, obs.got_response)
	testing.expect_value(t, resolve(obs.last_response.content), "bail")
	testing.expect_value(t, len(rl.received_calls), 2)
}
