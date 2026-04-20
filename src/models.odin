package enactod_impl

Model :: enum {
	Claude_Opus_4,
	Claude_Sonnet_4_5,
	Claude_Haiku_4_5,
	GPT_4o,
	GPT_4o_Mini,
	GPT_4_1,
	GPT_4_1_Mini,
	GPT_4_1_Nano,
	O3,
	O3_Mini,
	O4_Mini,
	Gemini_2_5_Pro,
	Gemini_2_5_Flash,
	Gemini_2_5_Flash_Lite,
}

model_string :: proc(model: Model) -> string {
	switch model {
	case .Claude_Opus_4:
		return "claude-opus-4-0-20250514"
	case .Claude_Sonnet_4_5:
		return "claude-sonnet-4-5-20250929"
	case .Claude_Haiku_4_5:
		return "claude-haiku-4-5-20251001"
	case .GPT_4o:
		return "gpt-4o"
	case .GPT_4o_Mini:
		return "gpt-4o-mini"
	case .GPT_4_1:
		return "gpt-4.1"
	case .GPT_4_1_Mini:
		return "gpt-4.1-mini"
	case .GPT_4_1_Nano:
		return "gpt-4.1-nano"
	case .O3:
		return "o3"
	case .O3_Mini:
		return "o3-mini"
	case .O4_Mini:
		return "o4-mini"
	case .Gemini_2_5_Pro:
		return "gemini-2.5-pro"
	case .Gemini_2_5_Flash:
		return "gemini-2.5-flash"
	case .Gemini_2_5_Flash_Lite:
		return "gemini-2.5-flash-lite"
	}
	return "unknown"
}
