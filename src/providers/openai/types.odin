package openai

OpenAI_Tool_Function :: struct {
	name:      string `json:"name"`,
	arguments: string `json:"arguments"`,
}

OpenAI_Tool_Call :: struct {
	id:       string `json:"id"`,
	type:     string `json:"type"`,
	function: OpenAI_Tool_Function `json:"function"`,
}

OpenAI_Message :: struct {
	role:         string `json:"role"`,
	content:      string `json:"content"`,
	tool_call_id: string `json:"tool_call_id,omitempty"`,
	tool_calls:   []OpenAI_Tool_Call `json:"tool_calls,omitempty"`,
}

OpenAI_Tool_Def_Function :: struct {
	name:        string `json:"name"`,
	description: string `json:"description"`,
	parameters:  string `json:"parameters,raw"`,
}

OpenAI_Tool_Def :: struct {
	type:     string `json:"type"`,
	function: OpenAI_Tool_Def_Function `json:"function"`,
}

OpenAI_Request :: struct {
	model:       string `json:"model"`,
	temperature: f32 `json:"temperature"`,
	max_tokens:  int `json:"max_tokens"`,
	stream:      bool `json:"stream,omitempty"`,
	messages:    []OpenAI_Message `json:"messages"`,
	tools:       []OpenAI_Tool_Def `json:"tools,omitempty"`,
}

OpenAI_Response_Choice :: struct {
	finish_reason: string `json:"finish_reason"`,
	message:       OpenAI_Message `json:"message"`,
}

OpenAI_Usage :: struct {
	prompt_tokens:     int `json:"prompt_tokens"`,
	completion_tokens: int `json:"completion_tokens"`,
}

OpenAI_Response :: struct {
	choices: []OpenAI_Response_Choice `json:"choices"`,
	usage:   OpenAI_Usage `json:"usage"`,
}
