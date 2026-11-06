# GOSH Architecture & Technical Design

## 1. Overview

**GOSH** (Goose Shell) is a high-performance Unix shell written primarily in the **Goose programming language**, with a minimal and isolated C interoperability layer for low-level POSIX primitives.

GOSH compiles directly into a standalone ELF binary via the Goose toolchain (`goose build`), providing instant sub-millisecond startup, native memory safety, and high execution speed.

```
+-------------------------------------------------------------------------+
|                                 GOSH REPL                               |
|                  (Interactive Line Editor & Terminal Engine)             |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                        Lexer & Token Stream                             |
|               (lexer.goose: words, quotes, operators, keywords)          |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                         Parser & AST Construction                       |
|           (parser.goose: statements, pipelines, compounds, subshells)   |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                   Expansion Engine & Evaluator                          |
|         (expansion.goose: $VAR, ${V:-d}, $((arith)), $(cmd), ~glob)     |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                        Executor & Process Engine                        |
|   (executor.goose: pipelines, builtins, functions, job control, signals) |
+-------------------------------------------------------------------------+
            |                                               |
            v                                               v
+-----------------------+                       +-----------------------+
|   Builtin Functions   |                       |    POSIX OS Interop   |
|   (builtins.goose)    |                       | (gosh_os.c / .goose)  |
+-----------------------+                       +-----------------------+
```

## 2. Core Components

### 2.1 Lexer (`src/lexer.goose`)
- Converts raw input text into a sequence of typed tokens (`Token` struct).
- Operators: `|`, `&&`, `||`, `;`, `&`, `<`, `>`, `>>`, `2>`, `2>>`, `2>&1`, `&>`, `(`, `)`.
- Keywords: `if`, `then`, `elif`, `else`, `fi`, `while`, `until`, `for`, `in`, `do`, `done`, `function`.
- Quoting preserving tokenizer:
  - Single quotes (`'...'`): preserved as tokens so expansion engine treats content verbatim without parameter or glob expansion.
  - Double quotes (`"..."`): preserved so parameter and command substitutions occur while inhibiting globbing.

### 2.2 Parser (`src/parser.goose`)
- Builds an abstract statement list (`Statement[..8]`).
- Supported statements:
  - `STMT_PIPELINE`: Single command or multi-stage pipeline with conditional connectors (`&&`, `||`, `;`, `&`).
  - `STMT_SUBSHELL`: `( ... )` statements that isolate environment changes to a child process.
  - `STMT_IF`: `if COND; then THEN; [else ELSE;] fi`.
  - `STMT_WHILE`: `while COND; do BODY; done`.
  - `STMT_FOR`: `for VAR in WORDS; do BODY; done`.
  - `STMT_FUNC`: `name() { ... }` or `function name { ... }`.
- Redirection association: Redirections can be attached both to individual pipeline commands and to compound statements (`( ... ) > file`, `for ... done > file`).

### 2.3 Expansion Engine (`src/expansion.goose`)
- **Variable Expansion**: `$VAR`, `${VAR}`.
- **Default Fallback**: `${VAR:-default}`.
- **String Length**: `${#VAR}`.
- **Special Shell Parameters**:
  - `$?`: Exit code of previous command.
  - `$$`: PID of the shell.
  - `$!`: PID of most recent background job.
  - `$#`: Number of positional arguments.
  - `$0`: Program name.
  - `$1`, `$2`, ...: Positional arguments (or function arguments).
  - `$PWD`, `$OLDPWD`, `$HOME`, `$USER`, `$HOSTNAME`.
- **Arithmetic Expansion**: `$((expr))` evaluating `+`, `-`, `*`, `/`, `%`, and parentheses `( ... )`.
- **Command Substitution**: `$(cmd)` and `` `cmd` `` executing arbitrary subshell pipelines and capturing stdout.
- **Globbing**: `*` and `?` pattern expansion against the filesystem.
- **Tilde Expansion**: `~` and `~/path` expanding to `$HOME`.

### 2.4 Command & Pipeline Executor (`src/executor.goose`)
- **Single Command Execution**: Variable assignments, shell functions, aliases, builtins, and external binaries.
- **Multi-Stage Pipelines**:
  - Creates POSIX pipe arrays (`gosh_pipe`).
  - Forks child processes (`gosh_fork`) for each pipeline stage.
  - Sets up `stdin`/`stdout` redirection via `gosh_dup2`.
  - Executes builtins, functions, and external binaries seamlessly within any stage of the pipeline.
  - Properly closes pipe descriptors across all child processes and parent.
  - Returns the exit status of the final pipeline command.
- **Subshell Execution**: Forks a subshell process for `( ... )`, isolating directory changes and variable mutations.
- **Job Control & Background Tasks**:
  - Asynchronous execution using `&`.
  - Tracks jobs in `state.jobs` with process group assignment (`setpgid(0, 0)`).
  - `jobs`, `fg`, and `bg` builtins with non-blocking status polling (`gosh_poll_job`).

### 2.5 Native POSIX Interoperability (`src/gosh_os.c`, `src/gosh_os.h`, `src/gosh_os.goose`)
Isolated C wrapper providing access to fundamental operating system calls:
- Process control: `fork`, `execvp`, `waitpid`, `kill`, `setpgid`, `tcsetpgrp`, `tcgetpgrp`.
- File descriptors: `pipe`, `dup`, `dup2`, `open`, `close`, `read`.
- Terminal raw mode: `tcgetattr`, `tcsetattr`, `ioctl(TIOCGWINSZ)`.
- Filesystem & environment: `chdir`, `getcwd`, `opendir`, `readdir`, `setenv`, `unsetenv`.
- Signals: `sigaction(SIGINT)`, ignoring interactive signals, restoring child defaults.

### 2.6 Interactive Line Editor (`src/line_editor.goose`, `src/prompt.goose`)
- Raw terminal engine with VT100/ANSI escape sequences.
- Real-time syntax highlighting:
  - Green for valid executables and builtins.
  - Red for unrecognized commands.
  - Yellow for strings and quotes.
  - Magenta for variables.
  - Blue for operators.
- Fish-style ghost autosuggestions from history (accepted with Right Arrow or Tab).
- Zsh-style Tab completion for commands, files, and variables.
- Interactive reverse history search (`Ctrl+R`).
- Git-aware status prompt showing branch information.
