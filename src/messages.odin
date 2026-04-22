package enactod_impl

import "../pkgs/actod"
import "core:time"

Agent_Request :: struct {
	request_id:        Request_ID,
	// 0 for top-level. Sub-agent bridges stamp the outer agent's id so
	// traces can reconstruct the call tree across sub-agent boundaries.
	parent_request_id: Request_ID,
	caller:            actod.PID,
	content:           Text,
  // TODO: find better data sructure for this.
	// Fixed-width slots — actod's wire format forbids dynamic arrays
	// in messages. Empty Text values are ignored.
	cache_block_1:     Text,
	cache_block_2:     Text,
	cache_block_3:     Text,
	cache_block_4:     Text,
}

Agent_Response :: struct {
	request_id:                  Request_ID,
	content:                     Text,
	is_error:                    bool,
	error_msg:                   Text,
	input_tokens:                int,
	output_tokens:               int,
	cache_creation_input_tokens: int,
	cache_read_input_tokens:     int,
}

LLM_Call :: struct {
	request_id:    Request_ID,
	caller:        actod.PID,
	payload:       Text,
	url:           Text,
	auth_header:   Text,
	extra_headers: Text, // newline-delimited extra headers
	timeout:       time.Duration,
	stream:        bool,
	format:        API_Format,
}

LLM_Result :: struct {
	request_id:  Request_ID,
	body:        Text,
	status_code: u32,
	error_msg:   Text,
	headers:     Text, // newline-delimited key:value pairs
}

Tool_Call_Msg :: struct {
	request_id: Request_ID,
	call_id:    Text,
	tool_name:  Text,
	arguments:  Text,
}

Tool_Result_Msg :: struct {
	request_id: Request_ID,
	call_id:    Text,
	tool_name:  Text,
	result:     Text,
	is_error:   bool,
}

Event_Kind :: enum u8 {
	LLM_CALL_START,
	LLM_CALL_DONE,
	TOOL_CALL_START,
	TOOL_CALL_DONE,
	THINKING_DONE,
	THINKING_DELTA,
	TEXT_DELTA,
}

Agent_Event :: struct {
	request_id: Request_ID,
	kind:       Event_Kind,
	subject:    Text,
	detail:     Text,
}

Set_Route :: struct {
	llm: LLM_Config,
}

Clear_Route :: struct {}

Reset_Conversation :: struct {
	request_id: Request_ID,
	caller:     actod.PID,
}

Compact_History :: struct {
	request_id:  Request_ID,
	caller:      actod.PID,
	instruction: string,
}

Compact_Result :: struct {
	request_id: Request_ID,
	summary:    Text,
	old_turns:  int,
	is_error:   bool,
	error_msg:  Text,
}

Arena_Status_Query :: struct {
	request_id: Request_ID,
	caller:     actod.PID,
}

Arena_Status :: struct {
	request_id:      Request_ID,
	arena_id:        uintptr,
	bytes_used:      uint,
	bytes_reserved:  uint,
	peak_bytes_used: uint,
	owns_arena:      bool,
	message_count:   int,
}

History_Query :: struct {
	request_id: Request_ID,
	caller:     actod.PID,
	index:      int,
}

History_Entry_Msg :: struct {
	request_id:   Request_ID,
	index:        int,
	found:        bool,
	role:         Chat_Role,
	content:      Text,
	tool_call_id: Text,
}

Session_Create :: struct {}

Session_Created :: struct {
	agent_name: string,
}

Session_Destroy :: struct {
	agent_name: string,
}

Reset_Recv_Arena :: struct {}

Rate_Limiter_Query :: struct {
	request_id: Request_ID,
	caller:     actod.PID,
}

Rate_Limiter_Status :: struct {
	request_id:         Request_ID,
	requests_limit:     u32,
	requests_remaining: u32,
	tokens_limit:       u32,
	tokens_remaining:   u32,
	queue_depth:        u32,
	in_flight:          u32,
}

Rate_Limit_Event_Kind :: enum u8 {
	QUEUED,
	RETRYING,
	PROCESSING,
}

