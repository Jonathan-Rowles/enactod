#+build !freestanding
package enactod_impl

import vmem "core:mem/virtual"
import "core:testing"

@(test)
test_text_empty_string_is_empty_sentinel :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	e := text("")
	testing.expect_value(t, resolve(e), "")
	testing.expect(t, !text_has_handle(e))
}

@(test)
test_text_string_backed_without_arena :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	x := text("hello")
	testing.expect_value(t, resolve(x), "hello")
	testing.expect(t, !text_has_handle(x))
}

@(test)
test_text_handle_backed_with_arena :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	arena: vmem.Arena
	testing.expect(t, arena_init(&arena, 4096))
	defer arena_destroy(&arena)

	x := text("world", &arena)
	testing.expect_value(t, resolve(x), "world")
	testing.expect(t, text_has_handle(x))
	testing.expect_value(t, arena_bytes_used(&arena), uint(5))
}

@(test)
test_persist_text_converts_handle_to_string_backed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	arena: vmem.Arena
	testing.expect(t, arena_init(&arena, 4096))
	handle_backed := text("inside arena", &arena)
	testing.expect(t, text_has_handle(handle_backed))

	copy := persist_text(handle_backed, context.temp_allocator)
	testing.expect(t, !text_has_handle(copy))
	testing.expect_value(t, resolve(copy), "inside arena")

	arena_destroy(&arena)
	testing.expect_value(t, resolve(copy), "inside arena")
}

@(test)
test_arena_bytes_used_and_reset :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	arena: vmem.Arena
	testing.expect(t, arena_init(&arena, 4096))
	defer arena_destroy(&arena)

	text("hello", &arena)
	used_before := arena_bytes_used(&arena)
	testing.expect(t, used_before > 0)

	arena_reset(&arena)
	testing.expect_value(t, arena_bytes_used(&arena), uint(0))
}

@(test)
test_intern_preserves_identity_when_already_in_same_arena :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	arena: vmem.Arena
	testing.expect(t, arena_init(&arena, 4096))
	defer arena_destroy(&arena)

	x := text("in-arena", &arena)
	y := intern(x, &arena)
	testing.expect_value(t, y.handle.offset, x.handle.offset)
	testing.expect_value(t, y.handle.len, x.handle.len)
}

@(test)
test_intern_copies_string_backed_into_arena :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	arena: vmem.Arena
	testing.expect(t, arena_init(&arena, 4096))
	defer arena_destroy(&arena)

	x := text("plain")
	testing.expect(t, !text_has_handle(x))
	y := intern(x, &arena)
	testing.expect(t, text_has_handle(y))
	testing.expect_value(t, resolve(y), "plain")
}
