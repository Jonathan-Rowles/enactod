package main

import enact "../../.."
import "core:bufio"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:sys/posix"

SERVER_NODE :: "agent-server"
SERVER_PORT :: 9100
CLI_ACTOR :: "cli"

// CLI client using the blocking_child pattern from the README. NODE_INIT
// spawns the CLI actor on the calling thread and returns when it
// terminates. The stdin reader is a dedicated OS thread child of the
// CLI. On quit/EOF it terminates its parent, which releases NODE_INIT,
// and main then calls SHUTDOWN_NODE explicitly.

User_Input :: struct {
	content: string,
}

Start_Reading :: struct {}

@(init)
register_cli_messages :: proc "contextless" () {
	enact.register_message_type(User_Input)
	enact.register_message_type(Start_Reading)
}

CLI_State :: struct {
	session:    enact.Session,
	agent_name: string,
	ready:      bool,
}

cli_behaviour :: enact.Actor_Behaviour(CLI_State) {
	init           = cli_init,
	handle_message = cli_handle_message,
	terminate      = cli_terminate,
}

cli_init :: proc(data: ^CLI_State) {
	server_addr := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = SERVER_PORT,
	}
	_, rok := enact.register_node(SERVER_NODE, server_addr, .TCP_Custom_Protocol)
	if !rok {
		fmt.println("Failed to register server node.")
		enact.self_terminate(.SHUTDOWN)
		return
	}
	enact.send_to("gateway", SERVER_NODE, enact.Session_Create{})
	fmt.println("Connecting to agent-server...")
}

cli_handle_message :: proc(data: ^CLI_State, from: enact.PID, content: any) {
	switch msg in content {
	case enact.Session_Created:
		data.agent_name = strings.clone(msg.agent_name)
		data.session = enact.make_session(data.agent_name, SERVER_NODE)
		data.ready = true
		fmt.printfln("Session '%s' created.", data.agent_name)
		fmt.print("> ")

	case User_Input:
		if !data.ready {
			fmt.println("Waiting for session...")
			return
		}
		err := enact.session_send(&data.session, msg.content)
		if err != .OK {
			fmt.printfln("Send failed: %v", err)
			fmt.print("> ")
			return
		}

	case enact.Agent_Event:
		switch msg.kind {
		case .LLM_CALL_START:
			fmt.printf("  [thinking...]\n")
		case .LLM_CALL_DONE:
		case .TOOL_CALL_START:
			fmt.printf("  [tool: %s(%s)]\n", enact.resolve(msg.subject), enact.resolve(msg.detail))
		case .TOOL_CALL_DONE:
			fmt.printf("  [result: %s]\n", enact.resolve(msg.detail))
		case .THINKING_DONE:
			fmt.printf("\x1b[2m%s\x1b[0m\n", enact.resolve(msg.detail))
		case .THINKING_DELTA:
			fmt.printf("\x1b[2m%s\x1b[0m", enact.resolve(msg.detail))
		case .TEXT_DELTA:
			fmt.printf("%s", enact.resolve(msg.detail))
		}

	case enact.Agent_Response:
		if msg.is_error {
			fmt.printfln("Error %s", enact.resolve(msg.error_msg))
		} else {
			fmt.println()
		}
		fmt.print("> ")
	}
}

cli_terminate :: proc(data: ^CLI_State) {
	if len(data.agent_name) > 0 {
		enact.send_to("gateway", SERVER_NODE, enact.Session_Destroy{agent_name = data.agent_name})
	}
}

Stdin_Reader_State :: struct {
	cli_name: string,
}

stdin_reader_behaviour :: enact.Actor_Behaviour(Stdin_Reader_State) {
	init           = stdin_reader_init,
	handle_message = stdin_reader_handle_message,
}

stdin_reader_init :: proc(data: ^Stdin_Reader_State) {
	enact.send_self(Start_Reading{})
}

stdin_reader_handle_message :: proc(data: ^Stdin_Reader_State, _: enact.PID, content: any) {
	switch _ in content {
	case Start_Reading:
		scanner: bufio.Scanner
		bufio.scanner_init(&scanner, os.to_reader(os.stdin))

		for bufio.scanner_scan(&scanner) {
			line := strings.trim_space(bufio.scanner_text(&scanner))

			if len(line) == 0 {
				continue
			}
			if line == "quit" || line == "exit" || line == "/quit" {
				break
			}

			err := enact.send_by_name(data.cli_name, User_Input{content = line})
			if err != .OK {
				fmt.printfln("Send failed: %v", err)
				fmt.print("> ")
				continue
			}
		}

		// Exit or EOF. Terminate the CLI actor, which releases NODE_INIT.
		cli_pid, ok := enact.get_actor_pid(data.cli_name)
		if ok {
			enact.terminate_actor(cli_pid, .SHUTDOWN)
		}
		fmt.println("Bye!")
	}
}

spawn_stdin_reader :: proc(_: string, _: enact.PID) -> (enact.PID, bool) {
	return enact.spawn_child(
		"stdin-reader",
		Stdin_Reader_State{cli_name = CLI_ACTOR},
		stdin_reader_behaviour,
		enact.make_actor_config(restart_policy = .TEMPORARY, use_dedicated_os_thread = true),
	)
}

spawn_cli :: proc(_: string, _: enact.PID) -> (enact.PID, bool) {
	return enact.spawn(
		CLI_ACTOR,
		CLI_State{},
		cli_behaviour,
		opts = enact.make_actor_config(children = enact.make_children(spawn_stdin_reader)),
	)
}

main :: proc() {
	fmt.println("enactod CLI.")

	// Unique node name per process so multiple clients don't collide in
	// the mesh (actod dedupes connections by node name).
	node_name := fmt.tprintf("enactod-cli-%d", posix.getpid())

	enact.NODE_INIT(
		node_name,
		enact.make_node_config(
			network = enact.make_network_config(),
			actor_config = enact.make_actor_config(
				page_size = mem.Kilobyte,
				logging = enact.make_log_config(.Error),
			),
			blocking_child = spawn_cli,
		),
	)
	enact.SHUTDOWN_NODE()
}
