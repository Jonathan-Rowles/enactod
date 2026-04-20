# Ollama

enactod speaks Ollama's native API (NDJSON streaming, `/api/chat`). Ollama is an external process; its model lifecycle is your call. By default models stay loaded after your program exits so the next run starts warm.

## Configuring

```odin
cfg := enact.make_agent_config(
    llm = enact.ollama("llama3.1:70b-instruct-q4_K_M"),
)
```

The `ollama` preset takes a string tag, defaults to `http://localhost:11434`, skips the API key, uses a 300s timeout, and defaults `enable_rate_limiting = false`. Override via keyword args:

```odin
cfg := enact.make_agent_config(
    llm = enact.ollama(
        "qwen2.5-coder:32b",
        base_url = "http://gpu-box.lan:11434",
        timeout  = 10 * time.Minute,
    ),
)
```

## Tracker

Every dispatch sends `Ollama_Model_Seen{base_url, model}` to a node scoped actor named `enact_ollama_tracker`. It dedupes `(base_url, model)` pairs used this session. Runs on a dedicated OS thread (blocking HTTP during unload). Spawned automatically by `NODE_INIT`.

```
agent dispatch ─> LLM_Call ─> ...
                │
                └─> Ollama_Model_Seen ─> enact_ollama_tracker (passive)
```

## Unloading

```odin
enact.unload_ollama_models(node_name: string = "") -> Send_Error
```

Sends `Ollama_Unload_All{}` to the tracker, which issues `POST /api/generate` with `keep_alive = 0` for every tracked `(base_url, model)`. Fire and forget.

```odin
enact.SHUTDOWN_NODE()                 // default: warm restart
enact.unload_ollama_models()          // opt in: release VRAM / RAM
enact.SHUTDOWN_NODE()
```

Call `unload_ollama_models` when running on a low RAM machine, in CI / one shot scripts that shouldn't leak state, or between workloads using different model sets. Skip it when you want fast subsequent starts on the same models or something else manages model lifecycle.

## Cross node

`unload_ollama_models("some-node")` sends `Ollama_Unload_All{}` to the tracker on that node. Useful for centrally administering a cluster of worker nodes each hosting their own Ollama instance.

---
[< Prompt Caching](10_prompt-caching.md) | [Tracing >](12_tracing.md)
