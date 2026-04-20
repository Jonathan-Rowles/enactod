#+build !freestanding
package enactod_impl

import "core:testing"

@(test)
test_trace_event_detail_role_exhaustive :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		trace_event_detail_role(Trace_Event{kind = .REQUEST_START}),
		Trace_Event_Detail_Role.USER_INPUT,
	)
	testing.expect_value(
		t,
		trace_event_detail_role(Trace_Event{kind = .REQUEST_END, is_error = false}),
		Trace_Event_Detail_Role.FINAL_RESPONSE,
	)
	testing.expect_value(
		t,
		trace_event_detail_role(Trace_Event{kind = .REQUEST_END, is_error = true}),
		Trace_Event_Detail_Role.ERROR_MESSAGE,
	)
	testing.expect_value(
		t,
		trace_event_detail_role(Trace_Event{kind = .LLM_CALL_DONE}),
		Trace_Event_Detail_Role.ASSISTANT_REPLY,
	)
	testing.expect_value(
		t,
		trace_event_detail_role(Trace_Event{kind = .TOOL_CALL_START}),
		Trace_Event_Detail_Role.TOOL_ARGS,
	)
	testing.expect_value(
		t,
		trace_event_detail_role(Trace_Event{kind = .TOOL_CALL_DONE, is_error = false}),
		Trace_Event_Detail_Role.TOOL_RESULT,
	)
	testing.expect_value(
		t,
		trace_event_detail_role(Trace_Event{kind = .TOOL_CALL_DONE, is_error = true}),
		Trace_Event_Detail_Role.ERROR_MESSAGE,
	)
	testing.expect_value(
		t,
		trace_event_detail_role(Trace_Event{kind = .THINKING_DONE}),
		Trace_Event_Detail_Role.THINKING,
	)
	testing.expect_value(
		t,
		trace_event_detail_role(Trace_Event{kind = .ERROR}),
		Trace_Event_Detail_Role.ERROR_MESSAGE,
	)

	testing.expect_value(
		t,
		trace_event_detail_role(Trace_Event{kind = .LLM_CALL_START}),
		Trace_Event_Detail_Role.NONE,
	)
	testing.expect_value(
		t,
		trace_event_detail_role(Trace_Event{kind = .RATE_LIMIT_QUEUED}),
		Trace_Event_Detail_Role.NONE,
	)
	testing.expect_value(
		t,
		trace_event_detail_role(Trace_Event{kind = .RATE_LIMIT_RETRYING}),
		Trace_Event_Detail_Role.NONE,
	)
	testing.expect_value(
		t,
		trace_event_detail_role(Trace_Event{kind = .RATE_LIMIT_PROCESSING}),
		Trace_Event_Detail_Role.NONE,
	)
}
