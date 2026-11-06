#!/usr/bin/env python3
"""
GOSH Reproducible Shell Benchmark Suite
Compares GOSH against Bash and Zsh on standard Unix workloads:
1. Startup latency (process initialization time)
2. Arithmetic loop throughput (looping + arithmetic evaluator)
3. Pipeline throughput (multi-process fork/exec/pipe)
4. Command substitution throughput (subshell output capture)
5. Shell function call overhead
"""

import os
import sys
import time
import shutil
import subprocess
import signal

# Seconds per validation or timed subprocess, including its child processes.
SUBPROCESS_TIMEOUT_SECONDS = 10.0

SHELLS = {}

# Locate shells
gosh_bin = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "bin", "gosh"))
if os.path.isfile(gosh_bin) and os.access(gosh_bin, os.X_OK):
    SHELLS["gosh"] = gosh_bin

for name in ["bash", "zsh", "sh"]:
    p = shutil.which(name)
    if p:
        SHELLS[name] = p

BENCHMARKS = [
    {
        "id": "startup",
        "name": "Shell Startup & Exit (50 runs)",
        "desc": "Measures cold process spawn and shell initialization overhead",
        "cmd": "exit 0",
        "expected_stdout": b"",
        "iterations": 50,
        "run_per_iter": True,
    },
    {
        "id": "arith_loop",
        "name": "Arithmetic Loop (1,000 iterations)",
        "desc": "Evaluates while loop, conditional test, and $((i + 1)) arithmetic evaluation",
        "cmd": "i=0; while test $i -lt 1000; do i=$((i + 1)); done",
        "check_cmd": "i=0; while test $i -lt 1000; do i=$((i + 1)); done; echo $i",
        "expected_stdout": b"1000\n",
        "iterations": 5,
        "run_per_iter": False,
    },
    {
        "id": "pipeline",
        "name": "Pipeline Throughput (30 runs)",
        "desc": "3-stage pipeline (printf | sort | head) measuring fork, pipe, and IPC coordination",
        "cmd": "printf '%s\\n' cherry apple banana date | sort | head -n 2",
        "expected_stdout": b"apple\nbanana\n",
        "iterations": 30,
        "run_per_iter": True,
    },
    {
        "id": "cmd_sub",
        "name": "Command Substitution (30 runs)",
        "desc": "Subshell output capture: echo $(echo benchmark_value)",
        "cmd": "echo $(echo benchmark_value)",
        "expected_stdout": b"benchmark_value\n",
        "iterations": 30,
        "run_per_iter": True,
    },
    {
        "id": "func_calls",
        "name": "Function Call Overhead (200 calls)",
        "desc": "Function invocation with arguments and redirection",
        "cmd": "f() { echo $1; }; i=0; while test $i -lt 200; do f $i >/dev/null; i=$((i + 1)); done",
        # Expose each call's output in the untimed correctness check.
        "check_cmd": "f() { echo $1; }; i=0; while test $i -lt 200; do f $i; i=$((i + 1)); done; echo $i",
        "expected_stdout": "".join(f"{i}\n" for i in range(201)).encode(),
        "iterations": 5,
        "run_per_iter": False,
    },
]


class BenchmarkFailure(RuntimeError):
    """A failed check or sample invalidates the entire benchmark result."""


