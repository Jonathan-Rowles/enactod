package core

Request_ID :: distinct u64

API_Format :: enum u8 {
	OPENAI_COMPAT,
	ANTHROPIC,
	OLLAMA,
	GEMINI,
}

Chat_Role :: enum {
	SYSTEM,
	USER,
	ASSISTANT,
	TOOL,
}

Cache_Mode :: enum u8 {
	NONE,
	EPHEMERAL,
}

Stream_Chunk_Kind :: enum u8 {
	THINKING_DELTA,
	TEXT_DELTA,
	TOOL_START,
	TOOL_INPUT_DELTA,
	DONE,
	ERROR,
}

Tool_Lifecycle :: enum u8 {
	INLINE,
	EPHEMERAL,
	PERSISTENT,
	SUB_AGENT,
}

Tool_Def :: struct {
	name:         string,
	description:  string,
	input_schema: string,
}

Tool_Call_Entry :: struct {
	id:        Text,
	name:      Text,
	arguments: Text,
}

Chat_Entry :: struct {
	role:         Chat_Role,
	content:      Text,
	tool_call_id: Text,
	tool_calls:   []Tool_Call_Entry,
	thinking:     Text,
	signature:    Text,
	cache_blocks: []Text,
	origin_model: Text,
}

Parsed_Tool_Call :: struct {
	id:        Text,
	name:      Text,
	arguments: Text,
}

Usage_Info :: struct {
	input_tokens:                int,
	output_tokens:               int,
	cache_creation_input_tokens: int,
	cache_read_input_tokens:     int,
}

Parsed_Response :: struct {
	content:            Text,
	tool_calls:         []Parsed_Tool_Call,
	finish_reason:      Text,
	error_msg:          Text,
	thinking:           Text,
	thinking_signature: Text,
	usage:              Usage_Info,
}

LLM_Stream_Chunk :: struct {
	request_id: Request_ID,
	kind:       Stream_Chunk_Kind,
	name:       Text,
	content:    Text,
}

Provider_Config :: struct {
	name:          string,
	base_url:      string,
	api_key:       string,
	format:        API_Format,
	extra_headers: string,
}

Capabilities :: struct {
	supports_temperature: bool,
	supports_top_p:       bool,
	supports_thinking:    bool,
	min_thinking_budget:  int,
	max_thinking_budget:  int,
	supports_cache:       bool,
	supports_tools:       bool,
	supports_streaming:   bool,
	context_window:       int,
	max_output_tokens:    int,
}

DEFAULT_CAPABILITIES :: Capabilities {
	supports_temperature = true,
	supports_top_p       = true,
	supports_tools       = true,
	supports_streaming   = true,
}

Model_Info :: struct {
	id:             string,
	display_name:   string,
	provider_name:  string,
	context_window: int,
	capabilities:   Capabilities,
	created_unix:   i64,
}

destroy_model_info_list :: proc(list: []Model_Info, allocator := context.allocator) {
	for m in list {
		delete(m.id, allocator)
		delete(m.display_name, allocator)
		delete(m.provider_name, allocator)
	}
	delete(list, allocator)
}
