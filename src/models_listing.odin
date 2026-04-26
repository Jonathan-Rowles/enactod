package enactod_impl

import "core:log"
import "core:time"
import "providers/anthropic"
import "providers/gemini"
import "providers/ollama"
import "providers/openai"

DEFAULT_LIST_MODELS_TIMEOUT :: 30 * time.Second

list_models :: proc(
	provider: Provider_Config,
	allocator := context.allocator,
) -> (
	[]Model_Info,
	bool,
) {
	prov := provider

	url: string
	switch prov.format {
	case .ANTHROPIC:
		url = anthropic.models_url(prov.base_url)
	case .OPENAI_COMPAT:
		url = openai.models_url(prov.base_url)
	case .OLLAMA:
		url = ollama.models_url(prov.base_url)
	case .GEMINI:
		url = gemini.models_url(prov.base_url, prov.api_key)
	}

	headers: [dynamic]string
	headers.allocator = context.temp_allocator
	auth := build_auth_header(&prov)
	if len(auth) > 0 {
		append(&headers, auth)
	}
	extra := build_extra_headers(&prov)
	if len(extra) > 0 {
		append(&headers, extra)
	}

	client: HTTP_Client
	if http_client_init(&client) != .OK {
		log.errorf("list_models: failed to init http client (%s)", provider.name)
		return nil, false
	}
	defer http_client_destroy(&client)

	req := HTTP_Request {
		url     = url,
		headers = headers[:],
		timeout = DEFAULT_LIST_MODELS_TIMEOUT,
	}
	resp, err, err_msg := http_get(&client, req)
	if err != .OK {
		log.errorf("list_models: http error (%s): %s", provider.name, err_msg)
		return nil, false
	}
	if resp.status < 200 || resp.status >= 300 {
		log.errorf(
			"list_models: HTTP %d from %s: %s",
			resp.status,
			provider.name,
			string(resp.body),
		)
		return nil, false
	}

	switch prov.format {
	case .ANTHROPIC:
		return anthropic.parse_models(resp.body, prov.name, allocator)
	case .OPENAI_COMPAT:
		return openai.parse_models(resp.body, prov.name, allocator)
	case .OLLAMA:
		return ollama.parse_models(resp.body, prov.name, allocator)
	case .GEMINI:
		return gemini.parse_models(resp.body, prov.name, allocator)
	}

	return nil, false
}

enrich_model_capabilities :: proc(provider: Provider_Config, model_id: string) -> Capabilities {
	base := capabilities_for(provider.format, model_id)
	if provider.format != .OLLAMA {
		return base
	}

	prov := provider
	client: HTTP_Client
	if http_client_init(&client) != .OK {
		log.errorf("enrich_model_capabilities: http init failed (%s)", prov.name)
		return base
	}
	defer http_client_destroy(&client)

	headers: [dynamic]string
	headers.allocator = context.temp_allocator
	auth := build_auth_header(&prov)
	if len(auth) > 0 {
		append(&headers, auth)
	}

	body := ollama.show_request_body(model_id)
	req := HTTP_Request {
		url     = ollama.show_url(prov.base_url),
		body    = transmute([]byte)body,
		headers = headers[:],
		timeout = DEFAULT_LIST_MODELS_TIMEOUT,
	}
	resp, err, err_msg := http_post(&client, req)
	if err != .OK {
		log.errorf("enrich_model_capabilities: http error (%s): %s", prov.name, err_msg)
		return base
	}
	if resp.status < 200 || resp.status >= 300 {
		log.errorf(
			"enrich_model_capabilities: HTTP %d (%s): %s",
			resp.status,
			prov.name,
			string(resp.body),
		)
		return base
	}

	overlaid, _ := ollama.parse_show_capabilities(resp.body, base)
	return overlaid
}
