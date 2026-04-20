package integration_test

import enact "../.."
import "core:fmt"
import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
STUB_PORT :: 19203

@(private = "file")
done_sema: sync.Sema

@(private = "file")
Runner_State :: struct {
	t:              ^testing.T,
	session:        enact.Session,
	text_deltas:    [dynamic]string,
	llm_call_start: bool,
	llm_call_done:  bool,
	final_content:  string,
}

@(private = "file")
runner_behaviour :: enact.Actor_Behaviour(Runner_State) {
	init           = runner_init,
	handle_message = runner_handle_message,
}

@(private = "file")
runner_init :: proc(data: ^Runner_State) {
	data.session = enact.make_session("demo")
	enact.session_send(&data.session, "tell me a joke")
}

@(private = "file")
runner_handle_message :: proc(data: ^Runner_State, _: enact.PID, content: any) {
	switch msg in content {
	case enact.Agent_Event:
		#partial switch msg.kind {
		case .LLM_CALL_START:
			data.llm_call_start = true
		case .TEXT_DELTA:
			append(&data.text_deltas, strings.clone(enact.resolve(msg.detail)))
		case .LLM_CALL_DONE:
			data.llm_call_done = true
		}
	case enact.Agent_Response:
		data.final_content = strings.clone(enact.resolve(msg.content))
		fmt.printf("  response: is_error=%v content=%q\n", msg.is_error, data.final_content)

		check(data.t, !msg.is_error, "streaming response succeeded", enact.resolve(msg.error_msg))
		check(data.t, data.llm_call_start, "received LLM_CALL_START event")
		check(data.t, data.llm_call_done, "received LLM_CALL_DONE event")
		check(
			data.t,
			len(data.text_deltas) == 3,
			"received 3 TEXT_DELTA events",
			fmt.tprintf("got %d", len(data.text_deltas)),
		)
		if len(data.text_deltas) == 3 {
			check(
				data.t,
				data.text_deltas[0] == "Hello",
				"delta 0",
				fmt.tprintf("got %q", data.text_deltas[0]),
			)
			check(
				data.t,
				data.text_deltas[1] == ", streaming ",
				"delta 1",
				fmt.tprintf("got %q", data.text_deltas[1]),
			)
			check(
				data.t,
				data.text_deltas[2] == "world!",
				"delta 2",
				fmt.tprintf("got %q", data.text_deltas[2]),
			)
		}
		check(
			data.t,
			data.final_content == "Hello, streaming world!",
			"final content assembled from deltas",
			fmt.tprintf("got %q", data.final_content),
		)

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

test_streaming :: proc(t: ^testing.T) {
	t_ref = t
	context.logger = log.create_console_logger(.Warning)
	fmt.println("starting SSE stub...")
	stub_server_start()
	time.sleep(200 * time.Millisecond)

	provider := enact.make_provider(
		"stub-sse",
		fmt.tprintf("http://127.0.0.1:%d", STUB_PORT),
		"dummy",
		.ANTHROPIC,
	)
	demo_cfg = enact.make_agent_config(
		llm = enact.LLM_Config {
			provider = provider,
			model = "claude-stub",
			enable_rate_limiting = false,
			timeout = 10 * time.Second,
		},
		worker_count = 1,
		stream = true,
		forward_events = true,
	)

	enact.NODE_INIT(
		"e2e-stream",
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
events :: []string {
	`event: message_start
data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"stub","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":0}}}

`,
	`event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

`,
	`event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

`,
	`event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", streaming "}}

`,
	`event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world!"}}

`,
	`event: content_block_stop
data: {"type":"content_block_stop","index":0}

`,
	`event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":5}}

`,
	`event: message_stop
data: {"type":"message_stop"}

`,
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
	log.infof("stub: SSE listening on http://127.0.0.1:%d", STUB_PORT)

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
			break
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

	headers := "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
	_, _ = net.send_tcp(client, transmute([]byte)headers)

	for ev in events {
		_, send_err := net.send_tcp(client, transmute([]byte)ev)
		if send_err != nil {
			return
		}
		time.sleep(5 * time.Millisecond)
	}
}
