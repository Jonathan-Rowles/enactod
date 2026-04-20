#+build !freestanding
package enactod_impl

import "../pkgs/actod"
import th "../pkgs/actod/test_harness"
import "core:mem"
import vmem "core:mem/virtual"
import "core:testing"

@(private = "file")
echo_impl :: proc(arguments: string, allocator: mem.Allocator) -> (string, bool) {
	return arguments, false
}

@(private = "file")
failing_impl :: proc(_: string, _: mem.Allocator) -> (string, bool) {
	return "boom", true
}

@(test)
test_tool_actor_happy_path :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	arena: vmem.Arena
	testing.expect(t, arena_init(&arena, 4096))
	defer arena_destroy(&arena)
	caller := actod.PID(42)
	h := th.create(Tool_Actor_State{execute = echo_impl, arena = &arena}, tool_actor_behaviour)
	defer th.destroy(&h)

	th.send(
		&h,
		Tool_Call_Msg {
			request_id = 1,
			call_id = text("call_1", &arena),
			tool_name = text("echo", &arena),
			arguments = text(`{"ping":true}`, &arena),
		},
		caller,
	)

	reply := th.expect_sent_to(&h, t, caller, Tool_Result_Msg)
	testing.expect_value(t, reply.request_id, Request_ID(1))
	testing.expect_value(t, resolve(reply.call_id), "call_1")
	testing.expect_value(t, resolve(reply.tool_name), "echo")
	testing.expect_value(t, resolve(reply.result), `{"ping":true}`)
	testing.expect_value(t, reply.is_error, false)
}

@(test)
test_tool_actor_propagates_is_error :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	arena: vmem.Arena
	testing.expect(t, arena_init(&arena, 4096))
	defer arena_destroy(&arena)
	caller := actod.PID(100)
	h := th.create(Tool_Actor_State{execute = failing_impl, arena = &arena}, tool_actor_behaviour)
	defer th.destroy(&h)

	th.send(
		&h,
		Tool_Call_Msg {
			request_id = 7,
			call_id = text("c", &arena),
			tool_name = text("bad", &arena),
			arguments = text("{}", &arena),
		},
		caller,
	)

	reply := th.expect_sent_to(&h, t, caller, Tool_Result_Msg)
	testing.expect_value(t, reply.is_error, true)
	testing.expect_value(t, resolve(reply.result), "boom")
}

@(test)
test_tool_actor_missing_execute_returns_error :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	context.logger.lowest_level = .Fatal
	arena: vmem.Arena
	testing.expect(t, arena_init(&arena, 4096))
	defer arena_destroy(&arena)
	caller := actod.PID(5)
	h := th.create(Tool_Actor_State{execute = nil, arena = &arena}, tool_actor_behaviour)
	defer th.destroy(&h)

	th.send(
		&h,
		Tool_Call_Msg {
			request_id = 2,
			call_id = text("x", &arena),
			tool_name = text("orphan", &arena),
			arguments = text("{}", &arena),
		},
		caller,
	)

	reply := th.expect_sent_to(&h, t, caller, Tool_Result_Msg)
	testing.expect_value(t, reply.is_error, true)
	testing.expect_value(t, resolve(reply.result), "tool has no implementation")
}

@(test)
test_tool_actor_ephemeral_self_terminates_after_reply :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	arena: vmem.Arena
	testing.expect(t, arena_init(&arena, 4096))
	defer arena_destroy(&arena)
	caller := actod.PID(9)
	h := th.create(
		Tool_Actor_State{execute = echo_impl, ephemeral = true, arena = &arena},
		tool_actor_behaviour,
	)
	defer th.destroy(&h)

	th.send(
		&h,
		Tool_Call_Msg {
			request_id = 1,
			call_id = text("c", &arena),
			tool_name = text("echo", &arena),
			arguments = text("{}", &arena),
		},
		caller,
	)

	th.expect_sent_to(&h, t, caller, Tool_Result_Msg)
	th.expect_terminated(&h, t)
}

@(test)
test_tool_actor_persistent_does_not_self_terminate :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	arena: vmem.Arena
	testing.expect(t, arena_init(&arena, 4096))
	defer arena_destroy(&arena)
	caller := actod.PID(3)
	h := th.create(
		Tool_Actor_State{execute = echo_impl, ephemeral = false, arena = &arena},
		tool_actor_behaviour,
	)
	defer th.destroy(&h)

	th.send(
		&h,
		Tool_Call_Msg {
			request_id = 1,
			call_id = text("c", &arena),
			tool_name = text("echo", &arena),
			arguments = text("{}", &arena),
		},
		caller,
	)
	th.expect_sent_to(&h, t, caller, Tool_Result_Msg)

	th.send(
		&h,
		Tool_Call_Msg {
			request_id = 2,
			call_id = text("c2", &arena),
			tool_name = text("echo", &arena),
			arguments = text(`"second"`, &arena),
		},
		caller,
	)
	second := th.expect_sent_to(&h, t, caller, Tool_Result_Msg)
	testing.expect_value(t, resolve(second.result), `"second"`)
}
