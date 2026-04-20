package main

import enact "../../.."
import ojson "../../../pkgs/ojson"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

// Multi-session agent server. Each connecting client gets its own
// Session_Create. The gateway spawns a fresh agent per session, so two
// clients talking at the same time have independent chat history, worker
// pools, rate limiters, and tool actors. Run multiple CLI clients against
// the same server to see it in action.

get_time_tool :: proc(arguments: string, allocator: mem.Allocator) -> (string, bool) {
	now := time.now()
	y, mon, d := time.date(now)
	h, min, s := time.clock(now)
	return fmt.aprintf(
			"%d-%02d-%02d %02d:%02d:%02d",
			y,
			int(mon),
			d,
			h,
			min,
			s,
			allocator = allocator,
		),
		false
}

Notepad_State :: struct {
	notes: [dynamic]string,
}

notepad_behaviour :: enact.Actor_Behaviour(Notepad_State) {
	init           = notepad_init,
	handle_message = notepad_handle_message,
}

notepad_init :: proc(data: ^Notepad_State) {
	data.notes = make([dynamic]string)
}

notepad_handle_message :: proc(data: ^Notepad_State, from: enact.PID, content: any) {
	switch msg in content {
	case enact.Tool_Call_Msg:
		result := notepad_execute(data, enact.resolve(msg.arguments))
		enact.send(
			from,
			enact.Tool_Result_Msg {
				request_id = msg.request_id,
				call_id = msg.call_id,
				tool_name = msg.tool_name,
				result = enact.text(result),
			},
		)
	}
}

notepad_execute :: proc(data: ^Notepad_State, arguments: string) -> string {
	reader: ojson.Reader
	ojson.init_reader(&reader, 4096)
	defer ojson.destroy_reader(&reader)

	err := ojson.parse(&reader, transmute([]byte)arguments)
	if err != .OK {
		return "invalid JSON arguments"
	}

	action, _ := ojson.read_string(&reader, "action")

	switch action {
	case "add":
		text, _ := ojson.read_string(&reader, "content")
		if len(text) == 0 {
			return "no content provided"
		}
		append(&data.notes, strings.clone(text))
		return fmt.tprintf("Added note: %s (%d total)", text, len(data.notes))
	case "list":
		if len(data.notes) == 0 {
			return "No notes saved."
		}
		sb := strings.builder_make(context.temp_allocator)
		for note, i in data.notes {
			if i > 0 {
				strings.write_byte(&sb, '\n')
			}
			fmt.sbprintf(&sb, "%d. %s", i + 1, note)
		}
		return strings.to_string(sb)
	case "clear":
		count := len(data.notes)
		clear(&data.notes)
		return fmt.tprintf("Cleared %d note(s).", count)
	}

	return fmt.tprintf("unknown action %s", action)
}

notepad_spawn :: proc(name: string, parent: enact.PID) -> (enact.PID, bool) {
	return enact.spawn_child(name, Notepad_State{}, notepad_behaviour)
}

Session_Entry :: struct {
	agent_name: string,
	client:     enact.PID,
}

Gateway_State :: struct {
	sessions: [dynamic]Session_Entry,
	next_id:  int,
	config:   enact.Agent_Config,
}

gateway_behaviour :: enact.Actor_Behaviour(Gateway_State) {
	handle_message = gateway_handle_message,
}

gateway_handle_message :: proc(data: ^Gateway_State, from: enact.PID, content: any) {
	switch msg in content {
	case enact.Session_Create:
		data.next_id += 1
		name := fmt.tprintf("session-%d", data.next_id)
		agent_name := strings.clone(name)

		_, ok := enact.spawn_agent(agent_name, data.config)
		if !ok {
			log.errorf("Gateway failed to spawn agent '%s'", agent_name)
			return
		}

		append(&data.sessions, Session_Entry{agent_name = agent_name, client = from})

		log.infof(
			"Gateway spawned '%s' for %v (active sessions: %d)",
			agent_name,
			from,
			len(data.sessions),
		)
		enact.send(from, enact.Session_Created{agent_name = agent_name})

	case enact.Session_Destroy:
		for entry, i in data.sessions {
			if entry.agent_name == msg.agent_name {
				enact.destroy_agent(entry.agent_name)
				unordered_remove(&data.sessions, i)
				log.infof(
					"Gateway destroyed '%s' (active sessions: %d)",
					msg.agent_name,
					len(data.sessions),
				)
				break
			}
		}
	}
}

server_config: enact.Agent_Config
research_config: enact.Agent_Config

spawn_gateway :: proc(_: string, _: enact.PID) -> (enact.PID, bool) {
	return enact.spawn_child("gateway", Gateway_State{config = server_config}, gateway_behaviour)
}

main :: proc() {
	api_key := os.get_env_alloc("ANTHROPIC_API_KEY", context.allocator)
	if len(api_key) == 0 {
		fmt.println("Set ANTHROPIC_API_KEY environment variable")
		return
	}

	research_config = enact.make_agent_config(
		system_prompt = "You are a research assistant. Answer questions concisely and factually. Keep responses under 200 words.",
		llm = enact.anthropic(api_key, enact.Model.Claude_Haiku_4_5),
		worker_count = 1,
	)

	tools := []enact.Tool {
		enact.function_tool(
			enact.Tool_Def {
				name = "get_time",
				description = "Get the current date and time",
				input_schema = `{"type":"object","properties":{}}`,
			},
			get_time_tool,
		),
		enact.persistent_tool_actor(
			enact.Tool_Def {
				name = "notepad",
				description = "A persistent notepad for saving, listing, and clearing notes",
				input_schema = `{"type":"object","properties":{"action":{"type":"string","enum":["add","list","clear"]},"content":{"type":"string","description":"Text to add (required for add)"}},"required":["action"]}`,
			},
			spawn_proc = notepad_spawn,
		),
		enact.sub_agent_tool(
			enact.Tool_Def {
				name = "research",
				description = "Delegate a research query to a specialist research agent",
				input_schema = `{"type":"object","properties":{"query":{"type":"string","description":"The research question"}},"required":["query"]}`,
			},
			config = &research_config,
		),
	}

	server_config = enact.make_agent_config(
		system_prompt = "You are a helpful assistant with tools. Use get_time for the current time, notepad to save/list/clear notes, and research to delegate research questions.",
		llm = enact.anthropic(
			api_key,
			enact.Model.Claude_Sonnet_4_5,
			max_tokens = 16000,
			thinking_budget = 10000,
		),
		tools = tools,
		worker_count = 1,
		stream = true,
		forward_events = true,
	)

	enact.NODE_INIT(
		"agent-server",
		enact.make_node_config(
			network = enact.make_network_config(port = 9100),
			actor_config = enact.make_actor_config(
				children = enact.make_children(spawn_gateway),
				page_size = mem.Kilobyte,
			),
		),
	)

	fmt.println("Agent server listening on :9100")
	fmt.println("Gateway ready. Each client gets its own session agent.")
	enact.await_signal()
}
