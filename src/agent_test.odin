#+build !freestanding
package enactod_impl

import "../pkgs/actod"
import th "../pkgs/actod/test_harness"
import "core:testing"
import "core:time"

@(private = "file")
local_pid :: proc(idx: u32) -> actod.PID {
	return actod.pack_pid(actod.Handle{idx = idx})
}

@(private = "file")
make_agent :: proc(
	cfg: Agent_Config,
	name: string = "test-agent",
) -> th.Test_Harness(Agent_State) {
	return th.create(Agent_State{config = cfg, agent_name = name}, agent_behaviour)
}

@(private = "file")
basic_cfg :: proc() -> Agent_Config {
	return make_agent_config(
		llm = openai_compat("stub", "http://stub", "", Model.GPT_4o_Mini),
		worker_count = 2,
	)
}

@(test)
test_agent_init_spawns_workers_and_rate_limiter :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_agent(basic_cfg())
	defer th.terminate(&h)
	defer th.destroy(&h)
	th.init(&h)

	s := th.expect_spawned(&h, t, LLM_Worker_State)
	testing.expect_value(t, s.name, "llm:test-agent:0")
	s = th.expect_spawned(&h, t, LLM_Worker_State)
	testing.expect_value(t, s.name, "llm:test-agent:1")
	s = th.expect_spawned(&h, t, Rate_Limiter_State)
	testing.expect_value(t, s.name, "ratelim:test-agent")
}

@(test)
test_agent_request_dispatches_llm_call_to_ratelim :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_agent(basic_cfg())
	defer th.terminate(&h)
	defer th.destroy(&h)
	th.init(&h)

	ratelim_pid := local_pid(500)
	th.register_pid(&h, "ratelim:test-agent", ratelim_pid)

	caller := local_pid(10)
	th.send(&h, Agent_Request{request_id = 1, content = text("hi")}, caller)

	call := th.expect_sent_to(&h, t, ratelim_pid, LLM_Call)
	testing.expect_value(t, call.request_id, Request_ID(1))
	testing.expect_value(t, call.format, API_Format.OPENAI_COMPAT)
	testing.expect(t, len(resolve(call.url)) > 0)
	testing.expect(t, len(resolve(call.payload)) > 0)
	testing.expect(t, call.timeout > 0)

	s := th.get_state(&h)
	testing.expect_value(t, s.phase, Agent_Phase.AWAITING_LLM)
	testing.expect_value(t, s.current_req, Request_ID(1))
	testing.expect_value(t, s.caller_pid, caller)
}

@(test)
test_agent_request_appends_user_entry :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_agent(basic_cfg())
	defer th.terminate(&h)
	defer th.destroy(&h)
	th.init(&h)
	th.register_pid(&h, "ratelim:test-agent", local_pid(500))

	th.send(&h, Agent_Request{request_id = 1, content = text("hello")}, local_pid(10))
	s := th.get_state(&h)
	testing.expect_value(t, len(s.messages), 1)
	testing.expect_value(t, s.messages[0].role, Chat_Role.USER)
	testing.expect_value(t, resolve(s.messages[0].content), "hello")
}

@(test)
test_agent_request_prepends_system_prompt_on_first_turn :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	cfg := basic_cfg()
	cfg.system_prompt = "be helpful"
	h := make_agent(cfg)
	defer th.terminate(&h)
	defer th.destroy(&h)
	th.init(&h)
	th.register_pid(&h, "ratelim:test-agent", local_pid(500))

	th.send(&h, Agent_Request{request_id = 1, content = text("hi")}, local_pid(10))
	s := th.get_state(&h)
	testing.expect_value(t, len(s.messages), 2)
	testing.expect_value(t, s.messages[0].role, Chat_Role.SYSTEM)
	testing.expect_value(t, resolve(s.messages[0].content), "be helpful")
	testing.expect_value(t, s.messages[1].role, Chat_Role.USER)
}

