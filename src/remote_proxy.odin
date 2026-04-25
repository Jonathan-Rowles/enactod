package enactod_impl

import "../pkgs/actod"
import "core:log"
import vmem "core:mem/virtual"

PROXY_RECV_ARENA_RESERVED :: 64 * 1024 * 1024

Proxy_State :: struct {
	remote_actor: string,
	remote_node:  string,
	recv_arena:   vmem.Arena,
}

proxy_behaviour :: actod.Actor_Behaviour(Proxy_State) {
	init           = proxy_init,
	handle_message = proxy_handle_message,
	terminate      = proxy_terminate,
}

proxy_init :: proc(data: ^Proxy_State) {
	arena_init(&data.recv_arena, PROXY_RECV_ARENA_RESERVED)
}

proxy_terminate :: proc(data: ^Proxy_State) {
	arena_destroy(&data.recv_arena)
}

proxy_handle_message :: proc(data: ^Proxy_State, from: actod.PID, content: any) {
	switch &msg in content {
	case Proxy_Forward:
		if _, is_req := msg.payload.(Agent_Request); is_req {
			arena_reset(&data.recv_arena)
		}
		intern_text_fields(&msg.payload, &data.recv_arena)
		proxy_forward_to_target(msg)
	case Reset_Recv_Arena:
		arena_reset(&data.recv_arena)
	case Agent_Request:
		proxy_reply(data, from, msg)
	case Agent_Response:
		proxy_reply(data, from, msg)
	case Agent_Event:
		proxy_reply(data, from, msg)
	case LLM_Call:
		proxy_reply(data, from, msg)
	case LLM_Result:
		proxy_reply(data, from, msg)
	case LLM_Stream_Chunk:
		proxy_reply(data, from, msg)
	case Tool_Call_Msg:
		proxy_reply(data, from, msg)
	case Tool_Result_Msg:
		proxy_reply(data, from, msg)
	case Session_Create:
		proxy_reply(data, from, msg)
	case Session_Created:
		proxy_reply(data, from, msg)
	case Session_Destroy:
		proxy_reply(data, from, msg)
	case Rate_Limiter_Query:
		proxy_reply(data, from, msg)
	case Rate_Limiter_Status:
		proxy_reply(data, from, msg)
	case Rate_Limit_Event:
		proxy_reply(data, from, msg)
	case Trace_Event:
		proxy_reply(data, from, msg)
	case Compact_Result:
		proxy_reply(data, from, msg)
	case History_Entry_Msg:
		proxy_reply(data, from, msg)
	case Load_History:
		proxy_reply(data, from, msg)
	case Load_History_Result:
		proxy_reply(data, from, msg)
	}
}

@(private = "file")
proxy_forward_to_target :: proc(f: Proxy_Forward) {
	switch &p in f.payload {
	case Agent_Request:
		proxy_send_to_local(f.target, p)
	case Agent_Response:
		proxy_send_to_local(f.target, p)
	case Agent_Event:
		proxy_send_to_local(f.target, p)
	case LLM_Call:
		proxy_send_to_local(f.target, p)
	case LLM_Result:
		proxy_send_to_local(f.target, p)
	case LLM_Stream_Chunk:
		proxy_send_to_local(f.target, p)
	case Tool_Call_Msg:
		proxy_send_to_local(f.target, p)
	case Tool_Result_Msg:
		proxy_send_to_local(f.target, p)
	case Session_Create:
		proxy_send_to_local(f.target, p)
	case Session_Created:
		proxy_send_to_local(f.target, p)
	case Session_Destroy:
		proxy_send_to_local(f.target, p)
	case Rate_Limiter_Query:
		proxy_send_to_local(f.target, p)
	case Rate_Limiter_Status:
		proxy_send_to_local(f.target, p)
	case Rate_Limit_Event:
		proxy_send_to_local(f.target, p)
	case Trace_Event:
		proxy_send_to_local(f.target, p)
	case Compact_Result:
		proxy_send_to_local(f.target, p)
	case History_Entry_Msg:
		proxy_send_to_local(f.target, p)
	case Load_History:
		proxy_send_to_local(f.target, p)
	case Load_History_Result:
		proxy_send_to_local(f.target, p)
	}
}

@(private = "file")
proxy_send_to_local :: proc(target: string, msg: $T) {
	// Not send_by_name_cached: `target` is a slice into the incoming
	// Proxy_Forward's pool page and dies when handle_message returns.
	err := actod.send_message_name(target, msg)
	if err != .OK {
		log.errorf("enact_proxy: send to '%s' failed: %v", target, err)
	}
}

build_proxy_reply_envelope :: proc(
	target_actor: string,
	from_actor: string,
	from_node: string,
	msg: $T,
) -> Remote_Envelope {
	wire := msg
	resolve_text_fields(&wire)
	return Remote_Envelope {
		target_name = target_actor,
		from_actor = from_actor,
		from_node = from_node,
		payload = wire,
	}
}

@(private = "file")
proxy_reply :: proc(data: ^Proxy_State, from: actod.PID, msg: $T) {
	envelope := build_proxy_reply_envelope(
		data.remote_actor,
		actod.get_actor_name(from),
		actod.get_local_node_name(),
		msg,
	)
	err := actod.send_to(INGRESS_ACTOR_NAME, data.remote_node, envelope)
	if err != .OK {
		log.errorf(
			"enact_proxy: reply to '%s@%s' failed: %v",
			data.remote_actor,
			data.remote_node,
			err,
		)
	}
}
