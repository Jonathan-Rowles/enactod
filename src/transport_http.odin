package enactod_impl

import "base:runtime"
import "core:c"
import "core:strings"
import "core:time"
import "vendor:curl"

HTTP_Error :: enum u8 {
	OK,
	Init_Failed,
	Request_Failed,
	Timeout,
}

HTTP_Chunk_Cb :: #type proc(chunk: []byte, userdata: rawptr)

HTTP_Request :: struct {
	url:      string,
	body:     []byte,
	headers:  []string, // each "Name: Value"; Content-Type: application/json is added automatically
	timeout:  time.Duration,
	stream:   bool,
	on_chunk: HTTP_Chunk_Cb, // invoked per chunk when stream=true; may be nil
	userdata: rawptr,
}

HTTP_Response :: struct {
	status:  u32,
	body:    []byte, // full response when stream=false; accumulated raw bytes when stream=true (for error recovery)
	headers: []byte, // newline-delimited "key:value" pairs
}

HTTP_Client :: struct {
	handle:       ^curl.CURL,
	response_buf: [dynamic]byte,
	header_buf:   [dynamic]byte,
	write_ctx:    HTTP_Write_Context,
	header_ctx:   HTTP_Header_Context,
	stream_ctx:   HTTP_Stream_Context,
	stub_state:   rawptr,
}

HTTP_Write_Context :: struct {
	buf: ^[dynamic]byte,
	ctx: runtime.Context,
}

HTTP_Header_Context :: struct {
	buf: ^[dynamic]byte,
	ctx: runtime.Context,
}

HTTP_Stream_Context :: struct {
	ctx:      runtime.Context,
	raw_buf:  ^[dynamic]byte,
	on_chunk: HTTP_Chunk_Cb,
	userdata: rawptr,
}

http_client_init :: proc(client: ^HTTP_Client) -> HTTP_Error {
	when ODIN_TEST {
		return http_stub_init(client)
	} else {
		return http_real_init(client)
	}
}

http_client_destroy :: proc(client: ^HTTP_Client) {
	when ODIN_TEST {
		http_stub_destroy(client)
	} else {
		http_real_destroy(client)
	}
}

http_post :: proc(client: ^HTTP_Client, req: HTTP_Request) -> (HTTP_Response, HTTP_Error, string) {
	when ODIN_TEST {
		return http_stub_post(client, req)
	} else {
		return http_real_post(client, req)
	}
}

http_get :: proc(client: ^HTTP_Client, req: HTTP_Request) -> (HTTP_Response, HTTP_Error, string) {
	when ODIN_TEST {
		return http_stub_post(client, req)
	} else {
		return http_real_get(client, req)
	}
}

@(private = "file")
http_real_init :: proc(client: ^HTTP_Client) -> HTTP_Error {
	client.handle = curl.easy_init()
	if client.handle == nil {
		return .Init_Failed
	}
	client.response_buf = make([dynamic]byte, 0, 4096)
	client.header_buf = make([dynamic]byte, 0, 1024)
	client.write_ctx = HTTP_Write_Context {
		buf = &client.response_buf,
		ctx = context,
	}
	client.header_ctx = HTTP_Header_Context {
		buf = &client.header_buf,
		ctx = context,
	}
	curl.easy_setopt(client.handle, .WRITEFUNCTION, http_curl_write_cb)
	curl.easy_setopt(client.handle, .WRITEDATA, &client.write_ctx)
	curl.easy_setopt(client.handle, .HEADERFUNCTION, http_curl_header_cb)
	curl.easy_setopt(client.handle, .HEADERDATA, &client.header_ctx)
	curl.easy_setopt(client.handle, .NOSIGNAL, c.long(1))
	return .OK
}

@(private = "file")
http_real_destroy :: proc(client: ^HTTP_Client) {
	if client.handle != nil {
		curl.easy_cleanup(client.handle)
		client.handle = nil
	}
	delete(client.response_buf)
	delete(client.header_buf)
}

