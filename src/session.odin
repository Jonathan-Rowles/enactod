package enactod_impl

import "../pkgs/actod"
import "core:fmt"
import "core:log"
import vmem "core:mem/virtual"
import "core:sync"
import "core:time"

Session :: struct {
	agent_name:  string,
	node_name:   string,
	next_id:     Request_ID,
	agent_arena: ^vmem.Arena,
	pid:         actod.PID,
}

make_session :: proc(agent_name: string, node_name: string = "") -> Session {
	s := Session {
		agent_name  = agent_name,
		node_name   = node_name,
		next_id     = 1,
		agent_arena = get_agent_arena_ptr(agent_name),
	}
	if len(node_name) == 0 {
		if pid, ok := actod.get_actor_pid(agent_actor_name(agent_name)); ok {
			s.pid = pid
		}
	}
	return s
}

session_destroy :: proc(s: ^Session) {
	if len(s.node_name) == 0 do return
	session_signal_proxy_reset(s)
}

@(private = "file")
session_signal_proxy_reset :: proc(s: ^Session) {
	self_name := actod.get_self_name()
	if len(self_name) == 0 do return
	proxy_name := fmt.tprintf(
		"enact_proxy:%s:%s@%s",
		self_name,
		agent_actor_name(s.agent_name),
		s.node_name,
	)
	if _, ok := actod.get_actor_pid(proxy_name); !ok do return
	send_to(proxy_name, "", Reset_Recv_Arena{})
}

agent_pid :: proc(s: Session) -> actod.PID {
	return s.pid
}

@(private)
reset_agent_arena :: proc(s: ^Session) {
	if s.agent_arena == nil do s.agent_arena = get_agent_arena_ptr(s.agent_name)
	arena_reset(s.agent_arena)
}

session_request :: proc(s: ^Session, content: string) -> Agent_Request {
	if s.agent_arena == nil do s.agent_arena = get_agent_arena_ptr(s.agent_name)
	if s.pid == 0 && len(s.node_name) == 0 {
		if pid, ok := actod.get_actor_pid(agent_actor_name(s.agent_name)); ok {
			s.pid = pid
		}
	}
	id := s.next_id
	s.next_id += 1
	return Agent_Request {
		request_id = id,
		caller     = actod.get_self_pid(),
		content    = session_outbound_text(s, content),
	}
}

@(private)
session_outbound_text :: proc(s: ^Session, content: string) -> Text {
	if s.agent_arena != nil do return text(content, s.agent_arena)
	if len(content) == 0 do return Text{}
	return Text{s = content}
}

session_send :: proc(s: ^Session, content: string) -> actod.Send_Error {
	reset_agent_arena(s)
	if len(s.node_name) > 0 do session_signal_proxy_reset(s)
	req := session_request(s, content)
	return send_to(agent_actor_name(s.agent_name), s.node_name, req)
}

session_send_with_parent :: proc(
	s: ^Session,
	content: string,
	parent_request_id: Request_ID,
) -> actod.Send_Error {
	req := session_request(s, content)
	req.parent_request_id = parent_request_id
	return send_to(agent_actor_name(s.agent_name), s.node_name, req)
}

session_send_cached :: proc(s: ^Session, blocks: ..string) -> actod.Send_Error {
	reset_agent_arena(s)
	if len(s.node_name) > 0 do session_signal_proxy_reset(s)
	if s.agent_arena == nil do s.agent_arena = get_agent_arena_ptr(s.agent_name)
	id := s.next_id
	s.next_id += 1
	req := Agent_Request {
		request_id = id,
		caller     = actod.get_self_pid(),
	}
	n := min(len(blocks), MAX_CACHE_BLOCKS)
	if len(blocks) > MAX_CACHE_BLOCKS {
		log.warnf(
			"session_send_cached: %d blocks provided, only first %d used (MAX_CACHE_BLOCKS)",
			len(blocks),
			MAX_CACHE_BLOCKS,
		)
	}
	if n > 0 {req.cache_block_1 = session_outbound_text(s, blocks[0])}
	if n > 1 {req.cache_block_2 = session_outbound_text(s, blocks[1])}
	if n > 2 {req.cache_block_3 = session_outbound_text(s, blocks[2])}
	if n > 3 {req.cache_block_4 = session_outbound_text(s, blocks[3])}
	return send_to(agent_actor_name(s.agent_name), s.node_name, req)
}

