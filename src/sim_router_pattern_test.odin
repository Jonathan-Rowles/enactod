#+build !freestanding
package enactod_impl

import "../pkgs/actod"
import "../pkgs/actod/test_harness/sim"
import "core:strings"
import "core:testing"

Router_State :: struct {
	target_agent: string,
	new_llm:      LLM_Config,
	responses:    int,
	route_sent:   bool,
}

router_behaviour :: actod.Actor_Behaviour(Router_State) {
	handle_message = proc(d: ^Router_State, _: actod.PID, content: any) {
		switch msg in content {
		case Agent_Response:
			d.responses += 1
			if !d.route_sent {
				actod.send_message_name(
					agent_actor_name(d.target_agent),
					Set_Route{llm = d.new_llm},
				)
				d.route_sent = true
			}
		}
	},
}

@(test)
test_sim_router_switches_route_between_turns :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := sim.create()
	defer sim.destroy(&s)

	start_provider := make_provider("stub-a", "http://stub-a", "", .OPENAI_COMPAT)
	cfg := make_agent_config(
		llm = LLM_Config {
			provider = start_provider,
			model = Model.GPT_4o_Mini,
			enable_rate_limiting = false,
		},
		worker_count = 1,
	)
	agent_pid, _, rl := spin_up_agent(&s, cfg)

	router_pid := sim.spawn(
		&s,
		"router",
		Router_State {
			target_agent = "demo",
			new_llm = openai_compat("stub-b", "http://stub-b", "", "swapped-model"),
		},
		router_behaviour,
	)

	fake_ratelim_enqueue_result(
		rl,
		`{"choices":[{"message":{"role":"assistant","content":"first"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}`,
	)
	fake_ratelim_enqueue_result(
		rl,
		`{"choices":[{"message":{"role":"assistant","content":"second"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}`,
	)

	sim.send_from(&s, agent_pid, router_pid, Agent_Request{request_id = 1, content = text("hi")})
	sim.run_until_idle(&s)

	sim.send_from(
		&s,
		agent_pid,
		router_pid,
		Agent_Request{request_id = 2, content = text("hi again")},
	)
	sim.run_until_idle(&s)

	testing.expect_value(t, len(rl.received_calls), 2)

	first_url := resolve(rl.received_calls[0].url)
	second_url := resolve(rl.received_calls[1].url)
	testing.expect(
		t,
		strings.contains(first_url, "stub-a"),
		"first call should use default provider",
	)
	testing.expect(
		t,
		strings.contains(second_url, "stub-b"),
		"second call should use Set_Route provider",
	)

	second_payload := resolve(rl.received_calls[1].payload)
	testing.expect(
		t,
		strings.contains(second_payload, "swapped-model"),
		"second call payload should carry the Set_Route model",
	)

	router := sim.get_state(&s, "router", Router_State)
	testing.expect_value(t, router.responses, 2)
	testing.expect(t, router.route_sent)
}

@(test)
test_sim_clear_route_reverts_to_config_default :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := sim.create()
	defer sim.destroy(&s)

	cfg := basic_sim_agent_cfg()
	agent_pid, observer_pid, rl := spin_up_agent(&s, cfg)

	sim.send(
		&s,
		"agent:demo",
		Set_Route{llm = openai_compat("override", "http://override", "", "override-model")},
	)
	sim.send(&s, "agent:demo", Clear_Route{})
	sim.run_until_idle(&s)

	fake_ratelim_enqueue_result(
		rl,
		`{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}`,
	)
	sim.send_from(&s, agent_pid, observer_pid, Agent_Request{request_id = 1, content = text("x")})
	sim.run_until_idle(&s)

	url := resolve(rl.received_calls[0].url)
	testing.expect(
		t,
		strings.contains(url, "stub"),
		"after Clear_Route, default provider should win",
	)
	testing.expect(t, !strings.contains(url, "override"))
}
