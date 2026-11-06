#!/usr/bin/env python3
"""Validate the Bash runner without requiring a Goose compiler or GOSH build."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SUITE = Path(__file__).with_name("test_suite.sh").read_text()
# Exercise the real setup, run_test function, and summary with focused cases.
SETUP = SUITE.split("# 1. Echo Builtin\n", 1)[0]
SUMMARY = SUITE.split("# Summary\n", 1)[1]


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gosh runner ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo with spaces"
        (self.repo / "test").mkdir(parents=True)
        (self.repo / "bin").mkdir()
        self.script = self.repo / "test/test_suite.sh"
        self.tmp = self.root / 'temp with spaces $literal `literal` "quote"'
        self.tmp.mkdir()
        self.env = dict(os.environ, TMPDIR=str(self.tmp))
        self.env.pop("GOSH", None)

    def binary(self, path=None, body='exec bash "$@"\n'):
        path = path or self.repo / "bin/gosh"
        path.write_text("#!/usr/bin/env bash\n" + body)
        path.chmod(0o755)
        return path

    def run_suite(self, cases=None):
        self.script.write_text(SUITE if cases is None else SETUP + cases + SUMMARY)
        result = subprocess.run(
            ["bash", str(self.script)], cwd=self.root, env=self.env,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=15,
        )
        self.assertEqual(list(self.tmp.iterdir()), [], result.stdout)
        return result

    def test_default_binary_from_other_directory(self):
        self.binary()
        result = self.run_suite('run_test "default" "echo ok" "ok"\n')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn(str(self.repo / "bin/gosh"), result.stdout)

    def test_override_with_spaces_and_relative_path(self):
        binary = self.binary(self.root / "custom gosh")
        for override in (str(binary), "./custom gosh"):
            with self.subTest(override=override):
                self.env["GOSH"] = override
                result = self.run_suite('run_test "override" "echo ok" "ok"\n')
                self.assertEqual(result.returncode, 0, result.stdout)

    def test_invalid_binaries_fail_before_tests(self):
        non_executable = self.binary()
        non_executable.chmod(0o644)
        for override, diagnostic in (
            (None, "not executable"),
            (str(self.root / "missing"), "missing or not a regular file"),
            (str(self.repo / "bin"), "missing or not a regular file"),
            ("", "missing or not a regular file"),
        ):
            with self.subTest(override=override):
                if override is not None:
                    self.env["GOSH"] = override
                result = self.run_suite()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(diagnostic, result.stdout)
                self.assertIn("set GOSH", result.stdout)
                self.assertNotIn("[PASS]", result.stdout)
                self.assertNotIn("[FAIL]", result.stdout)

    def test_missing_default_has_build_instruction(self):
        result = self.run_suite()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("goose build -o bin/gosh src/gosh.goose", result.stdout)
        self.assertIn(str(self.repo / "bin/gosh"), result.stdout)

    def test_output_status_and_continuation(self):
        self.binary()
        result = self.run_suite('''
run_test "default zero" "echo ok" "ok"
run_test "expected nonzero" "echo error >&2; exit 7" "error" 7
run_test "status mismatch" "echo ok; exit 7" "ok"
run_test "output mismatch" "echo wrong" "right"
run_test "nonzero mismatch" "exit 0" "" 7
run_test "after failures" "echo still-running" "still-running"
''')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Passed: 3", result.stdout)
        self.assertIn("Failed: 3", result.stdout)
        self.assertIn("Expected status: 0", result.stdout)
        self.assertIn("Actual status:   7", result.stdout)
        self.assertIn("[PASS]", result.stdout)
        self.assertIn("after failures", result.stdout)

    def test_redirection_paths_and_success_cleanup(self):
        self.binary()
        start = SUITE.index("# 5. Redirection")
        end = SUITE.index("# 6. Pipelines")
        result = self.run_suite(SUITE[start:end])
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("Passed: 5", result.stdout)

    def test_full_suite_reports_binary_failures_and_cleans_up(self):
        self.binary(body="exit 77\n")
        result = self.run_suite()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Passed: 0", result.stdout)
        self.assertIn("[FAIL]", result.stdout)
        self.assertIn("background job", result.stdout)
        self.assertIn("Actual status:   77", result.stdout)
        self.assertIn("Test Suite Finished", result.stdout)


if __name__ == "__main__":
    unittest.main()
