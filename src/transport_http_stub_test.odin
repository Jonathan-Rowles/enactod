#+build !freestanding
#+private
package enactod_impl

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

HTTP_Captured_Request :: struct {
	url:     string,
	body:    []byte,
	headers: []string,
	stream:  bool,
	timeout: time.Duration,
}

HTTP_Stub_Response :: struct {
	status:    u32,
	body:      []byte, // used when chunks is empty
	headers:   string, // newline-delimited "key:value" pairs
	chunks:    [][]byte, // non-empty → streaming; each entry delivered via on_chunk
	error:     HTTP_Error, // set to non-OK to simulate transport failure
	error_msg: string,
}

HTTP_Stub_State :: struct {
	responses:      [dynamic]HTTP_Stub_Response,
	captured:       [dynamic]HTTP_Captured_Request,
	last_error_msg: string,
}

@(private = "file")
stub_of :: proc(client: ^HTTP_Client) -> ^HTTP_Stub_State {
	return cast(^HTTP_Stub_State)client.stub_state
}

http_stub_init :: proc(client: ^HTTP_Client) -> HTTP_Error {
	state := new(HTTP_Stub_State)
	state.responses = make([dynamic]HTTP_Stub_Response)
	state.captured = make([dynamic]HTTP_Captured_Request)
	client.stub_state = state
	return .OK
}

http_stub_destroy :: proc(client: ^HTTP_Client) {
	state := stub_of(client)
	if state == nil do return
	for r in state.responses {
		delete(r.body)
		delete(r.headers)
		for c in r.chunks do delete(c)
		delete(r.chunks)
		delete(r.error_msg)
	}
	delete(state.responses)
	for r in state.captured {
		delete(r.url)
		delete(r.body)
		for h in r.headers do delete(h)
		delete(r.headers)
	}
	delete(state.captured)
	if len(state.last_error_msg) > 0 do delete(state.last_error_msg)
	free(state)
	client.stub_state = nil
	delete(client.response_buf)
	delete(client.header_buf)
}

http_stub_post :: proc(
	client: ^HTTP_Client,
	req: HTTP_Request,
) -> (
	HTTP_Response,
	HTTP_Error,
	string,
) {
	state := stub_of(client)
	if state == nil {
		return {}, .Init_Failed, "stub: client not initialized"
	}
	// Free the previous call's error_msg (if any) — the caller should have
	// consumed it by now.
	if len(state.last_error_msg) > 0 {
		delete(state.last_error_msg)
		state.last_error_msg = ""
	}

	captured := HTTP_Captured_Request {
		url     = strings.clone(req.url),
		body    = slice.clone(req.body),
		stream  = req.stream,
		timeout = req.timeout,
	}
	if len(req.headers) > 0 {
		hdrs := make([]string, len(req.headers))
		for h, i in req.headers {
			hdrs[i] = strings.clone(h)
		}
		captured.headers = hdrs
	}
	append(&state.captured, captured)

	if len(state.responses) == 0 {
		return {}, .Request_Failed, "stub: no response queued"
	}

	resp := state.responses[0]
	ordered_remove(&state.responses, 0)

	if resp.error != .OK {
		state.last_error_msg = resp.error_msg
		resp.error_msg = "" // transferred — cleanup block below must not double-free
		delete(resp.body)
		for c in resp.chunks do delete(c)
		delete(resp.chunks)
		delete(resp.headers)
		return {}, resp.error, state.last_error_msg
	}

	clear(&client.response_buf)
	clear(&client.header_buf)
	if len(resp.headers) > 0 {
		append(&client.header_buf, ..transmute([]byte)resp.headers)
	}

	if req.stream && len(resp.chunks) > 0 {
		for chunk in resp.chunks {
			append(&client.response_buf, ..chunk)
			if req.on_chunk != nil {
				req.on_chunk(chunk, req.userdata)
			}
		}
	} else {
		append(&client.response_buf, ..resp.body)
	}

	delete(resp.body)
	for c in resp.chunks do delete(c)
	delete(resp.chunks)
	delete(resp.headers)
	delete(resp.error_msg)

	return HTTP_Response {
			status = resp.status,
			body = client.response_buf[:],
			headers = client.header_buf[:],
		},
		.OK,
		""
}

http_enqueue_response :: proc(
	client: ^HTTP_Client,
	status: u32,
	body: string,
	headers: string = "",
) {
	state := stub_of(client)
	if state == nil do return
	append(
		&state.responses,
		HTTP_Stub_Response {
			status = status,
			body = slice.clone(transmute([]byte)body),
			headers = strings.clone(headers),
		},
	)
}

http_enqueue_stream :: proc(
	client: ^HTTP_Client,
	status: u32,
	chunks: []string,
	headers: string = "",
) {
	state := stub_of(client)
	if state == nil do return
	cloned := make([][]byte, len(chunks))
	for c, i in chunks {
		cloned[i] = slice.clone(transmute([]byte)c)
	}
	append(
		&state.responses,
		HTTP_Stub_Response{status = status, chunks = cloned, headers = strings.clone(headers)},
	)
}

http_enqueue_429 :: proc(client: ^HTTP_Client, retry_after_seconds: int = 1) {
	state := stub_of(client)
	if state == nil do return
	headers := fmt.aprintf("retry-after:%d", retry_after_seconds)
	append(
		&state.responses,
		HTTP_Stub_Response {
			status = 429,
			body = slice.clone(transmute([]byte)string("Too Many Requests")),
			headers = headers,
		},
	)
}

http_enqueue_error :: proc(client: ^HTTP_Client, err: HTTP_Error, msg: string = "") {
	state := stub_of(client)
	if state == nil do return
	append(&state.responses, HTTP_Stub_Response{error = err, error_msg = strings.clone(msg)})
}

http_get_sent :: proc(client: ^HTTP_Client) -> []HTTP_Captured_Request {
	state := stub_of(client)
	if state == nil do return nil
	return state.captured[:]
}

http_clear_sent :: proc(client: ^HTTP_Client) {
	state := stub_of(client)
	if state == nil do return
	for r in state.captured {
		delete(r.url)
		delete(r.body)
		for h in r.headers do delete(h)
		delete(r.headers)
	}
	clear(&state.captured)
}

http_pending_responses :: proc(client: ^HTTP_Client) -> int {
	state := stub_of(client)
	if state == nil do return 0
	return len(state.responses)
}
