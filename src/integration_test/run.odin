package integration_test

import "../../pkgs/actod/src/pkgs/threads_act"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

INTEGRATION_TEST_BIN ::
	"bin/integration_test" when ODIN_OS != .Windows else "bin\\integration_test.exe"

Test_Entry :: struct {
	name:      string,
	test_proc: proc(t: ^testing.T),
}

ALL_TESTS :: []Test_Entry {
	{name = "test_arena", test_proc = test_arena},
	{name = "test_anthropic", test_proc = test_anthropic},
	{name = "test_429_retry", test_proc = test_429_retry},
	{name = "test_streaming", test_proc = test_streaming},
	{name = "test_timeout", test_proc = test_timeout},
}

run_single_test :: proc(test_name: string) -> bool {
	for entry in ALL_TESTS {
		if entry.name == test_name {
			t := testing.T{}
			entry.test_proc(&t)
			return !testing.failed(&t)
		}
	}
	fmt.eprintf("Unknown test: %s\n", test_name)
	return false
}

Test_Result :: struct {
	name:      string,
	success:   bool,
	exit_code: int,
}

Test_Thread_Context :: struct {
	entry:  Test_Entry,
	result: ^Test_Result,
}

TEST_TIMEOUT_SECONDS :: 60

Watchdog_Data :: struct {
	process:   os.Process,
	cancelled: bool,
	fired:     bool,
}

test_watchdog_proc :: proc(data: rawptr) {
	wd := cast(^Watchdog_Data)data
	for _ in 0 ..< TEST_TIMEOUT_SECONDS * 4 {
		if sync.atomic_load_explicit(&wd.cancelled, .Acquire) {
			return
		}
		time.sleep(250 * time.Millisecond)
	}
	if !sync.atomic_load_explicit(&wd.cancelled, .Acquire) {
		sync.atomic_store_explicit(&wd.fired, true, .Release)
		_ = os.process_kill(wd.process)
	}
}

run_test_in_subprocess :: proc(test_name: string) -> Test_Result {
	result := Test_Result {
		name    = test_name,
		success = false,
	}

	proc_desc := os.Process_Desc {
		command = []string{INTEGRATION_TEST_BIN},
		env     = make_test_env([]string{fmt.tprintf("ENACT_TEST_RUN=%s", test_name)}),
	}

	process, err := os.process_start(proc_desc)
	if err != nil {
		fmt.eprintf("Failed to start test process for %s: %v\n", test_name, err)
		return result
	}

	watchdog_data := Watchdog_Data {
		process = process,
	}
	watchdog := thread.create_and_start_with_data(&watchdog_data, test_watchdog_proc)

	state, wait_err := os.process_wait(process)

	sync.atomic_store_explicit(&watchdog_data.cancelled, true, .Release)
	thread.join(watchdog)
	thread.destroy(watchdog)

	if watchdog_data.fired {
		result.exit_code = -1
		return result
	}

	if wait_err != nil {
		fmt.eprintf("Failed to wait for test %s: %v\n", test_name, wait_err)
		return result
	}

	result.exit_code = state.exit_code
	result.success = state.exit_code == 0

	return result
}

test_thread_proc :: proc(data: rawptr) {
	ctx := cast(^Test_Thread_Context)data
	ctx.result^ = run_test_in_subprocess(ctx.entry.name)
	if ctx.result.success {
		fmt.printf("  PASS: %s\n", ctx.result.name)
	} else if ctx.result.exit_code == -1 {
		fmt.printf("  TIMEOUT: %s (killed after %ds)\n", ctx.result.name, TEST_TIMEOUT_SECONDS)
	} else {
		fmt.printf("  FAIL: %s (exit code: %d)\n", ctx.result.name, ctx.result.exit_code)
	}
}

run_tests_parallel :: proc(t: ^testing.T) {
	tests := ALL_TESTS

	results := make([]Test_Result, len(tests))
	defer delete(results)

	contexts := make([]Test_Thread_Context, len(tests))
	defer delete(contexts)

	threads := make([]^thread.Thread, len(tests))
	defer {
		for th in threads {
			if th != nil {
				thread.destroy(th)
			}
		}
		delete(threads)
	}

	max_concurrent := max(2, threads_act.get_cpu_count() * 2)
	fmt.printf("Running %d tests in parallel (max %d at a time)...\n", len(tests), max_concurrent)

	for batch_start := 0; batch_start < len(tests); batch_start += max_concurrent {
		batch_end := min(batch_start + max_concurrent, len(tests))

		for i in batch_start ..< batch_end {
			contexts[i] = Test_Thread_Context {
				entry  = tests[i],
				result = &results[i],
			}
			threads[i] = thread.create_and_start_with_data(&contexts[i], test_thread_proc)
		}

		for i in batch_start ..< batch_end {
			if threads[i] != nil {
				thread.join(threads[i])
			}
		}
	}

	passed := 0
	failed := 0
	for result in results {
		if result.success {
			passed += 1
		} else {
			failed += 1
		}
	}
	fmt.printf("\nResults: %d passed, %d failed\n", passed, failed)

	if failed > 0 {
		testing.expect(t, false, fmt.tprintf("%d tests failed", failed))
	}
}

@(test)
run_integration_tests :: proc(t: ^testing.T) {
	if test_name, ok := os.lookup_env("ENACT_TEST_RUN", context.temp_allocator); ok {
		if run_single_test(test_name) {
			os.exit(0)
		} else {
			os.exit(1)
		}
	}
	run_tests_parallel(t)
}
