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
STUB_PORT :: 19200

@(private = "file")
done_sema: sync.Sema

@(private = "file")
stub_response_body: string = `{"id":"msg_01","type":"message","role":"assistant","content":[{"type":"text","text":"Hello from Anthropic stub"}],"stop_reason":"end_turn","usage":{"input_tokens":42,"output_tokens":11}}`

@(private = "file")
stub_rate_limit_headers: string = "anthropic-ratelimit-requests-limit: 1000\r\nanthropic-ratelimit-requests-remaining: 999\r\nanthropic-ratelimit-tokens-limit: 40000\r\nanthropic-ratelimit-tokens-remaining: 39958"

@(private = "file")
Step :: enum {
	START,
	SEND,
	RESPONSE,
	QUERY_LIMITS,
	LIMITS,
	DONE,
}

@(private = "file")
Runner_State :: struct {
	t:           ^testing.T,
	session:     enact.Session,
	step:        Step,
	pending_id:  u64,
	got_content: string,
}

@(private = "file")
runner_behaviour :: enact.Actor_Behaviour(Runner_State) {
	init           = runner_init,
	handle_message = runner_handle_message,
}

@(private = "file")
runner_init :: proc(data: ^Runner_State) {
	data.session = enact.make_session("demo")
	advance(data)
}

@(private = "file")
runner_handle_message :: proc(data: ^Runner_State, _: enact.PID, content: any) {
	switch msg in content {
	case enact.Agent_Response:
		handle_agent_response(data, msg)
	case enact.Rate_Limiter_Status:
		handle_rate_limiter_status(data, msg)
	}
}

@(private = "file")
advance :: proc(data: ^Runner_State) {
	data.step = Step(int(data.step) + 1)
	fmt.printf("\n--- step: %v ---\n", data.step)
	switch data.step {
	case .START:
	case .SEND:
		enact.session_send(&data.session, "hi")
	case .RESPONSE:
		advance(data)
	case .QUERY_LIMITS:
		data.pending_id += 1
		enact.send_by_name(
			"ratelim:demo",
			enact.Rate_Limiter_Query {
				request_id = enact.Request_ID(data.pending_id),
				caller = enact.get_self_pid(),
			},
		)
	case .LIMITS:
		advance(data)
	case .DONE:
		sync.sema_post(&done_sema)
	}
}

@(private = "file")
handle_agent_response :: proc(data: ^Runner_State, msg: enact.Agent_Response) {
	content := enact.resolve(msg.content)
	fmt.printf("  response: is_error=%v content=%q\n", msg.is_error, content)
	check(data.t, !msg.is_error, "agent response succeeded", enact.resolve(msg.error_msg))
	check(
		data.t,
		content == "Hello from Anthropic stub",
		"content matches stub body",
		fmt.tprintf("got %q", content),
	)
	check(
		data.t,
		msg.input_tokens == 42,
		"input_tokens parsed",
		fmt.tprintf("got %d", msg.input_tokens),
	)
	check(
		data.t,
		msg.output_tokens == 11,
		"output_tokens parsed",
		fmt.tprintf("got %d", msg.output_tokens),
	)
	data.got_content = content
	advance(data)
}

@(private = "file")
handle_rate_limiter_status :: proc(data: ^Runner_State, msg: enact.Rate_Limiter_Status) {
	fmt.printf(
		"  rate_limits: req=%d/%d tok=%d/%d queue=%d in_flight=%d\n",
		msg.requests_remaining,
		msg.requests_limit,
		msg.tokens_remaining,
		msg.tokens_limit,
		msg.queue_depth,
		msg.in_flight,
	)
	check(
		data.t,
		msg.requests_limit == 1000,
		"parsed requests-limit header",
		fmt.tprintf("got %d", msg.requests_limit),
	)
	check(
		data.t,
		msg.requests_remaining == 999,
		"parsed requests-remaining header",
		fmt.tprintf("got %d", msg.requests_remaining),
	)
	check(
		data.t,
		msg.tokens_limit == 40000,
		"parsed tokens-limit header",
		fmt.tprintf("got %d", msg.tokens_limit),
	)
	check(
		data.t,
		msg.tokens_remaining == 39958,
		"parsed tokens-remaining header",
		fmt.tprintf("got %d", msg.tokens_remaining),
	)
	advance(data)
}

@(private = "file")
t_ref: ^testing.T

@(private = "file")
spawn_runner :: proc(_: string, _: enact.PID) -> (enact.PID, bool) {
	return enact.spawn_child("runner", Runner_State{t = t_ref}, runner_behaviour)
}

@(private = "file")
demo_cfg: enact.Agent_Config

@(private = "file")
spawn_demo :: proc(_: string, _: enact.PID) -> (enact.PID, bool) {
	sess, ok := enact.spawn_agent("demo", demo_cfg)
	return sess.pid, ok
}

test_anthropic :: proc(t: ^testing.T) {
	t_ref = t
	context.logger = log.create_console_logger(.Warning)
	fmt.println("starting stub...")
	stub_server_start()
	time.sleep(200 * time.Millisecond)

	provider := enact.make_provider(
		"stub-anthropic",
		fmt.tprintf("http://127.0.0.1:%d", STUB_PORT),
		"dummy-key",
		.ANTHROPIC,
	)
	demo_cfg = enact.make_agent_config(
		llm = enact.LLM_Config {
			provider = provider,
			model = "claude-sonnet-4-5-stub",
			enable_rate_limiting = true,
		},
		worker_count = 1,
	)

	enact.NODE_INIT(
		"e2e-anthropic",
		enact.make_node_config(
			actor_config = enact.make_actor_config(
				children = enact.make_children(spawn_demo, spawn_runner),
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
		"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n%s\r\nConnection: close\r\n\r\n%s",
		len(body),
		stub_rate_limit_headers,
		body,
	)
	_, send_err := net.send_tcp(client, transmute([]byte)response)
	if send_err != nil {
		log.errorf("stub: send failed: %v", send_err)
	}
}
