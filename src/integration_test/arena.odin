package integration_test

import enact "../.."
import "core:fmt"
import "core:log"
import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
STUB_PORT :: 19100

@(private = "file")
done_sema: sync.Sema

@(private = "file")
stub_response_body: string = `{"id":"chatcmpl-stub","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"STUB"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}`

@(private = "file")
Step :: enum {
	START,
	QUERY_A_EMPTY,
	QUERY_B_EMPTY,
	CHECK_ARENAS_DISTINCT,
	FIRST_TURN_SEND,
	FIRST_TURN_RESPONSE,
	CHECK_ARENA_RESET_AND_HISTORY,
	CHECK_HISTORY_ENTRY_USER,
	CHECK_HISTORY_ENTRY_ASSISTANT,
	SECOND_TURN_SEND,
	SECOND_TURN_RESPONSE,
	CHECK_STASHED_SURVIVES,
	RESET_CONVERSATION,
	CHECK_RESET,
	COMPACT_TURN_1,
	COMPACT_TURN_2,
	COMPACT,
	CHECK_COMPACTED,
	DONE,
}

@(private = "file")
Runner_State :: struct {
	t:                 ^testing.T,
	step:              Step,
	session_a:         enact.Session,
	session_b:         enact.Session,
	pending_id:        u64,
	arena_a:           uintptr,
	arena_b:           uintptr,
	first_response:    enact.Text,
	expected_response: string,
	first_user_msg:    string,
}

@(private = "file")
runner_behaviour :: enact.Actor_Behaviour(Runner_State) {
	init           = runner_init,
	handle_message = runner_handle_message,
}

@(private = "file")
runner_init :: proc(data: ^Runner_State) {
	data.session_a = enact.make_session("agent-a")
	data.session_b = enact.make_session("agent-b")
	data.expected_response = "STUB"
	data.first_user_msg = "first question"
	advance(data)
}

@(private = "file")
runner_handle_message :: proc(data: ^Runner_State, _: enact.PID, content: any) {
	switch msg in content {
	case enact.Arena_Status:
		handle_arena_status(data, msg)
	case enact.Agent_Response:
		handle_agent_response(data, msg)
	case enact.Compact_Result:
		handle_compact_result(data, msg)
	case enact.History_Entry_Msg:
		handle_history_entry(data, msg)
	}
}

@(private = "file")
advance :: proc(data: ^Runner_State) {
	data.step = Step(int(data.step) + 1)
	fmt.printf("\n--- step: %v ---\n", data.step)
	switch data.step {
	case .START:
	case .QUERY_A_EMPTY:
		query_arena(data, "agent-a")
	case .QUERY_B_EMPTY:
		query_arena(data, "agent-b")
	case .CHECK_ARENAS_DISTINCT:
		check(
			data.t,
			data.arena_a != 0 && data.arena_b != 0,
			"both arenas non-nil",
			fmt.tprintf("a=%x b=%x", data.arena_a, data.arena_b),
		)
		check(
			data.t,
			data.arena_a != data.arena_b,
			"two top-level agents have distinct arenas",
			fmt.tprintf("a=%x b=%x", data.arena_a, data.arena_b),
		)
		advance(data)
	case .FIRST_TURN_SEND:
		enact.session_send(&data.session_a, data.first_user_msg)
	case .FIRST_TURN_RESPONSE:
	case .CHECK_ARENA_RESET_AND_HISTORY:
		query_arena(data, "agent-a")
	case .CHECK_HISTORY_ENTRY_USER:
		query_history(data, "agent-a", 0)
	case .CHECK_HISTORY_ENTRY_ASSISTANT:
		query_history(data, "agent-a", 1)
	case .SECOND_TURN_SEND:
		enact.session_send(&data.session_a, "second question")
	case .SECOND_TURN_RESPONSE:
	case .CHECK_STASHED_SURVIVES:
		resolved := enact.resolve(data.first_response)
		check(
			data.t,
			resolved == data.expected_response,
			"first response Text still resolves to expected bytes after a reset cycle",
			fmt.tprintf("got %q expected %q", resolved, data.expected_response),
		)
		advance(data)
	case .RESET_CONVERSATION:
		enact.reset_conversation(data.session_a.agent_name)
		time.sleep(100 * time.Millisecond)
		advance(data)
	case .CHECK_RESET:
		query_arena(data, "agent-a")
	case .COMPACT_TURN_1:
		enact.session_send(&data.session_a, "compact-turn-1")
	case .COMPACT_TURN_2:
		enact.session_send(&data.session_a, "compact-turn-2")
	case .COMPACT:
		enact.compact_history(data.session_a.agent_name)
	case .CHECK_COMPACTED:
		query_arena(data, "agent-a")
	case .DONE:
		sync.sema_post(&done_sema)
	}
}

