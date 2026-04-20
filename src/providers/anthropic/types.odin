package anthropic

Anthropic_Cache_Control :: struct {
	type: string `json:"type"`,
}

Anthropic_Thinking :: struct {
	type:          string `json:"type"`,
	budget_tokens: int `json:"budget_tokens"`,
}

Anthropic_Text_Block :: struct {
	type:          string `json:"type,tag=text"`,
	text:          string `json:"text"`,
	cache_control: Anthropic_Cache_Control `json:"cache_control,omitempty"`,
}

Anthropic_Thinking_Block :: struct {
	type:      string `json:"type,tag=thinking"`,
	thinking:  string `json:"thinking"`,
	signature: string `json:"signature"`,
}

Anthropic_Tool_Use_Block :: struct {
	type:  string `json:"type,tag=tool_use"`,
	id:    string `json:"id"`,
	name:  string `json:"name"`,
	input: string `json:"input,raw"`,
}

Anthropic_Tool_Result_Block :: struct {
	type:        string `json:"type,tag=tool_result"`,
	tool_use_id: string `json:"tool_use_id"`,
	content:     string `json:"content"`,
}

Anthropic_Content_Block :: union {
	Anthropic_Text_Block,
	Anthropic_Thinking_Block,
	Anthropic_Tool_Use_Block,
	Anthropic_Tool_Result_Block,
}

Anthropic_Message :: struct {
	role:    string `json:"role"`,
	content: []Anthropic_Content_Block `json:"content"`,
}

Anthropic_Tool :: struct {
	name:          string `json:"name"`,
	description:   string `json:"description"`,
	input_schema:  string `json:"input_schema,raw"`,
	cache_control: Anthropic_Cache_Control `json:"cache_control,omitempty"`,
}

Anthropic_Request :: struct {
	model:       string `json:"model"`,
	max_tokens:  int `json:"max_tokens"`,
	temperature: string `json:"temperature,raw,omitempty"`,
	thinking:    Anthropic_Thinking `json:"thinking,omitempty"`,
	stream:      bool `json:"stream,omitempty"`,
	system:      []Anthropic_Text_Block `json:"system,omitempty"`,
	messages:    []Anthropic_Message `json:"messages"`,
	tools:       []Anthropic_Tool `json:"tools,omitempty"`,
}

Anthropic_Usage :: struct {
	input_tokens:                int `json:"input_tokens"`,
	output_tokens:               int `json:"output_tokens"`,
	cache_creation_input_tokens: int `json:"cache_creation_input_tokens"`,
	cache_read_input_tokens:     int `json:"cache_read_input_tokens"`,
}

Anthropic_Response :: struct {
	stop_reason: string `json:"stop_reason"`,
	content:     []Anthropic_Content_Block `json:"content"`,
	usage:       Anthropic_Usage `json:"usage"`,
}
