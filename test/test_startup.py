#!/usr/bin/env python3
"""Startup regressions against a real GOSH binary (GOSH overrides bin/gosh)."""

import os
from pathlib import Path
import pty
import subprocess
import tempfile
import unittest


BINARY = Path(os.environ.get("GOSH", Path(__file__).resolve().parents[1] / "bin/gosh")).resolve()


class StartupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gosh-startup-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.config = self.home / ".goshrc"
        # Output, state changes, and exit must all be ignored outside a TTY REPL.
        self.config.write_text("echo CONFIG_LOADED\ncd /\nexit 7\n")
        self.env = dict(os.environ, HOME=str(self.home))

    def run_gosh(self, args=(), terminal=False, input=None):
        if terminal:
            master, slave = pty.openpty()
            try:
                return subprocess.run(
                    [str(BINARY), *args], stdin=slave, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, env=self.env, cwd=self.home,
                    text=True, timeout=5,
                )
            finally:
                os.close(slave)
                os.close(master)
        return subprocess.run(
            [str(BINARY), *args], input=input, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, env=self.env, cwd=self.home,
            text=True, timeout=5,
        )

    def test_command_and_script_ignore_config_even_on_tty(self):
        script = self.home / "script.gosh"
        script.write_text("pwd\n")
        for terminal in (False, True):
            for args in (("-c", "pwd"), (str(script),)):
                with self.subTest(terminal=terminal, args=args):
                    result = self.run_gosh(args, terminal=terminal)
                    self.assertEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(result.stdout.strip(), str(self.home))

    def test_information_flags_ignore_config_even_on_tty(self):
        for terminal in (False, True):
            for flag in ("--help", "-h", "--version", "-v"):
                with self.subTest(terminal=terminal, flag=flag):
                    result = self.run_gosh((flag,), terminal=terminal)
                    self.assertEqual(result.returncode, 0, result.stdout)
                    self.assertNotIn("CONFIG_LOADED", result.stdout)
                    self.assertTrue(result.stdout.strip())

    def test_piped_input_ignores_config(self):
        result = self.run_gosh(input="pwd\n")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout.strip(), str(self.home))

    def test_interactive_config_has_initialized_state_and_stops_startup(self):
        for status in (0, 7):
            with self.subTest(status=status):
                self.config.write_text(
                    'echo CONFIG_LOADED\necho "$HOME"\necho "$GOSH_VERSION"\n'
                    'cd /\npwd\nexit ' + str(status) + '\necho UNREACHABLE\n'
                )
                result = self.run_gosh(terminal=True)
                self.assertEqual(result.returncode, status, result.stdout)
                # Exact output also rules out a welcome banner or prompt after exit.
                self.assertEqual(result.stdout.splitlines(),
                                 ["CONFIG_LOADED", str(self.home), "1.0.0", "/"])


if __name__ == "__main__":
    unittest.main()
