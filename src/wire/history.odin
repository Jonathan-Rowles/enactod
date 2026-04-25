package wire

History_Message :: struct {
	role:    string `json:"role"`,
	content: string `json:"content"`,
}

History_Payload :: struct {
	messages: []History_Message `json:"messages"`,
}
