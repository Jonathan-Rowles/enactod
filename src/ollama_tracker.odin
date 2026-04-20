package enactod_impl

import "../pkgs/actod"
import "../pkgs/ojson"
import "core:c"
import "core:fmt"
import "core:strings"
import curl "vendor:curl"

OLLAMA_TRACKER_ACTOR_NAME :: "enact_ollama_tracker"

Ollama_Model_Seen :: struct {
	base_url: string,
	model:    string,
}

Ollama_Unload_All :: struct {}

Tracked_Ollama :: struct {
	base_url: string,
	model:    string,
}

Ollama_Tracker_State :: struct {
	seen: [dynamic]Tracked_Ollama,
}

ollama_tracker_behaviour :: actod.Actor_Behaviour(Ollama_Tracker_State) {
	init           = ollama_tracker_init,
	handle_message = ollama_tracker_handle_message,
}

ollama_tracker_init :: proc(data: ^Ollama_Tracker_State) {
	data.seen = make([dynamic]Tracked_Ollama)
}

ollama_tracker_handle_message :: proc(data: ^Ollama_Tracker_State, from: actod.PID, content: any) {
	switch msg in content {
	case Ollama_Model_Seen:
		for e in data.seen {
			if e.base_url == msg.base_url && e.model == msg.model {
				return
			}
		}
		append(
			&data.seen,
			Tracked_Ollama {
				base_url = strings.clone(msg.base_url),
				model = strings.clone(msg.model),
			},
		)
	case Ollama_Unload_All:
		for entry in data.seen {
			unload_ollama_model(entry.base_url, entry.model)
		}
	}
}

ollama_tracker_spawn :: proc(_: string, _: actod.PID) -> (actod.PID, bool) {
	return actod.spawn_child(
		OLLAMA_TRACKER_ACTOR_NAME,
		Ollama_Tracker_State{},
		ollama_tracker_behaviour,
		actod.make_actor_config(use_dedicated_os_thread = true),
	)
}

@(private = "file")
noop_write :: proc "c" (_: [^]byte, size: c.size_t, nmemb: c.size_t, _: rawptr) -> c.size_t {
	return size * nmemb
}

@(private = "file")
unload_ollama_model :: proc(base_url: string, model: string) {
	url := fmt.tprintf("%s/api/generate", base_url)

	w := ojson.init_writer()
	ojson.write_object_start(&w)
	ojson.write_key(&w, "model")
	ojson.write_string(&w, model)
	ojson.write_key(&w, "keep_alive")
	ojson.write_int(&w, 0)
	ojson.write_object_end(&w)
	body := ojson.writer_string(&w)
	defer ojson.destroy(&w)

	handle := curl.easy_init()
	if handle == nil {return}

	url_cstr := strings.clone_to_cstring(url, context.temp_allocator)
	body_cstr := strings.clone_to_cstring(body, context.temp_allocator)

	curl.easy_setopt(handle, .URL, url_cstr)
	curl.easy_setopt(handle, .POST, c.long(1))
	curl.easy_setopt(handle, .POSTFIELDS, body_cstr)
	curl.easy_setopt(handle, .POSTFIELDSIZE_LARGE, c.long(len(body)))
	curl.easy_setopt(handle, .WRITEFUNCTION, noop_write)
	curl.easy_setopt(handle, .NOSIGNAL, c.long(1))
	curl.easy_setopt(handle, .TIMEOUT_MS, c.long(3000))

	headers: ^curl.slist = nil
	headers = curl.slist_append(headers, "Content-Type: application/json")
	curl.easy_setopt(handle, .HTTPHEADER, headers)

	curl.easy_perform(handle)
	curl.slist_free_all(headers)
	curl.easy_cleanup(handle)
}
