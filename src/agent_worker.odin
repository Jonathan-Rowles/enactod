package enactod_impl

import "../pkgs/actod"
import "../pkgs/ojson"
import "core:fmt"
import "core:log"
import vmem "core:mem/virtual"
import "core:strings"
import "providers/anthropic"
import "providers/gemini"
import "providers/ollama"
import "providers/openai"

LLM_Worker_State :: struct {
	client:             HTTP_Client,
	sse_parser:         SSE_Parser,
	ndjson_parser:      NDJSON_Parser,
	decoder:            Stream_Decoder,
	reader:             ojson.Reader,
	ol_chunks:          [dynamic]LLM_Stream_Chunk,
	arena:              ^vmem.Arena,
	current_request_id: Request_ID,
	current_caller:     actod.PID,
}

llm_worker_behaviour :: actod.Actor_Behaviour(LLM_Worker_State) {
	init           = llm_worker_init,
	handle_message = llm_worker_handle_message,
	terminate      = llm_worker_terminate,
}

llm_worker_init :: proc(data: ^LLM_Worker_State) {
	if http_client_init(&data.client) != .OK {
		log.error("Failed to init HTTP client")
		return
	}
	init_sse_parser(&data.sse_parser)
	init_ndjson_parser(&data.ndjson_parser)
	ojson.init_reader(&data.reader)
	data.ol_chunks = make([dynamic]LLM_Stream_Chunk)
}

llm_worker_handle_message :: proc(data: ^LLM_Worker_State, from: actod.PID, content: any) {
	switch msg in content {
	case LLM_Call:
		perform_llm_call(data, msg)
	}
}

llm_worker_terminate :: proc(data: ^LLM_Worker_State) {
	http_client_destroy(&data.client)
}

@(private = "file")
send_stream_chunk :: proc(caller: actod.PID, arena: ^vmem.Arena, msg: LLM_Stream_Chunk) {
	interned := msg
	interned.name = intern(msg.name, arena)
	interned.content = intern(msg.content, arena)
	err := actod.send_message(caller, interned)
	if err != .OK && err != .SYSTEM_SHUTTING_DOWN {
		log.errorf("Send Failed %v", err)
	}
}

@(private = "file")
worker_on_chunk :: proc(chunk: []byte, userdata: rawptr) {
	data := cast(^LLM_Worker_State)userdata
	switch &d in data.decoder {
	case anthropic.Stream:
		for event in sse_feed(&data.sse_parser, chunk) {
			if msg, ok := anthropic.process_sse(
				&d,
				&data.reader,
				event,
				data.current_request_id,
				data.arena,
			); ok {
				send_stream_chunk(data.current_caller, data.arena, msg)
			}
		}
	case openai.Stream:
		for event in sse_feed(&data.sse_parser, chunk) {
			if msg, ok := openai.process_sse(
				&d,
				&data.reader,
				event,
				data.current_request_id,
				data.arena,
			); ok {
				send_stream_chunk(data.current_caller, data.arena, msg)
			}
		}
	case ollama.Stream:
		for line in ndjson_feed(&data.ndjson_parser, chunk) {
			clear(&data.ol_chunks)
			ollama.process_ndjson(
				&d,
				&data.reader,
				line,
				data.current_request_id,
				&data.ol_chunks,
				data.arena,
			)
			for msg in data.ol_chunks {
				send_stream_chunk(data.current_caller, data.arena, msg)
			}
		}
	case gemini.Stream:
		for event in sse_feed(&data.sse_parser, chunk) {
			clear(&data.ol_chunks)
			gemini.process_sse(
				&d,
				&data.reader,
				event,
				data.current_request_id,
				&data.ol_chunks,
				data.arena,
			)
			for msg in data.ol_chunks {
				send_stream_chunk(data.current_caller, data.arena, msg)
			}
		}
	}
}

perform_llm_call :: proc(data: ^LLM_Worker_State, call: LLM_Call) {
	data.current_request_id = call.request_id
	data.current_caller = call.caller

	headers := make([dynamic]string, 0, 8, context.temp_allocator)
	auth := resolve(call.auth_header)
	if len(auth) > 0 {
		append(&headers, auth)
	}
	extra := resolve(call.extra_headers)
	if len(extra) > 0 {
		remaining := extra
		for len(remaining) > 0 {
			nl := strings.index_byte(remaining, '\n')
			line: string
			if nl < 0 {
				line = remaining
				remaining = ""
			} else {
				line = remaining[:nl]
				remaining = remaining[nl + 1:]
			}
			if len(line) > 0 {
				append(&headers, line)
			}
		}
	}

	if call.stream {
		reset_sse_parser(&data.sse_parser)
		reset_ndjson_parser(&data.ndjson_parser)
		reset_decoder(&data.decoder, call.format)
	}

	payload_str := resolve(call.payload)
	req := HTTP_Request {
		url      = resolve(call.url),
		body     = transmute([]byte)payload_str,
		headers  = headers[:],
		timeout  = call.timeout,
		stream   = call.stream,
		on_chunk = worker_on_chunk if call.stream else nil,
		userdata = data if call.stream else nil,
	}

	resp, http_err, err_msg := http_post(&data.client, req)

	if http_err != .OK {
		log.errorf("http error: %s", err_msg)
		result := LLM_Result {
			request_id = call.request_id,
			error_msg  = text(err_msg, data.arena),
		}
		send_err := actod.send_message(call.caller, result)
		if send_err != .OK {
			log.errorf("failed to send http error result: %v", send_err)
		}
		return
	}

	headers_text := text(string(resp.headers), data.arena)

	if call.stream {
		if resp.status < 200 || resp.status >= 300 {
			body := string(resp.body)
			log.errorf("HTTP %d: %s", resp.status, body)
			result := LLM_Result {
				request_id  = call.request_id,
				status_code = resp.status,
				error_msg   = text(fmt.tprintf("HTTP %d: %s", resp.status, body), data.arena),
				headers     = headers_text,
			}
			err := actod.send_message(call.caller, result)
			if err != .OK {
				log.errorf("failed to send error result: %v", err)
			}
		} else {
			result := LLM_Result {
				request_id  = call.request_id,
				status_code = resp.status,
				headers     = headers_text,
			}
			err := actod.send_message(call.caller, result)
			if err != .OK {
				log.errorf("failed to send stream result: %v", err)
			}
		}
	} else {
		result := LLM_Result {
			request_id  = call.request_id,
			body        = text(string(resp.body), data.arena),
			status_code = resp.status,
			headers     = headers_text,
		}
		err := actod.send_message(call.caller, result)
		if err != .OK {
			log.errorf("failed to send result: %v", err)
		}
	}
}
