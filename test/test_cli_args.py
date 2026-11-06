#!/usr/bin/env python3
"""CLI argument regressions against a real GOSH build (GOSH overrides bin/gosh)."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


BINARY = Path(os.environ.get("GOSH", Path(__file__).resolve().parents[1] / "bin/gosh")).resolve()
COMMAND = 'echo "$0:$1:$2:$3:$#"'


class CliArgsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gosh-cli-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)

    def check_args(self, args, expected):
        result = subprocess.run(
            [str(BINARY), *args], env=dict(os.environ, HOME=str(self.home)),
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, expected + "\n")

    def test_command_without_operands(self):
        self.check_args(["-c", COMMAND], "gosh::::0")

    def test_command_name_only(self):
        self.check_args(["-c", COMMAND, "command-name"], "command-name::::0")

    def test_command_name_and_arguments(self):
        self.check_args(["-c", COMMAND, "command name", "first arg", "", "last"],
                        "command name:first arg::last:3")

    def test_script_file_arguments(self):
        script = self.home / "script with spaces.gosh"
        script.write_text(COMMAND + "\n")
        for args, suffix in (([], "::::0"), (["first arg", "", "last"], ":first arg::last:3")):
            with self.subTest(args=args):
                self.check_args([str(script), *args], str(script) + suffix)


if __name__ == "__main__":
    unittest.main()
