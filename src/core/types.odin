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