@(private = "file")
http_real_post :: proc(
	client: ^HTTP_Client,
	req: HTTP_Request,
) -> (
	HTTP_Response,
	HTTP_Error,
	string,
) {
	clear(&client.response_buf)
	clear(&client.header_buf)

	url_cstr := strings.clone_to_cstring(req.url, context.temp_allocator)
	curl.easy_setopt(client.handle, .URL, url_cstr)
	curl.easy_setopt(client.handle, .POST, c.long(1))
	curl.easy_setopt(client.handle, .POSTFIELDS, raw_data(req.body))
	curl.easy_setopt(client.handle, .POSTFIELDSIZE_LARGE, c.long(len(req.body)))

	hdr_list: ^curl.slist = nil
	hdr_list = curl.slist_append(hdr_list, "Content-Type: application/json")
	for h in req.headers {
		if len(h) == 0 {
			continue
		}
		hdr_list = curl.slist_append(hdr_list, strings.clone_to_cstring(h, context.temp_allocator))
	}
	defer curl.slist_free_all(hdr_list)
	curl.easy_setopt(client.handle, .HTTPHEADER, hdr_list)

	if req.timeout > 0 {
		timeout_ms := i64(time.duration_milliseconds(req.timeout))
		curl.easy_setopt(client.handle, .TIMEOUT_MS, c.long(timeout_ms))
	}

	if req.stream {
		client.stream_ctx = HTTP_Stream_Context {
			ctx      = context,
			raw_buf  = &client.response_buf,
			on_chunk = req.on_chunk,
			userdata = req.userdata,
		}
		curl.easy_setopt(client.handle, .WRITEFUNCTION, http_curl_stream_cb)
		curl.easy_setopt(client.handle, .WRITEDATA, &client.stream_ctx)
	}

	code := curl.easy_perform(client.handle)

	if req.stream {
		curl.easy_setopt(client.handle, .WRITEFUNCTION, http_curl_write_cb)
		curl.easy_setopt(client.handle, .WRITEDATA, &client.write_ctx)
	}

	if code != .E_OK {
		err_msg := string(curl.easy_strerror(code))
		if code == .E_OPERATION_TIMEDOUT {
			return {}, .Timeout, err_msg
		}
		return {}, .Request_Failed, err_msg
	}

	status: c.long = 0
	curl.easy_getinfo(client.handle, .RESPONSE_CODE, &status)

	return HTTP_Response {
			status = u32(status),
			body = client.response_buf[:],
			headers = client.header_buf[:],
		},
		.OK,
		""
}

@(private = "file")
http_real_get :: proc(
	client: ^HTTP_Client,
	req: HTTP_Request,
) -> (
	HTTP_Response,
	HTTP_Error,
	string,
) {
	clear(&client.response_buf)
	clear(&client.header_buf)

	url_cstr := strings.clone_to_cstring(req.url, context.temp_allocator)
	curl.easy_setopt(client.handle, .URL, url_cstr)
	curl.easy_setopt(client.handle, .HTTPGET, c.long(1))

	hdr_list: ^curl.slist = nil
	for h in req.headers {
		if len(h) == 0 {
			continue
		}
		hdr_list = curl.slist_append(hdr_list, strings.clone_to_cstring(h, context.temp_allocator))
	}
	defer curl.slist_free_all(hdr_list)
	curl.easy_setopt(client.handle, .HTTPHEADER, hdr_list)

	if req.timeout > 0 {
		timeout_ms := i64(time.duration_milliseconds(req.timeout))
		curl.easy_setopt(client.handle, .TIMEOUT_MS, c.long(timeout_ms))
	}

	code := curl.easy_perform(client.handle)
	if code != .E_OK {
		err_msg := string(curl.easy_strerror(code))
		if code == .E_OPERATION_TIMEDOUT {
			return {}, .Timeout, err_msg
		}
		return {}, .Request_Failed, err_msg
	}

	status: c.long = 0
	curl.easy_getinfo(client.handle, .RESPONSE_CODE, &status)

	return HTTP_Response {
			status = u32(status),
			body = client.response_buf[:],
			headers = client.header_buf[:],
		},
		.OK,
		""
}

@(private = "file")
http_curl_write_cb :: proc "c" (
	data: [^]byte,
	size: c.size_t,
	nmemb: c.size_t,
	userdata: rawptr,
) -> c.size_t {
	wc := cast(^HTTP_Write_Context)userdata
	context = wc.ctx
	total := size * nmemb
	chunk := data[:total]
	append(wc.buf, ..chunk)
	return total
}

@(private = "file")
http_curl_header_cb :: proc "c" (
	data: [^]byte,
	size: c.size_t,
	nmemb: c.size_t,
	userdata: rawptr,
) -> c.size_t {
	hc := cast(^HTTP_Header_Context)userdata
	context = hc.ctx
	total := size * nmemb

	line := string(data[:total])
	colon := -1
	for i in 0 ..< len(line) {
		if line[i] == ':' {
			colon = i
			break
		}
	}
	if colon > 0 {
		key := line[:colon]
		value := line[colon + 1:]
		for len(value) > 0 && (value[0] == ' ' || value[0] == '\t') {
			value = value[1:]
		}
		for len(value) > 0 && (value[len(value) - 1] == '\r' || value[len(value) - 1] == '\n') {
			value = value[:len(value) - 1]
		}
		if len(key) > 0 && len(value) > 0 {
			if len(hc.buf^) > 0 {
				append(hc.buf, '\n')
			}
			append(hc.buf, ..transmute([]byte)key)
			append(hc.buf, ':')
			append(hc.buf, ..transmute([]byte)value)
		}
	}
	return total
}

@(private = "file")
http_curl_stream_cb :: proc "c" (
	data: [^]byte,
	size: c.size_t,
	nmemb: c.size_t,
	userdata: rawptr,
) -> c.size_t {
	sc := cast(^HTTP_Stream_Context)userdata
	context = sc.ctx
	total := size * nmemb
	chunk := data[:total]
	append(sc.raw_buf, ..chunk)
	if sc.on_chunk != nil {
		sc.on_chunk(chunk, sc.userdata)
	}
	return total
}
