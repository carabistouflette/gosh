# Contributing to GOSH

Thank you for your interest in contributing to **GOSH** (Goose Shell)! GOSH is an open-source Unix shell written primarily in the [Goose programming language](https://github.com/goose-lang), combining fast startup and execution with modern interactive features.

---

## Prerequisites

To build and contribute to GOSH, you will need:

1. **Goose Compiler**: Ensure `goose` is installed and available on your `$PATH`.
   - Verify with: `goose version`
2. **C Toolchain**: A standard C compiler (`gcc` or `clang`), required by Goose for compiling the native C interop layer and producing the final ELF binary.
   - Verify with: `gcc --version` or `clang --version`
3. **Python 3**: (Optional, for benchmarks) Python 3.8+ to run the benchmark suite.
   - Verify with: `python3 --version`

---

## Development Workflow

### 1. Clone the Repository
```bash
git clone https://github.com/AD1TYA-commits/gosh.git
cd gosh
```

### 2. Building GOSH
Build the executable from source using Goose:
```bash
goose build -o bin/gosh src/gosh.goose
```
This produces the standalone binary `bin/gosh`.

### 3. Testing Your Changes
Always run the automated test suite before committing changes:
```bash
./test/test_suite.sh
```
All tests must pass. If adding a new feature or fixing a bug, please add corresponding test cases to `test/test_suite.sh`.

### 4. Running Benchmarks
To evaluate performance impacts:
```bash
./bench/run_benchmarks.sh
```

---

## Architectural Principles

When writing or modifying code in GOSH, please keep the following design rules in mind:

- **Goose First**: GOSH is primarily written in Goose. Lexing, parsing, AST execution, variable expansion, builtins, line editing, and process management logic must reside in Goose (`src/*.goose`).
- **Minimal, Isolated C Interop**: Low-level POSIX system calls unavailable in the Goose standard library (e.g. `fork`, `execvp`, `pipe`, `dup2`, `tcsetattr`, `waitpid`) belong in `src/gosh_os.c` and `src/gosh_os.h`, wrapped cleanly via `src/gosh_os.goose`. Do not move high-level shell logic into C.
- **No External Runtime Dependencies**: GOSH builds into a self-contained native binary. Avoid introducing external third-party libraries.
- **Safety and Robustness**: Check return values of system calls and handle errors cleanly without crashing or leaving zombie processes.

---

## Submitting Pull Requests

1. Create a feature branch:
   ```bash
   git checkout -b feature/my-new-feature
   ```
2. Commit your changes with clear, descriptive commit messages.
3. Verify that `goose check src/gosh.goose` and `./test/test_suite.sh` pass cleanly.
4. Push your branch and open a Pull Request against the `main` branch.
