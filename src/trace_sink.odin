package enactod_impl

import "../pkgs/actod"
import "core:log"
import "core:mem"

Trace_Sink_Kind :: enum u8 {
	NONE,
	FUNCTION,
	CUSTOM,
	EXTERNAL,
}

Trace_Handler :: proc(ev: Trace_Event, allocator: mem.Allocator)
Trace_Sink_Spawn_Proc :: proc(name: string, parent: actod.PID) -> (actod.PID, bool)

Trace_Sink :: struct {
	name:    string,
	kind:    Trace_Sink_Kind,
	handler: Trace_Handler,
	spawn:   Trace_Sink_Spawn_Proc,
}

function_trace_sink :: proc(name: string, handler: Trace_Handler) -> Trace_Sink {
	return Trace_Sink{name = name, kind = .FUNCTION, handler = handler}
}

custom_trace_sink :: proc(name: string, spawn: Trace_Sink_Spawn_Proc) -> Trace_Sink {
	return Trace_Sink{name = name, kind = .CUSTOM, spawn = spawn}
}

external_trace_sink :: proc(name: string) -> Trace_Sink {
	return Trace_Sink{name = name, kind = .EXTERNAL}
}

Function_Trace_Sink_State :: struct {
	handler: Trace_Handler,
}

function_trace_sink_behaviour :: actod.Actor_Behaviour(Function_Trace_Sink_State) {
	handle_message = function_trace_sink_handle,
}

function_trace_sink_handle :: proc(
	data: ^Function_Trace_Sink_State,
	from: actod.PID,
	content: any,
) {
	if ev, ok := content.(Trace_Event); ok {
		if data.handler != nil {
			data.handler(ev, context.temp_allocator)
		}
	}
}

ensure_trace_sink_spawned :: proc(sink: Trace_Sink, agent_name: string) {
	if sink.kind == .NONE || sink.kind == .EXTERNAL {
		return
	}
	if len(sink.name) == 0 {
		log.warnf("agent:%s trace_sink has no name — ignoring", agent_name)
		return
	}
	if _, exists := actod.get_actor_pid(sink.name); exists {
		return
	}
	parent := actod.get_parent_pid()
	switch sink.kind {
	case .FUNCTION:
		if sink.handler == nil {
			log.warnf(
				"agent:%s function_trace_sink '%s' has nil handler — ignoring",
				agent_name,
				sink.name,
			)
			return
		}
		_, ok := actod.spawn(
			sink.name,
			Function_Trace_Sink_State{handler = sink.handler},
			function_trace_sink_behaviour,
			actod.make_actor_config(),
			parent,
		)
		if !ok {
			log.errorf("agent:%s failed to spawn function trace sink '%s'", agent_name, sink.name)
		}
	case .CUSTOM:
		if sink.spawn == nil {
			log.warnf(
				"agent:%s custom_trace_sink '%s' has nil spawn proc — ignoring",
				agent_name,
				sink.name,
			)
			return
		}
		if _, ok := sink.spawn(sink.name, parent); !ok {
			log.errorf("agent:%s custom trace sink '%s' spawn failed", agent_name, sink.name)
		}
	case .NONE, .EXTERNAL:
	// handled above — unreachable
	}
}
