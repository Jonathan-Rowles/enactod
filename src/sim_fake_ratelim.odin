#+build !freestanding
package enactod_impl

import "../pkgs/actod"
import "../pkgs/actod/test_harness/sim"


Fake_Ratelim_Scripted :: union {
	Fake_Result_Reply,
	Fake_Stream_Reply,
}

Fake_Result_Reply :: struct {
	body:        string,
	status_code: u32,
	headers:     string,
	error_msg:   string,
}

Fake_Stream_Reply :: struct {
	chunks:      []LLM_Stream_Chunk,
	status_code: u32,
	headers:     string,
}

Fake_Ratelim_State :: struct {
	replies:        [dynamic]Fake_Ratelim_Scripted,
	received_calls: [dynamic]LLM_Call,
}

fake_ratelim_behaviour :: actod.Actor_Behaviour(Fake_Ratelim_State) {
	handle_message = fake_ratelim_handle,
}

fake_ratelim_handle :: proc(data: ^Fake_Ratelim_State, _: actod.PID, content: any) {
	switch msg in content {
	case LLM_Call:
		captured := msg
		captured.payload = persist_text(msg.payload)
		captured.url = persist_text(msg.url)
		captured.auth_header = persist_text(msg.auth_header)
		captured.extra_headers = persist_text(msg.extra_headers)
		append(&data.received_calls, captured)
		if len(data.replies) == 0 {
			actod.send_message(
				msg.caller,
				LLM_Result {
					request_id = msg.request_id,
					error_msg = text("fake ratelim: no scripted reply"),
				},
			)
			return
		}
		scripted := data.replies[0]
		ordered_remove(&data.replies, 0)

		switch r in scripted {
		case Fake_Result_Reply:
			result := LLM_Result {
				request_id  = msg.request_id,
				status_code = r.status_code if r.status_code != 0 else 200,
				body        = text(r.body),
				headers     = text(r.headers),
				error_msg   = text(r.error_msg),
			}
			actod.send_message(msg.caller, result)

		case Fake_Stream_Reply:
			for chunk in r.chunks {
				stamped := chunk
				stamped.request_id = msg.request_id
				actod.send_message(msg.caller, stamped)
			}
			result := LLM_Result {
				request_id  = msg.request_id,
				status_code = r.status_code if r.status_code != 0 else 200,
				headers     = text(r.headers),
			}
			actod.send_message(msg.caller, result)
		}
	}
}

fake_ratelim_enqueue_result :: proc(
	state: ^Fake_Ratelim_State,
	body: string,
	status_code: u32 = 200,
	headers: string = "",
) {
	append(
		&state.replies,
		Fake_Ratelim_Scripted(
			Fake_Result_Reply{body = body, status_code = status_code, headers = headers},
		),
	)
}

fake_ratelim_enqueue_transport_error :: proc(state: ^Fake_Ratelim_State, err: string) {
	append(&state.replies, Fake_Ratelim_Scripted(Fake_Result_Reply{error_msg = err}))
}

fake_ratelim_enqueue_stream :: proc(
	state: ^Fake_Ratelim_State,
	chunks: []LLM_Stream_Chunk,
	status_code: u32 = 200,
	headers: string = "",
) {
	append(
		&state.replies,
		Fake_Ratelim_Scripted(
			Fake_Stream_Reply{chunks = chunks, status_code = status_code, headers = headers},
		),
	)
}

Observer_State :: struct {
	last_response: Agent_Response,
	got_response:  bool,
	event_count:   int,
	last_event:    Agent_Event,
	tool_results:  [dynamic]Tool_Result_Msg,
}

observer_behaviour :: actod.Actor_Behaviour(Observer_State) {
	handle_message = proc(d: ^Observer_State, _: actod.PID, content: any) {
		switch msg in content {
		case Agent_Response:
			d.last_response = msg
			d.got_response = true
		case Agent_Event:
			d.last_event = msg
			d.event_count += 1
		case Tool_Result_Msg:
			append(&d.tool_results, msg)
		}
	},
}

basic_sim_agent_cfg :: proc() -> Agent_Config {
	return make_agent_config(
		llm = openai_compat(
			"stub",
			"http://stub",
			"",
			Model.GPT_4o_Mini,
			enable_rate_limiting = false,
		),
		worker_count = 1,
	)
}

spin_up_agent :: proc(
	s: ^sim.Sim,
	cfg: Agent_Config,
) -> (
	agent_pid: actod.PID,
	observer_pid: actod.PID,
	ratelim_state: ^Fake_Ratelim_State,
) {
	sim.spawn(s, "ratelim:demo", Fake_Ratelim_State{}, fake_ratelim_behaviour)
	agent_pid = sim.spawn(
		s,
		"agent:demo",
		Agent_State{config = cfg, agent_name = "demo"},
		agent_behaviour,
	)
	observer_pid = sim.spawn(s, "observer", Observer_State{}, observer_behaviour)
	sim.init_all(s)
	ratelim_state = sim.get_state(s, "ratelim:demo", Fake_Ratelim_State)
	return
}
