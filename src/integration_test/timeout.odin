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
STUB_PORT :: 19202

@(private = "file")
done_sema: sync.Sema

@(private = "file")
Runner_State :: struct {
	t:       ^testing.T,
	session: enact.Session,
	start:   time.Time,
}

@(private = "file")
runner_behaviour :: enact.Actor_Behaviour(Runner_State) {
	init           = runner_init,
	handle_message = runner_handle_message,
}

@(private = "file")
runner_init :: proc(data: ^Runner_State) {
	data.session = enact.make_session("demo")
	data.start = time.now()
	enact.session_send(&data.session, "hi — you will never respond")
}

@(private = "file")
runner_handle_message :: proc(data: ^Runner_State, _: enact.PID, content: any) {
	if msg, ok := content.(enact.Agent_Response); ok {
		elapsed := time.diff(data.start, time.now())
		err_msg := enact.resolve(msg.error_msg)
		fmt.printf(
			"  response: is_error=%v elapsed=%dms err=%q\n",
			msg.is_error,
			time.duration_milliseconds(elapsed),
			err_msg,
		)
		check(data.t, msg.is_error, "response is an error")
		check(
			data.t,
			strings.contains(err_msg, "timed out") || strings.contains(err_msg, "timeout"),
			"error mentions timeout",
			fmt.tprintf("got %q", err_msg),
		)
		check(
			data.t,
			elapsed < 10 * time.Second,
			"timeout fired within bounded time",
			fmt.tprintf("elapsed %dms", time.duration_milliseconds(elapsed)),
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

test_timeout :: proc(t: ^testing.T) {
	t_ref = t
	context.logger = log.create_console_logger(.Warning)
	fmt.println("starting stub (will hang)...")
	stub_server_start()
	time.sleep(200 * time.Millisecond)

	provider := enact.make_provider(
		"stub-hang",
		fmt.tprintf("http://127.0.0.1:%d", STUB_PORT),
		"dummy",
		.OPENAI_COMPAT,
	)
	demo_cfg = enact.make_agent_config(
		llm = enact.LLM_Config {
			provider = provider,
			model = "any",
			enable_rate_limiting = false,
			timeout = 2 * time.Second,
		},
		worker_count = 1,
	)

	enact.NODE_INIT(
		"e2e-timeout",
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
	t := thread.create(stub_server_loop)
	thread.start(t)
	return t
}

@(private = "file")
stub_server_loop :: proc(t: ^thread.Thread) {
	endpoint := net.Endpoint {
		address = net.IP4_Loopback,
		port    = STUB_PORT,
	}
	listener, err := net.listen_tcp(endpoint)
	if err != nil {
		log.errorf("stub: listen on %v failed: %v", endpoint, err)
		return
	}
	log.infof("stub: listening on http://127.0.0.1:%d (will hang without responding)", STUB_PORT)

	for {
		client, _, accept_err := net.accept_tcp(listener)
		if accept_err != nil {
			log.errorf("stub: accept failed: %v", accept_err)
			continue
		}
		buf: [4096]byte
		_, _ = net.recv_tcp(client, buf[:])
		time.sleep(60 * time.Second)
		net.close(client)
	}
}
