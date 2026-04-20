package enactod_impl

import actod "../pkgs/actod"
import "../pkgs/ojson"
import "core:fmt"
import "core:log"
import vmem "core:mem/virtual"
import "core:os"

Pool_Pending_Call :: struct {
	call_id:    Text,
	tool_name:  Text,
	query:      Text,
	request_id: Request_ID,
	caller:     actod.PID,
}

Pool_Agent_Slot :: struct {
	pid:     actod.PID,
	name:    string,
	busy:    bool,
	pending: Pool_Pending_Call,
}

Sub_Agent_Pool_State :: struct {
	base_name:        string,
	sub_agent_config: ^Agent_Config,
	pool_size:        int,
	context_file:     string,
	slots:            [dynamic]Pool_Agent_Slot,
	overflow:         [dynamic]Pool_Pending_Call,
	reader:           ojson.Reader,
	arena:            ^vmem.Arena,
}

sub_agent_pool_behaviour :: actod.Actor_Behaviour(Sub_Agent_Pool_State) {
	init           = sub_agent_pool_init,
	handle_message = sub_agent_pool_handle_message,
}

sub_agent_pool_init :: proc(data: ^Sub_Agent_Pool_State) {
	ojson.init_reader(&data.reader, 4096)
}

sub_agent_pool_handle_message :: proc(data: ^Sub_Agent_Pool_State, from: actod.PID, content: any) {
	switch msg in content {
	case Tool_Call_Msg:
		handle_pool_tool_call(data, from, msg)
	case Agent_Event:
		for &slot in data.slots {
			if slot.pid == from && slot.busy {
				actod.send_message(slot.pending.caller, msg)
				break
			}
		}
	case Agent_Response:
		handle_pool_agent_response(data, from, msg)
	}
}

handle_pool_tool_call :: proc(data: ^Sub_Agent_Pool_State, from: actod.PID, msg: Tool_Call_Msg) {
	args_str := resolve(msg.arguments)
	query: string
	err := ojson.parse(&data.reader, transmute([]byte)args_str)
	if err == .OK {
		query, _ = ojson.read_string(&data.reader, "query")
	}
	if len(query) == 0 {
		query = args_str
	}

	pending := Pool_Pending_Call {
		call_id    = intern(msg.call_id, data.arena),
		tool_name  = intern(msg.tool_name, data.arena),
		query      = text(query, data.arena),
		request_id = msg.request_id,
		caller     = from,
	}

	slot_idx := find_free_slot(data)
	if slot_idx >= 0 {
		dispatch_to_slot(data, slot_idx, pending)
	} else {
		append(&data.overflow, pending)
	}
}

handle_pool_agent_response :: proc(
	data: ^Sub_Agent_Pool_State,
	from: actod.PID,
	msg: Agent_Response,
) {
	slot_idx := -1
	for &slot, i in data.slots {
		if !slot.busy || slot.pid == 0 {
			continue
		}
		agent_pid, ok := actod.get_actor_pid(fmt.tprintf("agent:%s", slot.name))
		if ok && agent_pid == from {
			slot_idx = i
			break
		}
	}

	if slot_idx < 0 {
		log.warnf("pool '%s': got response from unknown sender", actod.get_self_name())
		return
	}

	slot := &data.slots[slot_idx]
	pending := slot.pending

	result_text: Text
	is_error := msg.is_error
	if msg.is_error {
		result_text = text(fmt.tprintf("sub-agent error: %s", resolve(msg.error_msg)), data.arena)
	} else {
		result_text = msg.content
	}

	actod.send_message(
		pending.caller,
		Tool_Result_Msg {
			request_id = pending.request_id,
			call_id = pending.call_id,
			tool_name = pending.tool_name,
			result = result_text,
			is_error = is_error,
		},
	)

	slot.pending = {}
	slot.busy = false

	if len(data.overflow) > 0 {
		next := data.overflow[0]
		ordered_remove(&data.overflow, 0)

		free_idx := find_free_slot(data)
		if free_idx >= 0 {
			dispatch_to_slot(data, free_idx, next)
		} else {
			append(&data.overflow, next)
		}
	}
}

find_free_slot :: proc(data: ^Sub_Agent_Pool_State) -> int {
	for len(data.slots) < data.pool_size {
		append(&data.slots, Pool_Agent_Slot{})
	}
	for &slot, i in data.slots {
		if !slot.busy {
			return i
		}
	}
	return -1
}

dispatch_to_slot :: proc(data: ^Sub_Agent_Pool_State, slot_idx: int, pending: Pool_Pending_Call) {
	slot := &data.slots[slot_idx]

	if slot.pid == 0 {
		name := fmt.aprintf("%s-%d", data.base_name, slot_idx)
		slot.name = name
		pid, ok := spawn_sub_agent(name, data.sub_agent_config^, data.arena)
		if !ok {
			log.errorf("pool '%s': failed to spawn sub-agent '%s'", actod.get_self_name(), name)
			actod.send_message(
				pending.caller,
				Tool_Result_Msg {
					request_id = pending.request_id,
					call_id = pending.call_id,
					tool_name = pending.tool_name,
					result = text("failed to spawn sub-agent", data.arena),
					is_error = true,
				},
			)
			return
		}
		slot.pid = pid
	}

	slot.busy = true
	slot.pending = pending

	query_s := resolve(pending.query)
	actual_query := query_s
	if len(data.context_file) > 0 {
		ctx_data, ctx_ok := os.read_entire_file(data.context_file, context.temp_allocator)
		if ctx_ok == nil && len(ctx_data) > 0 {
			actual_query = fmt.tprintf(
				"<context>\n%s\n</context>\n\n%s",
				string(ctx_data),
				query_s,
			)
		}
	}

	session := make_session(slot.name)
	send_err := session_send_with_parent(&session, actual_query, pending.request_id)
	if send_err != .OK {
		log.errorf(
			"pool '%s': send to '%s' failed: %v",
			actod.get_self_name(),
			slot.name,
			send_err,
		)
		actod.send_message(
			pending.caller,
			Tool_Result_Msg {
				request_id = pending.request_id,
				call_id = pending.call_id,
				tool_name = pending.tool_name,
				result = text(fmt.tprintf("sub-agent unavailable: %v", send_err), data.arena),
				is_error = true,
			},
		)
		slot.pending = {}
		slot.busy = false
	}
}