session_target_name :: proc(s: ^Session) -> string {
	if len(s.node_name) > 0 {
		return fmt.tprintf("agent:%s@%s", s.agent_name, s.node_name)
	}
	return fmt.tprintf("agent:%s", s.agent_name)
}

agent_actor_name :: proc(agent_name: string) -> string {
	return fmt.tprintf("agent:%s", agent_name)
}

agent_set_route :: proc(
	agent_name: string,
	llm: LLM_Config,
	node_name: string = "",
) -> actod.Send_Error {
	return send_to(agent_actor_name(agent_name), node_name, Set_Route{llm = llm})
}

agent_clear_route :: proc(agent_name: string, node_name: string = "") -> actod.Send_Error {
	return send_to(agent_actor_name(agent_name), node_name, Clear_Route{})
}

reset_conversation :: proc(
	agent_name: string,
	node_name: string = "",
	request_id: Request_ID = 0,
) -> actod.Send_Error {
	msg := Reset_Conversation {
		request_id = request_id,
		caller     = actod.get_self_pid(),
	}
	return send_to(agent_actor_name(agent_name), node_name, msg)
}

compact_history :: proc(
	agent_name: string,
	instruction: string = "",
	node_name: string = "",
	request_id: Request_ID = 0,
) -> actod.Send_Error {
	msg := Compact_History {
		request_id  = request_id,
		caller      = actod.get_self_pid(),
		instruction = instruction,
	}
	return send_to(agent_actor_name(agent_name), node_name, msg)
}

unload_ollama_models :: proc(node_name: string = "") -> actod.Send_Error {
	return send_to(OLLAMA_TRACKER_ACTOR_NAME, node_name, Ollama_Unload_All{})
}

Sync_Result :: struct {
	content:   Text,
	is_error:  bool,
	error_msg: Text,
	timed_out: bool,
}

Sync_Reply_State :: struct {
	target: Request_ID,
	sema:   ^sync.Sema,
	out:    ^Sync_Result,
}

@(private = "file")
sync_reply_behaviour :: actod.Actor_Behaviour(Sync_Reply_State) {
	handle_message = sync_reply_handle_message,
}

@(private = "file")
sync_reply_handle_message :: proc(data: ^Sync_Reply_State, _: actod.PID, content: any) {
	switch msg in content {
	case Agent_Response:
		if msg.request_id != data.target {
			return
		}
		data.out.is_error = msg.is_error
		data.out.error_msg = persist_text(msg.error_msg)
		data.out.content = persist_text(msg.content)
		sync.sema_post(data.sema)
	}
}

session_request_sync :: proc(
	s: ^Session,
	content: string,
	timeout: time.Duration = 60 * time.Second,
) -> Sync_Result {
	when ODIN_DEBUG {
		handle, _ := actod.unpack_pid(actod.get_self_pid())
		assert(
			handle.idx == 0 && handle.gen == 0,
			"session_request_sync must not be called from inside an actor handler — it blocks the worker thread waiting for the reply. Use session_send from actors.",
		)
	}

	reset_agent_arena(s)
	if len(s.node_name) > 0 do session_signal_proxy_reset(s)

	result: Sync_Result
	sema: sync.Sema
	id := s.next_id
	s.next_id += 1

	reply_name := fmt.tprintf("sync-reply:%d", id)
	state := Sync_Reply_State {
		target = id,
		sema   = &sema,
		out    = &result,
	}
	reply_pid, ok := actod.spawn(reply_name, state, sync_reply_behaviour)
	if !ok {
		result.is_error = true
		result.error_msg = text("failed to spawn sync reply actor")
		return result
	}
	defer actod.terminate_actor(reply_pid, .SHUTDOWN)

	req := Agent_Request {
		request_id = id,
		caller     = reply_pid,
		content    = session_outbound_text(s, content),
	}
	if err := send_to(agent_actor_name(s.agent_name), s.node_name, req); err != .OK {
		result.is_error = true
		result.error_msg = text(fmt.tprintf("send failed: %v", err))
		return result
	}

	acquired := sync.sema_wait_with_timeout(&sema, timeout)
	if !acquired {
		result.timed_out = true
		result.is_error = true
		result.error_msg = text("timed out waiting for response")
	}
	return result
}