Rate_Limit_Event :: struct {
	request_id:  Request_ID,
	kind:        Rate_Limit_Event_Kind,
	queue_depth: u32,
	retry_count: u32,
	retry_delay: u32, // milliseconds
}

Trace_Event_Kind :: enum u8 {
	REQUEST_START,
	REQUEST_END,
	LLM_CALL_START,
	LLM_CALL_DONE,
	TOOL_CALL_START,
	TOOL_CALL_DONE,
	THINKING_DONE,
	RATE_LIMIT_QUEUED,
	RATE_LIMIT_RETRYING,
	RATE_LIMIT_PROCESSING,
	ERROR,
}

Trace_Event :: struct {
	kind:                  Trace_Event_Kind,
	request_id:            Request_ID,
	parent_request_id:     Request_ID,
	agent_name:            Text,
	turn:                  u16,
	timestamp_ns:          i64,
	duration_ns:           i64,
	call_id:               Text,
	tool_name:             Text,
	model:                 Text,
	provider:              Text,
	detail:                Text,
	input_tokens:          u32,
	output_tokens:         u32,
	cache_creation_tokens: u32,
	cache_read_tokens:     u32,
	status_code:           u32,
	is_error:              bool,
	retry_count:           u32,
	retry_delay_ms:        u32,
	queue_depth:           u32,
}

Trace_Event_Detail_Role :: enum u8 {
	NONE,
	USER_INPUT, // REQUEST_START
	FINAL_RESPONSE, // REQUEST_END (success)
	ASSISTANT_REPLY, // LLM_CALL_DONE
	TOOL_ARGS, // TOOL_CALL_START
	TOOL_RESULT, // TOOL_CALL_DONE (success)
	THINKING, // THINKING_DONE
	ERROR_MESSAGE, // REQUEST_END (is_error), TOOL_CALL_DONE (is_error), ERROR
}

trace_event_detail_role :: proc "contextless" (ev: Trace_Event) -> Trace_Event_Detail_Role {
	#partial switch ev.kind {
	case .REQUEST_START:
		return .USER_INPUT
	case .REQUEST_END:
		return .ERROR_MESSAGE if ev.is_error else .FINAL_RESPONSE
	case .LLM_CALL_DONE:
		return .ASSISTANT_REPLY
	case .TOOL_CALL_START:
		return .TOOL_ARGS
	case .TOOL_CALL_DONE:
		return .ERROR_MESSAGE if ev.is_error else .TOOL_RESULT
	case .THINKING_DONE:
		return .THINKING
	case .ERROR:
		return .ERROR_MESSAGE
	}
	return .NONE
}

@(init)
init_enactod_messages :: proc "contextless" () {
	actod.register_message_type(Agent_Request)
	actod.register_message_type(Agent_Response)
	actod.register_message_type(Agent_Event)
	actod.register_message_type(LLM_Call)
	actod.register_message_type(LLM_Result)
	actod.register_message_type(LLM_Stream_Chunk)
	actod.register_message_type(Tool_Call_Msg)
	actod.register_message_type(Tool_Result_Msg)
	actod.register_message_type(Set_Route)
	actod.register_message_type(Clear_Route)
	actod.register_message_type(Reset_Conversation)
	actod.register_message_type(Compact_History)
	actod.register_message_type(Compact_Result)
	actod.register_message_type(Arena_Status_Query)
	actod.register_message_type(Arena_Status)
	actod.register_message_type(History_Query)
	actod.register_message_type(History_Entry_Msg)
	actod.register_message_type(Ollama_Model_Seen)
	actod.register_message_type(Ollama_Unload_All)
	actod.register_message_type(Session_Create)
	actod.register_message_type(Session_Created)
	actod.register_message_type(Session_Destroy)
	actod.register_message_type(Reset_Recv_Arena)
	actod.register_message_type(Rate_Limiter_Query)
	actod.register_message_type(Rate_Limiter_Status)
	actod.register_message_type(Rate_Limit_Event)
	actod.register_message_type(Trace_Event)
	actod.register_message_type(Remote_Envelope)
	actod.register_message_type(Proxy_Forward)
}