@(private = "file")
query_arena :: proc(data: ^Runner_State, agent_name: string) {
	data.pending_id += 1
	enact.send_by_name(
		enact.agent_actor_name(agent_name),
		enact.Arena_Status_Query {
			request_id = enact.Request_ID(data.pending_id),
			caller = enact.get_self_pid(),
		},
	)
}

@(private = "file")
query_history :: proc(data: ^Runner_State, agent_name: string, index: int) {
	data.pending_id += 1
	enact.send_by_name(
		enact.agent_actor_name(agent_name),
		enact.History_Query {
			request_id = enact.Request_ID(data.pending_id),
			caller = enact.get_self_pid(),
			index = index,
		},
	)
}

@(private = "file")
handle_arena_status :: proc(data: ^Runner_State, msg: enact.Arena_Status) {
	fmt.printf(
		"  arena: id=%x used=%d peak=%d reserved=%d owns=%v msgs=%d\n",
		msg.arena_id,
		msg.bytes_used,
		msg.peak_bytes_used,
		msg.bytes_reserved,
		msg.owns_arena,
		msg.message_count,
	)
	switch data.step {
	case .QUERY_A_EMPTY:
		check(
			data.t,
			msg.bytes_used == 0,
			"agent-a starts empty",
			fmt.tprintf("got %d", msg.bytes_used),
		)
		check(
			data.t,
			msg.peak_bytes_used == 0,
			"agent-a peak starts at 0",
			fmt.tprintf("got %d", msg.peak_bytes_used),
		)
		check(data.t, msg.owns_arena, "agent-a owns its arena")
		check(
			data.t,
			msg.message_count == 0,
			"agent-a has no messages",
			fmt.tprintf("got %d", msg.message_count),
		)
		check(
			data.t,
			msg.bytes_reserved > 0,
			"arena reserved > 0",
			fmt.tprintf("got %d", msg.bytes_reserved),
		)
		data.arena_a = msg.arena_id
		advance(data)
	case .QUERY_B_EMPTY:
		check(
			data.t,
			msg.bytes_used == 0,
			"agent-b starts empty",
			fmt.tprintf("got %d", msg.bytes_used),
		)
		check(data.t, msg.owns_arena, "agent-b owns its arena")
		data.arena_b = msg.arena_id
		advance(data)
	case .CHECK_ARENA_RESET_AND_HISTORY:
		check(
			data.t,
			msg.bytes_used == 0,
			"arena reset to 0 after Agent_Response",
			fmt.tprintf("got %d", msg.bytes_used),
		)
		check(
			data.t,
			msg.peak_bytes_used > 0,
			"arena actually FILLED during turn (peak > 0)",
			fmt.tprintf("got %d", msg.peak_bytes_used),
		)
		check(
			data.t,
			msg.message_count >= 2,
			"history retains system+user+assistant entries",
			fmt.tprintf("got %d", msg.message_count),
		)
		advance(data)
	case .CHECK_RESET:
		check(
			data.t,
			msg.message_count == 0,
			"Reset_Conversation cleared history",
			fmt.tprintf("got %d", msg.message_count),
		)
		check(
			data.t,
			msg.bytes_used == 0,
			"arena still 0 after Reset_Conversation",
			fmt.tprintf("got %d", msg.bytes_used),
		)
		advance(data)
	case .CHECK_COMPACTED:
		check(
			data.t,
			msg.message_count == 1,
			"compact collapsed history to single summary entry",
			fmt.tprintf("got %d", msg.message_count),
		)
		check(
			data.t,
			msg.bytes_used == 0,
			"arena reset after compact",
			fmt.tprintf("got %d", msg.bytes_used),
		)
		advance(data)
	case .START,
	     .CHECK_ARENAS_DISTINCT,
	     .FIRST_TURN_SEND,
	     .FIRST_TURN_RESPONSE,
	     .CHECK_HISTORY_ENTRY_USER,
	     .CHECK_HISTORY_ENTRY_ASSISTANT,
	     .SECOND_TURN_SEND,
	     .SECOND_TURN_RESPONSE,
	     .CHECK_STASHED_SURVIVES,
	     .RESET_CONVERSATION,
	     .COMPACT_TURN_1,
	     .COMPACT_TURN_2,
	     .COMPACT,
	     .DONE:
	}
}

