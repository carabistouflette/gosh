#ifndef GOSH_OS_H
#define GOSH_OS_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const uint8_t *data;
    int64_t len;
} gosh_slice_u8;

typedef struct {
    uint8_t *data;
    int64_t len;
} gosh_mut_slice_u8;

/* Terminal raw mode */
int32_t gosh_term_isatty(int32_t fd);
int32_t gosh_term_enable_raw(int32_t fd);
int32_t gosh_term_disable_raw(int32_t fd);
int32_t gosh_term_read_byte(int32_t fd);
int32_t gosh_term_get_size(int32_t fd, int32_t *rows, int32_t *cols);

/* File and directory operations */
int32_t gosh_chdir(gosh_slice_u8 path);
int32_t gosh_getcwd(gosh_mut_slice_u8 out);
int32_t gosh_is_dir(gosh_slice_u8 path);
int32_t gosh_is_executable(gosh_slice_u8 path);
int32_t gosh_file_exists(gosh_slice_u8 path);
int32_t gosh_glob_list_dir(gosh_slice_u8 path, gosh_mut_slice_u8 out);
int32_t gosh_list_dir(gosh_slice_u8 path, gosh_mut_slice_u8 out);

/* Environment */
int32_t gosh_setenv(gosh_slice_u8 key, gosh_slice_u8 val);
int32_t gosh_unsetenv(gosh_slice_u8 key);
int32_t gosh_getenv(gosh_slice_u8 key, gosh_mut_slice_u8 out);
int32_t gosh_get_env_count(void);
int32_t gosh_get_env_entry(int32_t index, gosh_mut_slice_u8 out_k, gosh_mut_slice_u8 out_v);

/* Process execution and pipelines */
int32_t gosh_exec_packed(
    gosh_slice_u8 packed_args,
    int32_t argc,
    gosh_slice_u8 in_file,
    gosh_slice_u8 out_file,
    int32_t append_out,
    gosh_slice_u8 err_file,
    int32_t append_err,
    int32_t redirect_err_to_out,
    int32_t background,
    int32_t *child_pid
);

int32_t gosh_wait_pid(int32_t pid);

/* Pipeline execution: commands packed with null-terminators */
/* cmd_packed has all args of all commands, each null terminated.
   argcs array has count of args for each command. */
int32_t gosh_run_pipeline_packed(
    int32_t num_cmds,
    gosh_slice_u8 packed_args,
    const int32_t *cmd_argcs,
    gosh_slice_u8 in_file,
    gosh_slice_u8 out_file,
    int32_t append_out,
    gosh_slice_u8 err_file,
    int32_t append_err,
    int32_t redirect_err_to_out,
    int32_t background
);

/* Command output capture: executes packed cmd and captures stdout */
int32_t gosh_capture_cmd_packed(
    gosh_slice_u8 packed_args,
    int32_t argc,
    gosh_mut_slice_u8 out
);

/* In-process redirection for builtins */
int32_t gosh_redirect_begin(
    gosh_slice_u8 in_file,
    gosh_slice_u8 out_file,
    int32_t append_out,
    gosh_slice_u8 err_file,
    int32_t append_err,
    int32_t redirect_err_to_out,
    int32_t *saved_fds
);

void gosh_redirect_end(const int32_t *saved_fds);

/* Compound descriptor scopes: -1 records an originally closed descriptor. */
int32_t gosh_save_stdio(int32_t *saved_fds);
int32_t gosh_restore_stdio(const int32_t *saved_fds);

/* Git branch detection: reads .git/HEAD directly */
int32_t gosh_get_git_branch(gosh_mut_slice_u8 out);

/* Signals and job control */
void gosh_init_signals(void);
void gosh_reset_signals(void);
int32_t gosh_get_pid(void);

/* Low-level POSIX process and descriptor primitives for Goose */
int32_t gosh_fork(void);
int32_t gosh_pipe(int32_t *fds);
int32_t gosh_dup2(int32_t oldfd, int32_t newfd);
void gosh_close(int32_t fd);
void gosh_exit(int32_t code);
int32_t gosh_open_file(gosh_slice_u8 path, int32_t mode);
int32_t gosh_execvp_packed(gosh_slice_u8 packed_args, int32_t argc);
int32_t gosh_read_fd(int32_t fd, gosh_mut_slice_u8 out);

/* Job control and process group primitives */
int32_t gosh_kill(int32_t pid, int32_t sig);
int32_t gosh_setpgid(int32_t pid, int32_t pgid);
int32_t gosh_tcsetpgrp(int32_t fd, int32_t pgrp);
int32_t gosh_tcgetpgrp(int32_t fd);
int32_t gosh_poll_job(int32_t pid, int32_t *status);

#ifdef __cplusplus
}
#endif

#endif /* GOSH_OS_H */
