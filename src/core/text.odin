package core

import "base:intrinsics"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"

String_Handle :: struct {
	offset: u32,
	len:    u32,
}

Text :: struct {
	s:      string,
	handle: String_Handle,
	arena:  uintptr,
}

DEFAULT_ARENA_RESERVED :: 256 * mem.Megabyte

arena_init :: proc(arena: ^vmem.Arena, reserved: uint = DEFAULT_ARENA_RESERVED) -> bool {
	return vmem.arena_init_static(arena, reserved) == nil
}

arena_reset :: proc(arena: ^vmem.Arena) {
	if arena != nil && arena.curr_block != nil {
		vmem.arena_static_reset_to(arena, 0)
	}
}

arena_destroy :: proc(arena: ^vmem.Arena) {
	if arena != nil && arena.curr_block != nil {
		vmem.arena_destroy(arena)
	}
}

arena_is_initialized :: proc "contextless" (arena: ^vmem.Arena) -> bool {
	return arena != nil && arena.curr_block != nil
}

arena_bytes_used :: proc "contextless" (arena: ^vmem.Arena) -> uint {
	if !arena_is_initialized(arena) {
		return 0
	}
	return arena.curr_block.used
}

arena_bytes_reserved :: proc "contextless" (arena: ^vmem.Arena) -> uint {
	if !arena_is_initialized(arena) {
		return 0
	}
	return arena.curr_block.reserved
}

text :: proc(s: string, arena: ^vmem.Arena = nil) -> Text {
	if len(s) == 0 {
		return Text{}
	}
	if arena_is_initialized(arena) {
		data, err := vmem.arena_alloc(arena, uint(len(s)), 1)
		if err == nil {
			intrinsics.mem_copy_non_overlapping(raw_data(data), raw_data(s), len(s))
			offset := u32(uintptr(raw_data(data)) - uintptr(arena.curr_block.base))
			return Text {
				handle = String_Handle{offset = offset, len = u32(len(s))},
				arena = uintptr(arena),
			}
		}
	}
	return Text{s = strings.clone(s, context.allocator)}
}

intern :: proc(t: Text, arena: ^vmem.Arena) -> Text {
	if t.handle.len > 0 && t.arena == uintptr(arena) {
		return t
	}
	return text(resolve(t), arena)
}

resolve :: proc(t: Text) -> string {
	if t.handle.len > 0 && t.arena != 0 {
		arena := (^vmem.Arena)(rawptr(t.arena))
		return string(arena.curr_block.base[t.handle.offset:][:t.handle.len])
	}
	return t.s
}

text_has_handle :: proc(t: Text) -> bool {
	return t.handle.len > 0
}

persist_text :: proc(t: Text, allocator := context.allocator) -> Text {
	if t.handle.len > 0 {
		return Text{s = strings.clone(resolve(t), allocator)}
	}
	if len(t.s) == 0 {
		return t
	}
	return Text{s = strings.clone(t.s, allocator)}
}

free_text :: proc(t: Text) {
	if t.handle.len > 0 {
		return
	}
	if len(t.s) > 0 {
		delete(t.s)
	}
}
