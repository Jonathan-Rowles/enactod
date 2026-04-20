package main

import enact "../"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:sync"
import "core:time"

done: sync.Sema

get_time_tool :: proc(arguments: string, allocator: mem.Allocator) -> (string, bool) {
	y, mon, d := time.date(time.now())
	h, m, s := time.clock(time.now())
	return fmt.aprintf(
			"%d-%02d-%02d %02d:%02d:%02d",
			y,
			int(mon),
			d,
			h,
			m,
			s,
			allocator = allocator,
		),
		false
}

Client :: struct {
	session: enact.Session,
}

client_behaviour := enact.Actor_Behaviour(Client) {
	init = proc(d: ^Client) {
		enact.session_send(&d.session, "What time is it?")
	},
	handle_message = proc(d: ^Client, from: enact.PID, msg: any) {
		if r, ok := msg.(enact.Agent_Response); ok {
			fmt.println(enact.resolve(r.content))
			sync.sema_post(&done)
		}
	},
}

agent_config: enact.Agent_Config

spawn_demo_agent :: proc(_: string, _: enact.PID) -> (enact.PID, bool) {
	sess, ok := enact.spawn_agent("demo", agent_config)
	return sess.pid, ok
}

spawn_client :: proc(_: string, _: enact.PID) -> (enact.PID, bool) {
	return enact.spawn_child(
		"client",
		Client{session = enact.make_session("demo")},
		client_behaviour,
	)
}

main :: proc() {
	api_key := os.get_env_alloc("ANTHROPIC_API_KEY", context.allocator)
	if len(api_key) == 0 {
		fmt.println("Set ANTHROPIC_API_KEY")
		return
	}

	tools := []enact.Tool {
		enact.function_tool(
			enact.Tool_Def {
				name = "get_time",
				description = "Get the current date and time",
				input_schema = `{"type":"object","properties":{}}`,
			},
			get_time_tool,
		),
	}

	agent_config = enact.make_agent_config(
		llm = enact.anthropic(api_key, enact.Model.Claude_Sonnet_4_5),
		tools = tools,
		trace_sink = enact.dev_trace_sink("dev", {md_dir = "traces"}),
	)

	enact.NODE_INIT(
		"hello-enactod",
		enact.make_node_config(
			actor_config = enact.make_actor_config(
				children = enact.make_children(spawn_demo_agent, spawn_client),
			),
		),
	)
	defer enact.SHUTDOWN_NODE()

	sync.sema_wait(&done)

	fmt.print("\n\n       check traces/demo-1.md\n\n")
}
