package enactod_impl

import "core"

Text :: core.Text
String_Handle :: core.String_Handle
Request_ID :: core.Request_ID
API_Format :: core.API_Format
Chat_Role :: core.Chat_Role
Cache_Mode :: core.Cache_Mode
Stream_Chunk_Kind :: core.Stream_Chunk_Kind
Tool_Lifecycle :: core.Tool_Lifecycle
Tool_Def :: core.Tool_Def
Tool_Call_Entry :: core.Tool_Call_Entry
Chat_Entry :: core.Chat_Entry
Parsed_Tool_Call :: core.Parsed_Tool_Call
Usage_Info :: core.Usage_Info
Parsed_Response :: core.Parsed_Response
LLM_Stream_Chunk :: core.LLM_Stream_Chunk
Provider_Config :: core.Provider_Config
Capabilities :: core.Capabilities
DEFAULT_CAPABILITIES :: core.DEFAULT_CAPABILITIES
Model_Info :: core.Model_Info
destroy_model_info_list :: core.destroy_model_info_list
SSE_Event :: core.SSE_Event
SSE_Parser :: core.SSE_Parser
NDJSON_Parser :: core.NDJSON_Parser

DEFAULT_ARENA_RESERVED :: core.DEFAULT_ARENA_RESERVED

arena_init :: core.arena_init
arena_reset :: core.arena_reset
arena_destroy :: core.arena_destroy
arena_is_initialized :: core.arena_is_initialized
arena_bytes_used :: core.arena_bytes_used
arena_bytes_reserved :: core.arena_bytes_reserved
text :: core.text
intern :: core.intern
resolve :: core.resolve
text_has_handle :: core.text_has_handle
persist_text :: core.persist_text
free_text :: core.free_text

role_string :: core.role_string
extract_error_msg :: core.extract_error_msg
make_provider :: core.make_provider

append_system_entry :: core.append_system_entry
append_user_entry :: core.append_user_entry
append_user_entry_cached :: core.append_user_entry_cached
append_assistant_entry :: core.append_assistant_entry
append_tool_result_entry :: core.append_tool_result_entry
free_chat_entries :: core.free_chat_entries

init_sse_parser :: core.init_sse_parser
destroy_sse_parser :: core.destroy_sse_parser
reset_sse_parser :: core.reset_sse_parser
sse_feed :: core.sse_feed

init_ndjson_parser :: core.init_ndjson_parser
destroy_ndjson_parser :: core.destroy_ndjson_parser
reset_ndjson_parser :: core.reset_ndjson_parser
ndjson_feed :: core.ndjson_feed
