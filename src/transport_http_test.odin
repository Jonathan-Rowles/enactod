#+build !freestanding
package enactod_impl

import "core:testing"
import "core:time"

@(test)
test_http_post_happy_path :: proc(t: ^testing.T) {
	client: HTTP_Client
	testing.expect_value(t, http_client_init(&client), HTTP_Error.OK)
	defer http_client_destroy(&client)

	http_enqueue_response(&client, 200, `{"ok":true}`, "content-type:application/json")

	req := HTTP_Request {
		url     = "https://example.com/v1/chat",
		body    = transmute([]byte)string(`{"hello":"world"}`),
		headers = {"authorization: Bearer x"},
		timeout = 1 * time.Second,
	}
	resp, err, msg := http_post(&client, req)

	testing.expect_value(t, err, HTTP_Error.OK)
	testing.expect_value(t, msg, "")
	testing.expect_value(t, resp.status, u32(200))
	testing.expect_value(t, string(resp.body), `{"ok":true}`)
	testing.expect_value(t, string(resp.headers), "content-type:application/json")

	sent := http_get_sent(&client)
	testing.expect_value(t, len(sent), 1)
	testing.expect_value(t, sent[0].url, "https://example.com/v1/chat")
	testing.expect_value(t, string(sent[0].body), `{"hello":"world"}`)
	testing.expect_value(t, sent[0].stream, false)
	testing.expect_value(t, len(sent[0].headers), 1)
	testing.expect_value(t, sent[0].headers[0], "authorization: Bearer x")
}

@(test)
test_http_post_streaming_delivers_chunks :: proc(t: ^testing.T) {
	client: HTTP_Client
	testing.expect_value(t, http_client_init(&client), HTTP_Error.OK)
	defer http_client_destroy(&client)

	http_enqueue_stream(&client, 200, {"chunk-1", "chunk-2", "chunk-3"})

	collected: [dynamic]string
	defer delete(collected)

	on_chunk :: proc(chunk: []byte, userdata: rawptr) {
		collector := cast(^[dynamic]string)userdata
		append(collector, string(chunk))
	}

	req := HTTP_Request {
		url      = "https://example.com/stream",
		body     = transmute([]byte)string(`{}`),
		stream   = true,
		on_chunk = on_chunk,
		userdata = &collected,
	}
	resp, err, _ := http_post(&client, req)

	testing.expect_value(t, err, HTTP_Error.OK)
	testing.expect_value(t, resp.status, u32(200))
	testing.expect_value(t, len(collected), 3)
	testing.expect_value(t, collected[0], "chunk-1")
	testing.expect_value(t, collected[1], "chunk-2")
	testing.expect_value(t, collected[2], "chunk-3")
	testing.expect_value(t, string(resp.body), "chunk-1chunk-2chunk-3")
}

@(test)
test_http_post_with_no_queued_response_errors :: proc(t: ^testing.T) {
	client: HTTP_Client
	testing.expect_value(t, http_client_init(&client), HTTP_Error.OK)
	defer http_client_destroy(&client)

	req := HTTP_Request {
		url  = "https://example.com",
		body = transmute([]byte)string("{}"),
	}
	_, err, msg := http_post(&client, req)

	testing.expect_value(t, err, HTTP_Error.Request_Failed)
	testing.expect_value(t, msg, "stub: no response queued")
}

@(test)
test_http_enqueue_429_shape :: proc(t: ^testing.T) {
	client: HTTP_Client
	testing.expect_value(t, http_client_init(&client), HTTP_Error.OK)
	defer http_client_destroy(&client)

	http_enqueue_429(&client, 5)

	req := HTTP_Request {
		url  = "https://example.com",
		body = transmute([]byte)string("{}"),
	}
	resp, err, _ := http_post(&client, req)

	testing.expect_value(t, err, HTTP_Error.OK)
	testing.expect_value(t, resp.status, u32(429))
	testing.expect_value(t, string(resp.headers), "retry-after:5")
}

@(test)
test_http_enqueue_error_surfaces_via_http_error :: proc(t: ^testing.T) {
	client: HTTP_Client
	testing.expect_value(t, http_client_init(&client), HTTP_Error.OK)
	defer http_client_destroy(&client)

	http_enqueue_error(&client, .Timeout, "operation timed out")

	req := HTTP_Request {
		url  = "https://example.com",
		body = transmute([]byte)string("{}"),
	}
	_, err, msg := http_post(&client, req)

	testing.expect_value(t, err, HTTP_Error.Timeout)
	testing.expect_value(t, msg, "operation timed out")
}
