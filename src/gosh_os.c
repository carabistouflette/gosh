#define _GNU_SOURCE
#include "gosh_os.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <dirent.h>
#include <termios.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/ioctl.h>

extern char **environ;

static struct termios orig_termios;
static int raw_mode_active = 0;

static void slice_to_cstr(gosh_slice_u8 s, char *buf, size_t max_buf) {
    if (s.len <= 0 || !s.data) {
        buf[0] = '\0';
        return;
    }
    size_t copy_len = (size_t)s.len;
    if (copy_len >= max_buf) {
        copy_len = max_buf - 1;
    }
    memcpy(buf, s.data, copy_len);
    buf[copy_len] = '\0';
}

int32_t gosh_term_isatty(int32_t fd) {
    return isatty(fd) ? 1 : 0;
}

int32_t gosh_term_enable_raw(int32_t fd) {
    if (!isatty(fd)) return 0;
    if (raw_mode_active) return 1;

    if (tcgetattr(fd, &orig_termios) == -1) {
        return 0;
    }

    struct termios raw = orig_termios;
    raw.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    raw.c_cflag |= (CS8);
    raw.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;

    if (tcsetattr(fd, TCSAFLUSH, &raw) < 0) {
        return 0;
    }
    raw_mode_active = 1;
    return 1;
}

int32_t gosh_term_disable_raw(int32_t fd) {
    if (!raw_mode_active) return 1;
    if (tcsetattr(fd, TCSAFLUSH, &orig_termios) < 0) {
        return 0;
    }
    raw_mode_active = 0;
    return 1;
}

int32_t gosh_term_read_byte(int32_t fd) {
    uint8_t c;
    ssize_t n = read(fd, &c, 1);
    if (n <= 0) {
        return -1;
    }
    return (int32_t)c;
}

int32_t gosh_term_get_size(int32_t fd, int32_t *rows, int32_t *cols) {
    struct winsize ws;
    if (ioctl(fd, TIOCGWINSZ, &ws) == -1 || ws.ws_col == 0) {
        *rows = 24;
        *cols = 80;
        return 0;
    }
    *rows = ws.ws_row;
    *cols = ws.ws_col;
    return 1;
}

int32_t gosh_chdir(gosh_slice_u8 path) {
    char pbuf[4096];
    slice_to_cstr(path, pbuf, sizeof(pbuf));
    return chdir(pbuf) == 0 ? 0 : -1;
}

int32_t gosh_getcwd(gosh_mut_slice_u8 out) {
    if (!out.data || out.len <= 0) return 0;
    if (getcwd((char *)out.data, (size_t)out.len) == NULL) {
        out.data[0] = '\0';
        return 0;
    }
    return (int32_t)strlen((char *)out.data);
}

int32_t gosh_is_dir(gosh_slice_u8 path) {
    char pbuf[4096];
    slice_to_cstr(path, pbuf, sizeof(pbuf));
    struct stat st;
    if (stat(pbuf, &st) != 0) return 0;
    return S_ISDIR(st.st_mode) ? 1 : 0;
}

int32_t gosh_is_executable(gosh_slice_u8 path) {
    char pbuf[4096];
    slice_to_cstr(path, pbuf, sizeof(pbuf));
    struct stat st;
    if (stat(pbuf, &st) != 0) return 0;
    if (S_ISDIR(st.st_mode)) return 0;
    return (access(pbuf, X_OK) == 0) ? 1 : 0;
}

int32_t gosh_file_exists(gosh_slice_u8 path) {
    char pbuf[4096];
    slice_to_cstr(path, pbuf, sizeof(pbuf));
    struct stat st;
    return (stat(pbuf, &st) == 0) ? 1 : 0;
}

static int32_t list_dir(gosh_slice_u8 path, gosh_mut_slice_u8 out, char separator) {
    char pbuf[4096];
    slice_to_cstr(path, pbuf, sizeof(pbuf));
    DIR *d = opendir(pbuf[0] ? pbuf : ".");
    if (!d) return -1;

    struct dirent *ent;
    int32_t written = 0;
    while ((ent = readdir(d)) != NULL) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) {
            continue;
        }
        int name_len = (int)strlen(ent->d_name);
        if (written + name_len + 1 > out.len) {
            if (separator == '\n') break;
            closedir(d);
            return -2;
        }
        memcpy(out.data + written, ent->d_name, name_len);
        written += name_len;
        out.data[written++] = separator;
    }
    closedir(d);
    return written;
}

