package core

append_system_entry :: proc(
	entries: ^[dynamic]Chat_Entry,
	content: string,
	allocator := context.allocator,
) {
	append(
		entries,
		Chat_Entry{role = .SYSTEM, content = persist_text(Text{s = content}, allocator)},
	)
}

append_user_entry :: proc(
	entries: ^[dynamic]Chat_Entry,
	content: string,
	allocator := context.allocator,
) {
	append(entries, Chat_Entry{role = .USER, content = persist_text(Text{s = content}, allocator)})
}

append_user_entry_cached :: proc(
	entries: ^[dynamic]Chat_Entry,
	blocks: []Text,
	allocator := context.allocator,
) {
	owned_blocks := make([]Text, len(blocks), allocator)
	for b, i in blocks {
		owned_blocks[i] = persist_text(b, allocator)
	}
	append(entries, Chat_Entry{role = .USER, cache_blocks = owned_blocks})
}

append_assistant_entry :: proc(
	entries: ^[dynamic]Chat_Entry,
	content: Text,
	tool_calls: []Parsed_Tool_Call = nil,
	thinking: Text = {},
	signature: Text = {},
	allocator := context.allocator,
) {
	tc: []Tool_Call_Entry
	if len(tool_calls) > 0 {
		tc = make([]Tool_Call_Entry, len(tool_calls), allocator)
		for call, i in tool_calls {
			tc[i] = Tool_Call_Entry {
				id        = persist_text(call.id, allocator),
				name      = persist_text(call.name, allocator),
				arguments = persist_text(call.arguments, allocator),
			}
		}
	}

	append(
		entries,
		Chat_Entry {
			role = .ASSISTANT,
			content = persist_text(content, allocator),
			tool_calls = tc,
			thinking = persist_text(thinking, allocator),
			signature = persist_text(signature, allocator),
		},
	)
}

append_tool_result_entry :: proc(
	entries: ^[dynamic]Chat_Entry,
	call_id: Text,
	content: Text,
	allocator := context.allocator,
) {
	append(
		entries,
		Chat_Entry {
			role = .TOOL,
			content = persist_text(content, allocator),
			tool_call_id = persist_text(call_id, allocator),
		},
	)
}

free_chat_entries :: proc(entries: ^[dynamic]Chat_Entry) {
	for &entry in entries {
		free_text(entry.content)
		free_text(entry.tool_call_id)
		free_text(entry.thinking)
		free_text(entry.signature)
		for tc in entry.tool_calls {
			free_text(tc.id)
			free_text(tc.name)
			free_text(tc.arguments)
		}
		if len(entry.tool_calls) > 0 {
			delete(entry.tool_calls)
		}
		for b in entry.cache_blocks {
			free_text(b)
		}
		if len(entry.cache_blocks) > 0 {
			delete(entry.cache_blocks)
		}
	}
	clear(entries)
}
