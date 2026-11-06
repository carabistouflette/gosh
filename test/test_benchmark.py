"""Run with python3 -m unittest discover -s test -p 'test_benchmark.py'."""

import contextlib
import io
from pathlib import Path
import shutil
import tempfile
import time
import unittest
from unittest.mock import patch

from bench import benchmark


class BenchmarkTests(unittest.TestCase):
    def workload(self, **changes):
        return dict(benchmark.BENCHMARKS[0], iterations=2, **changes)

    def test_false_never_produces_a_timing(self):
        for original in benchmark.BENCHMARKS[:2]:
            with self.subTest(benchmark=original['id']):
                with self.assertRaisesRegex(benchmark.BenchmarkFailure, 'validation.*exit status 1'):
                    benchmark.run_benchmark('/usr/bin/false', dict(original, iterations=2))

    def test_incorrect_output_is_rejected_before_timing(self):
        with patch.object(benchmark.time, 'perf_counter') as clock:
            with self.assertRaisesRegex(benchmark.BenchmarkFailure, 'validation: incorrect output'):
                benchmark.run_benchmark('/bin/sh', self.workload(cmd='echo wrong'))
            clock.assert_not_called()

    def test_successful_noop_cannot_pass_workload_validation(self):
        for bench in benchmark.BENCHMARKS[1:]:
            with self.subTest(workload=bench['id']):
                with self.assertRaisesRegex(benchmark.BenchmarkFailure, 'validation: incorrect output'):
                    benchmark.run_benchmark('/usr/bin/true', bench)

    def test_missing_executable_is_explicit(self):
        with self.assertRaisesRegex(benchmark.BenchmarkFailure, 'validation: could not execute'):
            benchmark.run_benchmark('/does/not/exist', self.workload())

    def test_partial_success_is_rejected_in_both_modes(self):
        # Validation and the first sample succeed; the second sample fails.
        with tempfile.TemporaryDirectory() as directory:
            counter = Path(directory) / 'counter'
            shell = Path(directory) / 'shell'
            shell.write_text(
                '#!/bin/sh\n'
                f'n=$(cat "{counter}" 2>/dev/null || echo 0)\n'
                'n=$((n + 1))\n'
                f'echo "$n" > "{counter}"\n'
                'if test "$n" -eq 3; then echo broken >&2; exit 7; fi\n'
                'exec /bin/sh "$@"\n'
            )
            shell.chmod(0o700)
            for mode in (True, False):
                with self.subTest(run_per_iter=mode):
                    counter.unlink(missing_ok=True)
                    with self.assertRaisesRegex(
                        benchmark.BenchmarkFailure, 'iteration 2/2: exit status 7: broken'
                    ):
                        benchmark.run_benchmark(str(shell), self.workload(run_per_iter=mode))

    def test_timeouts_in_validation_and_timing(self):
        for check_cmd, phase in [('sleep 5', 'validation'), ('exit 0', 'iteration 1/2')]:
            with self.subTest(phase=phase):
                with patch.object(benchmark, 'SUBPROCESS_TIMEOUT_SECONDS', 0.05):
                    with self.assertRaisesRegex(benchmark.BenchmarkFailure, phase + ': timed out after 0.05 s'):
                        benchmark.run_benchmark('/bin/sh', self.workload(cmd='sleep 5', check_cmd=check_cmd))

    def test_timeout_stops_child_processes(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / 'survived'
            command = f'(sleep 0.4; echo survived > "{marker}") & wait'
            with patch.object(benchmark, 'SUBPROCESS_TIMEOUT_SECONDS', 0.05):
                with self.assertRaisesRegex(benchmark.BenchmarkFailure, 'timed out'):
                    benchmark.run_command('/bin/sh', command, 'validation', capture_output=True)
            time.sleep(0.5)
            self.assertFalse(marker.exists(), 'a child survived the timeout')

    def test_aggregation_and_validation_exclusion(self):
        for mode, expected in [(True, 750.0), (False, 375.0)]:
            with self.subTest(run_per_iter=mode):
                # Two measured runs take 0.25 and 0.50 seconds. Validation uses no clock calls.
                with patch.object(benchmark.time, 'perf_counter', side_effect=[1, 1.25, 2, 2.5]):
                    actual = benchmark.run_benchmark('/bin/sh', self.workload(run_per_iter=mode))
                self.assertEqual(actual, expected)

    def test_empty_sample_set_is_rejected(self):
        bench = self.workload()
        bench['iterations'] = 0
        with self.assertRaisesRegex(ValueError, 'iterations must be positive'):
            benchmark.run_benchmark('/bin/sh', bench)

    def test_all_workloads_on_available_reference_shells(self):
        for shell in ('bash', 'sh', 'zsh'):
            path = shutil.which(shell)
            if path is None:
                continue
            for bench in benchmark.BENCHMARKS:
                with self.subTest(shell=shell, workload=bench['id']):
                    self.assertGreater(benchmark.run_benchmark(path, dict(bench, iterations=1)), 0)

    def test_report_preserves_failures_continues_and_labels_units(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'results.md'
            console = io.StringIO()
            with patch.object(benchmark, 'SHELLS', {'false': '/usr/bin/false', 'sh': '/bin/sh'}):
                with contextlib.redirect_stdout(console):
                    status = benchmark.main(report)
            self.assertEqual(status, 1)
            content = report.read_text()
            self.assertEqual(content.count('FAILED: validation: exit status 1'), 5)
            self.assertIn('FAILED: validation: exit status 1', console.getvalue())
            self.assertIn('ms total', content)
            self.assertIn('ms/run (mean)', content)
            self.assertIn('printf \\| sort \\| head', content)
            self.assertNotIn('nan', content)
            self.assertNotIn('Key Observations', content)
            for row in content.splitlines():
                if row.startswith('| **'):
                    self.assertRegex(row, r'\| \d+\.\d{2} \|$')

    def test_successful_report_returns_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(benchmark, 'SHELLS', {'sh': '/bin/sh'}):
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(benchmark.main(Path(directory) / 'results.md'), 0)


if __name__ == '__main__':
    unittest.main()
