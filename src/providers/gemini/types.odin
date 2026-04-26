package gemini

Gemini_Function_Call :: struct {
	name: string `json:"name"`,
	args: string `json:"args,raw"`,
}

Gemini_Function_Response_Body :: struct {
	result: string `json:"result"`,
}

Gemini_Function_Response :: struct {
	name:     string `json:"name"`,
	response: Gemini_Function_Response_Body `json:"response"`,
}

Gemini_Part :: struct {
	text:              string `json:"text,omitempty"`,
	thought:           bool `json:"thought,omitempty"`,
	function_call:     Gemini_Function_Call `json:"functionCall,omitempty"`,
	function_response: Gemini_Function_Response `json:"functionResponse,omitempty"`,
}

Gemini_Content :: struct {
	role:  string `json:"role,omitempty"`,
	parts: []Gemini_Part `json:"parts"`,
}

Gemini_System_Instruction :: struct {
	parts: []Gemini_Part `json:"parts"`,
}

Gemini_Tool_Declaration :: struct {
	name:        string `json:"name"`,
	description: string `json:"description"`,
	parameters:  string `json:"parameters,raw"`,
}

Gemini_Tool :: struct {
	function_declarations: []Gemini_Tool_Declaration `json:"functionDeclarations"`,
}

Gemini_Generation_Config :: struct {
	temperature:       string `json:"temperature,raw,omitempty"`,
	top_p:             string `json:"topP,raw,omitempty"`,
	max_output_tokens: int `json:"maxOutputTokens"`,
	thinking_config:   string `json:"thinkingConfig,raw,omitempty"`,
}

Gemini_Request :: struct {
	system_instruction: Gemini_System_Instruction `json:"systemInstruction,omitempty"`,
	contents:           []Gemini_Content `json:"contents"`,
	tools:              []Gemini_Tool `json:"tools,omitempty"`,
	generation_config:  Gemini_Generation_Config `json:"generationConfig"`,
}

Gemini_Candidate :: struct {
	content:       Gemini_Content `json:"content"`,
	finish_reason: string `json:"finishReason"`,
}

Gemini_Usage_Metadata :: struct {
	prompt_token_count:         int `json:"promptTokenCount"`,
	candidates_token_count:     int `json:"candidatesTokenCount"`,
	cached_content_token_count: int `json:"cachedContentTokenCount"`,
	thoughts_token_count:       int `json:"thoughtsTokenCount"`,
}

Gemini_Response :: struct {
	candidates:     []Gemini_Candidate `json:"candidates"`,
	usage_metadata: Gemini_Usage_Metadata `json:"usageMetadata"`,
}
