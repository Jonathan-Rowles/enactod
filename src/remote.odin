package enactod_impl

import "../pkgs/actod"
import "base:intrinsics"
import "base:runtime"
import "core:log"
import vmem "core:mem/virtual"
import curl "vendor:curl"

INGRESS_ACTOR_NAME :: "enact_ingress"

Remote_Payload :: union {
	Agent_Request,
	Agent_Response,
	Agent_Event,
	LLM_Call,
	LLM_Result,
	LLM_Stream_Chunk,
	Tool_Call_Msg,
	Tool_Result_Msg,
	Session_Create,
	Session_Created,
	Session_Destroy,
	Rate_Limiter_Query,
	Rate_Limiter_Status,
	Rate_Limit_Event,
	Trace_Event,
	Compact_Result,
	History_Entry_Msg,
}

Remote_Envelope :: struct {
	target_name: string,
	from_actor:  string,
	from_node:   string,
	payload:     Remote_Payload,
}

Proxy_Forward :: struct {
	target:  string,
	payload: Remote_Payload,
}

Text_Op :: #type proc(t: ^Text, user_data: rawptr)

resolve_text_fields :: proc(msg: ^$T) {
	walk_text_fields(rawptr(msg), type_info_of(T), flatten_text_op, nil)
}

intern_text_fields :: proc(msg: ^$T, arena: ^vmem.Arena) {
	if !arena_is_initialized(arena) do return
	walk_text_fields(rawptr(msg), type_info_of(T), intern_text_op, rawptr(arena))
}

@(private = "file")
walk_text_fields :: proc(
	data: rawptr,
	ti: ^runtime.Type_Info,
	op: Text_Op,
	user_data: rawptr,
) {
	base := runtime.type_info_base(ti)
	text_tid := typeid_of(Text)

	#partial switch v in base.variant {
	case runtime.Type_Info_Struct:
		for i in 0 ..< v.field_count {
			field_ti := v.types[i]
			field_ptr := rawptr(uintptr(data) + v.offsets[i])
			if field_ti.id == text_tid {
				op((^Text)(field_ptr), user_data)
				continue
			}
			walk_text_fields(field_ptr, field_ti, op, user_data)
		}
	case runtime.Type_Info_Union:
		tag_offset := uintptr(v.tag_offset)
		tag_ti := v.tag_type
		tag := union_tag_value(rawptr(uintptr(data) + tag_offset), tag_ti)
		if tag <= 0 || int(tag) > len(v.variants) {
			return
		}
		variant_ti := v.variants[tag - 1]
		if variant_ti.id == text_tid {
			op((^Text)(data), user_data)
		} else {
			walk_text_fields(data, variant_ti, op, user_data)
		}
	}
}

@(private = "file")
union_tag_value :: proc(ptr: rawptr, tag_ti: ^runtime.Type_Info) -> i64 {
	switch tag_ti.size {
	case 1:
		return i64((^u8)(ptr)^)
	case 2:
		return i64((^u16)(ptr)^)
	case 4:
		return i64((^u32)(ptr)^)
	case 8:
		return i64((^u64)(ptr)^)
	}
	return 0
}

@(private = "file")
flatten_text_op :: proc(t: ^Text, _: rawptr) {
	if t.handle.len > 0 {
		t^ = Text{s = resolve(t^)}
	}
}

@(private = "file")
intern_text_op :: proc(t: ^Text, user_data: rawptr) {
	arena := (^vmem.Arena)(user_data)
	if t.handle.len > 0 && t.arena == uintptr(arena) do return
	if t.handle.len == 0 && len(t.s) == 0 do return
	t^ = text(resolve(t^), arena)
}

send :: proc(to: actod.PID, msg: $T) -> actod.Send_Error {
	if actod.is_local_pid(to) {
		return actod.send_message(to, msg)
	}
	when intrinsics.type_is_variant_of(Remote_Payload, T) {
		if info, ok := actod.get_node_info(actod.get_node_id(to)); ok {
			return send_to(actod.get_actor_name(to), info.node_name, msg)
		}
		return actod.send_message(to, msg)
	} else {
		return actod.send_message(to, msg)
	}
}

send_to :: proc(actor_name: string, node_name: string, msg: $T) -> actod.Send_Error {
	if len(node_name) == 0 || node_name == actod.get_local_node_name() {
		return actod.send_message_name(actor_name, msg)
	}
	when intrinsics.type_is_variant_of(Remote_Payload, T) {
		wire := msg
		resolve_text_fields(&wire)
		envelope := Remote_Envelope {
			target_name = actor_name,
			from_actor  = actod.get_self_name(),
			from_node   = actod.get_local_node_name(),
			payload     = wire,
		}
		err := actod.send_to(INGRESS_ACTOR_NAME, node_name, envelope)
		if err != .OK {
			log.warnf("enact.send_to: ingress@%s target='%s' err=%v", node_name, actor_name, err)
		}
		return err
	} else {
		return actod.send_to(actor_name, node_name, msg)
	}
}

send_by_name :: proc(target: string, msg: $T) -> actod.Send_Error {
	at := -1
	for i in 0 ..< len(target) {
		if target[i] == '@' {
			at = i
			break
		}
	}
	if at < 0 {
		return actod.send_message_name(target, msg)
	}
	return send_to(target[:at], target[at + 1:], msg)
}

send_high :: proc(to: actod.PID, msg: $T) -> actod.Send_Error {
	actod.set_send_priority(.HIGH)
	defer actod.reset_send_priority()
	return send(to, msg)
}

send_low :: proc(to: actod.PID, msg: $T) -> actod.Send_Error {
	actod.set_send_priority(.LOW)
	defer actod.reset_send_priority()
	return send(to, msg)
}

send_to_parent :: proc(msg: $T) -> bool {
	parent := actod.get_parent_pid()
	if parent == 0 {
		return false
	}
	return send(parent, msg) == .OK
}

send_to_children :: proc(msg: $T) -> bool {
	children := actod.get_children(actod.get_self_pid())
	all_ok := true
	for child in children {
		if send(child, msg) != .OK {
			all_ok = false
		}
	}
	return all_ok
}

NODE_INIT :: proc(name: string, opts: actod.System_Config) {
	curl.global_init(curl.GLOBAL_DEFAULT)

	mutated := opts
	children := make([dynamic]actod.SPAWN)
	append(&children, actod.SPAWN(ollama_tracker_spawn))
	append(&children, actod.SPAWN(ingress_spawn))
	for c in opts.actor_config.children {
		append(&children, c)
	}
	delete(opts.actor_config.children)
	mutated.actor_config.children = children
	actod.NODE_INIT(name, mutated)
}
