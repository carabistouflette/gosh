// Goose declarations for C interoperability functions in gosh_os.c

extern fn gosh_term_isatty(fd: i32) -> i32;
extern fn gosh_term_enable_raw(fd: i32) -> i32;
extern fn gosh_term_disable_raw(fd: i32) -> i32;
extern fn gosh_term_read_byte(fd: i32) -> i32;
extern fn gosh_term_get_size(fd: i32, rows: i32&, cols: i32&) -> i32;

extern fn gosh_chdir(path: const u8[:]) -> i32;
extern fn gosh_getcwd(out: u8[:]) -> i32;
extern fn gosh_is_dir(path: const u8[:]) -> i32;
extern fn gosh_is_executable(path: const u8[:]) -> i32;
extern fn gosh_file_exists(path: const u8[:]) -> i32;
extern fn gosh_list_dir(path: const u8[:], out: u8[:]) -> i32;

extern fn gosh_setenv(key: const u8[:], val: const u8[:]) -> i32;
extern fn gosh_unsetenv(key: const u8[:]) -> i32;
extern fn gosh_getenv(key: const u8[:], out: u8[:]) -> i32;
extern fn gosh_get_env_count() -> i32;
extern fn gosh_get_env_entry(index: i32, out_k: u8[:], out_v: u8[:]) -> i32;

extern fn gosh_exec_packed(
    packed_args: const u8[:],
    argc: i32,
    in_file: const u8[:],
    out_file: const u8[:],
    append_out: i32,
    err_file: const u8[:],
    append_err: i32,
    redirect_err_to_out: i32,
    background: i32,
    child_pid: i32&
) -> i32;

extern fn gosh_wait_pid(pid: i32) -> i32;

extern fn gosh_run_pipeline_packed(
    num_cmds: i32,
    packed_args: const u8[:],
    cmd_argcs: const i32[:],
    in_file: const u8[:],
    out_file: const u8[:],
    append_out: i32,
    err_file: const u8[:],
    append_err: i32,
    redirect_err_to_out: i32,
    background: i32
) -> i32;

extern fn gosh_capture_cmd_packed(
    packed_args: const u8[:],
    argc: i32,
    out: u8[:]
) -> i32;

extern fn gosh_redirect_begin(
    in_file: const u8[:],
    out_file: const u8[:],
    append_out: i32,
    err_file: const u8[:],
    append_err: i32,
    redirect_err_to_out: i32,
    saved_fds: i32&
) -> i32;

extern fn gosh_redirect_end(saved_fds: const i32&);

// Snapshot/restore all three standard descriptors for compound commands.
extern fn gosh_save_stdio(saved_fds: i32&) -> i32;
extern fn gosh_restore_stdio(saved_fds: const i32&) -> i32;

extern fn gosh_get_git_branch(out: u8[:]) -> i32;
extern fn gosh_init_signals();
extern fn gosh_reset_signals();
extern fn gosh_get_pid() -> i32;

extern fn gosh_fork() -> i32;
extern fn gosh_pipe(fds: i32&) -> i32;
extern fn gosh_dup2(oldfd: i32, newfd: i32) -> i32;
extern fn gosh_close(fd: i32);
extern fn gosh_exit(code: i32);
extern fn gosh_open_file(path: const u8[:], mode: i32) -> i32;
extern fn gosh_execvp_packed(packed_args: const u8[:], argc: i32) -> i32;
extern fn gosh_read_fd(fd: i32, out: u8[:]) -> i32;

extern fn gosh_kill(pid: i32, sig: i32) -> i32;
extern fn gosh_setpgid(pid: i32, pgid: i32) -> i32;
extern fn gosh_tcsetpgrp(fd: i32, pgrp: i32) -> i32;
extern fn gosh_tcgetpgrp(fd: i32) -> i32;
extern fn gosh_poll_job(pid: i32, status: i32&) -> i32;

extern fn gosh_glob_list_dir(path: const u8[:], out: u8[:]) -> i32;
