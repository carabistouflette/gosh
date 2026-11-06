<p align="center">
  <img src="assets/gosh-logo.png" alt="GOSH Goose Terminal Logo" width="500">
</p>

<h1 align="center">GOSH</h1>

**A Native Unix Shell Implemented in Goose with a POSIX C Backend**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Build: Native](https://img.shields.io/badge/Language-Goose-orange.svg)](https://github.com/goose-lang)
[![Tests: 43 Passing](https://img.shields.io/badge/Tests-43%20Passed-brightgreen.svg)](test/test_suite.sh)

---

## 1. Overview

**GOSH** (Goose Shell) is a native Unix command interpreter whose shell language implementation is written in **Goose**. It uses a substantial **C POSIX backend** for operating-system and process execution work that Goose currently accesses through an FFI boundary.

The Goose code owns the shell-facing logic: tokenization, parsing, expansion, shell state, builtins, command dispatch, and the interactive line editor. The C backend handles low-level terminal and process operations, and currently also contains parts of command execution such as process creation, external-program launching, pipeline setup, redirection, and command-output capture. So GOSH is Goose-based, but its execution backend is not C-free or limited to tiny syscall wrappers.

GOSH compiles into a native ELF binary using the Goose toolchain. It aims to combine lightweight startup with interactive features such as syntax highlighting, history autosuggestions, tab completion, and git-aware prompts.

---

## 2. Feature Overview

- **Native Binary Execution**: Compiles to an independent ELF binary with zero interpreter warm-up overhead.
- **Full Multi-Stage Pipelines**: Arbitrary command pipelines (`cmd1 | cmd2 | cmd3`) where any stage can be an external executable, a shell builtin, an alias, or a user-defined function.
- **Comprehensive Redirection**:
  - File redirection: `< input`, `> output`, `>> append`
  - Standard error redirection: `2> err`, `2>> err_app`
  - Merged descriptors: `2>&1`, `&>`
  - Redirections apply to external commands, builtins, subshells, and compound loop/conditional statements.
- **Subshell Isolation**: Grouped commands in `( ... )` run in a dedicated forked subshell process, isolating working directory changes and variable mutations from the parent shell.
- **Command & Arithmetic Substitutions**: Full nested command capture (`$(...)` and `` `...` ``) and arithmetic expression evaluation (`$(( ... ))`).
- **Control Flow & Compound Commands**: Standard `if/then/elif/else/fi`, `while/do/done`, and `for/in/do/done` loops.
- **Shell Functions & Aliases**: User-defined functions with positional parameter arguments (`$1`, `$2`, `$#`) and command aliases.
- **Process Management & Job Control**: Background process spawning (`cmd &`), active job tracking (`jobs`), and foreground/background job resumption (`fg`, `bg`).
- **Interactive Line Editor**:
  - Real-time syntax highlighting (valid executables/builtins, unknown commands, quotes, variables, operators)
  - Fish-style history autosuggestions (accepted via Right Arrow or Tab)
  - Tab completion for executables, builtins, files, and directories
  - Reverse interactive history search (`Ctrl+R`)
  - Git repository branch prompt detection

---

## 3. Installation & Compiler Requirements

### System Requirements
- **Operating System**: Linux (x86_64, aarch64) or compatible Unix-like environment.
- **Goose Compiler**: `goose` (tested with Goose v2026.3).
- **C Compiler**: `gcc` (recommended: GCC 10+) or `clang`, required by Goose for linking the native C runtime and producing the final binary.
- **Make / Build Tools**: Standard build utilities (`cmake`, `git`).

### Installing the Goose Compiler
If Goose is not already installed on your system, install it via the official repository:

```bash
# Verify Goose installation
goose version
```

---

## 4. Build from Source

Clone the repository and build the binary:

```bash
# 1. Clone repository
git clone https://github.com/voidssx1/gosh.git
cd gosh

# 2. Build GOSH executable using Goose
goose build -o bin/gosh src/gosh.goose

# 3. Verify build
./bin/gosh -v
```

### Optional: Install to User or System Path
To make `gosh` accessible globally:

```bash
# Install to user local bin (~/.local/bin)
mkdir -p ~/.local/bin
cp bin/gosh ~/.local/bin/

# Or install system-wide (requires sudo)
sudo install -m 755 bin/gosh /usr/local/bin/gosh
```

---

## 5. Usage Examples

### Interactive Shell
Launch the interactive REPL:
```bash
./bin/gosh
```

### Running Commands Directly (`-c`)
Evaluate shell commands or scripts from the command line:
```bash
./bin/gosh -c "echo 'hello world' | tr 'a-z' 'A-Z'"
```

### Executing Script Files
Execute a shell script file with arguments:
```bash
./bin/gosh script.gosh arg1 arg2
```

### Interactive & Scripting Examples

#### Multi-Stage Pipeline with Builtins
```bash
# GOSH executes builtins and external binaries seamlessly inside pipelines
alias ll='ls -la'
alias | grep ll
echo -e "orange\napple\nbanana" | sort | head -n 2
```

#### File & Descriptor Redirection
```bash
# Standard output and append
echo "first line" > output.txt
echo "second line" >> output.txt

# Stderr and merged redirection
ls /nonexistent_path 2> error.log
ls /nonexistent_path 2>&1 | grep "No such"

# Input redirection
cat < output.txt
```

#### Subshell Isolation
```bash
# Changes made inside subshells do not leak to the parent process
(cd /tmp && echo "Inside subshell: $PWD") && echo "In parent shell: $PWD"
```

#### Conditionals & Loops
```bash
# If/then/else evaluation
if test 10 -gt 5; then
    echo "10 is greater than 5"
else
    echo "condition failed"
fi

# For loop
for name in Alice Bob Charlie; do
    echo "Hello, $name!"
done

# While loop with arithmetic expansion
count=0
while test $count -lt 3; do
    echo "Count: $count"
    count=$((count + 1))
done
```

#### Shell Functions & Positional Parameters
```bash
greet() {
    echo "Welcome to GOSH, $1! Parameter count: $#"
}

greet "Developer"
```

#### Background Jobs
```bash
# Launch a background process and view it in jobs
sleep 5 &
jobs
```

---

## 6. Supported Builtins and Syntax

### Builtin Commands

| Builtin | Description |
|:---|:---|
| `cd [dir]` | Change directory (`-` toggles to `OLDPWD`, defaults to `HOME`) |
| `pwd` | Print absolute path of current working directory |
| `echo [-n] [-e] [args]` | Output arguments with optional newline suppression and escape interpretation |
| `printf format [args]` | Formatted output printing |
| `export [NAME=VAL]` | Set or mark shell variables for export to child environments |
| `unset [NAME...]` | Unset variables from shell state and environment |
| `set` | Display all currently defined shell variables |
| `alias [name=val]` | Define or display command aliases |
| `unalias [name...]` | Remove defined command alias |
| `type [name...]` | Identify how command would be resolved (alias, builtin, function, or binary) |
| `command cmd [args]` | Execute command bypassing shell functions and aliases |
| `source file` / `. file` | Read and execute commands from a file in the current shell environment |
| `test / [ expr ]` | Evaluate conditional expressions (string, file, and integer tests) |
| `jobs` | List active and recently completed background jobs |
| `fg [%n]` | Bring background job into the foreground |
| `bg [%n]` | Send `SIGCONT` to resume job in background |
| `history` | Display command history with line indices |
| `help` | Print summary of available builtins and shell features |
| `exit [code]` | Terminate shell with specified exit status code |

### Parameter & Word Expansions

- **Variable Expansion**: `$VAR`, `${VAR}`
- **Default Value**: `${VAR:-default}` (uses default if unset or empty)
- **String Length**: `${#VAR}`
- **Special Shell Parameters**:
  - `$?`: Exit status of the most recently executed pipeline/command
  - `$$`: Process ID of the shell process
  - `$!`: Process ID of the most recently started background job
  - `$#`: Number of positional arguments
  - `$0`: Shell or script name
  - `$1` .. `$9`: Positional arguments (or function parameters)
  - `$PWD`, `$OLDPWD`, `$HOME`, `$USER`, `$HOSTNAME`
- **Quoting Semantics**:
  - Single quotes (`'...'`): Preserve all characters verbatim (disables parameter and glob expansions).
  - Double quotes (`"..."`): Interpolate variables, command substitutions, and arithmetic while disabling globbing.
- **Arithmetic Expansion**: `$(( expr ))` with `+`, `-`, `*`, `/`, `%`, and parenthesized sub-expressions.
- **Command Substitution**: `$(command)` and `` `command` `` capturing output from subshells.
- **Filesystem Globbing**: Path wildcard matching for `*` and `?`.
- **Tilde Expansion**: `~` and `~/path` expanding to user `$HOME`.

---

## 7. Architecture Overview

GOSH is designed with a layered pipeline architecture:

```
Input Line -> Lexer -> AST Parser -> Expander -> Executor -> POSIX Interop
```

- **Lexer ([`src/lexer.goose`](src/lexer.goose))**: Tokenizes input, recognizing operators, keywords, quotes, and whitespace. Quotes are preserved to guide the expansion phase.
- **AST Parser ([`src/parser.goose`](src/parser.goose))**: Converts tokens into structured statements (`Statement`), pipelines (`Pipeline`), and commands (`Command`).
- **Expansion Engine ([`src/expansion.goose`](src/expansion.goose))**: Resolves parameters, arithmetic, command substitutions, and glob patterns prior to execution.
- **Executor ([`src/executor.goose`](src/executor.goose))**: Coordinates builtins, functions, multi-stage POSIX pipelines, subshells, and job management.
- **POSIX Backend ([`src/gosh_os.c`](src/gosh_os.c) / [`src/gosh_os.goose`](src/gosh_os.goose))**: C functions exposed to Goose through FFI. Besides OS interfaces such as terminal control, file descriptors, and signals, this backend currently implements significant process-execution machinery, including `fork`/`exec`, pipeline creation, redirection, waiting, and command-output capture. The Goose executor coordinates shell semantics and execution, while some low-level execution paths are implemented in C.
- **Line Editor ([`src/line_editor.goose`](src/line_editor.goose))**: Terminal raw-mode engine providing syntax highlighting, autosuggestions, and tab completion.

For comprehensive architectural specifications, refer to [**`docs/ARCHITECTURE.md`**](docs/ARCHITECTURE.md).

---

## 8. Performance Benchmarks

The following benchmarks compare GOSH against standard Unix shells (**GNU Bash 5.3** and **Zsh 5.9**).

### Benchmark Results (lower is better, wall-clock time in milliseconds)

| Benchmark | GOSH | Bash | Zsh |
|:---|---:|---:|---:|
| **Startup and exit** | **58.88 ms** | 105.63 ms | 122.71 ms |
| **Pipeline throughput** | **97.11 ms** | 129.15 ms | 145.43 ms |
| **Command substitution** | **50.48 ms** | 78.88 ms | 86.12 ms |
| **Function calls** | **4.18 ms** | 5.02 ms | 7.14 ms |
| **Arithmetic loop** | 8.13 ms | **4.81 ms** | 5.39 ms |

> [!NOTE]
> **Performance Analysis**:
> - **GOSH excels** in startup latency (~1.8x faster than Bash, ~2.1x faster than Zsh), pipeline creation, subshell command substitution, and function invocation due to direct native compilation and lightweight process setup.
> - **GOSH loses** on the reported arithmetic loop benchmark (8.13 ms vs Bash's 4.81 ms and Zsh's 5.39 ms). GOSH evaluates arithmetic expressions and while-loop conditions via recursive AST traversal on each iteration, whereas Bash and Zsh utilize flattened bytecode or optimized internal evaluators. Optimizing the arithmetic evaluator is part of the project roadmap.

### Benchmark Methodology, Environment & Limitations
- **Platform**: Linux 6.18.56 (x86_64), GCC 15.3.0, Goose v2026.3.
- **Methodology**: Benchmarks are automated via `bench/benchmark.py` and run using standard wall-clock precision (`time.perf_counter()`).
- **Reproducibility**: Run `./bench/run_benchmarks.sh` locally to reproduce these figures.
- **Environment-Specific Notice**: These results reflect execution on a dedicated Linux x86_64 workstation and should not be interpreted as universal performance claims across all platforms, hardware configurations, or workloads.

---

## 9. Automated Test Suite

GOSH includes a comprehensive automated test suite verifying correctness across all shell subsystems.

**Current Test Status**: **43 / 43 tests passing (100% pass rate)**.

To execute the test suite:
```bash
./test/test_suite.sh
```

### Test Coverage Areas
- Echo builtin and escape sequence handling (`-n`, `-e`)
- Working directory manipulation (`pwd`, `cd`, `cd -`, `OLDPWD`)
- Variable assignment, scoping, and parameter expansions
- Double quote expansion vs. single quote literal preservation
- Arithmetic expansions (`$((...))` operator precedence and grouping)
- Special shell parameters (`$?`, `$$`, `$!`, `$#`, `$0`, `$1`..`$9`)
- Command substitutions (`$(...)` and backticks)
- File and stream redirections (`>`, `>>`, `<`, `2>`, `2>&1`)
- Multi-stage pipelines (2-stage, 3-stage, and builtins in pipelines)
- Subshell isolation and subshell output redirection
- Control flow statements (`if/then/else/fi`, `while/do/done`, `for/in/do/done`)
- Shell functions with positional arguments
- Aliases and unaliasing
- Environment variable export and unsetting
- Background job spawning and `jobs` command output

---

## 10. Known Limitations & Compatibility Status

GOSH is under active development. The current release is focused on core POSIX shell functionality and interactive productivity.

- **POSIX Coverage**: GOSH implements a large subset of POSIX shell semantics, but is not yet fully POSIX.1-2017 compliant.
- **Here-Documents (`<<EOF`)**: Not yet implemented; planned for the upcoming release.
- **Case Statements (`case ... in ... esac`)**: Not yet implemented; `if/elif/else` should be used instead.
- **Arithmetic Operators**: Arithmetic expansion supports standard arithmetic (`+`, `-`, `*`, `/`, `%`) and parentheses, but does not currently support bitwise or ternary operators.
- **Terminal Raw Mode**: The interactive line editor relies on standard ANSI/VT100 escape codes; dumb terminals or non-standard terminal emulators may experience reduced formatting capabilities.

---

## 11. Roadmap

- [x] Native Goose compiler integration and standalone ELF compilation
- [x] Multi-stage pipeline execution with builtins and functions
- [x] Descriptor redirections (`<`, `>`, `>>`, `2>`, `2>>`, `2>&1`, `&>`)
- [x] Subshells `( ... )` and subshell redirection
- [x] Quoting semantics (single quote verbatim, double quote expansion)
- [x] Parameter expansions (`${VAR:-default}`, `${#VAR}`, special variables)
- [x] Interactive line editor with syntax highlighting and autosuggestions
- [x] Background job management (`&`, `jobs`, `fg`, `bg`)
- [ ] Here-documents (`<<EOF`) and here-strings (`<<<`)
- [ ] `case ... esac` statement parsing and pattern execution
- [ ] Arithmetic evaluator bytecode compilation (to match and exceed Bash loop throughput)
- [ ] Recursive globbing (`**/*.ext`)
- [ ] Programmable user-defined completion functions
- [x] Interactive user configuration file loading (`~/.goshrc`)

---

## 12. Contributing

Contributions are welcome! Please review [**`CONTRIBUTING.md`**](CONTRIBUTING.md) for details on development workflow, compiler prerequisites, and coding standards.

To report bugs or suggest enhancements, please open an issue on GitHub.

---

## 13. License

GOSH is open-source software licensed under the [**MIT License**](LICENSE).

Copyright &copy; 2026 Aditya Bohra.