@(private = "file")
handle_history_entry :: proc(data: ^Runner_State, msg: enact.History_Entry_Msg) {
	content := enact.resolve(msg.content)
	fmt.printf(
		"  history[%d]: found=%v role=%v content=%q\n",
		msg.index,
		msg.found,
		msg.role,
		content,
	)
	switch data.step {
	case .CHECK_HISTORY_ENTRY_USER:
		check(data.t, msg.found, "history[0] exists")
		check(data.t, msg.role == .USER, "history[0] is USER", fmt.tprintf("got %v", msg.role))
		check(
			data.t,
			content == data.first_user_msg,
			"history[0] content survives arena reset with correct bytes",
			fmt.tprintf("got %q expected %q", content, data.first_user_msg),
		)
		advance(data)
	case .CHECK_HISTORY_ENTRY_ASSISTANT:
		check(data.t, msg.found, "history[1] exists")
		check(
			data.t,
			msg.role == .ASSISTANT,
			"history[1] is ASSISTANT",
			fmt.tprintf("got %v", msg.role),
		)
		check(
			data.t,
			content == data.expected_response,
			"history[1] content survives arena reset with correct bytes",
			fmt.tprintf("got %q expected %q", content, data.expected_response),
		)
		advance(data)
	case .START,
	     .QUERY_A_EMPTY,
	     .QUERY_B_EMPTY,
	     .CHECK_ARENAS_DISTINCT,
	     .FIRST_TURN_SEND,
	     .FIRST_TURN_RESPONSE,
	     .CHECK_ARENA_RESET_AND_HISTORY,
	     .SECOND_TURN_SEND,
	     .SECOND_TURN_RESPONSE,
	     .CHECK_STASHED_SURVIVES,
	     .RESET_CONVERSATION,
	     .CHECK_RESET,
	     .COMPACT_TURN_1,
	     .COMPACT_TURN_2,
	     .COMPACT,
	     .CHECK_COMPACTED,
	     .DONE:
	}
}

@(private = "file")
handle_agent_response :: proc(data: ^Runner_State, msg: enact.Agent_Response) {
	content := enact.resolve(msg.content)
	fmt.printf("  response: is_error=%v content=%q\n", msg.is_error, content)
	check(data.t, !msg.is_error, "agent response succeeded", enact.resolve(msg.error_msg))
	switch data.step {
	case .FIRST_TURN_SEND:
		data.first_response = enact.persist_text(msg.content, context.allocator)
		data.step = .FIRST_TURN_RESPONSE
		advance(data)
	case .SECOND_TURN_SEND:
		data.step = .SECOND_TURN_RESPONSE
		advance(data)
	case .COMPACT_TURN_1:
		advance(data)
	case .COMPACT_TURN_2:
		advance(data)
	case .START,
	     .QUERY_A_EMPTY,
	     .QUERY_B_EMPTY,
	     .CHECK_ARENAS_DISTINCT,
	     .FIRST_TURN_RESPONSE,
	     .CHECK_ARENA_RESET_AND_HISTORY,
	     .CHECK_HISTORY_ENTRY_USER,
	     .CHECK_HISTORY_ENTRY_ASSISTANT,
	     .SECOND_TURN_RESPONSE,
	     .CHECK_STASHED_SURVIVES,
	     .RESET_CONVERSATION,
	     .CHECK_RESET,
	     .COMPACT,
	     .CHECK_COMPACTED,
	     .DONE:
	}
}