/* Completion keeps its existing newline protocol; globbing uses NUL names. */
int32_t gosh_list_dir(gosh_slice_u8 path, gosh_mut_slice_u8 out) {
    return list_dir(path, out, '\n');
}

int32_t gosh_glob_list_dir(gosh_slice_u8 path, gosh_mut_slice_u8 out) {
    return list_dir(path, out, '\0');
}

int32_t gosh_setenv(gosh_slice_u8 key, gosh_slice_u8 val) {
    char kbuf[512], vbuf[4096];
    slice_to_cstr(key, kbuf, sizeof(kbuf));
    slice_to_cstr(val, vbuf, sizeof(vbuf));
    return setenv(kbuf, vbuf, 1) == 0 ? 0 : -1;
}

int32_t gosh_unsetenv(gosh_slice_u8 key) {
    char kbuf[512];
    slice_to_cstr(key, kbuf, sizeof(kbuf));
    return unsetenv(kbuf) == 0 ? 0 : -1;
}

int32_t gosh_getenv(gosh_slice_u8 key, gosh_mut_slice_u8 out) {
    char kbuf[512];
    slice_to_cstr(key, kbuf, sizeof(kbuf));
    const char *v = getenv(kbuf);
    if (!v) return -1;
    int len = (int)strlen(v);
    if (len >= out.len) len = out.len - 1;
    memcpy(out.data, v, len);
    out.data[len] = '\0';
    return len;
}

int32_t gosh_get_env_count(void) {
    int count = 0;
    if (!environ) return 0;
    while (environ[count]) count++;
    return count;
}

int32_t gosh_get_env_entry(int32_t index, gosh_mut_slice_u8 out_k, gosh_mut_slice_u8 out_v) {
    if (!environ || index < 0) return 0;
    int count = 0;
    while (environ[count]) {
        if (count == index) {
            const char *entry = environ[count];
            const char *eq = strchr(entry, '=');
            if (!eq) return 0;
            int klen = (int)(eq - entry);
            if (klen >= out_k.len) klen = out_k.len - 1;
            memcpy(out_k.data, entry, klen);
            out_k.data[klen] = '\0';

            const char *val = eq + 1;
            int vlen = (int)strlen(val);
            if (vlen >= out_v.len) vlen = out_v.len - 1;
            memcpy(out_v.data, val, vlen);
            out_v.data[vlen] = '\0';
            return 1;
        }
        count++;
    }
    return 0;
}

static void restore_signals_in_child(void) {
    signal(SIGINT, SIG_DFL);
    signal(SIGQUIT, SIG_DFL);
    signal(SIGTSTP, SIG_DFL);
    signal(SIGTTIN, SIG_DFL);
    signal(SIGTTOU, SIG_DFL);
    signal(SIGCHLD, SIG_DFL);
}

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
) {
    if (argc <= 0 || !packed_args.data || packed_args.len <= 0) {
        return -1;
    }

    char **c_argv = malloc((argc + 1) * sizeof(char *));
    if (!c_argv) return -1;

    const char *p = (const char *)packed_args.data;
    const char *end = p + packed_args.len;
    for (int i = 0; i < argc; i++) {
        if (p >= end) {
            c_argv[i] = "";
        } else {
            c_argv[i] = (char *)p;
            p += strlen(p) + 1;
        }
    }
    c_argv[argc] = NULL;

    char in_buf[4096] = {0};
    char out_buf[4096] = {0};
    char err_buf[4096] = {0};
    slice_to_cstr(in_file, in_buf, sizeof(in_buf));
    slice_to_cstr(out_file, out_buf, sizeof(out_buf));
    slice_to_cstr(err_file, err_buf, sizeof(err_buf));

    pid_t pid = fork();
    if (pid < 0) {
        free(c_argv);
        return -1;
    }

    if (pid == 0) {
        restore_signals_in_child();

        if (background) {
            setpgid(0, 0);
        }

        if (in_buf[0]) {
            int fd = open(in_buf, O_RDONLY);
            if (fd < 0) {
                fprintf(stderr, "gosh: cannot open %s: %s\n", in_buf, strerror(errno));
                _exit(1);
            }
            dup2(fd, STDIN_FILENO);
            close(fd);
        }

        if (out_buf[0]) {
            int flags = O_WRONLY | O_CREAT | (append_out ? O_APPEND : O_TRUNC);
            int fd = open(out_buf, flags, 0666);
            if (fd < 0) {
                fprintf(stderr, "gosh: cannot open %s: %s\n", out_buf, strerror(errno));
                _exit(1);
            }
            dup2(fd, STDOUT_FILENO);
            close(fd);
        }

        if (redirect_err_to_out) {
            dup2(STDOUT_FILENO, STDERR_FILENO);
        } else if (err_buf[0]) {
            int flags = O_WRONLY | O_CREAT | (append_err ? O_APPEND : O_TRUNC);
            int fd = open(err_buf, flags, 0666);
            if (fd < 0) {
                fprintf(stderr, "gosh: cannot open %s: %s\n", err_buf, strerror(errno));
                _exit(1);
            }
            dup2(fd, STDERR_FILENO);
            close(fd);
        }

        execvp(c_argv[0], c_argv);
        fprintf(stderr, "gosh: %s: %s\n", c_argv[0], strerror(errno));
        _exit(errno == ENOENT ? 127 : 126);
    }

    free(c_argv);

    if (child_pid) {
        *child_pid = (int32_t)pid;
    }

    if (background) {
        return 0;
    }

    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }

    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return status;
}

