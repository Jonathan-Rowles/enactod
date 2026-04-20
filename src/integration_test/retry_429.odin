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
STUB_PORT :: 19201

@(private = "file")
done_sema: sync.Sema

@(private = "file")
stub_request_count: int

@(private = "file")
stub_count_lock: sync.Mutex

@(private = "file")
stub_get_request_count :: proc() -> int {
	sync.mutex_lock(&stub_count_lock)
	defer sync.mutex_unlock(&stub_count_lock)
	return stub_request_count
}

@(private = "file")
Runner_State :: struct {
	t:            ^testing.T,
	session:      enact.Session,
	got_response: bool,
}

@(private = "file")
runner_behaviour :: enact.Actor_Behaviour(Runner_State) {
	init           = runner_init,
	handle_message = runner_handle_message,
}

@(private = "file")
runner_init :: proc(data: ^Runner_State) {
	data.session = enact.make_session("demo")
	enact.session_send(&data.session, "hello")
}

@(private = "file")
runner_handle_message :: proc(data: ^Runner_State, _: enact.PID, content: any) {
	if msg, ok := content.(enact.Agent_Response); ok {
		fmt.printf(
			"  response: is_error=%v content=%q\n",
			msg.is_error,
			enact.resolve(msg.content),
		)
		check(
			data.t,
			!msg.is_error,
			"agent eventually succeeded after 429",
			enact.resolve(msg.error_msg),
		)
		check(
			data.t,
			enact.resolve(msg.content) == "retry worked",
			"final response is the 2nd-try content",
			fmt.tprintf("got %q", enact.resolve(msg.content)),
		)
		check(
			data.t,
			stub_get_request_count() >= 2,
			"stub received at least 2 requests (original + retry)",
			fmt.tprintf("got %d", stub_get_request_count()),
		)
		data.got_response = true
		sync.sema_post(&done_sema)
	}
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

test_429_retry :: proc(t: ^testing.T) {
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
			model = "claude-stub",
			enable_rate_limiting = true,
			timeout = 20 * time.Second,
		},
		worker_count = 1,
	)

	enact.NODE_INIT(
		"e2e-429",
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

	sync.mutex_lock(&stub_count_lock)
	stub_request_count += 1
	n := stub_request_count
	sync.mutex_unlock(&stub_count_lock)

	response: string
	if n == 1 {
		body := `{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}`
		response = fmt.tprintf(
			"HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nRetry-After: 1\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
			len(body),
			body,
		)
	} else {
		body := `{"id":"msg_ok","type":"message","role":"assistant","content":[{"type":"text","text":"retry worked"}],"stop_reason":"end_turn","usage":{"input_tokens":5,"output_tokens":3}}`
		response = fmt.tprintf(
			"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
			len(body),
			body,
		)
	}
	_, send_err := net.send_tcp(client, transmute([]byte)response)
	if send_err != nil {
		log.errorf("stub: send failed: %v", send_err)
	}
}