@(test)
test_agent_busy_rejection :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_agent(basic_cfg())
	defer th.terminate(&h)
	defer th.destroy(&h)
	th.init(&h)
	th.register_pid(&h, "ratelim:test-agent", local_pid(500))

	caller := local_pid(10)

	th.send(&h, Agent_Request{request_id = 1, content = text("first")}, caller)
	th.expect_sent_to(&h, t, local_pid(500), LLM_Call)

	th.send(&h, Agent_Request{request_id = 2, content = text("second")}, caller)
	resp := th.expect_sent_to(&h, t, caller, Agent_Response)
	testing.expect_value(t, resp.request_id, Request_ID(2))
	testing.expect_value(t, resp.is_error, true)
	testing.expect_value(t, resolve(resp.error_msg), "agent is busy")

	s := th.get_state(&h)
	testing.expect_value(t, s.current_req, Request_ID(1))
	testing.expect_value(t, s.caller_pid, caller)
}

@(test)
test_agent_claim_rejection :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_agent(basic_cfg())
	defer th.terminate(&h)
	defer th.destroy(&h)
	th.init(&h)
	th.register_pid(&h, "ratelim:test-agent", local_pid(500))

	first := local_pid(10)
	intruder := local_pid(11)

	th.send(&h, Agent_Request{request_id = 1, content = text("first")}, first)
	th.expect_sent_to(&h, t, local_pid(500), LLM_Call)

	th.send(&h, Agent_Request{request_id = 2, content = text("intruder")}, intruder)
	resp := th.expect_sent_to(&h, t, intruder, Agent_Response)
	testing.expect_value(t, resp.request_id, Request_ID(2))
	testing.expect_value(t, resp.is_error, true)
	testing.expect_value(t, resolve(resp.error_msg), "agent claimed by another actor")

	s := th.get_state(&h)
	testing.expect_value(t, s.claimed_by, first)
}

@(test)
test_set_route_stashes_override :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_agent(basic_cfg())
	defer th.terminate(&h)
	defer th.destroy(&h)
	th.init(&h)

	th.send(&h, Set_Route{llm = anthropic("x", "claude-haiku-4-5-20251001")})

	s := th.get_state(&h)
	ovr, ok := s.route_override.?
	testing.expect(t, ok)
	testing.expect_value(t, ovr.provider.name, "anthropic")
	testing.expect_value(t, ovr.provider.format, API_Format.ANTHROPIC)
	testing.expect_value(t, resolve_model_string(ovr.model), "claude-haiku-4-5-20251001")
}

@(test)
test_clear_route_removes_override :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_agent(basic_cfg())
	defer th.terminate(&h)
	defer th.destroy(&h)
	th.init(&h)

	th.send(&h, Set_Route{llm = openai_compat("x", "https://x", "", "m")})
	th.send(&h, Clear_Route{})

	s := th.get_state(&h)
	_, ok := s.route_override.?
	testing.expect(t, !ok)
}

@(test)
test_reset_conversation_ignored_when_non_idle :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_agent(basic_cfg())
	defer th.terminate(&h)
	defer th.destroy(&h)
	th.init(&h)
	th.register_pid(&h, "ratelim:test-agent", local_pid(500))

	caller := local_pid(10)
	th.send(&h, Agent_Request{request_id = 1, content = text("hi")}, caller)
	th.expect_sent_to(&h, t, local_pid(500), LLM_Call)
	before := th.get_state(&h)
	msg_count_before := len(before.messages)

	th.send(&h, Reset_Conversation{request_id = 2, caller = caller})

	after := th.get_state(&h)
	testing.expect_value(t, after.phase, Agent_Phase.AWAITING_LLM)
	testing.expect_value(t, len(after.messages), msg_count_before)
}

@(test)
test_reset_conversation_clears_history_when_idle :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	cfg := basic_cfg()
	cfg.system_prompt = "system"
	h := make_agent(cfg)
	defer th.terminate(&h)
	defer th.destroy(&h)
	th.init(&h)

	s := th.get_state(&h)
	append_system_entry(&s.messages, "sys")
	append_user_entry(&s.messages, "u1")
	testing.expect_value(t, len(s.messages), 2)

	th.send(&h, Reset_Conversation{request_id = 1, caller = local_pid(10)})

	s2 := th.get_state(&h)
	testing.expect_value(t, len(s2.messages), 0)
}