int32_t gosh_wait_pid(int32_t pid) {
    int status = 0;
    while (waitpid((pid_t)pid, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return status;
}

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
) {
    if (num_cmds <= 0) return 0;
    if (num_cmds == 1) {
        int32_t child_pid = 0;
        return gosh_exec_packed(
            packed_args, cmd_argcs[0],
            in_file, out_file, append_out,
            err_file, append_err, redirect_err_to_out,
            background, &child_pid
        );
    }

    int pipes[num_cmds - 1][2];
    for (int i = 0; i < num_cmds - 1; i++) {
        if (pipe(pipes[i]) < 0) {
            perror("gosh: pipe");
            return -1;
        }
    }

    pid_t pids[num_cmds];
    const char *p = (const char *)packed_args.data;
    const char *end = p + packed_args.len;

    char in_buf[4096] = {0};
    char out_buf[4096] = {0};
    char err_buf[4096] = {0};
    slice_to_cstr(in_file, in_buf, sizeof(in_buf));
    slice_to_cstr(out_file, out_buf, sizeof(out_buf));
    slice_to_cstr(err_file, err_buf, sizeof(err_buf));

    for (int i = 0; i < num_cmds; i++) {
        int argc = cmd_argcs[i];
        char **c_argv = malloc((argc + 1) * sizeof(char *));
        for (int k = 0; k < argc; k++) {
            if (p >= end) {
                c_argv[k] = "";
            } else {
                c_argv[k] = (char *)p;
                p += strlen(p) + 1;
            }
        }
        c_argv[argc] = NULL;

        pid_t pid = fork();
        if (pid < 0) {
            perror("gosh: fork");
            free(c_argv);
            return -1;
        }

        if (pid == 0) {
            restore_signals_in_child();

            if (i == 0) {
                if (in_buf[0]) {
                    int fd = open(in_buf, O_RDONLY);
                    if (fd >= 0) {
                        dup2(fd, STDIN_FILENO);
                        close(fd);
                    }
                }
            } else {
                dup2(pipes[i - 1][0], STDIN_FILENO);
            }

            if (i == num_cmds - 1) {
                if (out_buf[0]) {
                    int flags = O_WRONLY | O_CREAT | (append_out ? O_APPEND : O_TRUNC);
                    int fd = open(out_buf, flags, 0666);
                    if (fd >= 0) {
                        dup2(fd, STDOUT_FILENO);
                        close(fd);
                    }
                }
            } else {
                dup2(pipes[i][1], STDOUT_FILENO);
            }

            if (i == num_cmds - 1) {
                if (redirect_err_to_out) {
                    dup2(STDOUT_FILENO, STDERR_FILENO);
                } else if (err_buf[0]) {
                    int flags = O_WRONLY | O_CREAT | (append_err ? O_APPEND : O_TRUNC);
                    int fd = open(err_buf, flags, 0666);
                    if (fd >= 0) {
                        dup2(fd, STDERR_FILENO);
                        close(fd);
                    }
                }
            }

            for (int q = 0; q < num_cmds - 1; q++) {
                close(pipes[q][0]);
                close(pipes[q][1]);
            }

            execvp(c_argv[0], c_argv);
            fprintf(stderr, "gosh: %s: %s\n", c_argv[0], strerror(errno));
            _exit(errno == ENOENT ? 127 : 126);
        }

        free(c_argv);
        pids[i] = pid;
    }

    for (int i = 0; i < num_cmds - 1; i++) {
        close(pipes[i][0]);
        close(pipes[i][1]);
    }

    if (background) {
        return 0;
    }

    int last_status = 0;
    for (int i = 0; i < num_cmds; i++) {
        int status = 0;
        while (waitpid(pids[i], &status, 0) < 0) {
            if (errno != EINTR) break;
        }
        if (i == num_cmds - 1) {
            if (WIFEXITED(status)) {
                last_status = WEXITSTATUS(status);
            } else if (WIFSIGNALED(status)) {
                last_status = 128 + WTERMSIG(status);
            }
        }
    }

    return last_status;
}

int32_t gosh_capture_cmd_packed(
    gosh_slice_u8 packed_args,
    int32_t argc,
    gosh_mut_slice_u8 out
) {
    if (argc <= 0 || !packed_args.data || !out.data || out.len <= 0) {
        return 0;
    }

    int p[2];
    if (pipe(p) < 0) return 0;

    pid_t pid = fork();
    if (pid < 0) {
        close(p[0]);
        close(p[1]);
        return 0;
    }

    if (pid == 0) {
        close(p[0]);
        dup2(p[1], STDOUT_FILENO);
        close(p[1]);

        char **c_argv = malloc((argc + 1) * sizeof(char *));
        const char *arg_p = (const char *)packed_args.data;
        const char *end = arg_p + packed_args.len;
        for (int i = 0; i < argc; i++) {
            if (arg_p >= end) {
                c_argv[i] = "";
            } else {
                c_argv[i] = (char *)arg_p;
                arg_p += strlen(arg_p) + 1;
            }
        }
        c_argv[argc] = NULL;

        execvp(c_argv[0], c_argv);
        _exit(127);
    }

    close(p[1]);
    int32_t total = 0;
    while (total < out.len) {
        ssize_t n = read(p[0], out.data + total, (size_t)(out.len - total));
        if (n <= 0) break;
        total += (int32_t)n;
    }
    close(p[0]);

    int status = 0;
    waitpid(pid, &status, 0);

    while (total > 0 && (out.data[total - 1] == '\n' || out.data[total - 1] == '\r')) {
        total--;
    }
    return total;
}

int32_t gosh_redirect_begin(
    gosh_slice_u8 in_file,
    gosh_slice_u8 out_file,
    int32_t append_out,
    gosh_slice_u8 err_file,
    int32_t append_err,
    int32_t redirect_err_to_out,
    int32_t *saved_fds
) {
    /* saved_fds array of 3 ints: [saved_stdin, saved_stdout, saved_stderr] */
    saved_fds[0] = -1;
    saved_fds[1] = -1;
    saved_fds[2] = -1;

    char in_buf[4096] = {0};
    char out_buf[4096] = {0};
    char err_buf[4096] = {0};
    slice_to_cstr(in_file, in_buf, sizeof(in_buf));
    slice_to_cstr(out_file, out_buf, sizeof(out_buf));
    slice_to_cstr(err_file, err_buf, sizeof(err_buf));

    if (in_buf[0]) {
        int fd = open(in_buf, O_RDONLY);
        if (fd >= 0) {
            saved_fds[0] = dup(STDIN_FILENO);
            dup2(fd, STDIN_FILENO);
            close(fd);
        }
    }

    if (out_buf[0]) {
        int flags = O_WRONLY | O_CREAT | (append_out ? O_APPEND : O_TRUNC);
        int fd = open(out_buf, flags, 0666);
        if (fd >= 0) {
            saved_fds[1] = dup(STDOUT_FILENO);
            dup2(fd, STDOUT_FILENO);
            close(fd);
        }
    }

    if (redirect_err_to_out) {
        saved_fds[2] = dup(STDERR_FILENO);
        dup2(STDOUT_FILENO, STDERR_FILENO);
    } else if (err_buf[0]) {
        int flags = O_WRONLY | O_CREAT | (append_err ? O_APPEND : O_TRUNC);
        int fd = open(err_buf, flags, 0666);
        if (fd >= 0) {
            saved_fds[2] = dup(STDERR_FILENO);
            dup2(fd, STDERR_FILENO);
            close(fd);
        }
    }

    return 0;
}

void gosh_redirect_end(const int32_t *saved_fds) {
    if (!saved_fds) return;
    fflush(stdout);
    fflush(stderr);

    if (saved_fds[0] >= 0) {
        dup2(saved_fds[0], STDIN_FILENO);
        close(saved_fds[0]);
    }
    if (saved_fds[1] >= 0) {
        dup2(saved_fds[1], STDOUT_FILENO);
        close(saved_fds[1]);
    }
    if (saved_fds[2] >= 0) {
        dup2(saved_fds[2], STDERR_FILENO);
        close(saved_fds[2]);
    }
}

/* Save above stdio even when one of 0..2 is closed. Do not leak backups to exec. */
int32_t gosh_save_stdio(int32_t *saved_fds) {
    fflush(stdout);
    fflush(stderr);
    for (int i = 0; i < 3; i++) saved_fds[i] = -1;
    for (int i = 0; i < 3; i++) {
        int fd;
        do {
            fd = fcntl(i, F_DUPFD_CLOEXEC, 3);
        } while (fd < 0 && errno == EINTR);
        if (fd < 0 && errno != EBADF) {
            for (int j = 0; j < i; j++) {
                if (saved_fds[j] >= 0) close(saved_fds[j]);
            }
            return -1;
        }
        saved_fds[i] = fd;
    }
    return 0;
}

int32_t gosh_restore_stdio(const int32_t *saved_fds) {
    fflush(stdout);
    fflush(stderr);
    int32_t status = 0;
    for (int i = 0; i < 3; i++) {
        if (saved_fds[i] >= 0) {
            if (gosh_dup2(saved_fds[i], i) < 0) status = -1;
            close(saved_fds[i]);
        } else {
            if (close(i) < 0 && errno != EBADF) status = -1;
        }
    }
    /* A write to a temporarily closed stream must not poison later output. */
    clearerr(stdin);
    clearerr(stdout);
    clearerr(stderr);
    return status;
}

int32_t gosh_get_git_branch(gosh_mut_slice_u8 out) {
    char path[512] = ".git/HEAD";
    int fd = -1;
    char prefix[32] = "";

    for (int depth = 0; depth < 5; depth++) {
        snprintf(path, sizeof(path), "%s.git/HEAD", prefix);
        fd = open(path, O_RDONLY);
        if (fd >= 0) break;
        snprintf(path, sizeof(path), "%s.git", prefix);
        int gfd = open(path, O_RDONLY);
        if (gfd >= 0) {
            char gbuf[256];
            ssize_t gn = read(gfd, gbuf, sizeof(gbuf) - 1);
            close(gfd);
            if (gn > 8 && strncmp(gbuf, "gitdir: ", 8) == 0) {
                gbuf[gn] = '\0';
                char *nl = strchr(gbuf, '\n');
                if (nl) *nl = '\0';
                snprintf(path, sizeof(path), "%s/HEAD", gbuf + 8);
                fd = open(path, O_RDONLY);
                if (fd >= 0) break;
            }
        }
        strcat(prefix, "../");
    }

    if (fd < 0) return 0;

    char head_buf[256];
    ssize_t n = read(fd, head_buf, sizeof(head_buf) - 1);
    close(fd);
    if (n <= 0) return 0;
    head_buf[n] = '\0';

    const char *ref_prefix = "ref: refs/heads/";
    size_t ref_len = strlen(ref_prefix);
    char *branch_name = head_buf;
    if (strncmp(head_buf, ref_prefix, ref_len) == 0) {
        branch_name = head_buf + ref_len;
    }

    char *end = branch_name + strlen(branch_name) - 1;
    while (end >= branch_name && (*end == '\n' || *end == '\r' || *end == ' ')) {
        *end = '\0';
        end--;
    }

    int blen = (int)strlen(branch_name);
    if (blen >= out.len) blen = out.len - 1;
    memcpy(out.data, branch_name, blen);
    return blen;
}

static void sigint_handler(int sig) {
    (void)sig;
    write(STDOUT_FILENO, "\n", 1);
}

void gosh_init_signals(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sigint_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    sigaction(SIGINT, &sa, NULL);

    signal(SIGQUIT, SIG_IGN);
    signal(SIGTSTP, SIG_IGN);
    signal(SIGTTIN, SIG_IGN);
    signal(SIGTTOU, SIG_IGN);
}

void gosh_reset_signals(void) {
    restore_signals_in_child();
}

int32_t gosh_get_pid(void) {
    return (int32_t)getpid();
}

int32_t gosh_fork(void) {
    return (int32_t)fork();
}

int32_t gosh_pipe(int32_t *fds) {
    if (!fds) return -1;
    int p[2];
    if (pipe(p) < 0) return -1;
    fds[0] = p[0];
    fds[1] = p[1];
    return 0;
}

int32_t gosh_dup2(int32_t oldfd, int32_t newfd) {
    int result;
    do {
        result = dup2(oldfd, newfd);
    } while (result < 0 && errno == EINTR);
    return result;
}

void gosh_close(int32_t fd) {
    if (fd >= 0) {
        close(fd);
    }
}

void gosh_exit(int32_t code) {
    _exit(code);
}

int32_t gosh_open_file(gosh_slice_u8 path, int32_t mode) {
    char pbuf[4096];
    slice_to_cstr(path, pbuf, sizeof(pbuf));
    if (mode == 0) {
        return open(pbuf, O_RDONLY);
    } else if (mode == 1) {
        return open(pbuf, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    } else if (mode == 2) {
        return open(pbuf, O_WRONLY | O_CREAT | O_APPEND, 0666);
    }
    return -1;
}

int32_t gosh_execvp_packed(gosh_slice_u8 packed_args, int32_t argc) {
    if (argc <= 0 || !packed_args.data || packed_args.len <= 0) {
        return -1;
    }
    char **c_argv = malloc((argc + 1) * sizeof(char *));
    if (!c_argv) return -1;
    const char *p = (const char *)packed_args.data;
    const char *end = p + packed_args.len;
    for (int i = 0; i < argc; i++) {
        if (p >= end) {
            c_argv[i] = "";
        } else {
            c_argv[i] = (char *)p;
            p += strlen(p) + 1;
        }
    }
    c_argv[argc] = NULL;
    execvp(c_argv[0], c_argv);
    fprintf(stderr, "gosh: %s: %s\n", c_argv[0], strerror(errno));
    int err = (errno == ENOENT ? 127 : 126);
    free(c_argv);
    return err;
}

int32_t gosh_read_fd(int32_t fd, gosh_mut_slice_u8 out) {
    if (fd < 0 || !out.data || out.len <= 0) return 0;
    int32_t total = 0;
    while (total < out.len) {
        ssize_t n = read(fd, out.data + total, (size_t)(out.len - total));
        if (n <= 0) break;
        total += (int32_t)n;
    }
    return total;
}

int32_t gosh_kill(int32_t pid, int32_t sig) {
    return kill((pid_t)pid, sig);
}

int32_t gosh_setpgid(int32_t pid, int32_t pgid) {
    return setpgid((pid_t)pid, (pid_t)pgid);
}

int32_t gosh_tcsetpgrp(int32_t fd, int32_t pgrp) {
    return tcsetpgrp(fd, (pid_t)pgrp);
}

int32_t gosh_tcgetpgrp(int32_t fd) {
    return (int32_t)tcgetpgrp(fd);
}

int32_t gosh_poll_job(int32_t pid, int32_t *status) {
    int st = 0;
    pid_t res = waitpid((pid_t)pid, &st, WNOHANG | WUNTRACED | WCONTINUED);
    if (res == 0) {
        return 0; /* Still running */
    } else if (res > 0) {
        if (status) {
            if (WIFEXITED(st)) {
                *status = WEXITSTATUS(st);
            } else if (WIFSIGNALED(st)) {
                *status = 128 + WTERMSIG(st);
            } else {
                *status = st;
            }
        }
        return 1; /* Terminated or status changed */
    }
    /* If waitpid failed with ECHILD (e.g. called from pipeline subshell), check kill(pid, 0) */
    if (errno == ECHILD && kill((pid_t)pid, 0) == 0) {
        return 0; /* Still alive! */
    }
    return -1; /* No such process */
}
