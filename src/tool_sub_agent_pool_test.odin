#+build !freestanding
package enactod_impl

import "../pkgs/actod"
import th "../pkgs/actod/test_harness"
import "core:testing"

@(private = "file")
make_pool :: proc(pool_size: int = 3) -> th.Test_Harness(Sub_Agent_Pool_State) {
	cfg := basic_pool_cfg()
	return th.create(
		Sub_Agent_Pool_State {
			base_name = "demo-research",
			sub_agent_config = &cfg,
			pool_size = pool_size,
		},
		sub_agent_pool_behaviour,
	)
}

@(private = "file")
basic_pool_cfg :: proc() -> Agent_Config {
	return make_agent_config(llm = openai_compat("stub", "http://stub", "", Model.GPT_4o_Mini))
}

@(test)
test_pool_find_free_slot_lazy_allocates_slots :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_pool(pool_size = 3)
	defer th.destroy(&h)
	th.init(&h)

	s := th.get_state(&h)
	testing.expect_value(t, len(s.slots), 0)

	idx := find_free_slot(s)
	testing.expect_value(t, idx, 0)
	testing.expect_value(t, len(s.slots), 3)
}

@(test)
test_pool_find_free_slot_returns_minus_one_when_full :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_pool(pool_size = 2)
	defer th.destroy(&h)
	th.init(&h)

	s := th.get_state(&h)
	find_free_slot(s)
	s.slots[0].busy = true
	s.slots[1].busy = true

	testing.expect_value(t, find_free_slot(s), -1)
}

@(test)
test_pool_find_free_slot_returns_next_free :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_pool(pool_size = 3)
	defer th.destroy(&h)
	th.init(&h)

	s := th.get_state(&h)
	find_free_slot(s)
	s.slots[0].busy = true
	s.slots[1].busy = false
	s.slots[2].busy = true

	testing.expect_value(t, find_free_slot(s), 1)
}

@(test)
test_pool_tool_call_queues_to_overflow_when_all_busy :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := make_pool(pool_size = 2)
	defer th.destroy(&h)
	th.init(&h)

	s := th.get_state(&h)
	find_free_slot(s)
	for i in 0 ..< len(s.slots) {
		s.slots[i].busy = true
		s.slots[i].pid = actod.pack_pid(actod.Handle{idx = u32(900 + i)})
	}

	caller := actod.pack_pid(actod.Handle{idx = 10})
	th.send(
		&h,
		Tool_Call_Msg {
			request_id = 1,
			call_id = text("c1"),
			tool_name = text("research"),
			arguments = text(`{"query":"first"}`),
		},
		caller,
	)
	th.send(
		&h,
		Tool_Call_Msg {
			request_id = 2,
			call_id = text("c2"),
			tool_name = text("research"),
			arguments = text(`{"query":"second"}`),
		},
		caller,
	)

	s2 := th.get_state(&h)
	testing.expect_value(t, len(s2.overflow), 2)
	testing.expect_value(t, resolve(s2.overflow[0].query), "first")
	testing.expect_value(t, resolve(s2.overflow[1].query), "second")
}