@(test)
test_arena_status_query_reply_shape :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_agent(basic_cfg())
	defer th.terminate(&h)
	defer th.destroy(&h)
	th.init(&h)

	caller := local_pid(10)
	th.send(&h, Arena_Status_Query{request_id = 7, caller = caller})

	status := th.expect_sent_to(&h, t, caller, Arena_Status)
	testing.expect_value(t, status.request_id, Request_ID(7))
	testing.expect(t, status.owns_arena)
	testing.expect_value(t, status.message_count, 0)
	testing.expect(t, status.bytes_reserved > 0)
}

@(test)
test_history_query_returns_entry_or_not_found :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_agent(basic_cfg())
	defer th.terminate(&h)
	defer th.destroy(&h)
	th.init(&h)

	s := th.get_state(&h)
	append_user_entry(&s.messages, "hello")
	append_assistant_entry(&s.messages, text("world"))

	caller := local_pid(10)
	th.send(&h, History_Query{request_id = 1, caller = caller, index = 0})
	entry0 := th.expect_sent_to(&h, t, caller, History_Entry_Msg)
	testing.expect_value(t, entry0.found, true)
	testing.expect_value(t, entry0.role, Chat_Role.USER)
	testing.expect_value(t, resolve(entry0.content), "hello")

	th.send(&h, History_Query{request_id = 2, caller = caller, index = 1})
	entry1 := th.expect_sent_to(&h, t, caller, History_Entry_Msg)
	testing.expect_value(t, entry1.found, true)
	testing.expect_value(t, entry1.role, Chat_Role.ASSISTANT)

	th.send(&h, History_Query{request_id = 3, caller = caller, index = 99})
	entry2 := th.expect_sent_to(&h, t, caller, History_Entry_Msg)
	testing.expect_value(t, entry2.found, false)
}

@(test)
test_accumulate_history_false_resets_each_request :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	cfg := basic_cfg()
	cfg.accumulate_history = false
	cfg.system_prompt = "sys"
	h := make_agent(cfg)
	defer th.terminate(&h)
	defer th.destroy(&h)
	th.init(&h)
	th.register_pid(&h, "ratelim:test-agent", local_pid(500))

	caller := local_pid(10)
	th.send(&h, Agent_Request{request_id = 1, content = text("first")}, caller)
	th.expect_sent_to(&h, t, local_pid(500), LLM_Call)

	s1 := th.get_state(&h)
	testing.expect_value(t, len(s1.messages), 2)

	s1.phase = .IDLE

	th.send(&h, Agent_Request{request_id = 2, content = text("second")}, caller)
	th.expect_sent_to(&h, t, local_pid(500), LLM_Call)

	s2 := th.get_state(&h)
	testing.expect_value(t, len(s2.messages), 2)
	testing.expect_value(t, resolve(s2.messages[1].content), "second")
}

@(test)
test_agent_llm_timeout_sends_error_response :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	context.logger.lowest_level = .Fatal
	cfg := basic_cfg()
	cfg.llm.timeout = 500 * time.Millisecond
	h := make_agent(cfg)
	defer th.terminate(&h)
	defer th.destroy(&h)
	th.init(&h)
	th.register_pid(&h, "ratelim:test-agent", local_pid(500))

	caller := local_pid(10)
	th.send(&h, Agent_Request{request_id = 1, content = text("hi")}, caller)
	th.expect_sent_to(&h, t, local_pid(500), LLM_Call)

	timer := th.expect_timer(&h, t)
	th.fire_timer(&h, timer.id)

	resp := th.expect_sent_to(&h, t, caller, Agent_Response)
	testing.expect_value(t, resp.request_id, Request_ID(1))
	testing.expect_value(t, resp.is_error, true)

	s := th.get_state(&h)
	testing.expect_value(t, s.phase, Agent_Phase.IDLE)
}