@(private = "file")
handle_compact_result :: proc(data: ^Runner_State, msg: enact.Compact_Result) {
	fmt.printf(
		"  compact: old_turns=%d is_error=%v summary=%q\n",
		msg.old_turns,
		msg.is_error,
		enact.resolve(msg.summary),
	)
	check(data.t, !msg.is_error, "compact succeeded", enact.resolve(msg.error_msg))
	check(
		data.t,
		msg.old_turns >= 2,
		"compact collapsed >=2 turns",
		fmt.tprintf("old_turns=%d", msg.old_turns),
	)
	if data.step == .COMPACT {
		advance(data)
	}
}

@(private = "file")
t_ref: ^testing.T

@(private = "file")
spawn_runner :: proc(_: string, _: enact.PID) -> (enact.PID, bool) {
	return enact.spawn_child("runner", Runner_State{t = t_ref}, runner_behaviour)
}

@(private = "file")
agent_a_cfg: enact.Agent_Config
@(private = "file")
agent_b_cfg: enact.Agent_Config

@(private = "file")
spawn_agent_a :: proc(_: string, _: enact.PID) -> (enact.PID, bool) {
	sess, ok := enact.spawn_agent("agent-a", agent_a_cfg)
	return sess.pid, ok
}

@(private = "file")
spawn_agent_b :: proc(_: string, _: enact.PID) -> (enact.PID, bool) {
	sess, ok := enact.spawn_agent("agent-b", agent_b_cfg)
	return sess.pid, ok
}

test_arena :: proc(t: ^testing.T) {
	t_ref = t
	context.logger = log.create_console_logger(.Warning)
	stub_server_start()
	time.sleep(200 * time.Millisecond)

	provider := enact.make_provider(
		"stub",
		fmt.tprintf("http://127.0.0.1:%d", STUB_PORT),
		"",
		.OPENAI_COMPAT,
	)
	agent_a_cfg = enact.make_agent_config(
		llm = enact.LLM_Config {
			provider = provider,
			model = "stub-model",
			enable_rate_limiting = false,
		},
		worker_count = 1,
	)
	agent_b_cfg = enact.make_agent_config(
		llm = enact.LLM_Config {
			provider = provider,
			model = "stub-model",
			enable_rate_limiting = false,
		},
		worker_count = 1,
	)

	enact.NODE_INIT(
		"arena-test",
		enact.make_node_config(
			actor_config = enact.make_actor_config(
				children = enact.make_children(spawn_agent_a, spawn_agent_b, spawn_runner),
			),
		),
	)

	sync.sema_wait(&done_sema)
	enact.SHUTDOWN_NODE()
}

@(private = "file")
stub_server_start :: proc() -> ^thread.Thread {
	th := thread.create(stub_server_loop)
	thread.start(th)
	return th
}

@(private = "file")
stub_server_loop :: proc(th: ^thread.Thread) {
	endpoint := net.Endpoint {
		address = net.IP4_Loopback,
		port    = STUB_PORT,
	}
	listener, err := net.listen_tcp(endpoint)
	if err != nil {
		log.errorf("stub: listen on %v failed: %v", endpoint, err)
		return
	}
	log.infof("stub: listening on http://127.0.0.1:%d", STUB_PORT)

	for {
		client, _, accept_err := net.accept_tcp(listener)
		if accept_err != nil {
			log.errorf("stub: accept failed: %v", accept_err)
			continue
		}
		handle_connection(client)
	}
}

@(private = "file")
handle_connection :: proc(client: net.TCP_Socket) {
	defer net.close(client)
	buf: [16 * 1024]byte
	total := 0
	header_end := -1
	content_length := 0
	for total < len(buf) {
		n, err := net.recv_tcp(client, buf[total:])
		if err != nil || n == 0 {
			return
		}
		total += n
		if header_end < 0 {
			header_end = find_header_end(buf[:total])
			if header_end >= 0 {
				content_length = parse_content_length(buf[:header_end])
			}
		}
		if header_end >= 0 && total >= header_end + content_length {
			break
		}
	}

	body := stub_response_body
	response := fmt.tprintf(
		"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		len(body),
		body,
	)
	_, send_err := net.send_tcp(client, transmute([]byte)response)
	if send_err != nil {
		log.errorf("stub: send failed: %v", send_err)
	}
}
