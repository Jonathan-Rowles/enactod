package enactod_impl

import "../pkgs/actod"
import "../pkgs/ojson"
import "core:fmt"
import "core:log"
import vmem "core:mem/virtual"
import "core:os"

Sub_Agent_Bridge_State :: struct {
	sub_agent_name:   string,
	sub_agent_config: ^Agent_Config,
	sub_agent_pid:    actod.PID,
	context_file:     string,
	pending_id:       Text,
	tool_name:        Text,
	request_id:       Request_ID,
	caller:           actod.PID,
	reader:           ojson.Reader,
	arena:            ^vmem.Arena,
}

sub_agent_bridge_behaviour :: actod.Actor_Behaviour(Sub_Agent_Bridge_State) {
	init           = sub_agent_bridge_init,
	handle_message = sub_agent_bridge_handle_message,
}

sub_agent_bridge_init :: proc(data: ^Sub_Agent_Bridge_State) {
	ojson.init_reader(&data.reader, 4096)
}

sub_agent_bridge_handle_message :: proc(
	data: ^Sub_Agent_Bridge_State,
	from: actod.PID,
	content: any,
) {
	switch msg in content {
	case Tool_Call_Msg:
		args_str := resolve(msg.arguments)
		query: string
		err := ojson.parse(&data.reader, transmute([]byte)args_str)
		if err == .OK {
			query, _ = ojson.read_string(&data.reader, "query")
		}
		if len(query) == 0 {
			query = args_str
		}

		data.pending_id = intern(msg.call_id, data.arena)
		data.tool_name = intern(msg.tool_name, data.arena)
		data.request_id = msg.request_id
		data.caller = from

		if data.sub_agent_pid == 0 {
			sup_pid, sok := spawn_sub_agent(
				data.sub_agent_name,
				data.sub_agent_config^,
				data.arena,
			)
			if !sok {
				log.errorf(
					"Sub-agent bridge '%s' failed to spawn sub-agent '%s'",
					actod.get_self_name(),
					data.sub_agent_name,
				)
				actod.send_message(
					from,
					Tool_Result_Msg {
						request_id = msg.request_id,
						call_id = msg.call_id,
						tool_name = msg.tool_name,
						result = text("failed to spawn sub-agent", data.arena),
						is_error = true,
					},
				)
				return
			}
			data.sub_agent_pid = sup_pid
		}

		actual_query := query
		if len(data.context_file) > 0 {
			ctx_data, ctx_ok := os.read_entire_file(data.context_file, context.temp_allocator)
			if ctx_ok == nil && len(ctx_data) > 0 {
				actual_query = fmt.tprintf(
					"<context>\n%s\n</context>\n\n%s",
					string(ctx_data),
					query,
				)
			}
		}

		session := make_session(data.sub_agent_name)
		send_err := session_send_with_parent(&session, actual_query, msg.request_id)
		if send_err != .OK {
			log.errorf("Sub-agent bridge '%s' send failed: %v", actod.get_self_name(), send_err)
			actod.send_message(
				from,
				Tool_Result_Msg {
					request_id = msg.request_id,
					call_id = msg.call_id,
					tool_name = msg.tool_name,
					result = text(fmt.tprintf("sub-agent unavailable: %v", send_err), data.arena),
					is_error = true,
				},
			)
		}

	case Agent_Event:
		actod.send_message(data.caller, msg)

	case Agent_Response:
		result_text: Text
		if msg.is_error {
			result_text = text(
				fmt.tprintf("sub-agent error: %s", resolve(msg.error_msg)),
				data.arena,
			)
		} else {
			result_text = msg.content
		}
		actod.send_message(
			data.caller,
			Tool_Result_Msg {
				request_id = data.request_id,
				call_id = data.pending_id,
				tool_name = data.tool_name,
				result = result_text,
				is_error = msg.is_error,
			},
		)

		if data.sub_agent_pid != 0 {
			destroy_agent(data.sub_agent_name)
			data.sub_agent_pid = 0
		}
	}
}