def run_command(shell_path, command, phase, capture_output=False):
    # A separate process group lets a timeout stop pipelines/subshells too.
    try:
        with subprocess.Popen(
            [shell_path, "-c", command],
            stdout=subprocess.PIPE if capture_output else subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            env=dict(os.environ, LC_ALL="C"),
            start_new_session=True,
        ) as proc:
            try:
                stdout, stderr = proc.communicate(timeout=SUBPROCESS_TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired as exc:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.communicate()
                raise BenchmarkFailure(
                    f"{phase}: timed out after {SUBPROCESS_TIMEOUT_SECONDS:g} s"
                ) from exc
            if proc.returncode != 0:
                detail = stderr.decode(errors="replace").strip()[:200]
                raise BenchmarkFailure(
                    f"{phase}: exit status {proc.returncode}" + (f": {detail}" if detail else "")
                )
            return stdout
    except OSError as exc:
        raise BenchmarkFailure(f"{phase}: could not execute {shell_path}: {exc}") from exc


def run_benchmark(shell_path, bench):
    if bench["iterations"] <= 0:
        raise ValueError("iterations must be positive")

    output = run_command(
        shell_path, bench.get("check_cmd", bench["cmd"]), "validation", capture_output=True
    )
    if output != bench["expected_stdout"]:
        raise BenchmarkFailure(
            f"validation: incorrect output (expected {bench['expected_stdout'][:200]!r}, "
            f"got {output[:200]!r})"
        )

    times = []
    for iteration in range(bench["iterations"]):
        t0 = time.perf_counter()
        run_command(shell_path, bench["cmd"], f"iteration {iteration + 1}/{bench['iterations']}")
        times.append(time.perf_counter() - t0)
    elapsed_ms = sum(times) * 1000.0
    return elapsed_ms if bench["run_per_iter"] else elapsed_ms / len(times)


def result_unit(bench):
    return "ms total" if bench["run_per_iter"] else "ms/run (mean)"


def markdown_cell(value):
    return str(value).replace("|", "\\|").replace("\n", " ")


def main(report_path=None):
    print("=" * 72)
    print(" GOSH REPRODUCIBLE BENCHMARK SUITE")
    print(" Detected Shells:")
    for name, path in SHELLS.items():
        print(f"   - {name:<6}: {path}")
    print("=" * 72)

    results = {b["id"]: {} for b in BENCHMARKS}
    failed = False

    for b in BENCHMARKS:
        print(f"\nRunning Benchmark: {b['name']} ...")
        for shell_name, shell_path in SHELLS.items():
            print(f"  Measuring {shell_name:<6} ...", end="", flush=True)
            try:
                elapsed_ms = run_benchmark(shell_path, b)
            except BenchmarkFailure as exc:
                failed = True
                result = f"FAILED: {exc}"
                print(f" {result}")
            else:
                result = f"{elapsed_ms:.2f}"
                print(f" {result} {result_unit(b)}")
            results[b["id"]][shell_name] = result

    # Generate Markdown Table Report
    report_lines = []
    report_lines.append("# GOSH Benchmark Results")
    report_lines.append("")
    report_lines.append(f"**Execution Date**: {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}")
    report_lines.append(f"**Platform**: Linux ({os.uname().machine}, {os.uname().release})")
    report_lines.append("")
    report_lines.append("### Evaluated Shells")
    for name, path in SHELLS.items():
        report_lines.append(f"- **{name}**: `{path}`")
    report_lines.append("")
    report_lines.append("### Results Summary (lower is better, in milliseconds)")
    report_lines.append("")
    report_lines.append("Each workload is validated before timing. Any failed check, nonzero exit, "
                        "launch error, or timeout invalidates the whole cell; partial timings are discarded.")
    report_lines.append(f"Per-process timeout: {SUBPROCESS_TIMEOUT_SECONDS:g} s. "
                        "Validation runs are excluded from timings; LC_ALL=C.")
    report_lines.append("")

    header = "| Benchmark | Description | Unit |"
    sep = "|:---|:---|:---|"
    for s in SHELLS:
        header += f" {s} |"
        sep += "---:|"
    report_lines.append(header)
    report_lines.append(sep)

    for b in BENCHMARKS:
        row = f"| **{b['name']}** | {markdown_cell(b['desc'])} | {result_unit(b)} |"
        for s in SHELLS:
            row += f" {markdown_cell(results[b['id']][s])} |"
        report_lines.append(row)

    report_lines.append("")
    report_content = "\n".join(report_lines)

    if report_path is None:
        report_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "BENCHMARK_RESULTS.md"))
    with open(report_path, "w") as f:
        f.write(report_content)

    print("\n" + "=" * 72)
    print(" BENCHMARK RESULTS (Summary Table)")
    print("=" * 72)
    print(report_content)
    print(f"\nFull report written to: {report_path}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
