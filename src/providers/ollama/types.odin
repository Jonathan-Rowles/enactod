package ollama

Ollama_Tool_Call_Function :: struct {
	name:      string `json:"name"`,
	arguments: string `json:"arguments,raw"`,
}

Ollama_Tool_Call :: struct {
	id:       string `json:"id"`,
	function: Ollama_Tool_Call_Function `json:"function"`,
}

Ollama_Message :: struct {
	role:       string `json:"role"`,
	content:    string `json:"content"`,
	thinking:   string `json:"thinking,omitempty"`,
	tool_calls: []Ollama_Tool_Call `json:"tool_calls,omitempty"`,
}

Ollama_Tool_Def_Function :: struct {
	name:        string `json:"name"`,
	description: string `json:"description"`,
	parameters:  string `json:"parameters,raw"`,
}

Ollama_Tool_Def :: struct {
	type:     string `json:"type"`,
	function: Ollama_Tool_Def_Function `json:"function"`,
}

Ollama_Options :: struct {
	num_ctx:     int `json:"num_ctx,omitempty"`,
	temperature: string `json:"temperature,raw,omitempty"`,
	top_p:       string `json:"top_p,raw,omitempty"`,
}

Ollama_Request :: struct {
	model:    string `json:"model"`,
	stream:   bool `json:"stream"`,
	think:    string `json:"think,raw,omitempty"`,
	messages: []Ollama_Message `json:"messages"`,
	tools:    []Ollama_Tool_Def `json:"tools,omitempty"`,
	options:  Ollama_Options `json:"options,omitempty"`,
}

Ollama_Response :: struct {
	done_reason:       string `json:"done_reason"`,
	message:           Ollama_Message `json:"message"`,
	prompt_eval_count: int `json:"prompt_eval_count"`,
	eval_count:        int `json:"eval_count"`,
}
